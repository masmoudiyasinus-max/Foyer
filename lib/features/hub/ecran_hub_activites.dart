import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/audio_router_service.dart';
import '../../core/services/foyer_manager_service.dart';
import '../../core/services/discovery_service.dart';
import '../../models/task_item.dart';
import '../../models/family_event.dart';
import '../../models/invitation.dart';
import '../../models/meal_item.dart';

enum ActivityFilter { all, tasks, events, meals, invitations }

enum FocusDuration { thirtyMin, oneHour, twoHours }

enum TimelineItemType { task, event, meal, invitation, arrival }

class TimelineItem {
  final int hour;
  final int minute;
  final TimelineItemType type;
  final TaskItem? task;
  final FamilyMeetingEvent? event;
  final MealItem? meal;
  final Invitation? invitation;
  final Map<String, dynamic>? arrival;

  TimelineItem.fromTask(TaskItem t)
      : type = TimelineItemType.task,
        task = t,
        event = null,
        meal = null,
        invitation = null,
        arrival = null,
        hour = _extractTime(t.title, t.updatedAt ?? t.createdAt).$1,
        minute = _extractTime(t.title, t.updatedAt ?? t.createdAt).$2;

  TimelineItem.fromEvent(FamilyMeetingEvent e)
      : type = TimelineItemType.event,
        task = null,
        event = e,
        meal = null,
        invitation = null,
        arrival = null,
        hour = _extractTime(e.dateTimeDisplay, e.createdAt).$1,
        minute = _extractTime(e.dateTimeDisplay, e.createdAt).$2;

  TimelineItem.fromMeal(MealItem m)
      : type = TimelineItemType.meal,
        task = null,
        event = null,
        meal = m,
        invitation = null,
        arrival = null,
        hour = _extractMealTime(m.title, m.createdAt).$1,
        minute = _extractMealTime(m.title, m.createdAt).$2;

  TimelineItem.fromInvitation(Invitation inv)
      : type = TimelineItemType.invitation,
        task = null,
        event = null,
        meal = null,
        invitation = inv,
        arrival = null,
        hour = _extractTime(inv.dateTimeDisplay, inv.createdAt).$1,
        minute = _extractTime(inv.dateTimeDisplay, inv.createdAt).$2;

  TimelineItem.fromArrival(Map<String, dynamic> a)
      : type = TimelineItemType.arrival,
        task = null,
        event = null,
        meal = null,
        invitation = null,
        arrival = a,
        hour = (DateTime.tryParse(a['timestamp']?.toString() ?? '') ?? DateTime.now()).hour,
        minute = (DateTime.tryParse(a['timestamp']?.toString() ?? '') ?? DateTime.now()).minute;

  int get timeInMinutes => hour * 60 + minute;
  String get timeFormatted =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  static (int, int) _extractTime(String text, DateTime fallback) {
    // 1. Search for colon-separated time: "08:00", "12:30", "15:00", "19:30"
    final matchColon = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    if (matchColon != null) {
      final h = int.tryParse(matchColon.group(1) ?? '');
      final m = int.tryParse(matchColon.group(2) ?? '');
      if (h != null && h >= 0 && h < 24 && m != null && m >= 0 && m < 60) {
        return (h, m);
      }
    }
    // 2. Search for French hour format: "8h", "14h30", "19h00"
    final matchH = RegExp(r'(\d{1,2})[h:H](\d{2})?').firstMatch(text);
    if (matchH != null) {
      final h = int.tryParse(matchH.group(1) ?? '');
      final m = matchH.group(2) != null ? int.tryParse(matchH.group(2)!) : 0;
      if (h != null && h >= 0 && h < 24 && m != null && m >= 0 && m < 60) {
        return (h, m);
      }
    }
    return (fallback.hour, fallback.minute);
  }

