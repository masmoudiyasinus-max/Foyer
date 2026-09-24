import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'core/theme/app_theme.dart';
import 'core/services/storage_service.dart';
import 'core/services/foyer_manager_service.dart';
import 'core/services/audio_router_service.dart';
import 'core/services/webrtc_service.dart';
import 'core/services/discovery_service.dart';
import 'core/services/background_service.dart';
import 'core/services/update_service.dart';
import 'features/onboarding/ecran_onboarding.dart';
import 'features/navigation/main_scaffold.dart';
import 'features/clock/ecran_horloge_ambiante.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pure pitch-black Android system status & navigation bars
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.layer1Surface,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: AppTheme.layer3Border,
    ),
  );

  // 1. Initialize Hive Local Storage & run midnight task purge check
  final storageService = StorageService();
  await storageService.initialize();

  // 1.1 Initialize Foyer Manager Service & active foyer context
  final foyerManager = FoyerManagerService();
  await foyerManager.initialize();

  // 2. Initialize Audio Routing to USAGE_ALARM and Loudspeaker
  final audioRouter = AudioRouterService();
  await audioRouter.initialize();

  // 3. Initialize Foreground 24/7 background listener
  final backgroundService = BackgroundService();
  backgroundService.initForegroundTask();

  // 4. Initialize Firebase (Offline-safe fallback)
  try {
    await Firebase.initializeApp();
    developer.log('Firebase initialized successfully', name: 'Main');
  } catch (e) {
    developer.log('Firebase initialization skipped or running offline: $e', name: 'Main');
  }

  // 5. If already onboarded, bootstrap background network & WebRTC services
  if (storageService.isOnboarded) {
    final myName = storageService.memberName;
    final myDeviceId = storageService.deviceId;
    final familyCode = foyerManager.getCurrentFoyer().familyCode.isNotEmpty
        ? foyerManager.getCurrentFoyer().familyCode
        : storageService.familyCode;

    // Start 24/7 background service
    await backgroundService.startService();

    // Initialize WebRTC engine & start ephemeral signaling listener
    final webrtcService = WebRtcService();
    await webrtcService.initialize();
    webrtcService.startSignalingListener(
      familyCode: familyCode,
      myDeviceId: myDeviceId,
    );

    // Start mDNS Bonsoir LAN discovery and Firebase sync
    final discoveryService = DiscoveryService();
    await discoveryService.start(
      myName: myName,
      myDeviceId: myDeviceId,
      familyCode: familyCode,
    );
  }

  runApp(IntercomFoyerApp(isOnboarded: storageService.isOnboarded));
}

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class IntercomFoyerApp extends StatefulWidget {
  final bool isOnboarded;
  const IntercomFoyerApp({super.key, required this.isOnboarded});

  @override
  State<IntercomFoyerApp> createState() => _IntercomFoyerAppState();
}

class _IntercomFoyerAppState extends State<IntercomFoyerApp> {
  bool _isShowingEmergencyDialog = false;

  @override
  void initState() {
    super.initState();
    WebRtcService().onIncomingEmergencyAlert = (senderId, senderName) {
      if (!mounted) return;
      _showEmergencyModal(senderName);
    };

    AudioRouterService().onAlarmTriggered = () {
      if (!mounted) return;
      _routeToActiveAlarm();
    };

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final isAlarm = await AudioRouterService().checkInitialAlarm();
      if (isAlarm && mounted) {
        _routeToActiveAlarm();
      }

      // Non-blocking background check for app updates
      if (widget.isOnboarded) {
        UpdateService().checkForUpdate().then((info) {
          if (info != null && mounted) {
            final ctx = rootNavigatorKey.currentContext;
            if (ctx != null && ctx.mounted) {
              UpdateService().showUpdateDialog(ctx, info);
            }
          }
        });
      }
    });
  }

  void _routeToActiveAlarm() {
    final nav = rootNavigatorKey.currentState;
    if (nav != null) {
      if (AudioRouterService().isClockScreenActive) {
        return;
      }
      nav.push(
        MaterialPageRoute(
          builder: (_) => const EcranHorlogeAmbiante(autoTriggerAlarm: true),
        ),
      );
    }
  }

  void _showEmergencyModal(String senderName) {
    if (_isShowingEmergencyDialog) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = rootNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;

      _isShowingEmergencyDialog = true;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: AppTheme.layer1Surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppTheme.alertRed, width: 2),
            ),
            icon: const Icon(Icons.warning_amber_rounded, color: AppTheme.alertRed, size: 52),
            title: const Text(
              "ALERTE D'URGENCE DU FOYER",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'RedRose',
                color: AppTheme.alertRed,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            content: Text(
              "$senderName a déclenché une alerte d'urgence prioritaire.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'InstrumentSans',
                color: AppTheme.textPrimary,
                fontSize: 15,
                height: 1.4,
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.alertRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    AudioRouterService().stopEmergencyAlert();
                    _isShowingEmergencyDialog = false;
                    Navigator.of(dialogCtx).pop();
                  },
                  child: const Text(
                    "Accepter / J'ai compris",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'InstrumentSans',
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ).then((_) {
        _isShowingEmergencyDialog = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Foyer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: widget.isOnboarded ? const MainScaffold() : const EcranOnboarding(),
    );
  }
}

