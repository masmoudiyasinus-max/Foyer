import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_constants.dart';
import '../../models/family_member.dart';
import 'storage_service.dart';

class DiscoveryService {
  static final DiscoveryService _instance = DiscoveryService._internal();
  factory DiscoveryService() => _instance;
  DiscoveryService._internal() {
    _storage.onPortfolioUpdated = (member) {
      broadcastProfile(member);
    };
  }

  final StorageService _storage = StorageService();

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _bonsoirSubscription;
  StreamSubscription? _firebaseMembersSubscription;

  RawDatagramSocket? _udpSocket;
  Timer? _udpBroadcastTimer;
  Timer? _reaperTimer;

  final Map<String, FamilyMember> _discoveredMembers = {};
  final StreamController<List<FamilyMember>> _membersController =
      StreamController<List<FamilyMember>>.broadcast();

  // ValueNotifier for immediate reactive UI binding
  final ValueNotifier<List<FamilyMember>> membersNotifier = ValueNotifier<List<FamilyMember>>([]);

  // Callback when an unapproved new member is detected
  Function(FamilyMember newMember)? onNewMemberDiscovered;

  // Passive Wi-Fi Radar arrival callback
  Function(String memberName, String memberId)? onMemberArrivedHome;

  // Real-time Hardware GPS Telemetry callback over UDP 8888
  Function(Map<String, dynamic> locationData)? onLocationReceived;

  final Map<String, DateTime> _lastSeenOnLan = {};
  AudioPlayer? _arrivalAudioPlayer;

  Stream<List<FamilyMember>> get membersStream => _membersController.stream;
  List<FamilyMember> get currentMembers =>
      _discoveredMembers.values.where((m) => m.isApproved && !_storage.isMemberBlocked(m.id)).toList();

  FamilyMember? getMember(String id) => _discoveredMembers[id];
  String? getMemberIp(String id) => _discoveredMembers[id]?.ip;

  bool _isStarted = false;
  bool get isStarted => _isStarted;

  String? _cachedIp;
  String? _cachedBroadcast;