  static (int, int) _extractMealTime(String text, DateTime fallback) {
    // Check explicit time first
    final colonMatch = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    if (colonMatch != null) {
      final h = int.tryParse(colonMatch.group(1) ?? '');
      final m = int.tryParse(colonMatch.group(2) ?? '');
      if (h != null && h >= 0 && h < 24 && m != null && m >= 0 && m < 60) {
        return (h, m);
      }
    }
    final hMatch = RegExp(r'(\d{1,2})[h:H](\d{2})?').firstMatch(text);
    if (hMatch != null) {
      final h = int.tryParse(hMatch.group(1) ?? '');
      final m = hMatch.group(2) != null ? int.tryParse(hMatch.group(2)!) : 0;
      if (h != null && h >= 0 && h < 24 && m != null && m >= 0 && m < 60) {
        return (h, m);
      }
    }
    // Semantic meal inference
    final lower = text.toLowerCase();
    if (lower.contains('petit-déjeuner') ||
        lower.contains('petit déjeuner') ||
        lower.contains('breakfast') ||
        lower.contains('matin')) {
      return (8, 30);
    }
    if (lower.contains('déjeuner') ||
        lower.contains('dejeuner') ||
        lower.contains('midi') ||
        lower.contains('lunch')) {
      return (12, 30);
    }
    if (lower.contains('goûter') || lower.contains('gouter')) {
      return (16, 30);
    }
    if (lower.contains('dîner') ||
        lower.contains('diner') ||
        lower.contains('souper') ||
        lower.contains('soir')) {
      return (19, 30);
    }
    // Default fallback based on creation hour
    if (fallback.hour >= 6 && fallback.hour < 11) {
      return (8, 30);
    } else if (fallback.hour >= 11 && fallback.hour < 15) {
      return (12, 30);
    } else {
      return (19, 30);
    }
  }
}

class EcranHubActivites extends StatefulWidget {
  const EcranHubActivites({super.key});

  @override
  State<EcranHubActivites> createState() => _EcranHubActivitesState();
}

class _EcranHubActivitesState extends State<EcranHubActivites> {
  final StorageService _storage = StorageService();
  ActivityFilter _selectedFilter = ActivityFilter.all;

  List<TaskItem> _tasks = [];
  List<FamilyMeetingEvent> _events = [];
  List<MealItem> _meals = [];
  List<Invitation> _invitations = [];
  List<Map<String, dynamic>> _arrivals = [];

  // Focus Mode State
  DateTime? _focusUntil;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    _restoreFocusState();

    // Sync meals in real-time
    _storage.startMealsSync(() {
      if (mounted) {
        setState(() {
          _meals = _storage.getMeals();
        });
      }
    });

    // Keep UI chip in sync with AudioRouterService transitions
    AudioRouterService().onFocusModeChanged = (active) {
      if (mounted) {
        if (!active && _focusUntil != null) {
          setState(() {
            _focusUntil = null;
          });
          _focusTimer?.cancel();
          _focusTimer = null;
        }
      }
    };

    // Listen to foyer switching to reload partitioned tasks, events, and meals
    FoyerManagerService().activeFoyerNotifier.addListener(_onFoyerChanged);

