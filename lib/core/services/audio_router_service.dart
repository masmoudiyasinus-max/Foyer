import 'dart:async';
import 'dart:developer' as developer;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import '../constants/app_constants.dart';
import 'storage_service.dart';

class AudioRouterService {
  static final AudioRouterService _instance = AudioRouterService._internal();
  factory AudioRouterService() => _instance;
  AudioRouterService._internal();

  static const MethodChannel _channel = MethodChannel(AppConstants.audioChannelName);
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isSpeakerphoneActive = false;
  bool get isSpeakerphoneActive => _isSpeakerphoneActive;

  Timer? _focusAutoTimer;
  Function(bool active)? onFocusModeChanged;

  bool get isFocusModeActive {
    final untilMs = StorageService().focusUntilMs;
    if (untilMs == null) return false;
    final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
    if (DateTime.now().isAfter(until)) {
      _focusAutoTimer?.cancel();
      _focusAutoTimer = null;
      StorageService().setFocusUntilMs(null);
      onFocusModeChanged?.call(false);
      return false;
    }
    return true;
  }

  void setFocusMode(bool active, [Duration duration = const Duration(minutes: 30)]) {
    _focusAutoTimer?.cancel();
    _focusAutoTimer = null;

    if (active) {
      final until = DateTime.now().add(duration);
      StorageService().setFocusUntilMs(until.millisecondsSinceEpoch);
      developer.log('AudioRouterService: Focus mode ACTIVATED until $until', name: 'AudioRouterService');

      // 1. Immediately cut off ordinary incoming audio / chime if not emergency
      if (!_isEmergencyAlertActive) {
        _audioPlayer.stop();
      }

      // 2. Automatically reactivate standard intercom once timer expires
      _focusAutoTimer = Timer(duration, () {
        developer.log('AudioRouterService: Focus mode timer expired, automatically re-enabling intercom', name: 'AudioRouterService');
        setFocusMode(false);
      });
    } else {
      StorageService().setFocusUntilMs(null);
      developer.log('AudioRouterService: Focus mode DEACTIVATED, intercom re-enabled', name: 'AudioRouterService');
    }

    onFocusModeChanged?.call(active);
  }

  bool isClockScreenActive = false;
  final List<VoidCallback> _alarmListeners = [];
  Function()? onAlarmTriggered;

  final List<Function(String bssid)> _wifiListeners = [];
  Function(String bssid)? onWifiConnected;

  void addAlarmListener(VoidCallback listener) {
    if (!_alarmListeners.contains(listener)) {
      _alarmListeners.add(listener);
    }
  }

  void removeAlarmListener(VoidCallback listener) {
    _alarmListeners.remove(listener);
  }

  void addWifiListener(Function(String bssid) listener) {
    if (!_wifiListeners.contains(listener)) {
      _wifiListeners.add(listener);
    }
  }

  void removeWifiListener(Function(String bssid) listener) {
    _wifiListeners.remove(listener);
  }

