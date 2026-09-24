import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_constants.dart';
import 'audio_router_service.dart';
import 'discovery_service.dart';
import 'storage_service.dart';

enum CallState { idle, connecting, connected, transmitting, disconnected, error }

class WebRtcService {
  static final WebRtcService _instance = WebRtcService._internal();
  factory WebRtcService() => _instance;
  WebRtcService._internal();

  final AudioRouterService _audioRouter = AudioRouterService();

  MediaStream? _localStream;
  MediaStream? get localStream => _localStream;

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, String> _peerIps = {};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};
  String _myDeviceId = '';
  String _familyCode = '';
  Timer? _handshakeTimer;

  // Peak Limiter & Acoustic Protection (Default 75% digital ceiling)
  double _audioCeiling = 0.75;
  double get audioCeiling => _audioCeiling;

  void setAudioCeiling(double ceiling) {
    _audioCeiling = ceiling.clamp(0.1, 1.0);
    _audioRouter.setVolumeCeiling(_audioCeiling);
  }

  Future<void> setSpeakerphoneMode(bool enable) async {
    try {
      await _audioRouter.setSpeakerphoneOn(enable);
    } catch (e) {
      developer.log('Error setting audio router speakerphone: $e', name: 'WebRtcService');
    }
    try {
      await Helper.setSpeakerphoneOn(enable);
    } catch (e) {
      developer.log('Error setting WebRTC Helper speakerphone: $e', name: 'WebRtcService');
    }
    await StorageService().setSpeakerphoneEnabled(enable);
  }

  void setMemberMuted(String memberId, bool muted) {
    StorageService().setMemberMuted(memberId, muted);
    final stream = _remoteStreams[memberId];
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !muted;
      }
    }
  }

  HttpServer? _lanSignalingServer;

  CallState _callState = CallState.idle;
  CallState get callState => _callState;

  bool _isMicMuted = true;
  bool get isMicMuted => _isMicMuted;

  StreamSubscription? _signalingSubscription;
  StreamSubscription? _chimeSubscription;
  StreamSubscription? _emergencySubscription;

  // Callbacks for UI updates
  Function(CallState state)? onCallStateChanged;
  Function(String senderId, String senderName)? onIncomingChime;
  Function(String senderId, String senderName)? onIncomingEmergencyAlert;
  Function(String peerId, MediaStream stream)? onRemoteStreamAdded;

  final Map<String, dynamic> _rtcConfiguration = {
    'iceServers': [
      {'urls': AppConstants.defaultStunServer},
    ],
    'sdpSemantics': 'unified-plan',
  };

  final Map<String, dynamic> _mediaConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'googEchoCancellation': true,
      'googAutoGainControl': true,
      'googNoiseSuppression': true,
      'googHighpassFilter': true,
    },
    'video': false,
  };

  /// Initialize local audio input & output settings
  Future<void> initialize() async {
    try {
      if (WebRTC.platformIsAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration(androidAudioMode: AndroidAudioMode.inCommunication),
        );
      }
      _localStream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);
      // Load user audio ceiling limiter
      _audioCeiling = StorageService().audioCeiling;
      // Start muted for Push-To-Talk
      setMicMute(true);
      // Ensure speakerphone or earpiece mode is respected and physical volume ceiling is applied
      final speakerEnabled = StorageService().isSpeakerphoneEnabled;
      await _audioRouter.setSpeakerphoneOn(speakerEnabled);
      try {
        await Helper.setSpeakerphoneOn(speakerEnabled);
      } catch (e) {
        developer.log('Helper.setSpeakerphoneOn error: $e', name: 'WebRtcService');
      }
      await _audioRouter.setVolumeCeiling(_audioCeiling);

      // Listen for hardware Focus Mode transitions to immediately cut active voice streams
      _audioRouter.onFocusModeChanged = (active) {
        onFocusModeChanged(active);
      };
    } catch (e) {
      developer.log('Error acquiring user audio media: $e', name: 'WebRtcService');
    }
  }

  /// Directly acquire hardware microphone and enable audio tracks (Android green indicator)
  Future<MediaStream> acquireHardwareMic() async {
    try {
      if (WebRTC.platformIsAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration(androidAudioMode: AndroidAudioMode.inCommunication),
        );
      }
      if (_localStream == null) {
        _localStream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);
      }
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = true;
      }
      _isMicMuted = false;
      _setCallState(CallState.transmitting);
      final speakerEnabled = StorageService().isSpeakerphoneEnabled;
      await _audioRouter.setSpeakerphoneOn(speakerEnabled);
      try {
        await Helper.setSpeakerphoneOn(speakerEnabled);
      } catch (e) {
        developer.log('Helper.setSpeakerphoneOn error: $e', name: 'WebRtcService');
      }
    } catch (e) {
      developer.log('Error acquiring hardware mic: $e', name: 'WebRtcService');
    }
    return _localStream!;
  }

  /// Directly disable audio tracks when PTT is released
  void releaseHardwareMic() {
    _isMicMuted = true;
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = false;
      }
    }
    _setCallState(CallState.connected);
    if (_remoteStreams.isEmpty) {
      _audioRouter.resetAudioMode();
    }
  }

  /// Start listening for incoming WebRTC signaling and Chime alerts via Local HTTP (port 8889) and Firebase
  void startSignalingListener({
    required String familyCode,
    required String myDeviceId,
  }) {
    _familyCode = familyCode;
    _myDeviceId = myDeviceId;
    _startLanSignalingServer();

    if (familyCode.isEmpty || myDeviceId.isEmpty) return;

    try {
      final DatabaseReference signalingRef = FirebaseDatabase.instance
          .ref('foyers/$familyCode/signaling/$myDeviceId');

      _signalingSubscription?.cancel();
      _signalingSubscription = signalingRef.onChildAdded.listen((event) async {
        final key = event.snapshot.key;
        final data = event.snapshot.value;

        if (key == null || data == null || data is! Map) return;

        // EPHEMERAL CONSUMPTION: Delete node immediately from Firebase
        await signalingRef.child(key).remove();
        developer.log('Ephemeral signaling node $key consumed and removed immediately', name: 'WebRtcService');

        final type = data['type']?.toString();
        final fromId = data['from']?.toString() ?? '';
        final sdp = data['sdp']?.toString();
        final candidateMap = data['candidate'];

        if (type == 'offer' && sdp != null) {
          await _handleIncomingOffer(fromId, sdp, familyCode, myDeviceId);
        } else if (type == 'answer' && sdp != null) {
          await _handleIncomingAnswer(fromId, sdp);
        } else if (type == 'candidate' && candidateMap is Map) {
          await _handleIncomingCandidate(fromId, candidateMap);
        }
      });

      // Listen for instant chime alerts
      final DatabaseReference chimeRef = FirebaseDatabase.instance
          .ref('foyers/$familyCode/chimes/$myDeviceId');

      _chimeSubscription?.cancel();
      _chimeSubscription = chimeRef.onChildAdded.listen((event) async {
        final key = event.snapshot.key;
        final data = event.snapshot.value;

        if (key == null || data == null || data is! Map) return;

        // EPHEMERAL CONSUMPTION: Delete chime node immediately
        await chimeRef.child(key).remove();

        final senderId = data['senderId']?.toString() ?? '';
        final senderName = data['senderName']?.toString() ?? 'Membre';

        if (_audioRouter.isFocusModeActive || StorageService().isSleepShieldActive || StorageService().isMemberBlocked(senderId)) {
          developer.log('Chime dropped: Focus Mode or Sleep Shield active or member blocked', name: 'WebRtcService');
          return;
        }

        developer.log('Received instant chime alert from $senderName ($senderId)', name: 'WebRtcService');
        await _audioRouter.playChimeAlert();
        onIncomingChime?.call(senderId, senderName);
      });

      // 3. Listen to incoming Level 2 Emergency Alert signals
      final DatabaseReference emergencyRef = FirebaseDatabase.instance
          .ref('foyers/$familyCode/emergency/$myDeviceId');

      _emergencySubscription = emergencyRef.onChildAdded.listen((event) async {
        final key = event.snapshot.key;
        final data = event.snapshot.value;

        if (key == null || data == null || data is! Map) return;

        await emergencyRef.child(key).remove();

        final senderId = data['senderId']?.toString() ?? '';
        final senderName = data['senderName']?.toString() ?? 'Membre';

        if (senderId.isNotEmpty && !StorageService().isMemberBlocked(senderId)) {
          developer.log('Received Firebase emergency alert from $senderName ($senderId)', name: 'WebRtcService');
          await _audioRouter.startEmergencyAlert();
          onIncomingEmergencyAlert?.call(senderId, senderName);
        }
      });
    } catch (e) {
      developer.log('Firebase signaling listener error (WAN offline mode active): $e', name: 'WebRtcService');
    }
  }

  /// Cut immediately all signaling listeners and background servers of current foyer
  void stopSignalingListener() {
    _signalingSubscription?.cancel();
    _signalingSubscription = null;
    _chimeSubscription?.cancel();
    _chimeSubscription = null;
    _emergencySubscription?.cancel();
    _emergencySubscription = null;
    _lanSignalingServer?.close(force: true);
    _lanSignalingServer = null;
    developer.log('Signaling listener and LAN server stopped', name: 'WebRtcService');
  }

  /// Trigger instant high-priority chime alert on a target member's device (LAN direct first, Firebase fallback)
  Future<void> sendChimeAlert({
    required String familyCode,
    required String myDeviceId,
    required String myName,
    required String targetDeviceId,
  }) async {
    _myDeviceId = myDeviceId;
    _familyCode = familyCode;

    // 1. Autonomous LAN Direct Chime Alert (Port 8889)
    final peerIp = _findPeerIp(targetDeviceId);
    if (peerIp != null && peerIp.isNotEmpty) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(milliseconds: 1500);
        final request = await client.postUrl(Uri.parse('http://$peerIp:8889/'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'type': 'chime',
          'from': myDeviceId,
          'senderId': myDeviceId,
          'senderName': myName,
        }));
        final response = await request.close();
        client.close();
        if (response.statusCode == HttpStatus.ok) {
          developer.log('Direct LAN chime alert delivered to $targetDeviceId ($peerIp:8889)', name: 'WebRtcService');
          return;
        }
      } catch (e) {
        developer.log('Direct LAN chime to $peerIp:8889 failed ($e), falling back to Firebase', name: 'WebRtcService');
      }
    }

    // 2. WAN Firebase Chime Fallback
    if (familyCode.isNotEmpty) {
      try {
        final DatabaseReference targetChimeRef = FirebaseDatabase.instance
            .ref('foyers/$familyCode/chimes/$targetDeviceId');

        await targetChimeRef.push().set({
          'senderId': myDeviceId,
          'senderName': myName,
          'timestamp': ServerValue.timestamp,
        });
      } catch (e) {
        developer.log('Error sending chime alert via Firebase: $e', name: 'WebRtcService');
      }
    }
  }

  /// Trigger Level 2 Continuous Emergency Alarm on a target member's device (LAN direct first, Firebase fallback)
  Future<void> sendEmergencyAlert({
    required String familyCode,
    required String myDeviceId,
    required String myName,
    required String targetDeviceId,
  }) async {
    _myDeviceId = myDeviceId;
    _familyCode = familyCode;

    // 1. Autonomous LAN Direct Emergency Alert (Port 8889)
    final peerIp = _findPeerIp(targetDeviceId);
    if (peerIp != null && peerIp.isNotEmpty) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(milliseconds: 1500);
        final request = await client.postUrl(Uri.parse('http://$peerIp:8889/'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'type': 'emergency_alert',
          'from': myDeviceId,
          'senderId': myDeviceId,
          'senderName': myName,
        }));
        final response = await request.close();
        client.close();
        if (response.statusCode == HttpStatus.ok) {
          developer.log('Direct LAN emergency alert delivered to $targetDeviceId ($peerIp:8889)', name: 'WebRtcService');
          return;
        }
      } catch (e) {
        developer.log('Direct LAN emergency alert to $peerIp:8889 failed ($e), falling back to Firebase', name: 'WebRtcService');
      }
    }

    // 2. WAN Firebase Emergency Fallback
    if (familyCode.isNotEmpty) {
      try {
        final DatabaseReference targetEmergencyRef = FirebaseDatabase.instance
            .ref('foyers/$familyCode/emergency/$targetDeviceId');

        await targetEmergencyRef.push().set({
          'senderId': myDeviceId,
          'senderName': myName,
          'timestamp': ServerValue.timestamp,
        });
      } catch (e) {
        developer.log('Error sending emergency alert via Firebase: $e', name: 'WebRtcService');
      }
    }
  }

  /// Set microphone mute state (PTT active or released)
  void setMicMute(bool mute) {
    _isMicMuted = mute;
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !mute;
      }
    }
    _setCallState(mute ? CallState.connected : CallState.transmitting);
  }

  /// Initiate a PTT call to one or multiple family members
  Future<void> startCall({
    required List<String> targetDeviceIds,
    required String familyCode,
    required String myDeviceId,
  }) async {
    _myDeviceId = myDeviceId;
    _familyCode = familyCode;
    await _startLanSignalingServer();

    _setCallState(CallState.connecting);

    if (_localStream == null) {
      await initialize();
    }

    final peersToCall = targetDeviceIds.where((id) {
      if (id == myDeviceId) return false;
      if (StorageService().isMemberBlocked(id)) return false;
      final member = DiscoveryService().getMember(id);
      if (member != null && (!member.isOnline || !member.isApproved)) {
        return false;
      }
      return true;
    }).toList();

    if (peersToCall.isEmpty) {
      developer.log('No online target peers available to call', name: 'WebRtcService');
      _setCallState(CallState.disconnected);
      return;
    }

    await Future.wait(
      peersToCall.map((targetId) => _createOfferForPeer(targetId, familyCode, myDeviceId)),
    );

    _setCallState(_isMicMuted ? CallState.connected : CallState.transmitting);

    // 2-second connection watchdog: fail fast if no peer answers
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(const Duration(milliseconds: 2000), () {
      _evaluateAggregateConnectionHealth(isTimeoutCheck: true);
    });
  }

  void _evaluateAggregateConnectionHealth({bool isTimeoutCheck = false}) {
    if (_peerConnections.isEmpty) return;

    int activeCount = 0;
    int failedCount = 0;

    for (final pc in _peerConnections.values) {
      final ice = pc.iceConnectionState;
      final conn = pc.connectionState;

      final isIceActive = ice == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                          ice == RTCIceConnectionState.RTCIceConnectionStateCompleted;
      final isConnActive = conn == RTCPeerConnectionState.RTCPeerConnectionStateConnected;

      final isIceFailed = ice == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                          ice == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                          ice == RTCIceConnectionState.RTCIceConnectionStateClosed;
      final isConnFailed = conn == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                           conn == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
                           conn == RTCPeerConnectionState.RTCPeerConnectionStateClosed;

      if (isIceActive || isConnActive) {
        activeCount++;
      } else if (isIceFailed || isConnFailed) {
        failedCount++;
      }
    }

    if (activeCount > 0) {
      if (!_isMicMuted && _callState != CallState.transmitting) {
        _setCallState(CallState.transmitting);
      }
    } else if (failedCount == _peerConnections.length || (isTimeoutCheck && activeCount == 0)) {
      developer.log('All peers disconnected or timeout reached with 0 active connections', name: 'WebRtcService');
      _setCallState(CallState.disconnected);
    }
  }

  Future<void> _createOfferForPeer(
    String peerId,
    String familyCode,
    String myDeviceId,
  ) async {
    try {
      final RTCPeerConnection pc = await createPeerConnection(_rtcConfiguration);
      _peerConnections[peerId] = pc;

      _localStream?.getTracks().forEach((track) {
        pc.addTrack(track, _localStream!);
      });

      pc.onIceConnectionState = (RTCIceConnectionState state) {
        developer.log('Peer $peerId ICE state: $state', name: 'WebRtcService');
        _evaluateAggregateConnectionHealth();
      };

      pc.onConnectionState = (RTCPeerConnectionState state) {
        developer.log('Peer $peerId connection state: $state', name: 'WebRtcService');
        _evaluateAggregateConnectionHealth();
      };

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        _sendSignal(
          targetId: peerId,
          familyCode: familyCode,
          myDeviceId: myDeviceId,
          data: {
            'type': 'candidate',
            'from': myDeviceId,
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          },
        );
      };

      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          final stream = event.streams[0];
          _remoteStreams[peerId] = stream;
          final isMuted = StorageService().isMemberMuted(peerId);
          for (final track in stream.getAudioTracks()) {
            track.enabled = !isMuted;
          }
          onRemoteStreamAdded?.call(peerId, stream);
          final speakerEnabled = StorageService().isSpeakerphoneEnabled;
          _audioRouter.setSpeakerphoneOn(speakerEnabled);
          try {
            Helper.setSpeakerphoneOn(speakerEnabled);
          } catch (e) {
            developer.log('Helper.setSpeakerphoneOn error: $e', name: 'WebRtcService');
          }
          _audioRouter.setVolumeCeiling(_audioCeiling);
        }
      };

      final RTCSessionDescription rawOffer = await pc.createOffer();
      final optimizedSdp = _optimizeOpusAndJitterSdp(rawOffer.sdp ?? '');
      final offer = RTCSessionDescription(optimizedSdp, 'offer');
      await pc.setLocalDescription(offer);

      await _sendSignal(
        targetId: peerId,
        familyCode: familyCode,
        myDeviceId: myDeviceId,
        data: {
          'type': 'offer',
          'from': myDeviceId,
          'sdp': offer.sdp,
        },
      );
    } catch (e) {
      developer.log('Error creating WebRTC offer for $peerId: $e', name: 'WebRtcService');
    }
  }

  Future<void> _handleIncomingOffer(
    String fromId,
    String sdp,
    String familyCode,
    String myDeviceId,
  ) async {
    try {
      if (_audioRouter.isFocusModeActive) {
        developer.log('Rejected incoming offer: Focus Mode active', name: 'WebRtcService');
        return;
      }
      if (StorageService().isSleepShieldActive) {
        developer.log('Rejected incoming offer: Sleep Shield active', name: 'WebRtcService');
        return;
      }
      if (StorageService().isMemberBlocked(fromId)) {
        developer.log('Rejected incoming offer from blocked member $fromId', name: 'WebRtcService');
        return;
      }
      final senderMember = DiscoveryService().getMember(fromId);
      if (senderMember != null && !senderMember.isApproved) {
        developer.log('Rejected incoming offer from unapproved member $fromId', name: 'WebRtcService');
        return;
      }

      await _audioRouter.wakeDevice();
      await _audioRouter.routeAudioToAlarm();
      await _audioRouter.setVolumeCeiling(_audioCeiling);

      final RTCPeerConnection pc = await createPeerConnection(_rtcConfiguration);
      _peerConnections[fromId] = pc;

      // Pure unidirectional receiver (recvonly): Do NOT initialize local mic and do NOT add local tracks!
      // This prevents microphone capture on the receiving phone and eliminates audio Larsen loops.

      pc.onIceConnectionState = (RTCIceConnectionState state) {
        developer.log('Receiver ICE state for $fromId: $state', name: 'WebRtcService');
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          _setCallState(CallState.idle);
        }
      };

      pc.onConnectionState = (RTCPeerConnectionState state) {
        developer.log('Receiver connection state for $fromId: $state', name: 'WebRtcService');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _setCallState(CallState.idle);
        }
      };

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        _sendSignal(
          targetId: fromId,
          familyCode: familyCode,
          myDeviceId: myDeviceId,
          data: {
            'type': 'candidate',
            'from': myDeviceId,
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          },
        );
      };

      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          final stream = event.streams[0];
          _remoteStreams[fromId] = stream;
          final isMuted = StorageService().isMemberMuted(fromId);
          for (final track in stream.getAudioTracks()) {
            track.enabled = !isMuted;
          }
          onRemoteStreamAdded?.call(fromId, stream);
          final speakerEnabled = StorageService().isSpeakerphoneEnabled;
          _audioRouter.setSpeakerphoneOn(speakerEnabled);
          try {
            Helper.setSpeakerphoneOn(speakerEnabled);
          } catch (e) {
            developer.log('Helper.setSpeakerphoneOn error: $e', name: 'WebRtcService');
          }
          _audioRouter.setVolumeCeiling(_audioCeiling);
        }
      };

      final optimizedOfferSdp = _optimizeOpusAndJitterSdp(sdp);
      final RTCSessionDescription remoteDesc = RTCSessionDescription(optimizedOfferSdp, 'offer');
      await pc.setRemoteDescription(remoteDesc);

      // Force all transceivers to RecvOnly to forbid any audio return from receiver
      try {
        final transceivers = await pc.getTransceivers();
        for (final t in transceivers) {
          await t.setDirection(TransceiverDirection.RecvOnly);
        }
      } catch (e) {
        developer.log('Error forcing transceiver RecvOnly: $e', name: 'WebRtcService');
      }

      // Drain queued ICE candidates received before remote description
      if (_pendingIceCandidates.containsKey(fromId)) {
        for (final cand in _pendingIceCandidates[fromId]!) {
          await pc.addCandidate(cand);
        }
        _pendingIceCandidates.remove(fromId);
      }

      final RTCSessionDescription rawAnswer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      final optimizedAnswerSdp = _optimizeOpusAndJitterSdp(rawAnswer.sdp ?? '', forceRecvOnly: true);
      final answer = RTCSessionDescription(optimizedAnswerSdp, 'answer');
      await pc.setLocalDescription(answer);

      await _sendSignal(
        targetId: fromId,
        familyCode: familyCode.isNotEmpty ? familyCode : _familyCode,
        myDeviceId: myDeviceId.isNotEmpty ? myDeviceId : _myDeviceId,
        data: {
          'type': 'answer',
          'from': myDeviceId.isNotEmpty ? myDeviceId : _myDeviceId,
          'sdp': answer.sdp,
        },
      );

      // Maintain transmitting state if user is holding PTT (Full-Duplex)
      if (_callState != CallState.transmitting) {
        _setCallState(CallState.connected);
      }
    } catch (e) {
      developer.log('Error handling incoming offer from $fromId: $e', name: 'WebRtcService');
    }
  }

  Future<void> _handleIncomingAnswer(String fromId, String sdp) async {
    try {
      final pc = _peerConnections[fromId];
      if (pc != null) {
        final optimizedAnswerSdp = _optimizeOpusAndJitterSdp(sdp);
        final RTCSessionDescription answerDesc = RTCSessionDescription(optimizedAnswerSdp, 'answer');
        await pc.setRemoteDescription(answerDesc);

        // Drain queued ICE candidates received before remote description
        if (_pendingIceCandidates.containsKey(fromId)) {
          for (final cand in _pendingIceCandidates[fromId]!) {
            await pc.addCandidate(cand);
          }
          _pendingIceCandidates.remove(fromId);
        }
      }
    } catch (e) {
      developer.log('Error handling answer from $fromId: $e', name: 'WebRtcService');
    }
  }

  /// Optimize Opus audio parameters: ptime=40 (25 pkts/sec instead of 50), 24kbps mono, FEC enabled
  String _optimizeOpusAndJitterSdp(String sdp, {bool forceRecvOnly = false}) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final result = <String>[];
    String? opusPayloadType;

    for (final line in lines) {
      if (line.startsWith('a=rtpmap:') && line.toLowerCase().contains('opus/48000')) {
        final match = RegExp(r'a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false).firstMatch(line);
        if (match != null) {
          opusPayloadType = match.group(1);
        }
      }
    }

    for (final line in lines) {
      if (forceRecvOnly && (line.trim() == 'a=sendrecv' || line.trim() == 'a=sendonly')) {
        result.add('a=recvonly');
        continue;
      }
      if (opusPayloadType != null && line.startsWith('a=fmtp:$opusPayloadType')) {
        var fmtp = line;
        // FEC for packet loss concealment
        if (!fmtp.contains('useinbandfec')) {
          fmtp += ';useinbandfec=1';
        } else {
          fmtp = fmtp.replaceAll(RegExp(r'useinbandfec=\d+'), 'useinbandfec=1');
        }
        // Human voice bitrate 24 kbps mono
        if (!fmtp.contains('maxaveragebitrate')) {
          fmtp += ';maxaveragebitrate=24000';
        } else {
          fmtp = fmtp.replaceAll(RegExp(r'maxaveragebitrate=\d+'), 'maxaveragebitrate=24000');
        }
        // Packet time 40ms: cuts UDP packet frequency by 50% (25 pkts/sec instead of 50)
        if (!fmtp.contains('ptime=')) {
          fmtp += ';ptime=40';
        } else {
          fmtp = fmtp.replaceAll(RegExp(r'ptime=\d+'), 'ptime=40');
        }
        if (!fmtp.contains('minptime=')) {
          fmtp += ';minptime=10';
        } else {
          fmtp = fmtp.replaceAll(RegExp(r'minptime=\d+'), 'minptime=10');
        }
        // Mono speech
        if (!fmtp.contains('stereo=')) {
          fmtp += ';stereo=0';
        } else {
          fmtp = fmtp.replaceAll(RegExp(r'stereo=\d+'), 'stereo=0');
        }
        if (!fmtp.contains('sprop-stereo=')) {
          fmtp += ';sprop-stereo=0';
        } else {
          fmtp = fmtp.replaceAll(RegExp(r'sprop-stereo=\d+'), 'sprop-stereo=0');
        }
        result.add(fmtp);
        result.add('a=playout-delay:min=100,max=150');
      } else {
        result.add(line);
      }
    }
    return result.join('\r\n');
  }

  Future<void> _handleIncomingCandidate(String fromId, Map candidateMap) async {
    try {
      final candidate = RTCIceCandidate(
        candidateMap['candidate']?.toString(),
        candidateMap['sdpMid']?.toString(),
        candidateMap['sdpMLineIndex'] is int ? candidateMap['sdpMLineIndex'] as int : 0,
      );
      final pc = _peerConnections[fromId];
      if (pc != null) {
        final remoteDesc = await pc.getRemoteDescription();
        if (remoteDesc != null) {
          await pc.addCandidate(candidate);
          return;
        }
      }
      _pendingIceCandidates.putIfAbsent(fromId, () => []).add(candidate);
    } catch (e) {
      developer.log('Error handling ICE candidate from $fromId: $e', name: 'WebRtcService');
    }
  }

  Future<void> _sendSignal({
    required String targetId,
    required String familyCode,
    required String myDeviceId,
    required Map<String, dynamic> data,
  }) async {
    // 1. Autonomous Direct LAN HTTP POST on port 8889 (Zero-Firebase)
    final peerIp = _findPeerIp(targetId);
    if (peerIp != null && peerIp.isNotEmpty) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(milliseconds: 1500);
        final request = await client.postUrl(Uri.parse('http://$peerIp:8889/'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(data));
        final response = await request.close();
        client.close();
        if (response.statusCode == HttpStatus.ok) {
          developer.log('Direct LAN signal [${data['type']}] delivered to $targetId at $peerIp:8889', name: 'WebRtcService');
          return;
        }
      } catch (e) {
        developer.log('Direct LAN signal to $peerIp:8889 failed ($e), falling back to Firebase', name: 'WebRtcService');
      }
    }

    // 2. WAN Firebase Signaling Fallback
    if (familyCode.isNotEmpty) {
      try {
        final DatabaseReference targetSignaling = FirebaseDatabase.instance
            .ref('foyers/$familyCode/signaling/$targetId');
        await targetSignaling.push().set(data);
      } catch (e) {
        developer.log('Error pushing signal to $targetId via Firebase: $e', name: 'WebRtcService');
      }
    }
  }

  /// Autonomous LAN Signaling Server listening on Port 8889
  Future<void> _startLanSignalingServer() async {
    if (_lanSignalingServer != null) return;
    try {
      _lanSignalingServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        8889,
        shared: true,
      );
      developer.log('Autonomous LAN Signaling Server listening on port 8889', name: 'WebRtcService');
      _lanSignalingServer!.listen((HttpRequest request) async {
        try {
          if (request.method == 'POST') {
            final content = await utf8.decoder.bind(request).join();
            final data = jsonDecode(content);
            if (data is Map) {
              final type = data['type']?.toString();
              final fromId = data['from']?.toString() ?? '';
              final sdp = data['sdp']?.toString();
              final candidateMap = data['candidate'];
              final senderName = data['senderName']?.toString() ?? 'Membre';

              // Dynamically cache peer IP from incoming HTTP connection
              if (fromId.isNotEmpty && request.connectionInfo != null) {
                _peerIps[fromId] = request.connectionInfo!.remoteAddress.address;
              }

              // Reject signals from blocked or unapproved members
              final lanSender = DiscoveryService().getMember(fromId);
              if (fromId.isNotEmpty && (StorageService().isMemberBlocked(fromId) || (lanSender != null && !lanSender.isApproved))) {
                developer.log('Rejected LAN signal from unapproved or blocked member $fromId', name: 'WebRtcService');
                request.response.statusCode = HttpStatus.forbidden;
                await request.response.close();
                return;
              }

              if (type == 'offer' && sdp != null) {
                developer.log('Received LAN WebRTC offer from $fromId', name: 'WebRtcService');
                await _handleIncomingOffer(fromId, sdp, _familyCode, _myDeviceId);
              } else if (type == 'answer' && sdp != null) {
                developer.log('Received LAN WebRTC answer from $fromId', name: 'WebRtcService');
                await _handleIncomingAnswer(fromId, sdp);
              } else if (type == 'candidate' && candidateMap is Map) {
                developer.log('Received LAN ICE candidate from $fromId', name: 'WebRtcService');
                await _handleIncomingCandidate(fromId, candidateMap);
              } else if (type == 'chime') {
                developer.log('Received direct LAN chime alert from $senderName ($fromId)', name: 'WebRtcService');
                if (!_audioRouter.isFocusModeActive && !StorageService().isSleepShieldActive && !StorageService().isMemberBlocked(fromId)) {
                  await _audioRouter.playChimeAlert();
                  onIncomingChime?.call(fromId, senderName);
                } else {
                  developer.log('LAN chime dropped: Focus Mode or Sleep Shield active or member blocked', name: 'WebRtcService');
                }
              } else if (type == 'emergency_alert') {
                developer.log('Received direct LAN emergency alert from $senderName ($fromId)', name: 'WebRtcService');
                await _audioRouter.startEmergencyAlert();
                onIncomingEmergencyAlert?.call(fromId, senderName);
              }
            }
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
          } else {
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
          }
        } catch (e) {
          developer.log('Error in LAN signaling server handler: $e', name: 'WebRtcService');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      developer.log('Failed to bind LAN signaling server on port 8889: $e', name: 'WebRtcService');
    }
  }

  String? _findPeerIp(String targetId) {
    if (_peerIps.containsKey(targetId) && _peerIps[targetId]!.isNotEmpty) {
      return _peerIps[targetId];
    }
    final member = DiscoveryService().getMember(targetId);
    if (member != null && member.ip != null && member.ip!.isNotEmpty) {
      _peerIps[targetId] = member.ip!;
      return member.ip!;
    }
    return null;
  }

  void _setCallState(CallState state) {
    _callState = state;
    onCallStateChanged?.call(state);
  }

  /// Hang up and release all active peer connections
  Future<void> endCall() async {
    _handshakeTimer?.cancel();
    for (final pc in _peerConnections.values) {
      await pc.close();
    }
    _peerConnections.clear();
    _remoteStreams.clear();
    _pendingIceCandidates.clear();
    setMicMute(true);
    _setCallState(CallState.idle);
    await _audioRouter.resetAudioMode();
  }

  /// Handle Focus Mode transitions: immediately sever active calls upon activation
  void onFocusModeChanged(bool active) {
    if (active) {
      if (_callState != CallState.idle) {
        developer.log('WebRtcService: Terminating active voice stream because Focus Mode was activated', name: 'WebRtcService');
        endCall();
      }
    }
  }

  /// Real Voice Activity Detection (VAD):
  /// Samples linear audioLevel from active outbound RTCPeerConnections
  Future<double> getSenderAudioLevel() async {
    if (_peerConnections.isEmpty) return 0.0;
    double maxLevel = 0.0;
    for (final pc in _peerConnections.values) {
      try {
        final reports = await pc.getStats();
        for (final report in reports) {
          // 1. Standard W3C audioLevel in [0.0, 1.0]
          final al = report.values['audioLevel'];
          if (al != null) {
            final val = double.tryParse(al.toString()) ?? 0.0;
            if (val > maxLevel) maxLevel = val;
          }
          // 2. Legacy audioInputLevel in [0, 32767]
          final ail = report.values['audioInputLevel'];
          if (ail != null) {
            final raw = double.tryParse(ail.toString()) ?? 0.0;
            final normalized = (raw / 32767.0).clamp(0.0, 1.0);
            if (normalized > maxLevel) maxLevel = normalized;
          }
        }
      } catch (_) {}
    }
    return maxLevel;
  }

  void dispose() {
    _signalingSubscription?.cancel();
    _chimeSubscription?.cancel();
    _emergencySubscription?.cancel();
    _lanSignalingServer?.close(force: true);
    _lanSignalingServer = null;
    _localStream?.dispose();
    endCall();
  }
}
