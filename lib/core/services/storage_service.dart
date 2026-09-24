import 'dart:async';
import 'dart:developer' as developer;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import '../constants/app_constants.dart';
import '../../models/family_member.dart';
import '../../models/announcement.dart';
import '../../models/invitation.dart';
import '../../models/task_item.dart';
import '../../models/family_event.dart';
import '../../models/meal_item.dart';
import '../../models/family_story.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  late Box _settingsBox;
  late Box _approvedMembersBox;
  late Box _tasksBox;
  late Box _groceriesBox;
  late Box _invitationsBox;
  late Box _eventsBox;
  late Box _portfolioBox;
  late Box _blockedMembersBox;
  late Box _mealsBox;
  late Box _storiesBox;
  late Box _arrivalEventsBox;

  final Set<String> _mutedMemberIds = {};

  Timer? _midnightPurgeTimer;
  Function(List<String> purgedTaskIds)? onTasksPurged;

  String _activeFoyerId = 'foyer_default';
  String get activeFoyerId => _activeFoyerId;

  Future<void> initialize() async {
    await Hive.initFlutter();

    _settingsBox = await Hive.openBox(AppConstants.boxSettings);
    _approvedMembersBox = await Hive.openBox(AppConstants.boxApprovedMembers);
    _portfolioBox = await Hive.openBox(AppConstants.boxPortfolio);
    _blockedMembersBox = await Hive.openBox(AppConstants.boxBlockedMembers);

    _activeFoyerId = _settingsBox.get('active_foyer_id', defaultValue: 'foyer_default') as String;

    _tasksBox = await Hive.openBox('tasks_$_activeFoyerId');
    _eventsBox = await Hive.openBox('events_$_activeFoyerId');
    _mealsBox = await Hive.openBox('meals_$_activeFoyerId');
    _groceriesBox = await Hive.openBox('groceries_$_activeFoyerId');
    _invitationsBox = await Hive.openBox('invitations_$_activeFoyerId');
    _storiesBox = await Hive.openBox('stories_$_activeFoyerId');
    _arrivalEventsBox = await Hive.openBox('arrival_events_$_activeFoyerId');

    // Run legacy migration if default foyer
    if (_activeFoyerId == 'foyer_default') {
      await _migrateLegacyBoxesIfPresent();
    }

    // Run midnight purge evaluator on startup
    evaluateMidnightPurge();

    // Schedule next midnight purge check
    _scheduleMidnightTimer();
  }

  Future<void> switchFoyerBoxes(String foyerId) async {
    _activeFoyerId = foyerId;
    await _settingsBox.put('active_foyer_id', foyerId);

    // Stop active subscriptions of previous foyer
    stopMealsSync();
    stopStoriesSync();

    // Explicitly close previous boxes before reopening to free file descriptors
    if (_tasksBox.isOpen) await _tasksBox.close();
    if (_eventsBox.isOpen) await _eventsBox.close();
    if (_mealsBox.isOpen) await _mealsBox.close();
    if (_groceriesBox.isOpen) await _groceriesBox.close();
    if (_invitationsBox.isOpen) await _invitationsBox.close();
    if (_storiesBox.isOpen) await _storiesBox.close();
    if (_arrivalEventsBox.isOpen) await _arrivalEventsBox.close();

    _tasksBox = await Hive.openBox('tasks_$foyerId');
    _eventsBox = await Hive.openBox('events_$foyerId');
    _mealsBox = await Hive.openBox('meals_$foyerId');
    _groceriesBox = await Hive.openBox('groceries_$foyerId');
    _invitationsBox = await Hive.openBox('invitations_$foyerId');
    _storiesBox = await Hive.openBox('stories_$foyerId');
    _arrivalEventsBox = await Hive.openBox('arrival_events_$foyerId');

    if (foyerId == 'foyer_default') {
      await _migrateLegacyBoxesIfPresent();
    }
  }

  Future<void> _migrateLegacyBoxesIfPresent() async {
    try {
      if (Hive.isBoxOpen(AppConstants.boxTasks) || await Hive.boxExists(AppConstants.boxTasks)) {
        final legacyTasks = await Hive.openBox(AppConstants.boxTasks);
        if (_tasksBox.isEmpty && legacyTasks.isNotEmpty) {
          for (final key in legacyTasks.keys) {
            await _tasksBox.put(key, legacyTasks.get(key));
          }
        }
      }
      if (Hive.isBoxOpen(AppConstants.boxEvents) || await Hive.boxExists(AppConstants.boxEvents)) {
        final legacyEvents = await Hive.openBox(AppConstants.boxEvents);
        if (_eventsBox.isEmpty && legacyEvents.isNotEmpty) {
          for (final key in legacyEvents.keys) {
            await _eventsBox.put(key, legacyEvents.get(key));
          }
        }
      }
      if (Hive.isBoxOpen(AppConstants.boxMeals) || await Hive.boxExists(AppConstants.boxMeals)) {
        final legacyMeals = await Hive.openBox(AppConstants.boxMeals);
        if (_mealsBox.isEmpty && legacyMeals.isNotEmpty) {
          for (final key in legacyMeals.keys) {
            await _mealsBox.put(key, legacyMeals.get(key));
          }
        }
      }
      if (Hive.isBoxOpen(AppConstants.boxGroceries) || await Hive.boxExists(AppConstants.boxGroceries)) {
        final legacyGroceries = await Hive.openBox(AppConstants.boxGroceries);
        if (_groceriesBox.isEmpty && legacyGroceries.isNotEmpty) {
          for (final key in legacyGroceries.keys) {
            await _groceriesBox.put(key, legacyGroceries.get(key));
          }
        }
      }
      if (Hive.isBoxOpen(AppConstants.boxInvitations) || await Hive.boxExists(AppConstants.boxInvitations)) {
        final legacyInv = await Hive.openBox(AppConstants.boxInvitations);
        if (_invitationsBox.isEmpty && legacyInv.isNotEmpty) {
          for (final key in legacyInv.keys) {
            await _invitationsBox.put(key, legacyInv.get(key));
          }
        }
      }
      if (Hive.isBoxOpen('family_stories') || await Hive.boxExists('family_stories')) {
        final legacyStories = await Hive.openBox('family_stories');
        if (_storiesBox.isEmpty && legacyStories.isNotEmpty) {
          for (final key in legacyStories.keys) {
            await _storiesBox.put(key, legacyStories.get(key));
          }
        }
      }
      if (Hive.isBoxOpen('arrival_events') || await Hive.boxExists('arrival_events')) {
        final legacyArrivals = await Hive.openBox('arrival_events');
        if (_arrivalEventsBox.isEmpty && legacyArrivals.isNotEmpty) {
          for (final key in legacyArrivals.keys) {
            await _arrivalEventsBox.put(key, legacyArrivals.get(key));
          }
        }
      }
    } catch (e) {
      developer.log('Legacy migration skipped or error: $e', name: 'StorageService');
    }
  }

  // --- Profile & Settings ---

  bool get isOnboarded => _settingsBox.get(AppConstants.keyIsOnboarded, defaultValue: false) == true;

  String get memberName => _settingsBox.get(AppConstants.keyMemberName, defaultValue: '') as String;

  String get familyCode => _settingsBox.get(AppConstants.keyFamilyCode, defaultValue: '') as String;

  String get deviceId => _settingsBox.get(AppConstants.keyDeviceId, defaultValue: '') as String;

  String get connectionMode =>
      _settingsBox.get(AppConstants.keyConnectionMode, defaultValue: AppConstants.modeLan) as String;

  Future<void> setConnectionMode(String mode) async {
    await _settingsBox.put(AppConstants.keyConnectionMode, mode);
  }

  double get audioCeiling =>
      (_settingsBox.get('audio_ceiling', defaultValue: 0.75) as num).toDouble();

  Future<void> setAudioCeiling(double ceiling) async {
    await _settingsBox.put('audio_ceiling', ceiling);
  }

  bool get isSpeakerphoneEnabled =>
      _settingsBox.get('is_speakerphone_enabled', defaultValue: true) == true;

  Future<void> setSpeakerphoneEnabled(bool enabled) async {
    await _settingsBox.put('is_speakerphone_enabled', enabled);
  }

  Future<void> saveUserProfile({
    required String name,
    required String familyCode,
    required String deviceId,
    String connectionMode = AppConstants.modeLan,
  }) async {
    await _settingsBox.put(AppConstants.keyMemberName, name);
    await _settingsBox.put(AppConstants.keyFamilyCode, familyCode);
    await _settingsBox.put(AppConstants.keyDeviceId, deviceId);
    await _settingsBox.put(AppConstants.keyConnectionMode, connectionMode);
    await _settingsBox.put(AppConstants.keyIsOnboarded, true);
  }

  // --- Approved Members Persistence ---

  bool hasDecisionForMember(String memberId) {
    return _approvedMembersBox.containsKey(memberId);
  }

  bool isMemberApproved(String memberId) {
    return _approvedMembersBox.get(memberId, defaultValue: false) == true;
  }

  Future<void> setMemberApproval(String memberId, bool approved) async {
    await _approvedMembersBox.put(memberId, approved);
  }

  List<String> getApprovedMemberIds() {
    return _approvedMembersBox.keys
        .where((key) => _approvedMembersBox.get(key) == true)
        .map((k) => k.toString())
        .toList();
  }

  // --- Inactivity Circuit Breaker ---

  bool get inactivityBreakerEnabled =>
      _settingsBox.get('inactivity_breaker_enabled', defaultValue: true) == true;

  Future<void> setInactivityBreakerEnabled(bool enabled) async {
    await _settingsBox.put('inactivity_breaker_enabled', enabled);
  }

  // --- Blocked Members Persistence ---

  bool isMemberBlocked(String memberId) {
    return _blockedMembersBox.get(memberId, defaultValue: false) == true;
  }

  Future<void> setMemberBlocked(String memberId, bool blocked) async {
    await _blockedMembersBox.put(memberId, blocked);
  }

  List<String> getBlockedMemberIds() {
    return _blockedMembersBox.keys
        .where((key) => _blockedMembersBox.get(key) == true)
        .map((k) => k.toString())
        .toList();
  }

  // --- Muted Members (Local Output) ---

  bool isMemberMuted(String memberId) {
    return _mutedMemberIds.contains(memberId);
  }

  void setMemberMuted(String memberId, bool muted) {
    if (muted) {
      _mutedMemberIds.add(memberId);
    } else {
      _mutedMemberIds.remove(memberId);
    }
  }

  // --- Announcement Banner ---

  Announcement? getAnnouncement() {
    final title = _settingsBox.get(AppConstants.keyAnnouncementTitle) as String?;
    final text = _settingsBox.get(AppConstants.keyAnnouncementText) as String?;
    final url = _settingsBox.get(AppConstants.keyAnnouncementUrl) as String?;
    final imagePath = _settingsBox.get(AppConstants.keyAnnouncementImagePath) as String?;

    if (title == null || title.isEmpty) return null;

    return Announcement(
      id: 'active_banner',
      title: title,
      text: text ?? '',
      url: url,
      imagePath: imagePath,
      createdAt: DateTime.now(),
    );
  }

  Future<void> saveAnnouncement(Announcement announcement) async {
    await _settingsBox.put(AppConstants.keyAnnouncementTitle, announcement.title);
    await _settingsBox.put(AppConstants.keyAnnouncementText, announcement.text);
    await _settingsBox.put(AppConstants.keyAnnouncementUrl, announcement.url ?? '');
    await _settingsBox.put(AppConstants.keyAnnouncementImagePath, announcement.imagePath ?? '');
  }

  Future<void> clearAnnouncement() async {
    await _settingsBox.delete(AppConstants.keyAnnouncementTitle);
    await _settingsBox.delete(AppConstants.keyAnnouncementText);
    await _settingsBox.delete(AppConstants.keyAnnouncementUrl);
    await _settingsBox.delete(AppConstants.keyAnnouncementImagePath);
  }

  // --- Automated Midnight Purge & Tasks ---

  void _scheduleMidnightTimer() {
    _midnightPurgeTimer?.cancel();

    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 0, 0, 10);
    final duration = tomorrow.difference(now);

    _midnightPurgeTimer = Timer(duration, () {
      evaluateMidnightPurge();
      _scheduleMidnightTimer();
    });
  }

  /// Automated Midnight Purge: permanently deletes tasks completed prior to today and tombstones older than 14 days
  void evaluateMidnightPurge() {
    try {
      final now = DateTime.now();
      final startOfToday = DateTime(now.year, now.month, now.day);
      final List<String> purgedIds = [];

      // 1. Purge completed tasks
      for (final key in _tasksBox.keys) {
        final raw = _tasksBox.get(key);
        if (raw is Map) {
          final task = TaskItem.fromMap(raw);
          if (task.isDone && task.completedAt != null) {
            if (task.completedAt!.isBefore(startOfToday)) {
              purgedIds.add(task.id);
            }
          }
          // Purge tombstones > 14 days
          if (task.isDeleted && task.deletedAt != null && now.difference(task.deletedAt!).inDays >= 14) {
            purgedIds.add(task.id);
          }
        }
      }

      for (final id in purgedIds) {
        _tasksBox.delete(id);
      }

      // 2. Purge grocery tombstones > 14 days
      final List<String> purgedGroceryIds = [];
      for (final key in _groceriesBox.keys) {
        final raw = _groceriesBox.get(key);
        if (raw is Map) {
          final item = TaskItem.fromMap(raw);
          if (item.isDeleted && item.deletedAt != null && now.difference(item.deletedAt!).inDays >= 14) {
            purgedGroceryIds.add(item.id);
          }
        }
      }
      for (final id in purgedGroceryIds) {
        _groceriesBox.delete(id);
      }

      // 3. Purge event tombstones > 14 days
      final List<String> purgedEventIds = [];
      for (final key in _eventsBox.keys) {
        final raw = _eventsBox.get(key);
        if (raw is Map) {
          final event = FamilyMeetingEvent.fromMap(raw);
          if (event.isDeleted && event.deletedAt != null && now.difference(event.deletedAt!).inDays >= 14) {
            purgedEventIds.add(event.id);
          }
        }
      }
      for (final id in purgedEventIds) {
        _eventsBox.delete(id);
      }

      // 4. Purge invitation tombstones > 14 days
      final List<String> purgedInvIds = [];
      for (final key in _invitationsBox.keys) {
        final raw = _invitationsBox.get(key);
        if (raw is Map) {
          final inv = Invitation.fromMap(raw);
          if (inv.isDeleted && inv.deletedAt != null && now.difference(inv.deletedAt!).inDays >= 14) {
            purgedInvIds.add(inv.id);
          }
        }
      }
      for (final id in purgedInvIds) {
        _invitationsBox.delete(id);
      }

      if (purgedIds.isNotEmpty) {
        developer.log('Midnight purge executed: removed ${purgedIds.length} tasks', name: 'StorageService');
        onTasksPurged?.call(purgedIds);
      }
    } catch (e) {
      developer.log('Error evaluating midnight purge: $e', name: 'StorageService');
    }
  }

  List<TaskItem> getTasks() {
    final List<TaskItem> list = [];
    for (final key in _tasksBox.keys) {
      final raw = _tasksBox.get(key);
      if (raw is Map) {
        final task = TaskItem.fromMap(raw);
        if (!task.isDeleted) {
          list.add(task);
        }
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveTask(TaskItem task) async {
    await _tasksBox.put(task.id, task.toMap());
  }

  /// Mark task as tombstone for reliable sync without phantom records
  Future<void> deleteTask(String id) async {
    final raw = _tasksBox.get(id);
    if (raw is Map) {
      final task = TaskItem.fromMap(raw);
      final tombstone = task.copyWith(
        isDeleted: true,
        deletedAt: DateTime.now(),
      );
      await _tasksBox.put(id, tombstone.toMap());
    } else {
      await _tasksBox.delete(id);
    }
  }

  Future<void> toggleTaskDone(String id) async {
    final raw = _tasksBox.get(id);
    if (raw is Map) {
      final task = TaskItem.fromMap(raw);
      final updated = task.copyWith(
        isDone: !task.isDone,
        completedAt: !task.isDone ? DateTime.now() : null,
      );
      await _tasksBox.put(id, updated.toMap());
    }
  }

  // --- Groceries ---

  List<TaskItem> getGroceries() {
    final List<TaskItem> list = [];
    for (final key in _groceriesBox.keys) {
      final raw = _groceriesBox.get(key);
      if (raw is Map) {
        final item = TaskItem.fromMap(raw);
        if (!item.isDeleted) {
          list.add(item);
        }
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveGrocery(TaskItem item) async {
    await _groceriesBox.put(item.id, item.toMap());
  }

  /// Mark grocery as tombstone
  Future<void> deleteGrocery(String id) async {
    final raw = _groceriesBox.get(id);
    if (raw is Map) {
      final item = TaskItem.fromMap(raw);
      final tombstone = item.copyWith(
        isDeleted: true,
        deletedAt: DateTime.now(),
      );
      await _groceriesBox.put(id, tombstone.toMap());
    } else {
      await _groceriesBox.delete(id);
    }
  }

  Future<void> toggleGroceryDone(String id) async {
    final raw = _groceriesBox.get(id);
    if (raw is Map) {
      final item = TaskItem.fromMap(raw);
      final updated = item.copyWith(
        isDone: !item.isDone,
        completedAt: !item.isDone ? DateTime.now() : null,
      );
      await _groceriesBox.put(id, updated.toMap());
    }
  }

  // --- Invitations ---

  List<Invitation> getInvitations() {
    final List<Invitation> list = [];
    for (final key in _invitationsBox.keys) {
      final raw = _invitationsBox.get(key);
      if (raw is Map) {
        final inv = Invitation.fromMap(raw);
        if (!inv.isDeleted) {
          list.add(inv);
        }
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveInvitation(Invitation invitation) async {
    await _invitationsBox.put(invitation.id, invitation.toMap());
  }

  /// Mark invitation as tombstone
  Future<void> deleteInvitation(String id) async {
    final raw = _invitationsBox.get(id);
    if (raw is Map) {
      final inv = Invitation.fromMap(raw);
      final tombstone = inv.copyWith(
        isDeleted: true,
        deletedAt: DateTime.now(),
      );
      await _invitationsBox.put(id, tombstone.toMap());
    } else {
      await _invitationsBox.delete(id);
    }
  }

  Future<void> setRsvpResponse({
    required String invitationId,
    required String memberId,
    required bool accepted,
  }) async {
    final raw = _invitationsBox.get(invitationId);
    if (raw is Map) {
      final invitation = Invitation.fromMap(raw);
      final updatedResponses = Map<String, bool>.from(invitation.rsvpResponses);
      updatedResponses[memberId] = accepted;
      final updated = invitation.copyWith(rsvpResponses: updatedResponses);
      await _invitationsBox.put(invitationId, updated.toMap());
    }
  }

  // --- Events & Nested Discussions ---

  List<FamilyMeetingEvent> getEvents() {
    final List<FamilyMeetingEvent> list = [];
    for (final key in _eventsBox.keys) {
      final raw = _eventsBox.get(key);
      if (raw is Map) {
        final ev = FamilyMeetingEvent.fromMap(raw);
        if (!ev.isDeleted) {
          list.add(ev);
        }
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveEvent(FamilyMeetingEvent event) async {
    await _eventsBox.put(event.id, event.toMap());
  }

  /// Mark event as tombstone
  Future<void> deleteEvent(String id) async {
    final raw = _eventsBox.get(id);
    if (raw is Map) {
      final ev = FamilyMeetingEvent.fromMap(raw);
      final tombstone = ev.copyWith(
        isDeleted: true,
        deletedAt: DateTime.now(),
      );
      await _eventsBox.put(id, tombstone.toMap());
    } else {
      await _eventsBox.delete(id);
    }
  }

  Future<void> addCommentToEvent(String eventId, EventComment comment) async {
    final raw = _eventsBox.get(eventId);
    if (raw is Map) {
      final event = FamilyMeetingEvent.fromMap(raw);
      final updatedComments = List<EventComment>.from(event.comments)..add(comment);
      final updated = event.copyWith(comments: updatedComments);
      await _eventsBox.put(eventId, updated.toMap());
    }
  }

  // --- Portfolio ---

  Function(FamilyMember member)? onPortfolioUpdated;

  FamilyMember? getPortfolio(String memberId) {
    final raw = _portfolioBox.get(memberId);
    if (raw is Map) {
      return FamilyMember.fromMap(raw);
    }
    return null;
  }

  Future<void> savePortfolio(FamilyMember member, {bool broadcast = true}) async {
    await _portfolioBox.put(member.id, member.toMap());
    if (broadcast) {
      onPortfolioUpdated?.call(member);
    }
  }

  // --- Focus Mode Persistence ---

  int? get focusUntilMs {
    try {
      return _settingsBox.get('focus_until_ms') as int?;
    } catch (_) {
      return null;
    }
  }

  Future<void> setFocusUntilMs(int? ms) async {
    try {
      if (ms == null) {
        await _settingsBox.delete('focus_until_ms');
      } else {
        await _settingsBox.put('focus_until_ms', ms);
      }
    } catch (_) {}
  }

  // --- Sleep Shield ---

  bool get isSleepShieldActive =>
      _settingsBox.get('sleep_shield_active', defaultValue: false) == true;

  Future<void> setSleepShieldActive(bool active) async {
    await _settingsBox.put('sleep_shield_active', active);
  }

  // --- Le Merci du Soir ---

  String get merciDuSoir =>
      _settingsBox.get('merci_du_soir', defaultValue: 'Merci à tous pour votre aide précieuse aujourd\'hui.') as String;

  Future<void> saveMerciDuSoir(String text) async {
    await _settingsBox.put('merci_du_soir', text);
    try {
      if (familyCode.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/merci');
        await ref.set({'text': text, 'updatedAt': DateTime.now().toIso8601String()});
      }
    } catch (_) {}
  }

  // --- Meals Persistence & Sync ---

  StreamSubscription? _mealsSubscription;

  List<MealItem> getMeals() {
    final list = <MealItem>[];
    for (final key in _mealsBox.keys) {
      final raw = _mealsBox.get(key);
      if (raw is Map) {
        list.add(MealItem.fromMap(raw));
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveMeal(MealItem meal) async {
    await _mealsBox.put(meal.id, meal.toMap());
    try {
      if (familyCode.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/meals/${meal.id}');
        await ref.set(meal.toMap());
      }
    } catch (_) {}
  }

  Future<void> deleteMeal(String id) async {
    await _mealsBox.delete(id);
    try {
      if (familyCode.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/meals/$id');
        await ref.remove();
      }
    } catch (_) {}
  }

  Future<void> toggleMealPrepared(String id) async {
    final raw = _mealsBox.get(id);
    if (raw is Map) {
      final meal = MealItem.fromMap(raw);
      final updated = meal.copyWith(isPrepared: !meal.isPrepared);
      await saveMeal(updated);
    }
  }

  Future<void> voteMeal(String mealId, String memberId, String vote) async {
    final raw = _mealsBox.get(mealId);
    if (raw is Map) {
      final meal = MealItem.fromMap(raw);
      final updatedVotes = Map<String, String>.from(meal.votes);
      if (updatedVotes[memberId] == vote) {
        updatedVotes.remove(memberId);
      } else {
        updatedVotes[memberId] = vote;
      }
      final updated = meal.copyWith(votes: updatedVotes);
      await saveMeal(updated);
    }
  }

  void startMealsSync(Function() onUpdated) {
    if (familyCode.isEmpty) return;
    try {
      final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/meals');
      _mealsSubscription?.cancel();
      _mealsSubscription = ref.onValue.listen((event) async {
        final raw = event.snapshot.value;
        if (raw is Map) {
          for (final entry in raw.entries) {
            if (entry.value is Map) {
              final meal = MealItem.fromMap(entry.value as Map);
              await _mealsBox.put(meal.id, meal.toMap());
            }
          }
          onUpdated();
        }
      });
    } catch (_) {}
  }

  void stopMealsSync() {
    _mealsSubscription?.cancel();
    _mealsSubscription = null;
  }

  // --- Family Stories Persistence & Expiry (24h) ---

  StreamSubscription? _storiesSubscription;

  List<FamilyStory> getActiveStories() {
    final list = <FamilyStory>[];
    final now = DateTime.now();
    for (final key in _storiesBox.keys) {
      final raw = _storiesBox.get(key);
      if (raw is Map) {
        final story = FamilyStory.fromMap(raw);
        if (now.isBefore(story.expiresAt)) {
          list.add(story);
        }
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<FamilyStory> getMemberActiveStories(String memberId) {
    return getActiveStories().where((s) => s.authorId == memberId).toList();
  }

  bool hasActiveStory(String memberId) {
    return getMemberActiveStories(memberId).isNotEmpty;
  }

  Future<void> saveStory(FamilyStory story) async {
    await _storiesBox.put(story.id, story.toMap());
    try {
      final familyStoriesBox = Hive.isBoxOpen('family_stories')
          ? Hive.box('family_stories')
          : await Hive.openBox('family_stories');
      await familyStoriesBox.put(story.id, story.toMap());
    } catch (_) {}

    try {
      if (familyCode.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/stories/${story.id}');
        await ref.set(story.toMap());
      }
    } catch (_) {}
  }

  Future<void> deleteStory(String storyId) async {
    await _storiesBox.delete(storyId);
    try {
      final familyStoriesBox = Hive.isBoxOpen('family_stories')
          ? Hive.box('family_stories')
          : await Hive.openBox('family_stories');
      await familyStoriesBox.delete(storyId);
    } catch (_) {}

    try {
      if (familyCode.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/stories/$storyId');
        await ref.remove();
      }
    } catch (_) {}
  }

  void startStoriesSync(Function() onUpdated) {
    if (familyCode.isEmpty) return;
    try {
      final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/stories');
      _storiesSubscription?.cancel();
      _storiesSubscription = ref.onValue.listen((event) async {
        final raw = event.snapshot.value;
        if (raw is Map) {
          final Set<String> remoteIds = {};
          final familyStoriesBox = Hive.isBoxOpen('family_stories')
              ? Hive.box('family_stories')
              : await Hive.openBox('family_stories');

          for (final entry in raw.entries) {
            if (entry.value is Map) {
              final story = FamilyStory.fromMap(entry.value as Map);
              if (DateTime.now().isBefore(story.expiresAt)) {
                remoteIds.add(story.id);
                await _storiesBox.put(story.id, story.toMap());
                await familyStoriesBox.put(story.id, story.toMap());
              }
            }
          }
          // Remove deleted or expired stories locally
          for (final localKey in _storiesBox.keys.toList()) {
            if (!remoteIds.contains(localKey.toString())) {
              await _storiesBox.delete(localKey);
              await familyStoriesBox.delete(localKey);
            }
          }
          onUpdated();
        } else if (raw == null) {
          await _storiesBox.clear();
          if (Hive.isBoxOpen('family_stories')) {
            await Hive.box('family_stories').clear();
          }
          onUpdated();
        }
      });
    } catch (_) {}
  }

  void stopStoriesSync() {
    _storiesSubscription?.cancel();
    _storiesSubscription = null;
  }

  // --- Passive Wi-Fi Radar Arrivals ---

  List<Map<String, dynamic>> getArrivalEvents() {
    final list = <Map<String, dynamic>>[];
    for (final key in _arrivalEventsBox.keys) {
      final raw = _arrivalEventsBox.get(key);
      if (raw is Map) {
        list.add(Map<String, dynamic>.from(raw));
      }
    }
    list.sort((a, b) {
      final tA = DateTime.tryParse(a['timestamp']?.toString() ?? '') ?? DateTime(2000);
      final tB = DateTime.tryParse(b['timestamp']?.toString() ?? '') ?? DateTime(2000);
      return tB.compareTo(tA);
    });
    return list;
  }

  DateTime? getMemberHomeArrivalTime(String memberId) {
    for (final a in getArrivalEvents()) {
      if (a['memberId'] == memberId) {
        return DateTime.tryParse(a['timestamp']?.toString() ?? '');
      }
    }
    return null;
  }

  Future<void> saveArrivalEvent({
    required String memberId,
    required String memberName,
    required DateTime timestamp,
  }) async {
    final id = 'arrival_${DateTime.now().millisecondsSinceEpoch}';
    final data = {
      'id': id,
      'memberId': memberId,
      'memberName': memberName,
      'timestamp': timestamp.toIso8601String(),
    };
    await _arrivalEventsBox.put(id, data);
    try {
      if (familyCode.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/arrivals/$id');
        await ref.set(data);
      }
    } catch (_) {}
  }

  void dispose() {
    _midnightPurgeTimer?.cancel();
    _mealsSubscription?.cancel();
    _storiesSubscription?.cancel();
  }
}
