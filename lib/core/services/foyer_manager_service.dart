import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../models/foyer_context.dart';
import 'storage_service.dart';
import 'discovery_service.dart';
import 'webrtc_service.dart';
import 'audio_router_service.dart';

class FoyerManagerService {
  static final FoyerManagerService _instance = FoyerManagerService._internal();
  factory FoyerManagerService() => _instance;
  FoyerManagerService._internal();

  static const String boxFoyers = 'foyer_contexts';
  late Box _foyersBox;
  StreamSubscription? _airlockSubscription;
  Timer? _wifiCheckTimer;

  Function(List<Map<String, dynamic>> pendingCandidates)? onAirlockUpdated;

  final ValueNotifier<List<Map<String, dynamic>>> airlockNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  final ValueNotifier<FoyerContext> activeFoyerNotifier = ValueNotifier<FoyerContext>(
    FoyerContext(
      id: 'foyer_default',
      name: 'Foyer Principal',
      familyCode: 'FOYER',
      isCurrent: true,
      createdAt: DateTime.now(),
    ),
  );

  Future<void> initialize() async {
    _foyersBox = await Hive.openBox(boxFoyers);

    // Bootstrap default foyer if none exists
    if (_foyersBox.isEmpty) {
      final storage = StorageService();
      final defaultCode = storage.familyCode.isNotEmpty ? storage.familyCode : 'FOYER';
      final defaultFoyer = FoyerContext(
        id: 'foyer_default',
        name: 'Foyer Principal',
        familyCode: defaultCode,
        isCurrent: true,
        createdAt: DateTime.now(),
      );
      await _foyersBox.put(defaultFoyer.id, defaultFoyer.toMap());
    }

    final current = getCurrentFoyer();
    activeFoyerNotifier.value = current;

    // Ensure StorageService boxes point to the current active foyer
    await StorageService().switchFoyerBoxes(current.id);

    // Register active Wi-Fi listener on AudioRouterService for BSSID events
    AudioRouterService().addWifiListener((bssid) async {
      if (bssid.isNotEmpty && bssid != '02:00:00:00:00:00') {
        await checkWifiBssidSwitch(bssid);
      }
    });

    _startWifiAutoSwitchListener();
    startAirlockListener();
  }

  List<FoyerContext> getFoyers() {
    final list = <FoyerContext>[];
    for (final key in _foyersBox.keys) {
      final raw = _foyersBox.get(key);
      if (raw is Map) {
        list.add(FoyerContext.fromMap(raw));
      }
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  FoyerContext getCurrentFoyer() {
    final foyers = getFoyers();
    return foyers.firstWhere(
      (f) => f.isCurrent,
      orElse: () => foyers.isNotEmpty
          ? foyers.first
          : FoyerContext(
              id: 'foyer_default',
              name: 'Foyer Principal',
              familyCode: 'FOYER',
              isCurrent: true,
              createdAt: DateTime.now(),
            ),
    );
  }

  Future<FoyerContext> addFoyer({
    required String name,
    required String familyCode,
    List<String> wifiBssids = const [],
    bool switchToNew = true,
  }) async {
    final id = 'foyer_${DateTime.now().millisecondsSinceEpoch}';
    final foyer = FoyerContext(
      id: id,
      name: name,
      familyCode: familyCode.toUpperCase(),
      wifiBssids: wifiBssids,
      isCurrent: false,
      createdAt: DateTime.now(),
    );
    await _foyersBox.put(id, foyer.toMap());
    if (switchToNew) {
      await switchFoyer(id);
    }
    return foyer;
  }

  Future<void> switchFoyer(String foyerId) async {
    final current = getCurrentFoyer();
    if (current.id == foyerId && activeFoyerNotifier.value.id == foyerId) {
      return;
    }

    developer.log('Switching foyer from ${current.name} to target $foyerId', name: 'FoyerManager');

    // 1. Coupe immédiatement la signalisation WebRTC et les écouteurs Firebase de l'ancien foyer
    WebRtcService().stopSignalingListener();
    StorageService().stopMealsSync();
    StorageService().stopStoriesSync();
    _airlockSubscription?.cancel();
    _airlockSubscription = null;

    // 2. Mettre à jour isCurrent dans Hive
    for (final key in _foyersBox.keys) {
      final raw = _foyersBox.get(key);
      if (raw is Map) {
        final foyer = FoyerContext.fromMap(raw);
        final isTarget = foyer.id == foyerId;
        await _foyersBox.put(key, foyer.copyWith(isCurrent: isTarget).toMap());
      }
    }

    final newFoyer = getCurrentFoyer();

    // 3. Réoriente les références des boîtes Hive vers celles du nouveau foyer
    final storage = StorageService();
    await storage.switchFoyerBoxes(newFoyer.id);

    await storage.saveUserProfile(
      name: storage.memberName,
      familyCode: newFoyer.familyCode,
      deviceId: storage.deviceId,
      connectionMode: storage.connectionMode,
    );

    // 4. Reconnecte la signalisation et les écouteurs sur le nouveau 'familyCode'
    await DiscoveryService().stop();
    await DiscoveryService().start(
      myName: storage.memberName,
      myDeviceId: storage.deviceId,
      familyCode: newFoyer.familyCode,
      mode: 'auto',
    );

    WebRtcService().startSignalingListener(
      familyCode: newFoyer.familyCode,
      myDeviceId: storage.deviceId,
    );

    startAirlockListener();

    // 5. Notifie l'interface pour recharger instantanément les données du nouveau foyer
    activeFoyerNotifier.value = newFoyer;
  }

  void _startWifiAutoSwitchListener() {
    _wifiCheckTimer?.cancel();
    _wifiCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      await pollCurrentWifiBssid();
    });
    // Immediate initial poll
    pollCurrentWifiBssid();
  }