    // Passive Wi-Fi Radar: Auto-insert arrival in timeline and notify
    DiscoveryService().onMemberArrivedHome = (name, id) {
      if (mounted) {
        _loadData();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.home_outlined, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text('$name est rentré à la maison'),
              ],
            ),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    };
  }

  @override
  void dispose() {
    FoyerManagerService().activeFoyerNotifier.removeListener(_onFoyerChanged);
    DiscoveryService().onMemberArrivedHome = null;
    _focusTimer?.cancel();
    super.dispose();
  }

  void _onFoyerChanged() {
    if (mounted) {
      _loadData();
      _storage.startMealsSync(() {
        if (mounted) {
          setState(() {
            _meals = _storage.getMeals();
          });
        }
      });
      setState(() {});
    }
  }

  void _restoreFocusState() {
    final untilMs = _storage.focusUntilMs;
    if (untilMs != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
      if (DateTime.now().isBefore(until)) {
        _focusUntil = until;
        _startFocusTicker();
      } else {
        _stopFocusMode();
      }
    }
  }

  void _loadData() {
    setState(() {
      _tasks = _storage.getTasks();
      _events = _storage.getEvents();
      _meals = _storage.getMeals();
      _invitations = _storage.getInvitations();
      _arrivals = _storage.getArrivalEvents();
    });
  }

  void _startFocusTicker() {
    _focusTimer?.cancel();
    _focusTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_focusUntil != null && DateTime.now().isAfter(_focusUntil!)) {
        _stopFocusMode();
      } else {
        setState(() {});
      }
    });
  }

  void _startFocusMode(FocusDuration duration) {
    int minutes = 30;
    if (duration == FocusDuration.oneHour) minutes = 60;
    if (duration == FocusDuration.twoHours) minutes = 120;

    final dur = Duration(minutes: minutes);
    // 1. Persistent Hive save & 2. Hardware audio cut + auto-timer
    AudioRouterService().setFocusMode(true, dur);

    setState(() {
      _focusUntil = DateTime.now().add(dur);
    });

    _startFocusTicker();
  }

  void _stopFocusMode() {
    _focusTimer?.cancel();
    _focusTimer = null;
    AudioRouterService().setFocusMode(false);
    setState(() {
      _focusUntil = null;
    });
  }

  String _formatFocusRemaining() {
    if (_focusUntil == null) return '';
    final diff = _focusUntil!.difference(DateTime.now());
    if (diff.isNegative) return '';
    final m = diff.inMinutes;
    final s = diff.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _showFocusDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        title: Text(
          'Mode Focus & Tranquillité',
          style: GoogleFonts.redRose(color: AppTheme.layer4Active, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Isole les flux vocaux de l\'interphone pour travailler ou se reposer. Les alertes d\'urgence restent actives.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined, color: AppTheme.nordicSlateLight),
              title: const Text('30 minutes', style: TextStyle(color: AppTheme.layer4Active)),
              onTap: () {
                Navigator.pop(ctx);
                _startFocusMode(FocusDuration.thirtyMin);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined, color: AppTheme.nordicSlateLight),
              title: const Text('1 heure', style: TextStyle(color: AppTheme.layer4Active)),
              onTap: () {
                Navigator.pop(ctx);
                _startFocusMode(FocusDuration.oneHour);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined, color: AppTheme.nordicSlateLight),
              title: const Text('2 heures', style: TextStyle(color: AppTheme.layer4Active)),
              onTap: () {
                Navigator.pop(ctx);
                _startFocusMode(FocusDuration.twoHours);
              },
            ),
          ],
        ),
        actions: [
          if (_focusUntil != null)
            TextButton(
              onPressed: () {
                _stopFocusMode();
                Navigator.pop(ctx);
              },
              child: const Text('Désactiver le Focus', style: TextStyle(color: AppTheme.alertRed)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  void _showRecurringTasksCatalog() {
    // Sorted strictly by updatedAt descending
    final catalog = _storage.getTasks()
      ..sort((a, b) {
        final dateA = a.updatedAt ?? a.createdAt;
        final dateB = b.updatedAt ?? b.createdAt;
        return dateB.compareTo(dateA);
      });

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Catalogue des Tâches Récurrentes',
                  style: GoogleFonts.redRose(fontSize: 16, color: AppTheme.layer4Active),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (catalog.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Aucune tâche récurrente enregistrée',
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: catalog.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final item = catalog[i];
                    return Card(
                      elevation: 0,
                      color: AppTheme.layer2Container,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.repeat, color: AppTheme.nordicSlateLight, size: 20),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppTheme.layer4Active, fontWeight: FontWeight.w500),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: AppTheme.nordicSlateLight),
                          onPressed: () async {
                            final newTask = TaskItem(
                              id: 'task_${DateTime.now().millisecondsSinceEpoch}',
                              title: item.title,
                              createdAt: DateTime.now(),
                              updatedAt: DateTime.now(),
                            );
                            await _storage.saveTask(newTask);
                            _loadData();
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showAddNewTaskDialog() {
    final titleCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        title: const Text('Nouvelle Tâche', style: TextStyle(color: AppTheme.layer4Active)),
        content: TextField(
          controller: titleCtrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.layer4Active),
          decoration: const InputDecoration(
            hintText: 'Ex: Remplir la carafe d\'eau',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.nordicSlate),
            onPressed: () async {
              final text = titleCtrl.text.trim();
              if (text.isNotEmpty) {
                final task = TaskItem(
                  id: 'task_${DateTime.now().millisecondsSinceEpoch}',
                  title: text,
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                );
                await _storage.saveTask(task);
                _loadData();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'HUB D\'ACTIVITÉS',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        actions: [
          // Focus chip button
          if (_focusUntil != null)
            ActionChip(
              backgroundColor: AppTheme.alertRed.withValues(alpha: 0.15),
              side: const BorderSide(color: AppTheme.alertRed),
              avatar: const Icon(Icons.do_not_disturb_on, size: 16, color: AppTheme.alertRed),
              label: Text(
                _formatFocusRemaining(),
                style: const TextStyle(color: AppTheme.alertRed, fontWeight: FontWeight.bold, fontSize: 12),
              ),
              onPressed: _showFocusDialog,
            )
          else
            IconButton(
              icon: const Icon(Icons.self_improvement_outlined, size: 22),
              tooltip: 'Mode Focus',
              onPressed: _showFocusDialog,
            ),
          IconButton(
            icon: const Icon(Icons.layers_outlined, size: 22),
            tooltip: 'Tâches récurrentes',
            onPressed: _showRecurringTasksCatalog,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.nordicSlate,
        foregroundColor: Colors.white,
        onPressed: _showAddNewTaskDialog,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Filter Segmented Buttons (Tout, Tâches, Agenda, Repas, Invitations)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SegmentedButton<ActivityFilter>(
                segments: const [
                  ButtonSegment(value: ActivityFilter.all, label: Text('Tout', maxLines: 1)),
                  ButtonSegment(value: ActivityFilter.tasks, label: Text('Tâches', maxLines: 1)),
                  ButtonSegment(value: ActivityFilter.events, label: Text('Agenda', maxLines: 1)),
                  ButtonSegment(value: ActivityFilter.meals, label: Text('Repas', maxLines: 1)),
                  ButtonSegment(value: ActivityFilter.invitations, label: Text('Invit.', maxLines: 1)),
                ],
                selected: {_selectedFilter},
                onSelectionChanged: (set) {
                  setState(() {
                    _selectedFilter = set.first;
                  });
                },
              ),
            ),

            // Unified Chronological Timeline
            Expanded(
              child: _buildTimelineList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineList() {
    final List<TimelineItem> entries = [];

    // 1. Tasks
    if (_selectedFilter == ActivityFilter.all || _selectedFilter == ActivityFilter.tasks) {
      entries.addAll(_tasks.map((t) => TimelineItem.fromTask(t)));
    }

    // 2. Events
    if (_selectedFilter == ActivityFilter.all || _selectedFilter == ActivityFilter.events) {
      entries.addAll(_events.map((e) => TimelineItem.fromEvent(e)));
    }

    // 3. Meals
    if (_selectedFilter == ActivityFilter.all || _selectedFilter == ActivityFilter.meals) {
      entries.addAll(_meals.map((m) => TimelineItem.fromMeal(m)));
    }

    // 4. Invitations
    if (_selectedFilter == ActivityFilter.all || _selectedFilter == ActivityFilter.invitations) {
      entries.addAll(_invitations.map((i) => TimelineItem.fromInvitation(i)));
    }

    // 5. Radar Wi-Fi Arrivals
    if (_selectedFilter == ActivityFilter.all) {
      entries.addAll(_arrivals.map((a) => TimelineItem.fromArrival(a)));
    }

    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.event_available_outlined, size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              'Aucune activité enregistrée',
              style: GoogleFonts.instrumentSans(fontSize: 15, color: AppTheme.textMuted),
            ),
          ],
        ),
      );
    }

    // Sort strictly by time of day (00:00 to 23:59)
    entries.sort((a, b) => a.timeInMinutes.compareTo(b.timeInMinutes));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        final isFirst = i == 0;
        final isLast = i == entries.length - 1;

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Vertical timeline line + M3 time badge
              SizedBox(
                width: 60,
                child: Column(
                  children: [
                    Container(
                      width: 2,
                      height: isFirst ? 6 : 8,
                      color: isFirst ? Colors.transparent : Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        entry.timeFormatted,
                        maxLines: 1,
                        style: GoogleFonts.instrumentSans(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.nordicSlateLight,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: 2,
                        color: isLast ? Colors.transparent : Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Card content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _buildCardForEntry(entry),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCardForEntry(TimelineItem entry) {
    switch (entry.type) {
      case TimelineItemType.task:
        return _buildTaskCard(entry.task!);
      case TimelineItemType.event:
        return _buildEventCard(entry.event!);
      case TimelineItemType.meal:
        return _buildMealCard(entry.meal!);
      case TimelineItemType.invitation:
        return _buildInvitationCard(entry.invitation!);
      case TimelineItemType.arrival:
        return _buildArrivalCard(entry.arrival!);
    }
  }

  Widget _buildMealCard(MealItem meal) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.nordicSlate.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.restaurant_outlined, size: 20, color: AppTheme.nordicSlateLight),
        ),
        title: Text(
          meal.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.redRose(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.layer4Active,
          ),
        ),
        subtitle: Text(
          meal.isPrepared ? 'Préparé • ${meal.authorName}' : 'Proposé par ${meal.authorName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.instrumentSans(fontSize: 12, color: AppTheme.textMuted),
        ),
        trailing: IconButton(
          icon: Icon(
            meal.isPrepared ? Icons.check_circle : Icons.check_circle_outline,
            size: 20,
            color: meal.isPrepared ? AppTheme.nordicSlateLight : AppTheme.textMuted,
          ),
          tooltip: 'Marquer comme préparé',
          onPressed: () async {
            await _storage.toggleMealPrepared(meal.id);
            _loadData();
          },
        ),
      ),
    );
  }

  Widget _buildArrivalCard(Map<String, dynamic> arrival) {
    final name = arrival['memberName']?.toString() ?? 'Membre';
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.nordicSlate.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.home_outlined, size: 20, color: AppTheme.nordicSlateLight),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$name est rentré à la maison',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.redRose(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.layer4Active,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Radar Wi-Fi passif détecté',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

  Widget _buildTaskCard(TaskItem task) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Checkbox(
          value: task.isDone,
          activeColor: AppTheme.nordicSlate,
          onChanged: (_) async {
            await _storage.toggleTaskDone(task.id);
            _loadData();
          },
        ),
        title: Text(
          task.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: task.isDone ? AppTheme.textMuted : AppTheme.layer4Active,
            decoration: task.isDone ? TextDecoration.lineThrough : null,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textMuted),
          onPressed: () async {
            await _storage.deleteTask(task.id);
            _loadData();
          },
        ),
      ),
    );
  }

  Widget _buildEventCard(FamilyMeetingEvent event) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: const Icon(Icons.calendar_today, color: AppTheme.nordicSlateLight, size: 22),
        title: Text(
          event.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.layer4Active, fontWeight: FontWeight.w500),
        ),
        subtitle: event.dateTimeDisplay.isNotEmpty
            ? Text(
                event.dateTimeDisplay,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.instrumentSans(fontSize: 12, color: AppTheme.textMuted),
              )
            : null,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textMuted),
          onPressed: () async {
            await _storage.deleteEvent(event.id);
            _loadData();
          },
        ),
      ),
    );
  }

  Widget _buildInvitationCard(Invitation inv) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: const Icon(Icons.mail_outline, color: AppTheme.nordicSlateLight, size: 22),
        title: Text(
          inv.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.layer4Active, fontWeight: FontWeight.w500),
        ),
        subtitle: inv.dateTimeDisplay.isNotEmpty
            ? Text(
                inv.dateTimeDisplay,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.instrumentSans(fontSize: 12, color: AppTheme.textMuted),
              )
            : null,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textMuted),
          onPressed: () async {
            await _storage.deleteInvitation(inv.id);
            _loadData();
          },
        ),
      ),
    );
  }
}
