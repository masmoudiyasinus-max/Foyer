import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../models/family_event.dart';

class EcranEvenements extends StatefulWidget {
  const EcranEvenements({super.key});

  @override
  State<EcranEvenements> createState() => _EcranEvenementsState();
}

class _EcranEvenementsState extends State<EcranEvenements> {
  final StorageService _storage = StorageService();
  List<FamilyMeetingEvent> _events = [];
  StreamSubscription? _eventsSubscription;

  // Expanded thread event ID
  String? _expandedEventId;
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadEvents();
    _syncFirebaseEvents();
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _commentController.dispose();
    super.dispose();
  }

  void _loadEvents() {
    setState(() {
      _events = _storage.getEvents();
    });
  }

  void _syncFirebaseEvents() {
    final familyCode = _storage.familyCode;
    if (familyCode.isEmpty) return;

    try {
      _eventsSubscription?.cancel();
      _eventsSubscription = FirebaseDatabase.instance.ref('foyers/$familyCode/events').onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          final List<FamilyMeetingEvent> list = [];
          data.forEach((k, v) {
            if (v is Map) {
              list.add(FamilyMeetingEvent.fromMap(v));
            }
          });
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          if (mounted) {
            setState(() => _events = list);
            for (final e in list) {
              _storage.saveEvent(e);
            }
          }
        }
      });
    } catch (e) {
      debugPrint('Erreur sync Firebase events: $e');
    }
  }

  Future<void> _postComment(String eventId) async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    final comment = EventComment(
      id: 'comm_${DateTime.now().millisecondsSinceEpoch}',
      authorId: _storage.deviceId,
      authorName: _storage.memberName,
      text: text,
      timestamp: DateTime.now(),
    );

    _commentController.clear();

    await _storage.addCommentToEvent(eventId, comment);

    // Sync comment to Firebase
    final familyCode = _storage.familyCode;
    if (familyCode.isNotEmpty) {
      try {
        final ref = FirebaseDatabase.instance
            .ref('foyers/$familyCode/events/$eventId/comments/${comment.id}');
        await ref.set(comment.toMap());
      } catch (e) {
        debugPrint('Erreur comment Firebase: $e');
      }
    }

    _loadEvents();
  }

  String _monthName(int month) {
    const months = [
      'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
      'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'
    ];
    if (month >= 1 && month <= 12) return months[month - 1];
    return '';
  }

  void _showAddEventDialog() {
    final titleController = TextEditingController();
    final locationController = TextEditingController();
    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    TimeOfDay selectedTime = const TimeOfDay(hour: 15, minute: 0);
    String dateTimeDisplay = '${selectedDate.day} ${_monthName(selectedDate.month)} à ${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
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
                'Planifier un rassemblement',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: 'Titre de la réunion'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: locationController,
                decoration: const InputDecoration(labelText: 'Lieu ou pièce'),
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
                              'Date et heure de la réunion',
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
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.nordicSlate,
                  foregroundColor: AppTheme.layer4Active,
                ),
                onPressed: () async {
                  final title = titleController.text.trim();
                  if (title.isEmpty) return;

                  final newEvent = FamilyMeetingEvent(
                    id: 'evt_${DateTime.now().millisecondsSinceEpoch}',
                    title: title,
                    location: locationController.text.trim(),
                    dateTimeDisplay: dateTimeDisplay,
                    createdAt: DateTime.now(),
                  );

                  await _storage.saveEvent(newEvent);

                  final familyCode = _storage.familyCode;
                  if (familyCode.isNotEmpty) {
                    try {
                      await FirebaseDatabase.instance
                          .ref('foyers/$familyCode/events/${newEvent.id}')
                          .set(newEvent.toMap());
                    } catch (e) {
                      debugPrint('Erreur set event Firebase: $e');
                    }
                  }

                  if (mounted) {
                    _loadEvents();
                    Navigator.pop(ctx);
                  }
                },
                child: const Text(
                  'Programmer la réunion',
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
    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'ÉVÉNEMENTS & DISCUSSIONS',
          style: GoogleFonts.redRose(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: AppTheme.layer4Active,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 22),
            onPressed: _showAddEventDialog,
            tooltip: 'Planifier',
          ),
        ],
      ),
      body: _events.isEmpty
          ? Center(
              child: Text(
                'Aucun rassemblement prévu',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _events.length,
              itemBuilder: (context, index) {
                final event = _events[index];
                final isExpanded = _expandedEventId == event.id;

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
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    event.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.layer1Surface,
                                    border: Border.all(
                                      color: Theme.of(context).colorScheme.outlineVariant,
                                      width: 1,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    event.dateTimeDisplay,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.redRose(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.layer4Active,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (event.location.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.place_outlined, size: 14, color: AppTheme.textMuted),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      event.location,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 12),

                            // Discussion Toggle Button
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                side: BorderSide(
                                  color: Theme.of(context).colorScheme.outlineVariant,
                                  width: 1,
                                ),
                              ),
                              icon: Icon(
                                isExpanded ? Icons.expand_less : Icons.chat_bubble_outline,
                                size: 16,
                              ),
                              label: Text(
                                'Fil de discussion (${event.comments.length})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () {
                                setState(() {
                                  _expandedEventId = isExpanded ? null : event.id;
                                });
                              },
                            ),
                          ],
                        ),
                      ),

                      // Expandable Nested Discussion Thread
                      if (isExpanded) ...[
                        Divider(
                          height: 1,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        Container(
                          color: AppTheme.layer1Surface,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Comment stream
                              if (event.comments.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(
                                    'Aucun commentaire pour l\'instant',
                                    style: Theme.of(context).textTheme.bodySmall,
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              else
                                ...event.comments.map((comment) => _buildCommentTile(comment)),

                              const SizedBox(height: 12),

                              // Bottom input bar ("Écrire un commentaire...")
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _commentController,
                                      style: GoogleFonts.instrumentSans(
                                        fontSize: 13,
                                        color: AppTheme.layer4Active,
                                      ),
                                      decoration: const InputDecoration(
                                        hintText: 'Écrire un commentaire...',
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                      ),
                                      onSubmitted: (_) => _postComment(event.id),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    style: IconButton.styleFrom(
                                      backgroundColor: AppTheme.layer4Active,
                                      foregroundColor: AppTheme.layer1Surface,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                    icon: const Icon(Icons.arrow_upward, size: 18),
                                    onPressed: () => _postComment(event.id),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildCommentTile(EventComment comment) {
    final isMe = comment.authorId == _storage.deviceId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.layer2Container,
              border: Border.all(color: AppTheme.layer3Border, width: 1),
            ),
            alignment: Alignment.center,
            child: Text(
              comment.authorMonogram,
              style: GoogleFonts.redRose(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppTheme.layer4Active,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.layer2Container,
                border: Border.all(color: AppTheme.layer3Border, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isMe ? 'Moi' : comment.authorName,
                        style: GoogleFonts.instrumentSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                      Text(
                        '${comment.timestamp.hour.toString().padLeft(2, '0')}:${comment.timestamp.minute.toString().padLeft(2, '0')}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    comment.text,
                    style: GoogleFonts.instrumentSans(
                      fontSize: 13,
                      color: AppTheme.layer4Active,
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