  Future<void> pollCurrentWifiBssid() async {
    try {
      const platform = MethodChannel('com.foyer.intercom/audio');
      final bssid = await platform.invokeMethod<String>('getWifiBssid');
      if (bssid != null && bssid.isNotEmpty && bssid != '02:00:00:00:00:00') {
        await checkWifiBssidSwitch(bssid);
      }
    } catch (e) {
      debugPrint('Erreur pollCurrentWifiBssid: $e');
    }
  }

  Future<String?> getCurrentWifiBssid() async {
    try {
      const platform = MethodChannel('com.foyer.intercom/audio');
      return await platform.invokeMethod<String>('getWifiBssid');
    } catch (e) {
      debugPrint('Erreur getCurrentWifiBssid: $e');
      return null;
    }
  }

  Future<bool> associateCurrentWifiWithFoyer(String foyerId) async {
    final bssid = await getCurrentWifiBssid();
    if (bssid != null && bssid.isNotEmpty && bssid != '02:00:00:00:00:00') {
      final raw = _foyersBox.get(foyerId);
      if (raw is Map) {
        final foyer = FoyerContext.fromMap(raw);
        final updatedBssids = Set<String>.from(foyer.wifiBssids)..add(bssid);
        final updated = foyer.copyWith(wifiBssids: updatedBssids.toList());
        await _foyersBox.put(foyerId, updated.toMap());
        if (foyer.isCurrent) {
          activeFoyerNotifier.value = updated;
        }
        return true;
      }
    }
    return false;
  }

  /// Automatically switch active foyer if current connected Wi-Fi BSSID matches a registered foyer
  Future<void> checkWifiBssidSwitch(String currentBssid) async {
    if (currentBssid.isEmpty) return;
    final cleanBssid = currentBssid.toLowerCase().trim();
    for (final foyer in getFoyers()) {
      if (!foyer.isCurrent) {
        final matches = foyer.wifiBssids.any((b) => b.toLowerCase().trim() == cleanBssid);
        if (matches) {
          developer.log('Auto-switching to foyer ${foyer.name} based on Wi-Fi BSSID $currentBssid', name: 'FoyerManager');
          await switchFoyer(foyer.id);
          break;
        }
      }
    }
  }

  // --- Universal Encrypted Invitation Links & QR Codes ---

  Future<String> createInvitationLink({
    required int maxQuota,
    Duration validity = const Duration(days: 7),
  }) async {
    final currentFoyer = getCurrentFoyer();
    final expiry = DateTime.now().add(validity).millisecondsSinceEpoch;
    final inviteId = 'inv_${DateTime.now().millisecondsSinceEpoch}';
    final tokenPayload = {
      'id': inviteId,
      'c': currentFoyer.familyCode,
      'n': currentFoyer.name,
      'q': maxQuota,
      'e': expiry,
      's': Random().nextInt(999999).toString(),
    };
    final base64Token = base64Url.encode(utf8.encode(jsonEncode(tokenPayload)));
    final inviteData = {
      'id': inviteId,
      'token': base64Token,
      'familyCode': currentFoyer.familyCode,
      'foyerName': currentFoyer.name,
      'maxQuota': maxQuota,
      'usedCount': 0,
      'expiresAt': expiry,
      'isRevoked': false,
      'createdAt': DateTime.now().toIso8601String(),
    };

    // Save locally in Hive
    try {
      final box = await Hive.openBox('foyer_invitations');
      await box.put(inviteId, inviteData);
    } catch (e) {
      debugPrint('Erreur ouverture boîte Hive foyer_invitations: $e');
    }

    // Save to Firebase
    try {
      final ref = FirebaseDatabase.instance.ref('foyers/${currentFoyer.familyCode}/invitations/$inviteId');
      await ref.set(inviteData);
    } catch (e) {
      debugPrint('Erreur enregistrement invitation Firebase: $e');
    }

    return 'https://foyer.app/join?token=$base64Token';
  }

  String generateInvitationLink({
    required int maxQuota,
    required Duration validity,
  }) {
    final currentFoyer = getCurrentFoyer();
    final expiry = DateTime.now().add(validity).millisecondsSinceEpoch;
    final tokenPayload = {
      'c': currentFoyer.familyCode,
      'n': currentFoyer.name,
      'q': maxQuota,
      'e': expiry,
      's': Random().nextInt(999999).toString(),
    };
    final base64Token = base64Url.encode(utf8.encode(jsonEncode(tokenPayload)));
    return 'https://foyer.app/join?token=$base64Token';
  }