  void notifyAlarmTriggered() {
    for (final listener in List.of(_alarmListeners)) {
      try {
        listener();
      } catch (e) {
        developer.log('Error in alarm listener: $e', name: 'AudioRouterService');
      }
    }
    onAlarmTriggered?.call();
  }

  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAlarmTriggered') {
        developer.log('Native onAlarmTriggered event received', name: 'AudioRouterService');
        notifyAlarmTriggered();
      } else if (call.method == 'onWifiConnected') {
        final bssid = call.arguments?.toString() ?? '';
        developer.log('Native onWifiConnected event received: $bssid', name: 'AudioRouterService');
        for (final listener in List.of(_wifiListeners)) {
          try {
            listener(bssid);
          } catch (e) {
            developer.log('Error in wifi listener: $e', name: 'AudioRouterService');
          }
        }
        onWifiConnected?.call(bssid);
      }
    });

    // Check if a Focus Mode schedule was active before app restart
    final savedFocusUntilMs = StorageService().focusUntilMs;
    if (savedFocusUntilMs != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(savedFocusUntilMs);
      final remaining = until.difference(DateTime.now());
      if (remaining > Duration.zero) {
        _focusAutoTimer?.cancel();
        _focusAutoTimer = Timer(remaining, () {
          setFocusMode(false);
        });
        developer.log('AudioRouterService: Restored active Focus Mode ($remaining remaining)', name: 'AudioRouterService');
      } else {
        StorageService().setFocusUntilMs(null);
      }
    }

    try {
      // Configure audio context to use STREAM_ALARM to bypass DND
      final AudioContext audioContext = AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      );
      await AudioPlayer.global.setAudioContext(audioContext);
    } catch (e) {
      developer.log('Failed to configure AudioPlayer global context: $e', name: 'AudioRouterService');
    }
  }

  /// Check if the application was launched/resumed by AlarmManager
  Future<bool> checkInitialAlarm() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkInitialAlarm');
      return res == true;
    } catch (e) {
      developer.log('Error checking initial alarm: $e', name: 'AudioRouterService');
      return false;
    }
  }

  /// Direct loudspeaker output via native Android AudioManager
  Future<void> setSpeakerphoneOn(bool enable) async {
    try {
      await _channel.invokeMethod('setSpeakerphoneOn', {'enable': enable});
      _isSpeakerphoneActive = enable;
    } on PlatformException catch (e) {
      developer.log('Error setting speakerphone: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Set the physical acoustic ceiling directly on Android AudioManager
  Future<void> setVolumeCeiling(double ceiling) async {
    try {
      await _channel.invokeMethod('setVolumeCeiling', {'ceiling': ceiling.clamp(0.1, 1.0)});
    } on PlatformException catch (e) {
      developer.log('Error setting volume ceiling: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Route audio stream to USAGE_ALARM (STREAM_ALARM) to bypass Silent & DND
  Future<void> routeAudioToAlarm() async {
    try {
      await _channel.invokeMethod('routeAudioToAlarm');
      _isSpeakerphoneActive = true;
    } on PlatformException catch (e) {
      developer.log('Error routing audio to alarm: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Wake the receiver device over lockscreen
  Future<void> wakeDevice() async {
    try {
      await _channel.invokeMethod('wakeDevice');
    } on PlatformException catch (e) {
      developer.log('Error waking device: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Plays the high-priority chime alert immediately through the speaker (rejected if Focus Mode active)
  Future<void> playChimeAlert() async {
    if (isFocusModeActive) {
      developer.log('AudioRouterService: Standard chime alert rejected silently (Focus Mode active)', name: 'AudioRouterService');
      return;
    }
    try {
      await wakeDevice();
      await routeAudioToAlarm();
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('audio/chime.wav'));
    } catch (e) {
      developer.log('Error playing chime: $e', name: 'AudioRouterService');
    }
  }

  /// Start hardware continuous cyclical emergency vibration
  Future<void> startEmergencyVibration() async {
    try {
      await _channel.invokeMethod('startEmergencyVibration');
    } on PlatformException catch (e) {
      developer.log('Error starting emergency vibration: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Stop hardware continuous cyclical emergency vibration
  Future<void> stopEmergencyVibration() async {
    try {
      await _channel.invokeMethod('stopEmergencyVibration');
    } on PlatformException catch (e) {
      developer.log('Error stopping emergency vibration: ${e.message}', name: 'AudioRouterService');
    }
  }

  // Active emergency alert state & timer
  bool _isEmergencyAlertActive = false;
  bool get isEmergencyAlertActive => _isEmergencyAlertActive;
  dynamic _emergencySafetyTimer;

  /// Start Level 2 Continuous Emergency Alarm (Paging violent)
  Future<void> startEmergencyAlert() async {
    if (_isEmergencyAlertActive) return;
    _isEmergencyAlertActive = true;
    try {
      await wakeDevice();
      await routeAudioToAlarm();
      await startEmergencyVibration();
      await _audioPlayer.stop();
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.play(AssetSource('audio/chime.wav'));

      // 60 seconds safety auto-timeout
      _emergencySafetyTimer?.cancel();
      _emergencySafetyTimer = Future.delayed(const Duration(seconds: 60), () {
        if (_isEmergencyAlertActive) {
          stopEmergencyAlert();
        }
      });
    } catch (e) {
      developer.log('Error starting emergency alert: $e', name: 'AudioRouterService');
    }
  }

  /// Stop Level 2 Continuous Emergency Alarm
  Future<void> stopEmergencyAlert() async {
    if (!_isEmergencyAlertActive) return;
    _isEmergencyAlertActive = false;
    _emergencySafetyTimer = null;
    try {
      await stopEmergencyVibration();
      await _audioPlayer.stop();
      await _audioPlayer.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      developer.log('Error stopping emergency alert: $e', name: 'AudioRouterService');
    }
  }

  /// Schedule native Doze-proof alarm via AlarmManager.setAlarmClock()
  Future<void> setAlarmClock(DateTime triggerTime) async {
    try {
      await _channel.invokeMethod('setAlarmClock', {
        'triggerTimeMs': triggerTime.millisecondsSinceEpoch,
      });
      developer.log('Native alarm clock set for $triggerTime', name: 'AudioRouterService');
    } on PlatformException catch (e) {
      developer.log('Error setting alarm clock: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Cancel native alarm clock
  Future<void> cancelAlarmClock() async {
    try {
      await _channel.invokeMethod('cancelAlarmClock');
    } on PlatformException catch (e) {
      developer.log('Error cancelling alarm clock: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Start step detector sensor
  Future<void> startStepDetector() async {
    try {
      await _channel.invokeMethod('startStepDetector');
    } on PlatformException catch (e) {
      developer.log('Error starting step detector: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Get current step count from sensor
  Future<int> getStepCount() async {
    try {
      final count = await _channel.invokeMethod<int>('getStepCount');
      return count ?? 0;
    } on PlatformException catch (_) {
      return 0;
    }
  }

  /// Stop step detector sensor
  Future<void> stopStepDetector() async {
    try {
      await _channel.invokeMethod('stopStepDetector');
    } on PlatformException catch (e) {
      developer.log('Error stopping step detector: ${e.message}', name: 'AudioRouterService');
    }
  }

  /// Ascending exponential volume ramp (5% to 100% over 60 seconds)
  Timer? _rampTimer;
  Future<void> startAscendingAlarmRamp() async {
    await wakeDevice();
    await routeAudioToAlarm();
    await _audioPlayer.stop();
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    await _audioPlayer.play(AssetSource('audio/chime.wav'));

    double volume = 0.05;
    await setVolumeCeiling(volume);

    _rampTimer?.cancel();
    _rampTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      volume = (volume * 1.2).clamp(0.05, 1.0);
      await setVolumeCeiling(volume);
      if (volume >= 1.0) {
        timer.cancel();
      }
    });
  }

  void stopAscendingAlarmRamp() {
    _rampTimer?.cancel();
    _rampTimer = null;
    _audioPlayer.stop();
  }

  void dispose() {
    stopEmergencyAlert();
    stopAscendingAlarmRamp();
    _audioPlayer.dispose();
  }
}
