import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/discovery_service.dart';
import '../../models/family_member.dart';

class EcranPortfolio extends StatefulWidget {
  final String? initialMemberId;
  const EcranPortfolio({super.key, this.initialMemberId});

  @override
  State<EcranPortfolio> createState() => _EcranPortfolioState();
}

class _EcranPortfolioState extends State<EcranPortfolio> {
  final StorageService _storage = StorageService();
  final DiscoveryService _discovery = DiscoveryService();

  late FamilyMember _currentProfile;
  List<FamilyMember> _familyMembers = [];
  String _selectedMemberId = '';
  StreamSubscription<List<FamilyMember>>? _membersSubscription;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _membersSubscription = _discovery.membersStream.listen((_) {
      if (mounted) {
        _refreshFromSync();
      }
    });
  }

  @override
  void dispose() {
    _membersSubscription?.cancel();
    super.dispose();
  }

  String _detectCountryDialingCode() {
    try {
      final locale = WidgetsBinding.instance.platformDispatcher.locale;
      final country = locale.countryCode?.toUpperCase() ?? '';
      const countryToDialCode = {
        'TN': '+216',
        'FR': '+33',
        'DZ': '+213',
        'MA': '+212',
        'BE': '+32',
        'CH': '+41',
        'CA': '+1',
        'US': '+1',
        'SN': '+221',
        'CI': '+225',
        'EG': '+20',
        'SA': '+966',
        'AE': '+971',
        'DE': '+49',
        'IT': '+39',
        'ES': '+34',
        'GB': '+44',
        'UK': '+44',
        'TR': '+90',
        'QA': '+974',
        'KW': '+965',
        'LY': '+218',
      };
      if (countryToDialCode.containsKey(country)) {
        return countryToDialCode[country]!;
      }
    } catch (_) {}
    return '+33';
  }

  String _monthName(int month) {
    const months = [
      'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
      'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'
    ];
    if (month >= 1 && month <= 12) return months[month - 1];
    return '';
  }

  void _loadProfile() {
    final myId = _storage.deviceId;
    final myName = _storage.memberName;
    final targetId = widget.initialMemberId ?? myId;

    final myProfile = _storage.getPortfolio(myId) ??
        FamilyMember(
          id: myId,
          name: myName,
          phone: '${_detectCountryDialingCode()} 6 12 34 56 78',
          birthDate: '15 Janvier 1995',
        );

    final List<FamilyMember> members = [myProfile];
    for (final m in _discovery.currentMembers) {
      if (m.id != myId && m.isApproved) {
        final cached = _storage.getPortfolio(m.id);
        final fullMember = (cached != null)
            ? m.copyWith(
                name: cached.name.isNotEmpty ? cached.name : m.name,
                phone: cached.phone ?? m.phone,
                birthDate: cached.birthDate ?? m.birthDate,
                bio: cached.bio ?? m.bio,
                accountColor: cached.accountColor ?? m.accountColor,
                updatedAt: cached.updatedAt ?? m.updatedAt,
              )
            : m;
        members.add(fullMember);
      }
    }
    _familyMembers = members;

    _selectedMemberId = targetId;
    if (targetId == myId) {
      _currentProfile = myProfile;
    } else {
      _resolveSelectedProfile(targetId, myProfile);
    }

    setState(() {});
  }

  void _resolveSelectedProfile(String targetId, [FamilyMember? fallback]) {
    final cached = _storage.getPortfolio(targetId);
    final discovered = _discovery.getMember(targetId);

    if (cached != null && discovered != null) {
      _currentProfile = cached.copyWith(
        name: discovered.name.isNotEmpty ? discovered.name : cached.name,
        phone: (discovered.phone != null && discovered.phone!.isNotEmpty)
            ? discovered.phone
            : cached.phone,
        birthDate: (discovered.birthDate != null && discovered.birthDate!.isNotEmpty)
            ? discovered.birthDate
            : cached.birthDate,
        bio: (discovered.bio != null && discovered.bio!.isNotEmpty)
            ? discovered.bio
            : cached.bio,
        accountColor: discovered.accountColor ?? cached.accountColor,
        isOnline: discovered.isOnline,
        ip: discovered.ip ?? cached.ip,
        port: discovered.port ?? cached.port,
        lastSeen: discovered.lastSeen ?? cached.lastSeen,
      );
    } else if (cached != null) {
      _currentProfile = cached;
    } else if (discovered != null) {
      _currentProfile = discovered;
    } else if (fallback != null) {
      _currentProfile = fallback;
    }
  }

  void _selectMember(String memberId) {
    _selectedMemberId = memberId;
    if (memberId == _storage.deviceId) {
      _currentProfile = _storage.getPortfolio(memberId) ??
          FamilyMember(
            id: memberId,
            name: _storage.memberName,
            phone: '${_detectCountryDialingCode()} 6 12 34 56 78',
            birthDate: '15 Janvier 1995',
          );
    } else {
      _resolveSelectedProfile(memberId);
    }
    setState(() {});
  }

  void _refreshFromSync() {
    final myId = _storage.deviceId;
    final myName = _storage.memberName;

    final myProfile = _storage.getPortfolio(myId) ??
        FamilyMember(
          id: myId,
          name: myName,
          phone: '${_detectCountryDialingCode()} 6 12 34 56 78',
          birthDate: '15 Janvier 1995',
        );

    final List<FamilyMember> members = [myProfile];
    for (final m in _discovery.currentMembers) {
      if (m.id != myId && m.isApproved) {
        final cached = _storage.getPortfolio(m.id);
        final fullMember = (cached != null)
            ? m.copyWith(
                name: cached.name.isNotEmpty ? cached.name : m.name,
                phone: cached.phone ?? m.phone,
                birthDate: cached.birthDate ?? m.birthDate,
                bio: cached.bio ?? m.bio,
                accountColor: cached.accountColor ?? m.accountColor,
                updatedAt: cached.updatedAt ?? m.updatedAt,
              )
            : m;
        members.add(fullMember);
      }
    }
    _familyMembers = members;

    if (_selectedMemberId == myId || _selectedMemberId.isEmpty) {
      _currentProfile = myProfile;
    } else {
      _resolveSelectedProfile(_selectedMemberId);
    }
    setState(() {});
  }

  Future<void> _makeCall(String? phoneNumber) async {
    if (phoneNumber == null || phoneNumber.isEmpty) return;

    final uri = Uri(scheme: 'tel', path: phoneNumber.replaceAll(' ', ''));
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d\'initier l\'appel')),
        );
      }
    }
  }

  Color _getAccountBorderColor(String? colorHex) {
    if (colorHex == null || colorHex.isEmpty) return AppTheme.nordicSlate;
    try {
      String hex = colorHex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return AppTheme.nordicSlate;
    }
  }

  Future<void> _uploadBannerImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final updated = _currentProfile.copyWith(bannerImagePath: path, updatedAt: DateTime.now());
      await _storage.savePortfolio(updated);
      await _discovery.broadcastProfile(updated);
      setState(() {
        _currentProfile = updated;
      });
    }
  }

  Future<void> _uploadTimetable() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final updated = _currentProfile.copyWith(timetableDocumentPath: path, updatedAt: DateTime.now());
      await _storage.savePortfolio(updated);
      await _discovery.broadcastProfile(updated);
      setState(() {
        _currentProfile = updated;
      });
    }
  }

  void _showEditProfileDialog() {
    final nameController = TextEditingController(text: _currentProfile.name);
    final initialPhone = (_currentProfile.phone != null && _currentProfile.phone!.isNotEmpty)
        ? _currentProfile.phone!
        : '${_detectCountryDialingCode()} ';
    final phoneController = TextEditingController(text: initialPhone);
    final bioController = TextEditingController(text: _currentProfile.bio ?? '');
    String birthDateString = _currentProfile.birthDate ?? '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.layer2Container,
          title: Text(
            'MODIFIER LE PROFIL',
            style: GoogleFonts.redRose(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppTheme.layer4Active,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
                  decoration: const InputDecoration(
                    labelText: 'Nom',
                    hintText: 'Votre prénom ou pseudo',
                    prefixIcon: Icon(Icons.person_outline, size: 18),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
                  decoration: const InputDecoration(
                    labelText: 'Numéro de téléphone',
                    hintText: 'Ex: +33 6 00 00 00 00',
                    prefixIcon: Icon(Icons.phone_outlined, size: 18),
                  ),
                ),
                const SizedBox(height: 14),

                // Material 3 Date Picker Trigger
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime(1995, 1, 15),
                      firstDate: DateTime(1920),
                      lastDate: now,
                    );
                    if (picked != null) {
                      setDialogState(() {
                        birthDateString = '${picked.day} ${_monthName(picked.month)} ${picked.year}';
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppTheme.layer2Container,
                      border: Border.all(color: AppTheme.layer3Border, width: 1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_outlined, size: 18, color: AppTheme.textMuted),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Date de naissance',
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 11,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                birthDateString.isNotEmpty ? birthDateString : 'Sélectionner une date',
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 13,
                                  color: birthDateString.isNotEmpty
                                      ? AppTheme.layer4Active
                                      : AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, color: AppTheme.textMuted),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                TextField(
                  controller: bioController,
                  maxLines: 3,
                  style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
                  decoration: const InputDecoration(
                    labelText: 'Bio',
                    hintText: 'Quelques mots sur vous...',
                    prefixIcon: Icon(Icons.info_outline, size: 18),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.nordicSlate,
                foregroundColor: AppTheme.layer4Active,
              ),
              onPressed: () async {
                final updatedName = nameController.text.trim().isNotEmpty
                    ? nameController.text.trim()
                    : _currentProfile.name;
                final updatedPhone = phoneController.text.trim();
                final updatedBio = bioController.text.trim();
                final updatedBirthDate = birthDateString.trim();

                final updated = _currentProfile.copyWith(
                  name: updatedName,
                  phone: updatedPhone,
                  phoneNumber: updatedPhone,
                  birthDate: updatedBirthDate,
                  bio: updatedBio,
                  updatedAt: DateTime.now(),
                );

                // 1. Sauvegarde dans Hive local
                await _storage.savePortfolio(updated);

                if (_selectedMemberId == _storage.deviceId) {
                  await _storage.saveUserProfile(
                    name: updatedName,
                    familyCode: _storage.familyCode,
                    deviceId: _storage.deviceId,
                    connectionMode: _storage.connectionMode,
                  );
                }

                // 2. Notifie immédiatement DiscoveryService pour diffuser le profil complet
                await _discovery.broadcastProfile(updated);

                if (mounted) {
                  setState(() => _currentProfile = updated);
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = _selectedMemberId == _storage.deviceId;

    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'PORTFOLIO MEMBRE',
          style: GoogleFonts.redRose(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: AppTheme.layer4Active,
          ),
        ),
        actions: [
          if (isMe)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: _showEditProfileDialog,
              tooltip: 'Modifier le profil',
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Member Switcher Row if multiple members available
            if (_familyMembers.length > 1)
              Container(
                height: 48,
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _familyMembers.length,
                  itemBuilder: (context, index) {
                    final member = _familyMembers[index];
                    final isSelected = member.id == _selectedMemberId;

                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          member.id == _storage.deviceId ? 'Moi' : member.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        selected: isSelected,
                        onSelected: (_) => _selectMember(member.id),
                        backgroundColor: AppTheme.layer2Container,
                        selectedColor: AppTheme.nordicSlate,
                        labelStyle: GoogleFonts.instrumentSans(
                          color: isSelected ? AppTheme.layer4Active : AppTheme.textMuted,
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                        ),
                        side: const BorderSide(color: AppTheme.layer3Border, width: 1),
                        elevation: 0,
                      ),
                    );
                  },
                ),
              ),

            // Top Banner with real image support & upload button
            Stack(
              children: [
                Container(
                  height: 130,
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppTheme.layer2Container,
                    border: Border(bottom: BorderSide(color: AppTheme.layer3Border, width: 1)),
                  ),
                  child: (_currentProfile.bannerImagePath != null &&
                          File(_currentProfile.bannerImagePath!).existsSync())
                      ? Image.file(
                          File(_currentProfile.bannerImagePath!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: 130,
                        )
                      : Container(
                          color: AppTheme.layer2Container,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.landscape_outlined,
                            size: 32,
                            color: AppTheme.layer3Border,
                          ),
                        ),
                ),
                if (isMe)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: InkWell(
                      onTap: _uploadBannerImage,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.layer1Surface.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppTheme.layer3Border, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.photo_camera_outlined, size: 14, color: AppTheme.layer4Active),
                            const SizedBox(width: 6),
                            Text(
                              'Bannière',
                              style: GoogleFonts.instrumentSans(
                                fontSize: 11,
                                color: AppTheme.layer4Active,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),

            // Avatar & Profile Info section
            Transform.translate(
              offset: const Offset(0, -45),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Monogram Avatar
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.layer1Surface,
                        border: Border.all(
                          color: _getAccountBorderColor(_currentProfile.accountColor),
                          width: 2,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _currentProfile.monogram,
                        style: GoogleFonts.redRose(
                          fontSize: 38,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Member Name
                    Text(
                      _currentProfile.name,
                      style: GoogleFonts.redRose(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.layer4Active,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isMe ? 'Profil local' : 'Membre du foyer',
                      style: GoogleFonts.instrumentSans(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Phone & Birth Date & Bio Card
                    Card(
                      elevation: 0,
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            // Phone Number
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Numéro de téléphone',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.instrumentSans(
                                          fontSize: 11,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        (_currentProfile.phone != null && _currentProfile.phone!.isNotEmpty)
                                            ? _currentProfile.phone!
                                            : (_currentProfile.phoneNumber ?? 'Non renseigné'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.redRose(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: AppTheme.layer4Active,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if ((_currentProfile.phone != null && _currentProfile.phone!.isNotEmpty) ||
                                    (_currentProfile.phoneNumber != null && _currentProfile.phoneNumber!.isNotEmpty))
                                  FilledButton.tonalIcon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppTheme.nordicSlate,
                                      foregroundColor: AppTheme.layer4Active,
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    ),
                                    icon: const Icon(Icons.call, size: 16),
                                    label: const Text(
                                      'Appeler',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onPressed: () => _makeCall(_currentProfile.phone ?? _currentProfile.phoneNumber),
                                  ),
                              ],
                            ),

                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Divider(
                                height: 1,
                                color: Theme.of(context).colorScheme.outlineVariant,
                              ),
                            ),

                            // Date of birth
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Date de naissance',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.instrumentSans(
                                          fontSize: 11,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _currentProfile.birthDate ?? 'Non renseignée',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.redRose(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: AppTheme.layer4Active,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Divider(
                                height: 1,
                                color: Theme.of(context).colorScheme.outlineVariant,
                              ),
                            ),

                            // Bio
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Bio',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.instrumentSans(
                                          fontSize: 11,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        (_currentProfile.bio != null && _currentProfile.bio!.isNotEmpty)
                                            ? _currentProfile.bio!
                                            : 'Non renseignée',
                                        style: GoogleFonts.instrumentSans(
                                          fontSize: 13,
                                          color: (_currentProfile.bio != null && _currentProfile.bio!.isNotEmpty)
                                              ? AppTheme.layer4Active
                                              : AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    if (isMe) ...[
                      const SizedBox(height: 16),
                      Card(
                        elevation: 0,
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            width: 1,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _storage.isSleepShieldActive ? Icons.bedtime : Icons.bedtime_outlined,
                                    size: 20,
                                    color: _storage.isSleepShieldActive
                                        ? AppTheme.nordicSlateLight
                                        : AppTheme.textMuted,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    'Protection Sommeil',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.redRose(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.layer4Active,
                                    ),
                                  ),
                                ],
                              ),
                              Switch(
                                value: _storage.isSleepShieldActive,
                                activeThumbColor: AppTheme.nordicSlateLight,
                                onChanged: (val) async {
                                  await _storage.setSleepShieldActive(val);
                                  _discovery.updateSleepShield(val);
                                  if (mounted) setState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // Timetable Section: "Emploi du temps" Inline
                    Card(
                      elevation: 0,
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.schedule_outlined, size: 18, color: AppTheme.layer4Active),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Emploi du temps',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.redRose(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.layer4Active,
                                      ),
                                    ),
                                  ],
                                ),
                                if (_currentProfile.timetableDocumentPath != null &&
                                    File(_currentProfile.timetableDocumentPath!).existsSync())
                                  Text(
                                    'Pincer pour zoomer',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.instrumentSans(
                                      fontSize: 11,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 14),

                            // INLINE VIEWER (Image or PDF)
                            if (_currentProfile.timetableDocumentPath != null &&
                                File(_currentProfile.timetableDocumentPath!).existsSync()) ...[
                              Builder(
                                builder: (context) {
                                  final path = _currentProfile.timetableDocumentPath!;
                                  final isPdf = path.toLowerCase().endsWith('.pdf');

                                  if (isPdf) {
                                    return ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Container(
                                        height: 300,
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Theme.of(context).colorScheme.outlineVariant,
                                            width: 1,
                                          ),
                                        ),
                                        child: PDFView(
                                          filePath: path,
                                          enableSwipe: true,
                                          swipeHorizontal: false,
                                          autoSpacing: false,
                                          pageFling: false,
                                        ),
                                      ),
                                    );
                                  } else {
                                    return ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Container(
                                        height: 260,
                                        width: double.infinity,
                                        decoration: BoxDecoration(
                                          color: AppTheme.layer1Surface,
                                          border: Border.all(
                                            color: Theme.of(context).colorScheme.outlineVariant,
                                            width: 1,
                                          ),
                                        ),
                                        child: InteractiveViewer(
                                          panEnabled: true,
                                          scaleEnabled: true,
                                          minScale: 1.0,
                                          maxScale: 4.0,
                                          child: Image.file(
                                            File(path),
                                            fit: BoxFit.contain,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                              const SizedBox(height: 12),
                            ] else ...[
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                alignment: Alignment.center,
                                child: Text(
                                  'Aucun emploi du temps enregistré',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.instrumentSans(
                                    fontSize: 13,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ),
                            ],

                            if (isMe) ...[
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: Theme.of(context).colorScheme.outlineVariant,
                                    width: 1,
                                  ),
                                ),
                                icon: const Icon(Icons.upload_file_outlined, size: 18),
                                label: Text(
                                  _currentProfile.timetableDocumentPath == null
                                      ? 'Importer Image ou PDF'
                                      : 'Remplacer le document',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onPressed: _uploadTimetable,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