  // --- Airlock (Sas d'Attente) Security ---

  Future<bool> joinAirlockWithToken({
    required String token,
    required String deviceId,
    required String newcomerName,
  }) async {
    try {
      final jsonStr = utf8.decode(base64Url.decode(token));
      final payload = jsonDecode(jsonStr);
      if (payload is! Map) return false;

      final familyCode = payload['c']?.toString() ?? '';
      final inviteId = payload['id']?.toString() ?? '';
      final expiry = (payload['e'] as num?)?.toInt() ?? 0;
      final maxQuota = (payload['q'] as num?)?.toInt() ?? 1;

      // 1. Check expiration
      if (DateTime.now().millisecondsSinceEpoch > expiry) {
        return false;
      }

      // 2. Check quota & auto-revoke if depleted
      if (familyCode.isNotEmpty && inviteId.isNotEmpty) {
        final invRef = FirebaseDatabase.instance.ref('foyers/$familyCode/invitations/$inviteId');
        final snapshot = await invRef.get();
        if (snapshot.exists && snapshot.value is Map) {
          final invMap = snapshot.value as Map;
          final isRevoked = invMap['isRevoked'] == true;
          final usedCount = (invMap['usedCount'] as num?)?.toInt() ?? 0;
          if (isRevoked || usedCount >= maxQuota) {
            return false; // Quota épuisé ou révoqué
          }
          final newUsed = usedCount + 1;
          await invRef.update({
            'usedCount': newUsed,
            'isRevoked': newUsed >= maxQuota,
          });
        }
      }

      // 3. Enqueue in Airlock (Hive & Firebase)
      final airlockData = {
        'deviceId': deviceId,
        'name': newcomerName,
        'timestamp': DateTime.now().toIso8601String(),
        'familyCode': familyCode,
        'inviteId': inviteId,
      };

      try {
        final box = await Hive.openBox('airlock_queue');
        await box.put(deviceId, airlockData);
      } catch (e) {
        debugPrint('Erreur boîte Hive airlock_queue: $e');
      }

      try {
        final ref = FirebaseDatabase.instance.ref('foyers/$familyCode/airlock/$deviceId');
        await ref.set(airlockData);
      } catch (e) {
        debugPrint('Erreur écriture airlock Firebase: $e');
      }

      return true;
    } catch (e) {
      developer.log('Error joining airlock with token: $e', name: 'FoyerManager');
      return false;
    }
  }

  void startAirlockListener() {
    final currentFoyer = getCurrentFoyer();
    try {
      final airlockRef = FirebaseDatabase.instance.ref('foyers/${currentFoyer.familyCode}/airlock');
      _airlockSubscription?.cancel();
      _airlockSubscription = airlockRef.onValue.listen((event) {
        final raw = event.snapshot.value;
        final List<Map<String, dynamic>> candidates = [];
        if (raw is Map) {
          raw.forEach((k, v) {
            if (v is Map) {
              candidates.add({
                'deviceId': k.toString(),
                'name': v['name']?.toString() ?? 'Nouvel Invité',
                'timestamp': v['timestamp']?.toString() ?? '',
              });
            }
          });
        }
        airlockNotifier.value = candidates;
        onAirlockUpdated?.call(candidates);
      });
    } catch (e) {
      debugPrint('Erreur startAirlockListener: $e');
    }
  }

  Future<void> decideCandidate({
    required String candidateId,
    required String candidateName,
    required bool approve,
  }) async {
    final currentFoyer = getCurrentFoyer();
    final airlockRef = FirebaseDatabase.instance.ref('foyers/${currentFoyer.familyCode}/airlock/$candidateId');
    await airlockRef.remove();

    try {
      if (Hive.isBoxOpen('airlock_queue')) {
        await Hive.box('airlock_queue').delete(candidateId);
      }
    } catch (e) {
      debugPrint('Erreur suppression airlock_queue: $e');
    }

    if (approve) {
      await StorageService().setMemberApproval(candidateId, true);
      final membersRef = FirebaseDatabase.instance.ref('foyers/${currentFoyer.familyCode}/approved/$candidateId');
      await membersRef.set({
        'name': candidateName,
        'approvedAt': DateTime.now().toIso8601String(),
      });
      DiscoveryService().approveDiscoveredMember(candidateId, true);
    } else {
      await StorageService().setMemberBlocked(candidateId, true);
      final blockedRef = FirebaseDatabase.instance.ref('foyers/${currentFoyer.familyCode}/blocked/$candidateId');
      await blockedRef.set({
        'name': candidateName,
        'blockedAt': DateTime.now().toIso8601String(),
      });
      DiscoveryService().approveDiscoveredMember(candidateId, false);
    }
  }

  void dispose() {
    _airlockSubscription?.cancel();
    _wifiCheckTimer?.cancel();
    airlockNotifier.dispose();
  }
}
