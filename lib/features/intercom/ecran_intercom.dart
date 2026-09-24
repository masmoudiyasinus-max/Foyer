import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/webrtc_service.dart';
import '../../core/services/discovery_service.dart';
import '../../models/family_member.dart';
import '../../models/announcement.dart';
import '../../core/services/foyer_manager_service.dart';
import '../portfolio/ecran_portfolio.dart';
import '../clock/ecran_horloge_ambiante.dart';
import '../map/ecran_carte_foyer.dart';
import '../meals/ecran_repas_partages.dart';
import '../stories/ecran_family_stories.dart';
import 'widgets/ambient_header_card.dart';
import 'widgets/foyer_selector_modal.dart';
import '../../core/services/update_service.dart';

class EcranIntercom extends StatefulWidget {
  const EcranIntercom({super.key});

  @override
  State<EcranIntercom> createState() => _EcranIntercomState();
}

class _EcranIntercomState extends State<EcranIntercom> {
  final StorageService _storage = StorageService();
  final WebRtcService _webrtc = WebRtcService();
  final DiscoveryService _discovery = DiscoveryService();
  final FoyerManagerService _foyerManager = FoyerManagerService();

  List<FamilyMember> _members = [];
  final Set<String> _selectedMemberIds = {};
  bool _selectAll = true;

  FamilyMember? _unapprovedCandidate;
  Announcement? _announcement;

  bool _isPttLocked = false;
  bool _isTransmitting = false;
  bool _isTransmitError = false;
  bool _isPointerPhysicallyDown = false;
  String _transmitErrorMessage = 'Erreur';
  Timer? _errorResetTimer;
  Timer? _inactivityBreakerTimer;
  bool _showInactivityBanner = false;
  double _pointerStartY = 0.0;
  bool _isSpeakerphoneOn = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _isSpeakerphoneOn = _storage.isSpeakerphoneEnabled;

    // One-time microphone permission check on screen entry
    unawaited(Permission.microphone.request());

    // Ensure discovery and signaling are active
    _discovery.ensureStarted(
      myName: _storage.memberName,
      myDeviceId: _storage.deviceId,
      familyCode: _storage.familyCode,
      mode: _storage.connectionMode,
    );
    _webrtc.startSignalingListener(
      familyCode: _storage.familyCode,
      myDeviceId: _storage.deviceId,
    );

    // Listen to DiscoveryService ValueNotifier for instantaneous reactive updates
    _discovery.membersNotifier.addListener(_onMembersUpdated);
    _onMembersUpdated();

    _foyerManager.activeFoyerNotifier.addListener(_onActiveFoyerChanged);

    // Sync family stories in real-time
    _storage.startStoriesSync(() {
      if (mounted) setState(() {});
    });

    _discovery.onNewMemberDiscovered = (candidate) {
      if (mounted && !_storage.hasDecisionForMember(candidate.id)) {
        setState(() {
          _unapprovedCandidate = candidate;
        });
      }
    };

