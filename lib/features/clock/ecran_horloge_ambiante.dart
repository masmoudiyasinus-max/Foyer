import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/audio_router_service.dart';
import '../../core/services/discovery_service.dart';
import '../../core/services/storage_service.dart';

class EcranHorlogeAmbiante extends StatefulWidget {
  final bool autoTriggerAlarm;
  const EcranHorlogeAmbiante({super.key, this.autoTriggerAlarm = false});

  @override
  State<EcranHorlogeAmbiante> createState() => _EcranHorlogeAmbianteState();
}

class _EcranHorlogeAmbianteState extends State<EcranHorlogeAmbiante> {
  final AudioRouterService _audioRouter = AudioRouterService();
  final DiscoveryService _discovery = DiscoveryService();
  final StorageService _storage = StorageService();

  late DateTime _currentTime;
  Timer? _clockTimer;
  Timer? _pixelShiftTimer;
  Offset _pixelShift = Offset.zero;

  // Alarm state
  TimeOfDay? _scheduledAlarm;
  bool _isRinging = false;
  bool _isSecondAlarm = false;
  Timer? _alarmSafetyTimer;
  Timer? _smartWakeTimer;
  Timer? _stepPollTimer;

  // Smart Wake Check state
  bool _isSmartWakeActive = false;
  bool _isWakeConfirmedByWalk = false;
  int _stepCount = 0;

  // Daily Appreciation Note ("Le Merci du Soir")
  String _dailyAppreciation = 'Merci à tous pour votre aide précieuse aujourd\'hui.';
  StreamSubscription? _merciSubscription;

