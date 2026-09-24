import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../models/invitation.dart';

class EcranInvitations extends StatefulWidget {
  const EcranInvitations({super.key});

  @override
  State<EcranInvitations> createState() => _EcranInvitationsState();
}

class _EcranInvitationsState extends State<EcranInvitations> {
  final StorageService _storage = StorageService();
  List<Invitation> _invitations = [];
  StreamSubscription? _invitationsSubscription;

  @override
  void initState() {
    super.initState();
    _loadInvitations();
    _syncFirebaseInvitations();
  }

  @override
  void dispose() {
    _invitationsSubscription?.cancel();
    super.dispose();
  }

  void _loadInvitations() {
    setState(() {
      _invitations = _storage.getInvitations();
    });
  }

  void _syncFirebaseInvitations() {
    final familyCode = _storage.familyCode;
    if (familyCode.isEmpty) return;

    try {
      final DatabaseReference ref =
          FirebaseDatabase.instance.ref('foyers/$familyCode/invitations');

      _invitationsSubscription?.cancel();
      _invitationsSubscription = ref.onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          final List<Invitation> list = [];
          data.forEach((k, v) {
            if (v is Map) {
              list.add(Invitation.fromMap(v));
            }
          });
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          if (mounted) {
            setState(() {
              _invitations = list;
            });
            // Update local storage
            for (final inv in list) {
              _storage.saveInvitation(inv);
            }
          }
        }
      });
    } catch (e) {
      debugPrint('Erreur sync invitations Firebase: $e');
    }
  }

  Future<void> _handleRsvp(Invitation inv, bool accepted) async {
    final myId = _storage.deviceId;
    final familyCode = _storage.familyCode;

    // Update local Hive
    await _storage.setRsvpResponse(
      invitationId: inv.id,
      memberId: myId,
      accepted: accepted,
    );

    // Update Firebase
    if (familyCode.isNotEmpty) {
      try {
        final DatabaseReference rsvpRef = FirebaseDatabase.instance
            .ref('foyers/$familyCode/invitations/${inv.id}/rsvpResponses/$myId');
        await rsvpRef.set(accepted);
      } catch (e) {
        debugPrint('Erreur RSVP Firebase: $e');
      }
    }

    _loadInvitations();
  }

  String _monthName(int month) {
    const months = [
      'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
      'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'
    ];
    if (month >= 1 && month <= 12) return months[month - 1];
    return '';
  }

  void _showAddInvitationDialog() {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    DateTime selectedDate = DateTime.now().add(const Duration(days: 2));
    TimeOfDay selectedTime = const TimeOfDay(hour: 19, minute: 30);
    String dateTimeDisplay = '${selectedDate.day} ${_monthName(selectedDate.month)} à ${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';
    String? selectedImagePath;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Nouvelle invitation',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Titre de l\'invitation'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 12),

              // Interactive M3 Date & Time Picker
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final pickedDate = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (pickedDate != null && context.mounted) {
                    final pickedTime = await showTimePicker(
                      context: context,
                      initialTime: selectedTime,
                    );
                    if (pickedTime != null) {
                      setModalState(() {
                        selectedDate = pickedDate;
                        selectedTime = pickedTime;
                        dateTimeDisplay = '${pickedDate.day} ${_monthName(pickedDate.month)} à ${pickedTime.hour.toString().padLeft(2, '0')}:${pickedTime.minute.toString().padLeft(2, '0')}';
                      });
                    }
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppTheme.layer1Surface,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
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
                              'Date et heure de l\'événement',
                              style: GoogleFonts.instrumentSans(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              dateTimeDisplay,
                              style: GoogleFonts.instrumentSans(
                                fontSize: 13,
                                color: AppTheme.layer4Active,
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
              const SizedBox(height: 12),

              // Image attachment button
              OutlinedButton.icon(
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(
                  selectedImagePath == null ? 'Joindre une photo' : 'Photo sélectionnée',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () async {
                  final result = await FilePicker.platform.pickFiles(type: FileType.image);
                  if (result != null && result.files.single.path != null) {
                    setModalState(() {
                      selectedImagePath = result.files.single.path;
                    });
                  }
                },
              ),
              const SizedBox(height: 20),

              FilledButton(
                onPressed: () async {
                  if (titleController.text.trim().isEmpty) return;

                  final newInv = Invitation(
                    id: 'inv_${DateTime.now().millisecondsSinceEpoch}',
                    title: titleController.text.trim(),
                    description: descController.text.trim(),
                    dateTimeDisplay: dateTimeDisplay,
                    imagePath: selectedImagePath,
                    createdAt: DateTime.now(),
                  );

                  await _storage.saveInvitation(newInv);

                  // Sync to Firebase
                  final familyCode = _storage.familyCode;
                  if (familyCode.isNotEmpty) {
                    try {
                      final ref = FirebaseDatabase.instance
                          .ref('foyers/$familyCode/invitations/${newInv.id}');
                      await ref.set(newInv.toMap());
                    } catch (e) {
                      debugPrint('Erreur add invitation Firebase: $e');
                    }
                  }

                  if (mounted) {
                    _loadInvitations();
                    Navigator.pop(ctx);
                  }
                },
                child: const Text(
                  'Publier l\'invitation',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = _storage.deviceId;

    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'INVITATIONS',
          style: GoogleFonts.redRose(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: AppTheme.layer4Active,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 22),
            onPressed: _showAddInvitationDialog,
            tooltip: 'Ajouter',
          ),
        ],
      ),
      body: _invitations.isEmpty
          ? Center(
              child: Text(
                'Aucune invitation familiale',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _invitations.length,
              itemBuilder: (context, index) {
                final inv = _invitations[index];
                final hasRsvp = inv.rsvpResponses.containsKey(myId);
                final accepted = inv.rsvpResponses[myId] == true;

                return Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Photo if provided (natural 16:9 aspect ratio)
                      if (inv.imagePath != null && File(inv.imagePath!).existsSync())
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.file(
                            File(inv.imagePath!),
                            fit: BoxFit.cover,
                            width: double.infinity,
                          ),
                        ),

                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Title (Red Rose)
                            Text(
                              inv.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),

                            // Static date and time clearly visible at all times
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppTheme.layer1Surface,
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.outlineVariant,
                                  width: 1,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.event_outlined, size: 14, color: AppTheme.layer4Active),
                                  const SizedBox(width: 8),
                                  Text(
                                    inv.dateTimeDisplay,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.redRose(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.layer4Active,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),

                            // Description
                            if (inv.description.isNotEmpty)
                              Text(
                                inv.description,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            const SizedBox(height: 16),

                            // Action buttons: Flat Accepter and Refuser
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      side: BorderSide(
                                        color: Theme.of(context).colorScheme.outlineVariant,
                                        width: 1,
                                      ),
                                      backgroundColor: hasRsvp && !accepted
                                          ? AppTheme.layer4Active
                                          : Colors.transparent,
                                      foregroundColor: hasRsvp && !accepted
                                          ? AppTheme.layer1Surface
                                          : AppTheme.layer4Active,
                                    ),
                                    onPressed: () => _handleRsvp(inv, false),
                                    child: const Text(
                                      'Refuser',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: hasRsvp && accepted
                                          ? AppTheme.nordicSlateLight
                                          : AppTheme.nordicSlate,
                                      foregroundColor: AppTheme.layer4Active,
                                    ),
                                    onPressed: () => _handleRsvp(inv, true),
                                    child: const Text(
                                      'Accepter',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
