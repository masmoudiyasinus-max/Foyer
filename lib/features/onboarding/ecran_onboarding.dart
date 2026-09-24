import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/discovery_service.dart';
import '../../core/services/background_service.dart';
import '../../core/services/webrtc_service.dart';
import '../../models/family_member.dart';
import '../navigation/main_scaffold.dart';

class EcranOnboarding extends StatefulWidget {
  const EcranOnboarding({super.key});

  @override
  State<EcranOnboarding> createState() => _EcranOnboardingState();
}

class _EcranOnboardingState extends State<EcranOnboarding> {
  int _currentStep = 0;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  bool _micGranted = false;
  bool _notificationGranted = false;
  bool _batteryOptimized = false;
  bool _overlayGranted = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _phoneController.text = '${_detectCountryDialingCode()} ';
    _checkExistingPermissions();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String _detectCountryDialingCode() {
    try {
      final country = WidgetsBinding.instance.platformDispatcher.locale.countryCode?.toUpperCase();
      const countryToDialCode = {
        'TN': '+216',
        'FR': '+33',
        'DZ': '+213',
        'MA': '+212',
        'BE': '+32',
        'CH': '+41',
        'CA': '+1',
        'US': '+1',
        'DE': '+49',
        'GB': '+44',
        'IT': '+39',
        'ES': '+34',
        'EG': '+20',
        'SA': '+966',
        'AE': '+971',
        'SN': '+221',
        'CI': '+225',
        'LY': '+218',
      };
      if (country != null && countryToDialCode.containsKey(country)) {
        return countryToDialCode[country]!;
      }
    } catch (_) {}
    return '+33';
  }

  Future<void> _checkExistingPermissions() async {
    final mic = await Permission.microphone.isGranted;
    final notif = await Permission.notification.isGranted;
    final overlay = await Permission.systemAlertWindow.isGranted;
    final battery = await DisableBatteryOptimization.isBatteryOptimizationDisabled ?? false;

    if (mounted) {
      setState(() {
        _micGranted = mic;
        _notificationGranted = notif;
        _overlayGranted = overlay;
        _batteryOptimized = battery;
      });
    }
  }

  Future<void> _requestStep1() async {
    final micStatus = await Permission.microphone.request();
    final notifStatus = await Permission.notification.request();
    if (mounted) {
      setState(() {
        _micGranted = micStatus.isGranted;
        _notificationGranted = notifStatus.isGranted;
      });
    }
  }

  Future<void> _requestStep2() async {
    try {
      final isIgnored = await DisableBatteryOptimization.isBatteryOptimizationDisabled;
      if (isIgnored == false) {
        await DisableBatteryOptimization.showDisableBatteryOptimizationSettings();
      }
      final isManDisabled = await DisableBatteryOptimization.isManufacturerBatteryOptimizationDisabled;
      if (isManDisabled == false) {
        await DisableBatteryOptimization.showDisableManufacturerBatteryOptimizationSettings(
          "Foyer nécessite l'exécution permanente en arrière-plan.",
          "Veuillez désactiver l'optimisation de batterie.",
        );
      }
    } catch (_) {}
    await _checkExistingPermissions();
  }

  Future<void> _requestStep3() async {
    try {
      final status = await Permission.systemAlertWindow.request();
      if (mounted) {
        setState(() {
          _overlayGranted = status.isGranted;
        });
      }
    } catch (_) {}
  }