    _webrtc.onCallStateChanged = (state) {
      if (mounted) {
        setState(() {
          if (state == CallState.transmitting) {
            _isTransmitting = true;
          } else if (state == CallState.disconnected || state == CallState.error) {
            // Strict physical synchronization: cut transmission and alert user immediately
            _isPttLocked = false;
            _isTransmitting = false;
            _isPointerPhysicallyDown = false;
            _isTransmitError = true;
            _transmitErrorMessage = 'Aucun membre connecté';
            _stopInactivityTimer();
            HapticFeedback.heavyImpact();
            _errorResetTimer?.cancel();
            _errorResetTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) {
                setState(() => _isTransmitError = false);
              }
            });
          } else if (state == CallState.idle && !_isPttLocked && !_isPointerPhysicallyDown) {
            _isTransmitting = false;
            _stopInactivityTimer();
          }
        });
      }
    };
  }

  int _consecutiveSilentSeconds = 0;
  static const double _voiceThreshold = 0.02;
  static const int _maxSilentSeconds = 300; // 5 minutes cumulées de silence

  void _startInactivityTimer() {
    _stopInactivityTimer();
    if (!_storage.inactivityBreakerEnabled) return;
    _consecutiveSilentSeconds = 0;

    _inactivityBreakerTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || !_isPttLocked) {
        timer.cancel();
        return;
      }

      final double audioLevel = await _webrtc.getSenderAudioLevel();
      developer.log('VAD: audioLevel=$audioLevel, silenceSec=$_consecutiveSilentSeconds', name: 'IntercomVAD');

      if (audioLevel >= _voiceThreshold) {
        // Voice detected: reset silence counter
        _consecutiveSilentSeconds = 0;
      } else {
        // Silence detected: accumulate silent seconds
        _consecutiveSilentSeconds += 2;
        if (_consecutiveSilentSeconds >= _maxSilentSeconds) {
          timer.cancel();
          if (mounted && _isPttLocked) {
            _unlockAndStop();
            setState(() {
              _showInactivityBanner = true;
            });
          }
        }
      }
    });
  }

  void _stopInactivityTimer() {
    _inactivityBreakerTimer?.cancel();
    _inactivityBreakerTimer = null;
    _consecutiveSilentSeconds = 0;
  }

  void _onMembersUpdated() {
    if (mounted) {
      setState(() {
        _members = _discovery.membersNotifier.value;
        if (_selectAll) {
          _selectedMemberIds.clear();
          for (final m in _members) {
            if (m.isApproved && !_storage.isMemberBlocked(m.id)) {
              _selectedMemberIds.add(m.id);
            }
          }
        }
      });
    }
  }

  void _loadInitialData() {
    setState(() {
      _announcement = _storage.getAnnouncement();
      _members = _discovery.currentMembers;
    });
  }

  @override
  void dispose() {
    _errorResetTimer?.cancel();
    _stopInactivityTimer();
    _discovery.membersNotifier.removeListener(_onMembersUpdated);
    _foyerManager.activeFoyerNotifier.removeListener(_onActiveFoyerChanged);
    _storage.stopStoriesSync();
    super.dispose();
  }

  void _onActiveFoyerChanged() {
    if (mounted) {
      _loadInitialData();
      setState(() {});
    }
  }

  void _handleMemberApproval(FamilyMember member, bool approve) {
    _discovery.approveDiscoveredMember(member.id, approve);
    setState(() {
      _unapprovedCandidate = null;
    });
  }

  void _toggleSelectAll() {
    setState(() {
      _selectAll = !_selectAll;
      _selectedMemberIds.clear();
      if (_selectAll) {
        for (final m in _members) {
          if (m.isApproved) _selectedMemberIds.add(m.id);
        }
      }
    });
  }

  void _toggleMemberSelection(String id) {
    setState(() {
      if (_selectedMemberIds.contains(id)) {
        _selectedMemberIds.remove(id);
      } else {
        _selectedMemberIds.add(id);
      }
      _selectAll = _selectedMemberIds.length == _approvedMembers.length && _approvedMembers.isNotEmpty;
    });
  }

  List<FamilyMember> get _approvedMembers =>
      _members.where((m) => m.isApproved).toList();

  List<String> get _targetRecipients {
    final approved = _approvedMembers.where((m) => !_storage.isMemberBlocked(m.id)).toList();
    if (_selectAll || _selectedMemberIds.isEmpty) {
      return approved.map((m) => m.id).toList();
    }
    return _selectedMemberIds.where((id) => !_storage.isMemberBlocked(id)).toList();
  }

  Future<void> _triggerChimeAlert(FamilyMember member) async {
    final myId = _storage.deviceId;
    final myName = _storage.memberName;
    final familyCode = _storage.familyCode;

    try {
      await _webrtc.sendChimeAlert(
        familyCode: familyCode,
        myDeviceId: myId,
        myName: myName,
        targetDeviceId: member.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Alerte envoyée à ${member.name}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      developer.log('Erreur envoi chime: $e', name: 'Intercom');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Échec de transmission réseau'),
            backgroundColor: AppTheme.alertRed,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<bool> _startHardwareMicTransmission() async {
    try {
      // 1. Android audio configuration for WebRTC (Android 14 & Xiaomi HyperOS)
      if (WebRTC.platformIsAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration(androidAudioMode: AndroidAudioMode.inCommunication),
        );
      }

      // 2. Microphone permission verification
      final hasPermission = await Permission.microphone.isGranted;
      if (!hasPermission) {
        final perm = await Permission.microphone.request();
        if (!perm.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Erreur : Permission microphone refusée'),
                backgroundColor: AppTheme.layer2Container,
                duration: Duration(seconds: 3),
              ),
            );
          }
          _unlockAndStop();
          return false;
        }
      }

      final targets = _targetRecipients;
      if (targets.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Recherche de membres sur le réseau Wi-Fi...'),
              backgroundColor: AppTheme.layer2Container,
              duration: Duration(seconds: 2),
            ),
          );
        }
        _unlockAndStop();
        return false;
      }

      await _webrtc.startCall(
        targetDeviceIds: targets,
        familyCode: _storage.familyCode,
        myDeviceId: _storage.deviceId,
      );

      // Race condition protection: if user lifted finger or unlocked while connecting
      if (!_isPointerPhysicallyDown && !_isPttLocked) {
        _webrtc.setMicMute(true);
        return false;
      }

      _webrtc.setMicMute(false);
      return true;
    } catch (e) {
      debugPrint('Hardware mic access error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur Micro : $e'),
            backgroundColor: AppTheme.layer2Container,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _startHardwareMicTransmissionAsync() async {
    final success = await _startHardwareMicTransmission();
    if (!success && mounted) {
      setState(() {
        _isTransmitting = false;
        _isTransmitError = true;
      });
      HapticFeedback.heavyImpact();
      _errorResetTimer?.cancel();
      _errorResetTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) {
          setState(() {
            _isTransmitError = false;
          });
        }
      });
    }
  }

  void _stopHardwareMicTransmission() {
    if (_isPttLocked) return;
    _webrtc.setMicMute(true);
    if (mounted) {
      setState(() => _isTransmitting = false);
    }
  }

  void _unlockAndStop() {
    _errorResetTimer?.cancel();
    _stopInactivityTimer();
    HapticFeedback.lightImpact();
    _isPointerPhysicallyDown = false;
    if (mounted) {
      setState(() {
        _isPttLocked = false;
        _isTransmitting = false;
        _isTransmitError = false;
      });
    }
    _webrtc.setMicMute(true);
  }

  void _showMemberActionModal(FamilyMember member) {
    final bool isBlocked = _storage.isMemberBlocked(member.id);
    final bool isMuted = _storage.isMemberMuted(member.id);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.layer1Surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: AppTheme.layer3Border, width: 1),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.layer2Container,
                          border: Border.all(color: AppTheme.layer3Border),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          member.monogram,
                          style: GoogleFonts.redRose(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.layer4Active,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              member.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              member.isOnline ? 'En ligne' : 'Hors ligne',
                              style: GoogleFonts.instrumentSans(
                                fontSize: 12,
                                color: member.isOnline ? AppTheme.layer4Active : AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: AppTheme.layer3Border),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      isMuted ? Icons.volume_up_outlined : Icons.volume_off_outlined,
                      color: AppTheme.layer4Active,
                    ),
                    title: Text(isMuted ? 'Rétablir le son' : 'Couper le son (Mute)'),
                    onTap: () {
                      _webrtc.setMemberMuted(member.id, !isMuted);
                      Navigator.pop(ctx);
                      setState(() {});
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      isBlocked ? Icons.check_circle_outline : Icons.block_outlined,
                      color: AppTheme.layer4Active,
                    ),
                    title: Text(isBlocked ? 'Débloquer ce membre' : 'Bloquer ce membre'),
                    onTap: () async {
                      await _storage.setMemberBlocked(member.id, !isBlocked);
                      if (!isBlocked) {
                        _selectedMemberIds.remove(member.id);
                      }
                      Navigator.pop(ctx);
                      setState(() {});
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showEditAnnouncementDialog() {
    final titleController = TextEditingController(text: _announcement?.title ?? '');
    final textController = TextEditingController(text: _announcement?.text ?? '');
    final urlController = TextEditingController(text: _announcement?.url ?? '');
    String? imagePath = _announcement?.imagePath;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Bandeau d\'annonce'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'Titre'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: textController,
                  decoration: const InputDecoration(labelText: 'Message'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(labelText: 'Lien URL (optionnel)'),
                ),
                const SizedBox(height: 14),
                if (imagePath != null && File(imagePath!).existsSync()) ...[
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(imagePath!),
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.alertRed),
                    label: const Text('Retirer l\'image', style: TextStyle(color: AppTheme.alertRed)),
                    onPressed: () => setDialogState(() => imagePath = null),
                  ),
                ] else ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: const Text('Ajouter une image'),
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(type: FileType.image);
                      if (result != null && result.files.single.path != null) {
                        setDialogState(() => imagePath = result.files.single.path);
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _storage.clearAnnouncement();
                if (mounted) {
                  setState(() => _announcement = null);
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Supprimer'),
            ),
            FilledButton(
              onPressed: () async {
                if (titleController.text.trim().isNotEmpty) {
                  final ann = Announcement(
                    id: 'active_banner',
                    title: titleController.text.trim(),
                    text: textController.text.trim(),
                    url: urlController.text.trim().isNotEmpty ? urlController.text.trim() : null,
                    imagePath: imagePath,
                    createdAt: DateTime.now(),
                  );
                  await _storage.saveAnnouncement(ann);
                  if (mounted) {
                    setState(() => _announcement = ann);
                    Navigator.pop(ctx);
                  }
                }
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAcousticLimiterModal() {
    double currentCeiling = _webrtc.audioCeiling;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.layer1Surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: AppTheme.layer3Border, width: 1),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Protection Acoustique',
                        style: GoogleFonts.redRose(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                      Text(
                        '${(currentCeiling * 100).round()}%',
                        style: GoogleFonts.instrumentSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: AppTheme.layer4Active,
                      inactiveTrackColor: AppTheme.layer3Border,
                      thumbColor: AppTheme.layer4Active,
                      overlayColor: AppTheme.layer4Active.withValues(alpha: 0.12),
                    ),
                    child: Slider(
                      value: currentCeiling,
                      min: 0.50,
                      max: 1.00,
                      divisions: 10,
                      onChanged: (val) {
                        setModalState(() {
                          currentCeiling = val;
                        });
                        _webrtc.setAudioCeiling(val);
                        _storage.setAudioCeiling(val);
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: const FoyerSelectorAppBarTitle(),
        actions: [
          IconButton(
            icon: Icon(
              _isSpeakerphoneOn ? Icons.volume_up : Icons.phone_in_talk,
              size: 22,
              color: _isSpeakerphoneOn ? AppTheme.nordicSlateLight : AppTheme.layer4Active,
            ),
            onPressed: () async {
              final newMode = !_isSpeakerphoneOn;
              setState(() => _isSpeakerphoneOn = newMode);
              await _webrtc.setSpeakerphoneMode(newMode);
            },
            tooltip: _isSpeakerphoneOn ? 'Haut-parleur' : 'Écouteur',
          ),
          IconButton(
            icon: const Icon(Icons.bedtime_outlined, size: 22),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EcranHorlogeAmbiante()),
              );
            },
            tooltip: 'Horloge Ambiante',
          ),
          IconButton(
            icon: const Icon(Icons.map_outlined, size: 22),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EcranCarteFoyer()),
              );
            },
            tooltip: 'Carte du Foyer',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 22),
            color: AppTheme.layer1Surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppTheme.layer3Border),
            ),
            onSelected: (val) {
              if (val == 'meals') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EcranRepasPartages()),
                );
              } else if (val == 'stories') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EcranFamilyStories()),
                );
              } else if (val == 'limiter') {
                _showAcousticLimiterModal();
              } else if (val == 'announcement') {
                _showEditAnnouncementDialog();
              } else if (val == 'update') {
                UpdateService().checkForUpdateManual(context);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'meals',
                child: Row(
                  children: [
                    Icon(Icons.restaurant_outlined, size: 20, color: AppTheme.layer4Active),
                    SizedBox(width: 12),
                    Text('Repas Partagés', style: TextStyle(color: AppTheme.layer4Active, fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'stories',
                child: Row(
                  children: [
                    Icon(Icons.auto_stories_outlined, size: 20, color: AppTheme.layer4Active),
                    SizedBox(width: 12),
                    Text('Family Stories', style: TextStyle(color: AppTheme.layer4Active, fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'limiter',
                child: Row(
                  children: [
                    Icon(Icons.hearing_outlined, size: 20, color: AppTheme.layer4Active),
                    SizedBox(width: 12),
                    Text('Protection Acoustique', style: TextStyle(color: AppTheme.layer4Active, fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'announcement',
                child: Row(
                  children: [
                    Icon(Icons.campaign_outlined, size: 20, color: AppTheme.layer4Active),
                    SizedBox(width: 12),
                    Text('Bandeau d\'Annonce', style: TextStyle(color: AppTheme.layer4Active, fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'update',
                child: Row(
                  children: [
                    Icon(Icons.system_update_outlined, size: 20, color: AppTheme.layer4Active),
                    SizedBox(width: 12),
                    Text('Mises à jour', style: TextStyle(color: AppTheme.layer4Active, fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The Ambient Header Card (Météo Bioclimatique)
            const AmbientHeaderCard(),

            // Bandeau Coupe-Circuit Inactivité
            if (_showInactivityBanner)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.layer2Container,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.layer3Border, width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer_off_outlined, size: 18, color: AppTheme.layer4Active),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Microphone coupé automatiquement pour inactivité (5 min)',
                        style: GoogleFonts.instrumentSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _showInactivityBanner = false),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close, size: 16, color: AppTheme.layer4Active),
                      ),
                    ),
                  ],
                ),
              ),

            // Bandeau d'annonce (Top Banner) avec Image et Swipe-to-Dismiss
            if (_announcement != null)
              Dismissible(
                key: const ValueKey('active_announcement_banner'),
                direction: DismissDirection.horizontal,
                onDismissed: (_) async {
                  await _storage.clearAnnouncement();
                  if (mounted) {
                    setState(() => _announcement = null);
                  }
                },
                child: GestureDetector(
                  onTap: () async {
                    if (_announcement!.url != null && _announcement!.url!.isNotEmpty) {
                      final uri = Uri.tryParse(_announcement!.url!);
                      if (uri != null && await canLaunchUrl(uri)) {
                        await launchUrl(uri);
                      }
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Card(
                      elevation: 0,
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_announcement!.imagePath != null &&
                                File(_announcement!.imagePath!).existsSync())
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(
                                      File(_announcement!.imagePath!),
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ),
                        Row(
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Icon(Icons.campaign_outlined, color: AppTheme.nordicSlate, size: 22),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _announcement!.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.redRose(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.layer4Active,
                                    ),
                                  ),
                                  if (_announcement!.text.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      _announcement!.text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.instrumentSans(
                                        fontSize: 12,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (_announcement!.url != null && _announcement!.url!.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(Icons.open_in_new, color: AppTheme.textMuted, size: 16),
                              ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 16, color: AppTheme.textMuted),
                              tooltip: 'Fermer l\'annonce',
                              onPressed: () async {
                                await _storage.clearAnnouncement();
                                if (mounted) {
                                  setState(() => _announcement = null);
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

            // New Member Discovery Notification Card avec Swipe-to-Dismiss
            if (_unapprovedCandidate != null)
              Dismissible(
                key: ValueKey('candidate_${_unapprovedCandidate!.id}'),
                direction: DismissDirection.horizontal,
                onDismissed: (_) {
                  _handleMemberApproval(_unapprovedCandidate!, false);
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: AppTheme.layer1Surface,
                              border: Border.all(color: AppTheme.nordicSlate, width: 1.5),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              _unapprovedCandidate!.monogram,
                              style: GoogleFonts.redRose(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.layer4Active,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Nouveau membre détecté : ${_unapprovedCandidate!.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.instrumentSans(
                                fontSize: 13,
                                color: AppTheme.layer4Active,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            ),
                            onPressed: () => _handleMemberApproval(_unapprovedCandidate!, false),
                            child: const Text('Ignorer', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 6),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.nordicSlate,
                              foregroundColor: AppTheme.layer4Active,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            ),
                            onPressed: () => _handleMemberApproval(_unapprovedCandidate!, true),
                            child: const Text('Accepter', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // Family Members Grid / Horizontal Chips
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        'DESTINATAIRES',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.layer2Container,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.layer3Border, width: 1),
                        ),
                        child: Text(
                          '${_members.length}',
                          style: GoogleFonts.instrumentSans(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.layer4Active,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    (_isTransmitting || _isPttLocked) ? 'EN DIRECT' : 'VEILLE',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: (_isTransmitting || _isPttLocked) ? AppTheme.layer4Active : AppTheme.textMuted,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Recipient Monogram Chips List
            SizedBox(
              height: 84,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // Broadcast "Tous" chip
                  _buildBroadcastChip(),
                  const SizedBox(width: 10),

                  // Individual member chips
                  ..._members.map((member) => Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: _buildMemberTile(member),
                      )),
                ],
              ),
            ),

            const Spacer(),

            // Lock indicator badge / Swipe hint above button
            Center(
              child: SizedBox(
                height: 42,
                child: Center(
                  child: _isPttLocked
                      ? GestureDetector(
                          onTap: _unlockAndStop,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppTheme.layer4Active,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: AppTheme.layer4Active, width: 1.0),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.lock, size: 16, color: AppTheme.layer1Surface),
                                const SizedBox(width: 8),
                                Text(
                                  'VERROUILLÉ - APPUYER POUR ARRÊTER',
                                  style: GoogleFonts.redRose(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.layer1Surface,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Opacity(
                          opacity: _isTransmitting ? 1.0 : 0.0,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.keyboard_arrow_up, size: 18, color: AppTheme.layer4Active),
                              const SizedBox(width: 4),
                              Text(
                                'GLISSER POUR VERROUILLER',
                                style: GoogleFonts.redRose(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.layer4Active,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Central Massive Circular PTT Controller with Slide-to-Lock gesture
            Center(
              child: Listener(
                onPointerDown: (event) {
                  if (_isPttLocked) {
                    _unlockAndStop();
                    return;
                  }
                  _isPointerPhysicallyDown = true;
                  _pointerStartY = event.position.dy;
                  HapticFeedback.heavyImpact();
                  setState(() {
                    _isTransmitting = true;
                    _isTransmitError = false;
                  });
                  unawaited(_startHardwareMicTransmissionAsync());
                },
                onPointerMove: (event) {
                  if (!_isPttLocked && _isTransmitting) {
                    final double startY = _pointerStartY;
                    final double currentY = event.position.dy;
                    if (startY - currentY > 50) {
                      HapticFeedback.heavyImpact();
                      setState(() {
                        _isPttLocked = true;
                      });
                      _startInactivityTimer();
                    }
                  }
                },
                onPointerUp: (event) {
                  _isPointerPhysicallyDown = false;
                  if (!_isPttLocked) {
                    HapticFeedback.lightImpact();
                    _stopHardwareMicTransmission();
                  }
                },
                onPointerCancel: (event) {
                  _isPointerPhysicallyDown = false;
                  if (!_isPttLocked) {
                    HapticFeedback.lightImpact();
                    _stopHardwareMicTransmission();
                  }
                },
                child: Container(
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isTransmitError
                        ? AppTheme.alertRed.withValues(alpha: 0.15)
                        : ((_isTransmitting || _isPttLocked) ? AppTheme.nordicSlate : AppTheme.layer2Container),
                    border: Border.all(
                      color: _isTransmitError
                          ? AppTheme.alertRed
                          : ((_isTransmitting || _isPttLocked) ? AppTheme.nordicSlateLight : AppTheme.layer3Border),
                      width: 2.5,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isTransmitError
                            ? Icons.error_outline
                            : ((_isTransmitting || _isPttLocked) ? Icons.mic : Icons.mic_none_outlined),
                        size: 54,
                        color: _isTransmitError
                            ? AppTheme.alertRed
                            : AppTheme.layer4Active,
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _isTransmitError
                              ? _transmitErrorMessage
                              : (_isPttLocked
                                  ? '● VERROUILLÉ / PARLEZ'
                                  : (_isTransmitting ? '● EN DIRECT / PARLEZ...' : 'MAINTENIR POUR PARLER')),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.redRose(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _isTransmitError
                                ? AppTheme.alertRed
                                : AppTheme.layer4Active,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const Spacer(),

            // Façade Control Strip: Limiteur Acoustique & Coupe-circuit 5m
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Sound Limiter Quick Button
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: _showAcousticLimiterModal,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.tune, size: 16, color: AppTheme.nordicSlateLight),
                          const SizedBox(width: 6),
                          Text(
                            'Plafond : ${(_webrtc.audioCeiling * 100).round()}%',
                            style: GoogleFonts.instrumentSans(
                              fontSize: 12,
                              color: AppTheme.layer4Active,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Inactivity Breaker in Façade
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, size: 16, color: AppTheme.textMuted),
                      const SizedBox(width: 6),
                      Text(
                        'Coupe-circuit 5m',
                        style: GoogleFonts.instrumentSans(
                          fontSize: 12,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 24,
                        width: 36,
                        child: Switch(
                          value: _storage.inactivityBreakerEnabled,
                          onChanged: (val) {
                            setState(() {
                              _storage.setInactivityBreakerEnabled(val);
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
          ],
        ),
      ),
    );
  }

  Widget _buildBroadcastChip() {
    final isSelected = _selectAll;
    final onlineCount = _approvedMembers.where((m) => m.isOnline).length;
    return GestureDetector(
      onTap: _toggleSelectAll,
      child: Container(
        width: 74,
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.layer4Active : AppTheme.layer2Container,
          border: Border.all(
            color: isSelected ? AppTheme.layer4Active : AppTheme.layer3Border,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.sensors_outlined,
              size: 20,
              color: isSelected ? AppTheme.layer1Surface : AppTheme.layer4Active,
            ),
            const SizedBox(height: 3),
            Text(
              'Tous',
              style: GoogleFonts.instrumentSans(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isSelected ? AppTheme.layer1Surface : AppTheme.layer4Active,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected ? AppTheme.layer1Surface : AppTheme.layer4Active,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  '$onlineCount actif${onlineCount > 1 ? 's' : ''}',
                  style: GoogleFonts.instrumentSans(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w400,
                    color: isSelected ? AppTheme.layer1Surface : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberTile(FamilyMember member) {
    final isBlocked = _storage.isMemberBlocked(member.id);
    final isMuted = _storage.isMemberMuted(member.id);
    final isSelected = !isBlocked && (_selectAll || _selectedMemberIds.contains(member.id));

    return GestureDetector(
      onTap: () {
        if (isBlocked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Ce membre est bloqué'),
              backgroundColor: AppTheme.layer2Container,
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }
        _toggleMemberSelection(member.id);
      },
      onLongPress: () => _showMemberActionModal(member),
      onDoubleTap: () {
        if (!isBlocked) _triggerChimeAlert(member);
      },
      child: Container(
        width: 74,
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.layer2Container : AppTheme.layer1Surface,
          border: Border.all(
            color: isSelected ? AppTheme.layer4Active : AppTheme.layer3Border,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Monogram circle with story ring & badges (tap opens Story if active, else Portfolio)
            GestureDetector(
              onTap: () {
                final stories = _storage.getMemberActiveStories(member.id);
                if (stories.isNotEmpty) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EcranFamilyStories(
                        storiesToView: stories,
                        initialStoryIndex: 0,
                      ),
                    ),
                  );
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EcranPortfolio(initialMemberId: member.id),
                    ),
                  );
                }
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2.0),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _storage.hasActiveStory(member.id)
                            ? const Color(0xFF3B82F6) // Bleu Ardoise Nordique (#3B82F6)
                            : Colors.transparent,
                        width: 2.0,
                      ),
                    ),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? AppTheme.layer4Active : AppTheme.layer2Container,
                        border: Border.all(
                          color: isSelected ? AppTheme.nordicSlate : AppTheme.layer3Border,
                          width: 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        member.monogram,
                        style: GoogleFonts.redRose(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: isSelected ? AppTheme.layer1Surface : AppTheme.layer4Active,
                        ),
                      ),
                    ),
                  ),
                  if (member.isSleepShieldActive || (member.id == _storage.deviceId && _storage.isSleepShieldActive))
                    Positioned(
                      left: -3,
                      bottom: -3,
                      child: Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: const BoxDecoration(
                          color: AppTheme.layer1Surface,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.bedtime, size: 10, color: AppTheme.nordicSlateLight),
                      ),
                    ),
                  if (isBlocked)
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: const BoxDecoration(
                          color: AppTheme.layer1Surface,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.block, size: 10, color: AppTheme.alertRed),
                      ),
                    )
                  else if (isMuted)
                    Positioned(
                      right: -3,
                      bottom: -3,
                      child: Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: const BoxDecoration(
                          color: AppTheme.layer1Surface,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.volume_off, size: 10, color: AppTheme.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.instrumentSans(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                color: isBlocked
                    ? AppTheme.textMuted
                    : (isSelected ? AppTheme.layer4Active : AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: member.isOnline ? AppTheme.nordicSlate : Colors.transparent,
                    border: member.isOnline
                        ? null
                        : Border.all(color: AppTheme.textMuted, width: 1),
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  member.isOnline ? 'En ligne' : 'Hors ligne',
                  style: GoogleFonts.instrumentSans(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w400,
                    color: member.isOnline ? AppTheme.nordicSlateLight : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