  @override
  void initState() {
    super.initState();
    _currentTime = DateTime.now();
    _dailyAppreciation = _storage.merciDuSoir;

    AudioRouterService().isClockScreenActive = true;
    AudioRouterService().addAlarmListener(_onNativeAlarmTriggered);

    if (_storage.familyCode.isNotEmpty) {
      try {
        final ref = FirebaseDatabase.instance.ref('foyers/${_storage.familyCode}/merci');
        _merciSubscription = ref.onValue.listen((event) {
          final raw = event.snapshot.value;
          if (raw is Map && raw['text'] != null) {
            final text = raw['text'].toString();
            if (text.isNotEmpty && mounted) {
              setState(() {
                _dailyAppreciation = text;
              });
            }
          }
        });
      } catch (_) {}
    }

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _currentTime = DateTime.now();
      });
      _checkAlarmTrigger();
    });

    // AMOLED Pixel-Shift protection: shifts ±6 pixels every 60s
    _pixelShiftTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      final rand = Random();
      final dx = (rand.nextDouble() * 12 - 6);
      final dy = (rand.nextDouble() * 12 - 6);
      setState(() {
        _pixelShift = Offset(dx, dy);
      });
    });

    // Check if launched by AlarmManager or initial intent
    AudioRouterService().checkInitialAlarm().then((isAlarm) {
      if (isAlarm && mounted && !_isRinging) {
        _triggerAlarmRinging();
      }
    });

    // If launched from native AlarmManager Intent
    if (widget.autoTriggerAlarm) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isRinging) {
          _triggerAlarmRinging();
        }
      });
    }
  }

  void _onNativeAlarmTriggered() {
    if (mounted && !_isRinging) {
      _triggerAlarmRinging(isSecond: _isSecondAlarm);
    }
  }

  @override
  void dispose() {
    AudioRouterService().removeAlarmListener(_onNativeAlarmTriggered);
    AudioRouterService().isClockScreenActive = false;
    _clockTimer?.cancel();
    _pixelShiftTimer?.cancel();
    _alarmSafetyTimer?.cancel();
    _smartWakeTimer?.cancel();
    _stepPollTimer?.cancel();
    _merciSubscription?.cancel();
    _audioRouter.stopStepDetector();
    _audioRouter.stopEmergencyVibration();
    _audioRouter.stopAscendingAlarmRamp();
    super.dispose();
  }

  void _checkAlarmTrigger() {
    if (_scheduledAlarm == null || _isRinging) return;
    if (_currentTime.hour == _scheduledAlarm!.hour &&
        _currentTime.minute == _scheduledAlarm!.minute &&
        _currentTime.second == 0) {
      _triggerAlarmRinging();
    }
  }

  void _triggerAlarmRinging({bool isSecond = false}) {
    setState(() {
      _isRinging = true;
      _isSecondAlarm = isSecond;
      _isSmartWakeActive = false;
      _isWakeConfirmedByWalk = false;
    });

    _audioRouter.startAscendingAlarmRamp();
    _audioRouter.startEmergencyVibration();

    // 5-minute strict safety cutoff
    _alarmSafetyTimer?.cancel();
    _alarmSafetyTimer = Timer(const Duration(minutes: 5), () {
      if (_isRinging) {
        _silenceAlarm();
      }
    });
  }

  void _silenceAlarm() {
    _audioRouter.stopAscendingAlarmRamp();
    _audioRouter.stopEmergencyVibration();
    _alarmSafetyTimer?.cancel();
    _smartWakeTimer?.cancel();
    _stepPollTimer?.cancel();
    _audioRouter.stopStepDetector();
    _audioRouter.cancelAlarmClock();

    if (mounted) {
      setState(() {
        _isRinging = false;
        _isSmartWakeActive = false;
        _isSecondAlarm = false;
      });
    }
  }

  void _dismissFirstAlarm() {
    _audioRouter.stopAscendingAlarmRamp();
    _audioRouter.stopEmergencyVibration();
    _alarmSafetyTimer?.cancel();

    setState(() {
      _isRinging = false;
      _isSmartWakeActive = true;
      _isWakeConfirmedByWalk = false;
      _isSecondAlarm = true;
      _stepCount = 0;
    });

    // Schedule Smart Wake Check between 4 and 10 minutes later (random window)
    final randMinutes = 4 + Random().nextInt(7); // 4 to 10 min
    final wakeDuration = Duration(minutes: randMinutes);

    // Hardware Doze-proof backup alarm via AlarmManager
    final backupTrigger = DateTime.now().add(wakeDuration);
    _audioRouter.setAlarmClock(backupTrigger);

    // Start background step detector with partial wake lock (10 min max)
    _audioRouter.startStepDetector();

    _smartWakeTimer?.cancel();
    _smartWakeTimer = Timer(wakeDuration, () {
      // If user hasn't walked 20 steps, ring second wake
      if (_stepCount < 20 && mounted) {
        _audioRouter.stopStepDetector();
        _stepPollTimer?.cancel();
        _triggerAlarmRinging(isSecond: true);
      }
    });

    // Poll step detector every second
    _stepPollTimer?.cancel();
    _stepPollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final steps = await _audioRouter.getStepCount();
      if (mounted) {
        setState(() {
          _stepCount = steps;
        });
      }
      if (steps >= 20) {
        // User confirmed awake and walking!
        _smartWakeTimer?.cancel();
        timer.cancel();
        await _audioRouter.cancelAlarmClock();
        await _audioRouter.stopStepDetector();
        if (mounted) {
          setState(() {
            _isSmartWakeActive = false;
            _isWakeConfirmedByWalk = true;
            _isSecondAlarm = false;
          });
        }
      }
    });
  }

  void _pickAlarmTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _scheduledAlarm ?? const TimeOfDay(hour: 7, minute: 0),
    );
    if (picked != null) {
      setState(() {
        _scheduledAlarm = picked;
        _isWakeConfirmedByWalk = false;
      });

      final now = DateTime.now();
      var trigger = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
      if (trigger.isBefore(now)) {
        trigger = trigger.add(const Duration(days: 1));
      }
      await _audioRouter.setAlarmClock(trigger);
    }
  }

  String _formatHumanizedNextAlarm() {
    if (_scheduledAlarm == null) return 'Aucune alarme programmée';
    final now = DateTime.now();
    final h = _scheduledAlarm!.hour.toString().padLeft(2, '0');
    final m = _scheduledAlarm!.minute.toString().padLeft(2, '0');
    final isToday = (_scheduledAlarm!.hour > now.hour) ||
        (_scheduledAlarm!.hour == now.hour && _scheduledAlarm!.minute > now.minute);
    return isToday ? 'Aujourd\'hui à $h:$m' : 'Demain matin à $h:$m';
  }

  void _editMerciDuSoir() {
    final textCtrl = TextEditingController(text: _dailyAppreciation);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.layer1Surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.layer3Border),
        ),
        title: Text(
          'Le Merci du Soir',
          style: GoogleFonts.redRose(color: AppTheme.layer4Active, fontSize: 18),
        ),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLines: 3,
          style: const TextStyle(color: AppTheme.layer4Active),
          decoration: const InputDecoration(
            hintText: 'Partagez une note de gratitude pour le foyer...',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.nordicSlate),
            onPressed: () async {
              final text = textCtrl.text.trim();
              if (text.isNotEmpty) {
                setState(() {
                  _dailyAppreciation = text;
                });
                await _storage.saveMerciDuSoir(text);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hours = _currentTime.hour.toString().padLeft(2, '0');
    final minutes = _currentTime.minute.toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      body: SafeArea(
        child: Stack(
          children: [
            // Close / Back button
            Positioned(
              top: 16,
              left: 16,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: AppTheme.layer4Active),
                onPressed: () => Navigator.pop(context),
              ),
            ),

            // Top action: Pick Alarm
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.alarm_add, color: AppTheme.nordicSlateLight),
                onPressed: _pickAlarmTime,
              ),
            ),

            // Main Display with Pixel-Shift protection
            Center(
              child: Transform.translate(
                offset: _pixelShift,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Stacked M3 Expressive giant vertical digits
                    GestureDetector(
                      onTap: _pickAlarmTime,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            hours,
                            style: GoogleFonts.redRose(
                              fontSize: 104,
                              fontWeight: FontWeight.bold,
                              color: _isRinging ? AppTheme.alertRed : AppTheme.layer4Active,
                              letterSpacing: -2,
                              height: 0.9,
                            ),
                          ),
                          Text(
                            minutes,
                            style: GoogleFonts.redRose(
                              fontSize: 104,
                              fontWeight: FontWeight.bold,
                              color: _isRinging ? AppTheme.alertRed : AppTheme.nordicSlateLight,
                              letterSpacing: -2,
                              height: 0.9,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Humanized Next Alarm Display
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.alarm, size: 16, color: AppTheme.textMuted),
                        const SizedBox(width: 8),
                        Text(
                          'Prochaine alarme : ${_formatHumanizedNextAlarm()}',
                          style: GoogleFonts.instrumentSans(
                            fontSize: 14,
                            color: AppTheme.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),

                    // Smart Wake monitoring state badge
                    if (_isSmartWakeActive) ...[
                      const SizedBox(height: 12),
                      Card(
                        elevation: 0,
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: const BorderSide(color: AppTheme.nordicSlate),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.directions_walk, size: 16, color: AppTheme.nordicSlateLight),
                              const SizedBox(width: 8),
                              Text(
                                'Smart Wake : $_stepCount / 20 pas',
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.nordicSlateLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ] else if (_isWakeConfirmedByWalk) ...[
                      const SizedBox(height: 12),
                      Card(
                        elevation: 0,
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: const BorderSide(color: AppTheme.nordicSlate),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.check_circle_outline, size: 16, color: AppTheme.nordicSlateLight),
                              const SizedBox(width: 8),
                              Text(
                                'Réveil validé par la marche',
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.nordicSlateLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Ringing state or Dismiss button
                    if (_isRinging)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.alertRed,
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                          ),
                          icon: const Icon(Icons.alarm_off, color: Colors.white),
                          label: Text(
                            _isSecondAlarm ? 'Arrêter le réveil' : 'Je suis réveillé(e)',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          onPressed: () {
                            if (_isSecondAlarm) {
                              _silenceAlarm();
                            } else {
                              _dismissFirstAlarm();
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Bottom: "Le Merci du Soir" & Family Wake Telemetry
            Positioned(
              bottom: 24,
              left: 20,
              right: 20,
              child: Column(
                children: [
                  // Daily appreciation phrase (Tap to edit)
                  Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: AppTheme.layer3Border, width: 1),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _editMerciDuSoir,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.favorite_outline, size: 16, color: AppTheme.nordicSlateLight),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _dailyAppreciation,
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 12,
                                  color: AppTheme.layer4Active,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.edit_outlined, size: 14, color: AppTheme.textMuted),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Family Wake Telemetry indicator
                  Text(
                    'Télémétrie réveil : ${(_discovery.membersNotifier.value.where((m) => m.isOnline).length)} membres connectés',
                    style: GoogleFonts.instrumentSans(fontSize: 11, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
