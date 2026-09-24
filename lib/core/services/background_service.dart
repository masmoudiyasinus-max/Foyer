import 'dart:developer' as developer;
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Top-level entry point for background foreground task
@pragma('vm:entry-point')
void startForegroundServiceCallback() {
  FlutterForegroundTask.setTaskHandler(IntercomTaskHandler());
}

class IntercomTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    developer.log('IntercomTaskHandler started in background', name: 'BackgroundService');
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    // Keep background sockets and wake lock active
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    developer.log('IntercomTaskHandler destroyed', name: 'BackgroundService');
  }
}

class BackgroundService {
  static final BackgroundService _instance = BackgroundService._internal();
  factory BackgroundService() => _instance;
  BackgroundService._internal();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foyer_service_channel',
        channelName: 'Foyer',
        channelDescription: 'Service d\'écoute permanent pour l\'interphone Foyer',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<bool> startService() async {
    if (await FlutterForegroundTask.isRunningService) {
      _isRunning = true;
      return true;
    }

    final bool result = await FlutterForegroundTask.startService(
      notificationTitle: 'Intercom Foyer Actif',
      notificationText: 'Prêt à recevoir les transmissions audio',
      callback: startForegroundServiceCallback,
    );

    _isRunning = result;
    return _isRunning;
  }

  Future<bool> stopService() async {
    final bool result = await FlutterForegroundTask.stopService();
    if (result) {
      _isRunning = false;
    }
    return result;
  }
}