  Future<void> _finishOnboarding() async {
    final name = _nameController.text.trim();
    final code = _codeController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Veuillez renseigner votre nom');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final randomHex = List.generate(8, (_) => Random().nextInt(16).toRadixString(16)).join();
      final deviceId = 'dev_$randomHex';
      final finalCode = (code.isNotEmpty ? code : 'FOYER').toUpperCase();

      final storage = StorageService();
      await storage.saveUserProfile(
        name: name,
        familyCode: finalCode,
        deviceId: deviceId,
        connectionMode: 'auto',
      );

      // Save initial portfolio profile
      final initialMember = FamilyMember(
        id: deviceId,
        name: name,
        phone: _phoneController.text.trim(),
        isApproved: true,
        isOnline: true,
        updatedAt: DateTime.now(),
      );
      await storage.savePortfolio(initialMember);

      // Bootstrap discovery and networking
      final discoveryService = DiscoveryService();
      await discoveryService.start(
        myName: name,
        myDeviceId: deviceId,
        familyCode: finalCode,
        mode: 'auto',
      );

      try {
        final backgroundService = BackgroundService();
        await backgroundService.startService();

        final webrtcService = WebRtcService();
        await webrtcService.initialize();
        webrtcService.startSignalingListener(
          familyCode: finalCode,
          myDeviceId: deviceId,
        );
      } catch (_) {}

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainScaffold()),
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Erreur d\'enregistrement : $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.layer2Container,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.layer3Border, width: 1.5),
                  ),
                  child: const Icon(Icons.home_outlined, size: 28, color: AppTheme.nordicSlateLight),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Bienvenue sur Foyer',
                textAlign: TextAlign.center,
                style: GoogleFonts.redRose(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.layer4Active,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Configuration guidée du système domestique',
                textAlign: TextAlign.center,
                style: GoogleFonts.instrumentSans(
                  fontSize: 13,
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 28),

              // Stepper Indicator
              Row(
                children: List.generate(4, (index) {
                  final isActive = index <= _currentStep;
                  return Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: isActive ? AppTheme.nordicSlate : AppTheme.layer3Border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 28),

              // Step Content
              if (_currentStep == 0) _buildIdentityStep(),
              if (_currentStep == 1) _buildPermissionsStep(),
              if (_currentStep == 2) _buildBatteryStep(),
              if (_currentStep == 3) _buildOverlayStep(),

              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.instrumentSans(
                    fontSize: 13,
                    color: AppTheme.alertRed,
                  ),
                ),
              ],

              const SizedBox(height: 32),

              // Navigation Buttons
              Row(
                children: [
                  if (_currentStep > 0)
                    Expanded(
                      flex: 1,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppTheme.layer3Border),
                        ),
                        onPressed: () => setState(() => _currentStep--),
                        child: Text(
                          'Retour',
                          style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
                        ),
                      ),
                    ),
                  if (_currentStep > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.nordicSlate,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _isLoading
                          ? null
                          : () {
                              if (_currentStep < 3) {
                                if (_currentStep == 0 && _nameController.text.trim().isEmpty) {
                                  setState(() => _errorMessage = 'Veuillez saisir votre nom');
                                  return;
                                }
                                setState(() {
                                  _errorMessage = null;
                                  _currentStep++;
                                });
                              } else {
                                _finishOnboarding();
                              }
                            },
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _currentStep == 3 ? 'Entrer dans le Foyer' : 'Continuer',
                              style: GoogleFonts.instrumentSans(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdentityStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Votre Identité',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
          decoration: const InputDecoration(
            labelText: 'Votre Nom ou Pièce (ex: Salon, Papa)',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
          decoration: const InputDecoration(
            labelText: 'Numéro de téléphone (avec indicatif)',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
          decoration: const InputDecoration(
            labelText: 'Code Foyer (Optionnel, ex: MAISON)',
            prefixIcon: Icon(Icons.tag),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Microphone & Notifications',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        const SizedBox(height: 8),
        Text(
          'Nécessaires pour l\'interphone vocal direct et les carillons d\'appel.',
          style: GoogleFonts.instrumentSans(fontSize: 13, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        _buildPermissionTile(
          title: 'Microphone matériel',
          granted: _micGranted,
          icon: Icons.mic_none_outlined,
        ),
        const SizedBox(height: 10),
        _buildPermissionTile(
          title: 'Notifications d\'appel',
          granted: _notificationGranted,
          icon: Icons.notifications_none_outlined,
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          icon: const Icon(Icons.security),
          label: const Text('Accorder les autorisations'),
          onPressed: _requestStep1,
        ),
      ],
    );
  }

  Widget _buildBatteryStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Exemption de Batterie & Autostart',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        const SizedBox(height: 8),
        Text(
          'Autorise Foyer à fonctionner en arrière-plan sans être interrompu par le système.',
          style: GoogleFonts.instrumentSans(fontSize: 13, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        _buildPermissionTile(
          title: 'Exécution permanente 24/7',
          granted: _batteryOptimized,
          icon: Icons.battery_charging_full_outlined,
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          icon: const Icon(Icons.battery_alert_outlined),
          label: const Text('Désactiver l\'optimisation de batterie'),
          onPressed: _requestStep2,
        ),
      ],
    );
  }

  Widget _buildOverlayStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Superposition & Alertes d\'Urgence',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        const SizedBox(height: 8),
        Text(
          'Permet à l\'interphone d\'afficher les alertes critiques et le réveil même écran éteint.',
          style: GoogleFonts.instrumentSans(fontSize: 13, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        _buildPermissionTile(
          title: 'Affichage par-dessus les applications',
          granted: _overlayGranted,
          icon: Icons.layers_outlined,
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Autoriser la superposition système'),
          onPressed: _requestStep3,
        ),
      ],
    );
  }

  Widget _buildPermissionTile({
    required String title,
    required bool granted,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.layer2Container,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: granted ? AppTheme.nordicSlate : AppTheme.layer3Border,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: granted ? AppTheme.nordicSlateLight : AppTheme.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.instrumentSans(
                fontSize: 14,
                color: AppTheme.layer4Active,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Icon(
            granted ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: granted ? AppTheme.nordicSlateLight : AppTheme.textMuted,
          ),
        ],
      ),
    );
  }
}
