import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/discovery_service.dart';
import '../../core/services/webrtc_service.dart';
import '../../core/services/foyer_manager_service.dart';
import '../../models/family_member.dart';
import '../portfolio/ecran_portfolio.dart';
import '../stories/ecran_family_stories.dart';

class EcranMembers extends StatefulWidget {
  const EcranMembers({super.key});

  @override
  State<EcranMembers> createState() => _EcranMembersState();
}

class _EcranMembersState extends State<EcranMembers> {
  final StorageService _storage = StorageService();
  final DiscoveryService _discovery = DiscoveryService();
  final WebRtcService _webrtc = WebRtcService();

  List<FamilyMember> _members = [];
  final Set<String> _selectedMemberIds = {};
  bool _isSendingChime = false;
  bool _isSendingEmergency = false;

  @override
  void initState() {
    super.initState();
    _discovery.membersNotifier.addListener(_onMembersChanged);
    _onMembersChanged();
    _storage.startStoriesSync(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _discovery.membersNotifier.removeListener(_onMembersChanged);
    _storage.stopStoriesSync();
    super.dispose();
  }

  void _onMembersChanged() {
    if (!mounted) return;
    setState(() {
      _members = _discovery.membersNotifier.value;
    });
  }

  void _openMemberPortfolio(String memberId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EcranPortfolio(initialMemberId: memberId),
      ),
    );
  }

  void _toggleMemberSelection(String id) {
    setState(() {
      if (_selectedMemberIds.contains(id)) {
        _selectedMemberIds.remove(id);
      } else {
        _selectedMemberIds.add(id);
      }
    });
  }

  void _selectAllMembers() {
    setState(() {
      if (_selectedMemberIds.length == _members.length) {
        _selectedMemberIds.clear();
      } else {
        _selectedMemberIds.clear();
        for (final m in _members) {
          if (m.id != _storage.deviceId) {
            _selectedMemberIds.add(m.id);
          }
        }
      }
    });
  }

  Future<void> _sendLevel1Chime() async {
    final targets = _selectedMemberIds.toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sélectionnez au moins un membre')),
      );
      return;
    }

    setState(() => _isSendingChime = true);
    HapticFeedback.lightImpact();

    try {
      for (final targetId in targets) {
        await _webrtc.sendChimeAlert(
          familyCode: _storage.familyCode,
          myDeviceId: _storage.deviceId,
          myName: _storage.memberName,
          targetDeviceId: targetId,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.layer2Container,
            content: Text(
              'Bip standard envoyé (${targets.length} membre${targets.length > 1 ? 's' : ''})',
              style: GoogleFonts.instrumentSans(color: AppTheme.layer4Active),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSendingChime = false);
      }
    }
  }

  Future<void> _sendLevel2Emergency() async {
    final targets = _selectedMemberIds.toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sélectionnez au moins un membre pour l\'alerte')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.layer2Container,
        title: Text(
          'DÉCLENCHER L\'ALERTE D\'URGENCE',
          style: GoogleFonts.redRose(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: AppTheme.alertRed,
          ),
        ),
        content: Text(
          'Une sonnerie d\'alarme continue et des vibrations puissantes vont retentir sur les téléphones ciblés jusqu\'à acceptation manuelle.',
          style: GoogleFonts.instrumentSans(
            fontSize: 13,
            color: AppTheme.layer4Active,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.alertRed,
              foregroundColor: AppTheme.layer4Active,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Déclencher'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSendingEmergency = true);
    HapticFeedback.heavyImpact();

    try {
      for (final targetId in targets) {
        await _webrtc.sendEmergencyAlert(
          familyCode: _storage.familyCode,
          myDeviceId: _storage.deviceId,
          myName: _storage.memberName,
          targetDeviceId: targetId,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.alertRed,
            content: Text(
              'Alerte d\'urgence transmise (${targets.length} membre${targets.length > 1 ? 's' : ''})',
              style: GoogleFonts.instrumentSans(
                color: AppTheme.layer4Active,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSendingEmergency = false);
      }
    }
  }

  void _showInviteMemberDialog() {
    int selectedQuota = 1;
    String? generatedLink;
    bool isGenerating = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            title: Row(
              children: [
                const Icon(Icons.person_add_outlined, color: AppTheme.nordicSlateLight, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Inviter un membre au Foyer',
                  style: GoogleFonts.redRose(fontSize: 17, color: AppTheme.layer4Active),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Définissez le quota d\'utilisation du lien d\'invitation :',
                    style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1 membre')),
                      ButtonSegment(value: 2, label: Text('2 membres')),
                      ButtonSegment(value: 5, label: Text('5 membres')),
                    ],
                    selected: {selectedQuota},
                    onSelectionChanged: (set) {
                      setDialogState(() {
                        selectedQuota = set.first;
                        generatedLink = null;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  if (generatedLink == null) ...[
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF3B82F6),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: isGenerating
                          ? null
                          : () async {
                              setDialogState(() => isGenerating = true);
                              final link = await FoyerManagerService().createInvitationLink(
                                maxQuota: selectedQuota,
                              );
                              setDialogState(() {
                                generatedLink = link;
                                isGenerating = false;
                              });
                            },
                      icon: isGenerating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.qr_code_rounded, size: 18),
                      label: const Text('Générer le lien & QR Code'),
                    ),
                  ] else ...[
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: QrImageView(
                          data: generatedLink!,
                          version: QrVersions.auto,
                          size: 160.0,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Quota : $selectedQuota membre${selectedQuota > 1 ? 's' : ''} • Révocation automatique dès épuisement.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.instrumentSans(fontSize: 11, color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF3B82F6)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: generatedLink!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Lien d\'invitation copié dans le presse-papier')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16, color: Color(0xFF3B82F6)),
                      label: const Text('Copier le lien sécurisé', style: TextStyle(color: Color(0xFF3B82F6))),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Fermer'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAirlockApprovalSection() {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: FoyerManagerService().airlockNotifier,
      builder: (context, candidates, _) {
        if (candidates.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.5), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sensor_occupied_outlined, size: 18, color: Color(0xFF3B82F6)),
                  const SizedBox(width: 8),
                  Text(
                    'Sas d\'attente sécurisé (Airlock)',
                    style: GoogleFonts.redRose(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.layer4Active,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${candidates.length}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF3B82F6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...candidates.map((cand) {
                final candId = cand['deviceId']?.toString() ?? '';
                final candName = cand['name']?.toString() ?? 'Nouvel Invité';

                return Card(
                  elevation: 0,
                  color: AppTheme.layer1Surface,
                  margin: const EdgeInsets.only(top: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$candName demande à rejoindre le foyer',
                          style: const TextStyle(
                            color: AppTheme.layer4Active,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.alertRed,
                                side: const BorderSide(color: AppTheme.alertRed),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () async {
                                await FoyerManagerService().decideCandidate(
                                  candidateId: candId,
                                  candidateName: candName,
                                  approve: false,
                                );
                              },
                              icon: const Icon(Icons.block, size: 16),
                              label: const Text('Bloquer'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF3B82F6),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () async {
                                await FoyerManagerService().decideCandidate(
                                  candidateId: candId,
                                  candidateName: candName,
                                  approve: true,
                                );
                              },
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Accepter'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = _storage.deviceId;

    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'MEMBRES DU FOYER',
          style: GoogleFonts.redRose(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: AppTheme.layer4Active,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all, size: 20),
            onPressed: _selectAllMembers,
            tooltip: 'Tout sélectionner',
          ),
        ],
      ),
      body: Column(
        children: [
          // Airlock Approval Cards (Sas d'Attente)
          _buildAirlockApprovalSection(),

          // M3 Invite Button: "Inviter un membre au Foyer"
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                  foregroundColor: const Color(0xFF3B82F6),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                ),
                onPressed: _showInviteMemberDialog,
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
                label: const Text(
                  'Inviter un membre au Foyer',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ),
          ),

          // Header summary badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_members.length} membre${_members.length > 1 ? 's' : ''} détecté${_members.length > 1 ? 's' : ''}',
                  style: GoogleFonts.instrumentSans(
                    fontSize: 13,
                    color: AppTheme.textMuted,
                  ),
                ),
                Text(
                  '${_selectedMemberIds.length} sélectionné${_selectedMemberIds.length > 1 ? 's' : ''}',
                  style: GoogleFonts.instrumentSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _selectedMemberIds.isNotEmpty
                        ? AppTheme.nordicSlateLight
                        : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),

          // Member List
          Expanded(
            child: _members.isEmpty
                ? Center(
                    child: Text(
                      'Aucun membre du foyer détecté pour le moment',
                      style: GoogleFonts.instrumentSans(
                        fontSize: 13,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _members.length,
                    separatorBuilder: (_, __) => const Divider(
                      color: AppTheme.layer3Border,
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                    ),
                    itemBuilder: (context, index) {
                      final member = _members[index];
                      final isMe = member.id == myId;
                      final isSelected = _selectedMemberIds.contains(member.id);
                      final isBlocked = _storage.isMemberBlocked(member.id);
                      final isMuted = _storage.isMemberMuted(member.id);

                      return InkWell(
                        onTap: isMe ? null : () => _toggleMemberSelection(member.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              // Checkbox selection (disabled for self)
                              if (!isMe)
                                Checkbox(
                                  value: isSelected,
                                  onChanged: (_) => _toggleMemberSelection(member.id),
                                )
                              else
                                const SizedBox(width: 40),

                              // Monogram Avatar (tap opens Story if active, else Portfolio)
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
                                    _openMemberPortfolio(member.id);
                                  }
                                },
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(2.5),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _storage.hasActiveStory(member.id)
                                              ? const Color(0xFF3B82F6) // Bleu Ardoise Nordique (#3B82F6)
                                              : Colors.transparent,
                                          width: 2.5,
                                        ),
                                      ),
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppTheme.layer2Container,
                                          border: Border.all(
                                            color: isSelected
                                                ? AppTheme.nordicSlate
                                                : AppTheme.layer3Border,
                                            width: 1.5,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          member.monogram,
                                          style: GoogleFonts.redRose(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w500,
                                            color: AppTheme.layer4Active,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Status Dot: Nordic Slate if online, Muted if offline
                                    Positioned(
                                      right: 2,
                                      bottom: 2,
                                      child: Container(
                                        width: 11,
                                        height: 11,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: member.isOnline
                                              ? AppTheme.nordicSlate
                                              : AppTheme.textMuted,
                                          border: Border.all(
                                            color: AppTheme.layer1Surface,
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(width: 14),

                              // Name & Network Status
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => _openMemberPortfolio(member.id),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              member.name,
                                              style: GoogleFonts.redRose(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w500,
                                                color: AppTheme.layer4Active,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (isMe) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppTheme.layer3Border,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                'Moi',
                                                style: GoogleFonts.instrumentSans(
                                                  fontSize: 10,
                                                  color: AppTheme.layer4Active,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        member.isOnline
                                            ? (member.ip != null && member.ip!.isNotEmpty
                                                ? 'En ligne (${member.ip})'
                                                : 'En ligne (Relais Cloud)')
                                            : 'Hors ligne',
                                        style: GoogleFonts.instrumentSans(
                                          fontSize: 11,
                                          color: member.isOnline
                                              ? AppTheme.nordicSlateLight
                                              : AppTheme.textMuted,
                                        ),
                                      ),
                                       if (member.isOnline) ...[
                                         Builder(
                                           builder: (context) {
                                             final arrivalTime = _storage.getMemberHomeArrivalTime(member.id);
                                             if (arrivalTime == null) return const SizedBox.shrink();
                                             final hStr = arrivalTime.hour.toString().padLeft(2, '0');
                                             final mStr = arrivalTime.minute.toString().padLeft(2, '0');
                                             return Padding(
                                               padding: const EdgeInsets.only(top: 3),
                                               child: Row(
                                                 mainAxisSize: MainAxisSize.min,
                                                 children: [
                                                   const Icon(Icons.home_outlined, size: 12, color: Color(0xFF3B82F6)),
                                                   const SizedBox(width: 4),
                                                   Text(
                                                     'À la maison depuis $hStr:$mStr',
                                                     style: GoogleFonts.instrumentSans(
                                                       fontSize: 10,
                                                       fontWeight: FontWeight.w600,
                                                       color: const Color(0xFF3B82F6),
                                                     ),
                                                   ),
                                                 ],
                                               ),
                                             );
                                           },
                                         ),
                                       ],
                                    ],
                                  ),
                                ),
                              ),

                              // Status badges & Actions
                              if (member.isSleepShieldActive || (isMe && _storage.isSleepShieldActive))
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(Icons.bedtime, size: 18, color: AppTheme.nordicSlateLight),
                                ),
                              if (isBlocked)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(Icons.block, size: 18, color: AppTheme.alertRed),
                                ),
                              if (isMuted)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(Icons.volume_off, size: 18, color: AppTheme.textMuted),
                                ),

                              // Quick Mute / Block buttons (not for self)
                              if (!isMe) ...[
                                IconButton(
                                  icon: Icon(
                                    isMuted ? Icons.volume_off : Icons.volume_up_outlined,
                                    size: 18,
                                    color: isMuted ? AppTheme.alertRed : AppTheme.textMuted,
                                  ),
                                  tooltip: isMuted ? 'Rétablir le son' : 'Couper le son',
                                  onPressed: () {
                                    setState(() {
                                      _storage.setMemberMuted(member.id, !isMuted);
                                    });
                                  },
                                ),
                                IconButton(
                                  icon: Icon(
                                    isBlocked ? Icons.lock_open : Icons.block,
                                    size: 18,
                                    color: isBlocked ? AppTheme.alertRed : AppTheme.textMuted,
                                  ),
                                  tooltip: isBlocked ? 'Débloquer' : 'Bloquer',
                                  onPressed: () {
                                    setState(() {
                                      _storage.setMemberBlocked(member.id, !isBlocked);
                                    });
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Dual-Level Alert Action Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  // Niveau 1: Bip Standard
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      icon: _isSendingChime
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.notifications_outlined, size: 18),
                      label: const Text(
                        'Bip Standard',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: _isSendingChime || _isSendingEmergency ? null : _sendLevel1Chime,
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Niveau 2: Alerte d'Urgence / Appel Continu
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.alertRed,
                        foregroundColor: AppTheme.layer4Active,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: _isSendingEmergency
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.layer4Active,
                              ),
                            )
                          : const Icon(Icons.warning_amber_rounded, size: 18),
                      label: const Text(
                        'Alerte d\'Urgence',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: _isSendingChime || _isSendingEmergency ? null : _sendLevel2Emergency,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}