  /// Récupère l'IP locale et l'adresse de broadcast avec mise en cache anti-drain de batterie
  Future<Map<String, String>> _getLocalNetworkInfo({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedIp != null && _cachedBroadcast != null) {
      return {'ip': _cachedIp!, 'broadcast': _cachedBroadcast!};
    }
    String localIp = _cachedIp ?? '127.0.0.1';
    String broadcastIp = _cachedBroadcast ?? '255.255.255.255';
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && !addr.isLinkLocal) {
            localIp = addr.address;
            final parts = localIp.split('.');
            if (parts.length == 4) {
              broadcastIp = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            }
            _cachedIp = localIp;
            _cachedBroadcast = broadcastIp;
            return {'ip': localIp, 'broadcast': broadcastIp};
          }
        }
      }
    } catch (e) {
      debugPrint('Erreur obtention network info: $e');
    }
    _cachedIp = localIp;
    _cachedBroadcast = broadcastIp;
    return {'ip': localIp, 'broadcast': broadcastIp};
  }

  Future<void> start({
    required String myName,
    required String myDeviceId,
    required String familyCode,
    String? mode,
  }) async {
    _isStarted = true;
    // Initialiser le cache réseau au démarrage
    await _getLocalNetworkInfo(forceRefresh: true);

    // 1. Start Bonsoir mDNS local broadcast & discovery (Offline-First LAN)
    await _startMdns(myName: myName, myDeviceId: myDeviceId);

    // 2. Start UDP Broadcast on port 8888 (Every 1.5s ping)
    await _startUdpBroadcast(
      myName: myName,
      myDeviceId: myDeviceId,
      familyCode: familyCode,
    );

    // 3. Start Firebase Cloud Presence Sync automatically (Seamless WAN fallback & Cloud coordination)
    if (familyCode.isNotEmpty) {
      _startFirebaseSync(
        myName: myName,
        myDeviceId: myDeviceId,
        familyCode: familyCode,
      );
    }
  }

  Future<void> ensureStarted({
    required String myName,
    required String myDeviceId,
    required String familyCode,
    String? mode,
  }) async {
    if (!_isStarted) {
      await start(
        myName: myName,
        myDeviceId: myDeviceId,
        familyCode: familyCode,
        mode: mode,
      );
    }
  }

  Future<void> updateMode({
    required String newMode,
    required String myName,
    required String myDeviceId,
    required String familyCode,
  }) async {
    await _storage.setConnectionMode(newMode);
    if (newMode == AppConstants.modeCloud && familyCode.isNotEmpty) {
      _startFirebaseSync(myName: myName, myDeviceId: myDeviceId, familyCode: familyCode);
    } else {
      await _firebaseMembersSubscription?.cancel();
      _firebaseMembersSubscription = null;
    }
  }

  /// Broadcasts full profile to both LAN (UDP 8888) and Cloud (Firebase)
  Future<void> broadcastProfile([FamilyMember? customMember]) async {
    try {
      final myId = _storage.deviceId;
      final myName = _storage.memberName;
      if (myId.isEmpty) return;

      final myProfile = customMember ??
          _storage.getPortfolio(myId) ??
          FamilyMember(
            id: myId,
            name: myName,
            isOnline: true,
          );

      final netInfo = await _getLocalNetworkInfo();
      final ip = netInfo['ip'] ?? '127.0.0.1';
      final bcast = netInfo['broadcast'] ?? '255.255.255.255';

      final memberWithNetwork = myProfile.copyWith(
        ip: ip,
        isOnline: true,
        isSleepShieldActive: _storage.isSleepShieldActive,
        updatedAt: customMember?.updatedAt ?? DateTime.now(),
      );

      final payload = jsonEncode({
        'type': 'profile_sync',
        'id': myId,
        'name': memberWithNetwork.name,
        'ip': ip,
        'isSleepShieldActive': _storage.isSleepShieldActive,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'member': memberWithNetwork.toMap(),
      });
      final bytes = utf8.encode(payload);

      await _sendUdpPacket(bytes, bcast);

      if (_storage.familyCode.isNotEmpty) {
        try {
          final ref = FirebaseDatabase.instance
              .ref('foyers/${_storage.familyCode}/members/$myId');
          await ref.update(memberWithNetwork.toMap());
        } catch (e) {
          debugPrint('Erreur update members Firebase: $e');
        }
      }
      developer.log('Broadcasted profile for ${memberWithNetwork.name}', name: 'DiscoveryService');
    } catch (e) {
      developer.log('Error broadcasting profile: $e', name: 'DiscoveryService');
    }
  }

  /// Broadcasts smoothed GPS location to local network via UDP port 8888
  Future<void> broadcastLocation(Map<String, dynamic> locationData) async {
    try {
      final payload = jsonEncode({
        'type': 'location_update',
        ...locationData,
      });
      final bytes = utf8.encode(payload);
      final netInfo = await _getLocalNetworkInfo();
      final bcast = netInfo['broadcast'] ?? '255.255.255.255';
      await _sendUdpPacket(bytes, bcast);
    } catch (e) {
      developer.log('Error broadcasting location over UDP: $e', name: 'DiscoveryService');
    }
  }

  /// Envoi sécurisé de paquets UDP avec réinstanciation automatique si socket fermé
  Future<void> _sendUdpPacket(List<int> bytes, String bcast) async {
    try {
      if (_udpSocket == null) {
        await _rebindUdpSocket();
      }
      _udpSocket?.send(bytes, InternetAddress(bcast), 8888);
      _udpSocket?.send(bytes, InternetAddress('255.255.255.255'), 8888);
    } catch (e) {
      debugPrint('Erreur socket UDP: $e');
      try {
        await _rebindUdpSocket();
        _udpSocket?.send(bytes, InternetAddress(bcast), 8888);
        _udpSocket?.send(bytes, InternetAddress('255.255.255.255'), 8888);
      } catch (err) {
        debugPrint('Erreur socket UDP réinstanciation: $err');
      }
    }
  }

  Future<void> _rebindUdpSocket() async {
    try {
      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8888,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket?.broadcastEnabled = true;
      _setupUdpSocketListener();
      debugPrint('Socket UDP réinstancié avec succès sur le port 8888');
    } catch (e) {
      debugPrint('Erreur socket UDP bind: $e');
    }
  }

  void _setupUdpSocketListener({String? myDeviceId}) {
    final selfId = myDeviceId ?? _storage.deviceId;
    _udpSocket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final datagram = _udpSocket?.receive();
        if (datagram != null) {
          try {
            final jsonStr = utf8.decode(datagram.data);
            final data = jsonDecode(jsonStr);
            if (data is Map) {
              // Intercept real-time GPS telemetry packets
              if (data['type'] == 'location_update') {
                final id = data['memberId']?.toString() ?? data['id']?.toString() ?? '';
                if (id.isNotEmpty && id != selfId) {
                  onLocationReceived?.call(Map<String, dynamic>.from(data));
                }
                return;
              }

              // Intercept Wi-Fi arrival signals
              if (data['type'] == 'member_arrival') {
                final arrId = data['memberId']?.toString() ?? '';
                final arrName = data['memberName']?.toString() ?? 'Membre';
                if (arrId.isNotEmpty && arrId != selfId) {
                  _handleRemoteArrivalSignal(id: arrId, name: arrName);
                }
                return;
              }

              FamilyMember? incomingMember;
              if (data['member'] is Map) {
                try {
                  incomingMember = FamilyMember.fromMap(data['member'] as Map);
                } catch (e) {
                  developer.log('Error parsing incoming member profile: $e', name: 'DiscoveryService');
                }
              }

              final id = incomingMember?.id.isNotEmpty == true
                  ? incomingMember!.id
                  : (data['id']?.toString() ?? '');
              final name = incomingMember?.name.isNotEmpty == true
                  ? incomingMember!.name
                  : (data['name']?.toString() ?? 'Membre');
              final ip = incomingMember?.ip?.isNotEmpty == true
                  ? incomingMember!.ip!
                  : (data['ip']?.toString() ?? datagram.address.address);

              if (id.isNotEmpty && id != selfId) {
                final bool isSleepShield = incomingMember?.isSleepShieldActive ??
                    (data['isSleepShieldActive'] == true);

                // Passive Wi-Fi Radar: Detect device appearance on local Wi-Fi
                final lastSeen = _lastSeenOnLan[id];
                final now = DateTime.now();
                if (lastSeen == null || now.difference(lastSeen).inMinutes >= 5) {
                  _triggerMemberArrival(id: id, name: name);
                }
                _lastSeenOnLan[id] = now;

                if (incomingMember != null) {
                  final updatedMember = incomingMember.copyWith(
                    ip: ip,
                    isOnline: true,
                    lastSeen: now,
                  );
                  _storage.savePortfolio(updatedMember, broadcast: false);
                  _registerDiscoveredMember(
                    id: id,
                    name: updatedMember.name,
                    ip: ip,
                    isOnline: true,
                    isSleepShieldActive: isSleepShield,
                    memberProfile: updatedMember,
                  );
                } else {
                  _registerDiscoveredMember(
                    id: id,
                    name: name,
                    ip: ip,
                    isOnline: true,
                    isSleepShieldActive: isSleepShield,
                  );
                }
              }
            }
          } catch (e) {
            developer.log('Error parsing UDP packet: $e', name: 'DiscoveryService');
          }
        }
      }
    });
  }

  /// Lightweight UDP Broadcast on Port 8888 to ensure instant local discovery on Wi-Fi
  Future<void> _startUdpBroadcast({
    required String myName,
    required String myDeviceId,
    required String familyCode,
  }) async {
    try {
      final netInfo = await _getLocalNetworkInfo();
      final String initialIp = netInfo['ip'] ?? '127.0.0.1';
      final String directedBroadcast = netInfo['broadcast'] ?? '255.255.255.255';

      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8888,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket?.broadcastEnabled = true;

      _setupUdpSocketListener(myDeviceId: myDeviceId);

      // Send UDP heartbeat with full profile every 2 seconds
      _udpBroadcastTimer?.cancel();
      _udpBroadcastTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final info = await _getLocalNetworkInfo();
          final ip = info['ip'] ?? initialIp;
          final bcast = info['broadcast'] ?? directedBroadcast;

          final myProfile = _storage.getPortfolio(myDeviceId) ??
              FamilyMember(
                id: myDeviceId,
                name: myName,
                isOnline: true,
              );

          final memberWithNetwork = myProfile.copyWith(
            ip: ip,
            isOnline: true,
            isSleepShieldActive: _storage.isSleepShieldActive,
          );

          final payload = jsonEncode({
            'type': 'profile_sync',
            'id': myDeviceId,
            'name': memberWithNetwork.name,
            'ip': ip,
            'isSleepShieldActive': _storage.isSleepShieldActive,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'member': memberWithNetwork.toMap(),
          });
          final bytes = utf8.encode(payload);
          await _sendUdpPacket(bytes, bcast);
        } catch (e) {
          developer.log('UDP broadcast send error: $e', name: 'DiscoveryService');
        }
      });

      // Start automatic Reaper Timer: Purge members inactive for > 4 seconds
      _startReaperTimer();
      developer.log('UDP broadcast & Reaper started on port 8888 (IP: $initialIp, Bcast: $directedBroadcast)', name: 'DiscoveryService');
    } catch (e) {
      developer.log('UDP broadcast bind error: $e', name: 'DiscoveryService');
    }
  }

  /// Reaper Timer running every 2 seconds to mark inactive members as offline (timeout > 4s)
  void _startReaperTimer() {
    _reaperTimer?.cancel();
    _reaperTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      bool hasChanged = false;
      for (final id in _discoveredMembers.keys) {
        final member = _discoveredMembers[id]!;
        if (member.isOnline && member.lastSeen != null) {
          final diff = now.difference(member.lastSeen!).inMilliseconds;
          if (diff >= 4000) {
            _discoveredMembers[id] = member.copyWith(isOnline: false);
            hasChanged = true;
          }
        }
      }
      if (hasChanged) {
        _notifyMembersChanged();
      }
    });
  }

  Future<void> _startMdns({
    required String myName,
    required String myDeviceId,
  }) async {
    try {
      final service = BonsoirService(
        name: 'Intercom-$myDeviceId',
        type: AppConstants.mdnsServiceType,
        port: AppConstants.defaultUdpPort,
        attributes: {
          'id': myDeviceId,
          'name': myName,
        },
      );

      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
      developer.log('mDNS broadcast started for $myName ($myDeviceId)', name: 'DiscoveryService');

      _discovery = BonsoirDiscovery(type: AppConstants.mdnsServiceType);
      await _discovery!.ready;
      await _discovery!.start();

      _bonsoirSubscription = _discovery!.eventStream?.listen((event) {
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final resolvedService = event.service as ResolvedBonsoirService?;
          if (resolvedService != null) {
            final id = resolvedService.attributes['id'] ?? resolvedService.name;
            final name = resolvedService.attributes['name'] ?? resolvedService.name;
            final ip = resolvedService.host;
            final port = resolvedService.port;

            if (id != myDeviceId) {
              _registerDiscoveredMember(
                id: id,
                name: name,
                ip: ip,
                port: port,
              );
            }
          }
        } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
          final lostService = event.service;
          if (lostService != null) {
            final id = lostService.attributes['id'] ?? lostService.name;
            if (_discoveredMembers.containsKey(id)) {
              final existing = _discoveredMembers[id]!;
              _discoveredMembers[id] = existing.copyWith(isOnline: false);
              _notifyMembersChanged();
            }
          }
        }
      });
    } catch (e) {
      developer.log('mDNS discovery error (continuing with UDP & WAN): $e', name: 'DiscoveryService');
    }
  }

  void _startFirebaseSync({
    required String myName,
    required String myDeviceId,
    required String familyCode,
  }) {
    if (familyCode.isEmpty || myDeviceId.isEmpty) return;

    try {
      final DatabaseReference myNode = FirebaseDatabase.instance
          .ref('foyers/$familyCode/members/$myDeviceId');

      final myProfile = _storage.getPortfolio(myDeviceId) ??
          FamilyMember(id: myDeviceId, name: myName, isOnline: true);
      final initialData = myProfile.toMap();
      initialData.addAll({
        'id': myDeviceId,
        'name': myName,
        'code': familyCode.toUpperCase(),
        'isOnline': true,
        'isSleepShieldActive': _storage.isSleepShieldActive,
        'lastSeen': ServerValue.timestamp,
      });

      // Publish local presence with full profile
      myNode.set(initialData);

      myNode.onDisconnect().update({
        'isOnline': false,
        'lastSeen': ServerValue.timestamp,
      });

      // Listen in real-time for all members with the same Code Foyer
      final DatabaseReference membersNode =
          FirebaseDatabase.instance.ref('foyers/$familyCode/members');

      _firebaseMembersSubscription = membersNode.onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          data.forEach((k, v) {
            if (k != myDeviceId && v is Map) {
              final id = v['id']?.toString() ?? k.toString();
              final name = v['name']?.toString() ?? 'Membre';
              final isOnline = v['isOnline'] != false;
              final isSleepShield = v['isSleepShieldActive'] == true;

              FamilyMember? profile;
              try {
                profile = FamilyMember.fromMap(v);
                _storage.savePortfolio(profile, broadcast: false);
              } catch (e) {
                debugPrint('Erreur parsing membre Firebase: $e');
              }

              _registerDiscoveredMember(
                id: id,
                name: name,
                isOnline: isOnline,
                isSleepShieldActive: isSleepShield,
                memberProfile: profile,
              );
            }
          });
        }
      });
    } catch (e) {
      developer.log('Firebase presence sync error: $e', name: 'DiscoveryService');
    }
  }

  void updateSleepShield(bool active) {
    if (_storage.familyCode.isNotEmpty && _storage.deviceId.isNotEmpty) {
      try {
        FirebaseDatabase.instance
            .ref('foyers/${_storage.familyCode}/members/${_storage.deviceId}')
            .update({'isSleepShieldActive': active});
      } catch (e) {
        debugPrint('Erreur mise à jour sleep shield Firebase: $e');
      }
    }
  }

  void _registerDiscoveredMember({
    required String id,
    required String name,
    String? ip,
    int? port,
    bool isOnline = true,
    bool isSleepShieldActive = false,
    FamilyMember? memberProfile,
  }) {
    final bool isKnown = _discoveredMembers.containsKey(id);
    final bool hasDecision = _storage.hasDecisionForMember(id);
    // If not decided yet, default to approved for devices sharing the exact Code Foyer
    final bool isApproved = hasDecision ? _storage.isMemberApproved(id) : true;

    final existing = _discoveredMembers[id] ?? _storage.getPortfolio(id);

    final base = memberProfile ?? existing ?? FamilyMember(id: id, name: name);
    final member = base.copyWith(
      id: id,
      name: name,
      ip: ip ?? existing?.ip,
      port: port ?? existing?.port,
      isOnline: isOnline,
      isApproved: isApproved,
      isSleepShieldActive: isSleepShieldActive,
      lastSeen: DateTime.now(),
    );

    _discoveredMembers[id] = member;
    _notifyMembersChanged();

    // If new and unapproved explicitly, trigger notification
    if (!isKnown && !hasDecision) {
      onNewMemberDiscovered?.call(member);
    }
  }

  void _notifyMembersChanged() {
    final list = currentMembers;
    membersNotifier.value = List<FamilyMember>.from(list);
    _membersController.add(list);
  }

  Future<void> _triggerMemberArrival({required String id, required String name}) async {
    developer.log('Radar Wi-Fi passif: $name ($id) est rentré à la maison', name: 'DiscoveryService');

    // 1. Émets un signal d'arrivée au domicile vers tous les appareils déjà présents sur le LAN
    try {
      final payload = jsonEncode({
        'type': 'member_arrival',
        'memberId': id,
        'memberName': name,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final bytes = utf8.encode(payload);
      final netInfo = await _getLocalNetworkInfo();
      final bcast = netInfo['broadcast'] ?? '255.255.255.255';
      await _sendUdpPacket(bytes, bcast);
    } catch (e) {
      debugPrint('Erreur broadcast arrivée UDP: $e');
    }

    // 2. Déclenche une notification discrète et un carillon doux ('assets/audio/chime.wav') avec vibration légère
    onMemberArrivedHome?.call(name, id);
    await _storage.saveArrivalEvent(
      memberId: id,
      memberName: name,
      timestamp: DateTime.now(),
    );
    try {
      _arrivalAudioPlayer?.dispose();
      _arrivalAudioPlayer = AudioPlayer();
      await _arrivalAudioPlayer?.play(AssetSource('audio/chime.wav'));
      HapticFeedback.lightImpact(); // Vibration légère
    } catch (e) {
      debugPrint('Erreur lecture carillon arrivée: $e');
    }
  }

  Future<void> _handleRemoteArrivalSignal({required String id, required String name}) async {
    final now = DateTime.now();
    final lastSeen = _lastSeenOnLan[id];
    if (lastSeen != null && now.difference(lastSeen).inMinutes < 2) {
      return; // Déjà traité récemment
    }
    _lastSeenOnLan[id] = now;
    developer.log('Signal d\'arrivée reçu à distance: $name ($id)', name: 'DiscoveryService');
    onMemberArrivedHome?.call(name, id);
    await _storage.saveArrivalEvent(
      memberId: id,
      memberName: name,
      timestamp: now,
    );
    try {
      _arrivalAudioPlayer?.dispose();
      _arrivalAudioPlayer = AudioPlayer();
      await _arrivalAudioPlayer?.play(AssetSource('audio/chime.wav'));
      HapticFeedback.lightImpact(); // Vibration légère
    } catch (e) {
      debugPrint('Erreur lecture carillon arrivée distante: $e');
    }
  }

  void approveDiscoveredMember(String memberId, bool approved) {
    _storage.setMemberApproval(memberId, approved);
    if (_discoveredMembers.containsKey(memberId)) {
      _discoveredMembers[memberId] = _discoveredMembers[memberId]!.copyWith(isApproved: approved);
      _notifyMembersChanged();
    }
  }

  Future<void> stop() async {
    _isStarted = false;
    _udpBroadcastTimer?.cancel();
    _reaperTimer?.cancel();
    _reaperTimer = null;
    _udpSocket?.close();
    await _bonsoirSubscription?.cancel();
    await _firebaseMembersSubscription?.cancel();
    await _discovery?.stop();
    await _broadcast?.stop();
  }

  void dispose() {
    stop();
    _arrivalAudioPlayer?.dispose();
    _membersController.close();
    membersNotifier.dispose();
  }
}
