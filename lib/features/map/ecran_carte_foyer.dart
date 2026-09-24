import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/discovery_service.dart';

/// 2D Kalman Filter for smoothing noisy GPS coordinates
class Kalman2D {
  double _lat = 0.0;
  double _lon = 0.0;
  double _variance = -1.0;
  final double _q = 0.00001; // Process noise covariance

  void update(double rawLat, double rawLon, double accuracy) {
    final double r = math.max(accuracy * accuracy, 1.0);
    if (_variance < 0) {
      _lat = rawLat;
      _lon = rawLon;
      _variance = r;
    } else {
      _variance += _q;
      final double k = _variance / (_variance + r);
      _lat += k * (rawLat - _lat);
      _lon += k * (rawLon - _lon);
      _variance = (1.0 - k) * _variance;
    }
  }

  double get lat => _lat;
  double get lon => _lon;
}

class MemberTelemetryData {
  final String memberId;
  final String name;
  final double lat; // latest target smoothed latitude
  final double lon; // latest target smoothed longitude
  final double startLat;
  final double startLon;
  final double targetLat;
  final double targetLon;
  final double accuracy; // meters
  final double speedKmh;
  final double altitude;
  final DateTime timestamp;
  final List<Offset> historyPoints; // Recent coordinates for spline smoothing

  const MemberTelemetryData({
    required this.memberId,
    required this.name,
    required this.lat,
    required this.lon,
    required this.startLat,
    required this.startLon,
    required this.targetLat,
    required this.targetLon,
    required this.accuracy,
    required this.speedKmh,
    this.altitude = 0.0,
    required this.timestamp,
    this.historyPoints = const [],
  });

  /// Computes fluid interpolated position based on 1.2s curve progress
  double currentLat(double progress) => startLat + (targetLat - startLat) * progress;
  double currentLon(double progress) => startLon + (targetLon - startLon) * progress;
}

/// Haversine distance in meters between two coordinates
double _calculateDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const double earthRadius = 6371000.0;
  final double dLat = (lat2 - lat1) * math.pi / 180.0;
  final double dLon = (lon2 - lon1) * math.pi / 180.0;
  final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) *
      math.sin(dLon / 2) * math.sin(dLon / 2);
  final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadius * c;
}

class EcranCarteFoyer extends StatefulWidget {
  const EcranCarteFoyer({super.key});

  @override
  State<EcranCarteFoyer> createState() => _EcranCarteFoyerState();
}

class _EcranCarteFoyerState extends State<EcranCarteFoyer> with TickerProviderStateMixin {
  static const MethodChannel _channel = MethodChannel('com.foyer.intercom/audio');
  final StorageService _storage = StorageService();
  final DiscoveryService _discovery = DiscoveryService();

  late AnimationController _haloController;
  late AnimationController _interpolationController;
  late Animation<double> _curvedInterpolation;

  StreamSubscription? _firebaseLocationsSubscription;
  StreamSubscription? _firebaseTelemetrySubscription;
  Timer? _staleCheckTimer;

  final Map<String, Kalman2D> _kalmanFilters = {};
  final Map<String, List<Offset>> _historyMap = {};
  final Map<String, MemberTelemetryData> _telemetryMap = {};

  DateTime? _lastBroadcastTime;
  double? _lastBroadcastLat;
  double? _lastBroadcastLon;

  bool _isGpsActive = false;
  String _gpsStatus = 'Initialisation GPS matériel...';
  Timer? _gpsTimeoutTimer;
  bool _isGpsTimedOut = false;

  void _startGpsTimeoutTimer() {
    _gpsTimeoutTimer?.cancel();
    _isGpsTimedOut = false;
    _gpsTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _telemetryMap.isEmpty) {
        setState(() {
          _isGpsTimedOut = true;
          _gpsStatus = 'Signal GPS en attente (Intérieur / Recherche satellite)';
        });
      }
    });
  }

  void _retryGpsAcquisition() {
    setState(() {
      _isGpsTimedOut = false;
      _gpsStatus = 'Acquisition GPS en cours...';
    });
    _startGpsTimeoutTimer();
    _initHardwareLocation();
  }

  @override
  void initState() {
    super.initState();
    _haloController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _interpolationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _curvedInterpolation = CurvedAnimation(
      parent: _interpolationController,
      curve: Curves.easeOutCubic,
    );

    _initHardwareLocation();
    _initUdpTelemetryListener();
    _initFirebaseTelemetryListener();
    _startGpsTimeoutTimer();

    // Check periodically for stale telemetry (e.g. signal loss > 5s) to reflect degraded state
    _staleCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && _telemetryMap.isNotEmpty) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _stopHardwareLocation();
    _staleCheckTimer?.cancel();
    _gpsTimeoutTimer?.cancel();
    _haloController.dispose();
    _interpolationController.dispose();
    _firebaseLocationsSubscription?.cancel();
    _firebaseTelemetrySubscription?.cancel();
    _discovery.onLocationReceived = null;
    super.dispose();
  }

  Future<void> _initHardwareLocation() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLocationUpdate' && call.arguments is Map) {
        _handleRawLocationUpdate(Map<String, dynamic>.from(call.arguments as Map));
      }
    });

    try {
      final res = await _channel.invokeMethod('startLocationUpdates');
      if (res is Map) {
        _handleRawLocationUpdate(Map<String, dynamic>.from(res));
      }
      if (mounted) {
        setState(() {
          _isGpsActive = true;
          _gpsStatus = 'Signal GPS matériel actif';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isGpsActive = false;
          _gpsStatus = 'En attente d\'autorisation ou signal GPS';
        });
      }
    }
  }

  Future<void> _stopHardwareLocation() async {
    try {
      await _channel.invokeMethod('stopLocationUpdates');
    } catch (_) {}
  }

  void _handleRawLocationUpdate(Map<String, dynamic> data) {
    final rawLat = (data['latitude'] as num?)?.toDouble() ?? (data['lat'] as num?)?.toDouble();
    final rawLon = (data['longitude'] as num?)?.toDouble() ?? (data['lon'] as num?)?.toDouble();
    final accuracy = (data['accuracy'] as num?)?.toDouble() ?? 10.0;
    final speedMps = (data['speed'] as num?)?.toDouble() ?? 0.0;
    final speedKmh = speedMps > 0 ? speedMps * 3.6 : ((data['speedKmh'] as num?)?.toDouble() ?? 0.0);
    final altitude = (data['altitude'] as num?)?.toDouble() ?? 0.0;
    final now = DateTime.now();

    if (rawLat == null || rawLon == null || (rawLat == 0.0 && rawLon == 0.0)) return;

    _gpsTimeoutTimer?.cancel();
    _isGpsTimedOut = false;

    final myId = _storage.deviceId.isNotEmpty ? _storage.deviceId : 'local_device';
    final myName = _storage.memberName.isNotEmpty ? _storage.memberName : 'Moi';

    // 1. Apply Kalman 2D Filter
    final kalman = _kalmanFilters.putIfAbsent(myId, () => Kalman2D());
    kalman.update(rawLat, rawLon, accuracy);

    final smoothLat = kalman.lat;
    final smoothLon = kalman.lon;

    // 2. Track history for spline rendering
    final hist = _historyMap.putIfAbsent(myId, () => []);
    hist.add(Offset(smoothLon, smoothLat));
    if (hist.length > 10) hist.removeAt(0);

    // 3. Fluid 1.2s Tween interpolation setup
    final prev = _telemetryMap[myId];
    final double animT = _curvedInterpolation.value;
    final double startLat = prev != null ? prev.currentLat(animT) : smoothLat;
    final double startLon = prev != null ? prev.currentLon(animT) : smoothLon;

    final updated = MemberTelemetryData(
      memberId: myId,
      name: myName,
      lat: smoothLat,
      lon: smoothLon,
      startLat: startLat,
      startLon: startLon,
      targetLat: smoothLat,
      targetLon: smoothLon,
      accuracy: accuracy,
      speedKmh: speedKmh,
      altitude: altitude,
      timestamp: now,
      historyPoints: List.from(hist),
    );

    if (mounted) {
      setState(() {
        _telemetryMap[myId] = updated;
        _isGpsActive = true;
        _gpsStatus = 'GPS matériel actif (${accuracy.round()}m)';
      });
      _interpolationController.forward(from: 0.0);
    }

    // 4. Throttled Broadcast (every 3 to 5 seconds, ONLY IF USER MOVES)
    _broadcastLocationIfMoving(
      myId: myId,
      myName: myName,
      smoothLat: smoothLat,
      smoothLon: smoothLon,
      accuracy: accuracy,
      speedKmh: speedKmh,
      altitude: altitude,
      timestamp: now,
    );
  }

  void _broadcastLocationIfMoving({
    required String myId,
    required String myName,
    required double smoothLat,
    required double smoothLon,
    required double accuracy,
    required double speedKmh,
    required double altitude,
    required DateTime timestamp,
  }) {
    final now = DateTime.now();
    final bool isThrottled = _lastBroadcastTime != null &&
        now.difference(_lastBroadcastTime!).inMilliseconds < 3000;

    final double distFromLast = (_lastBroadcastLat != null && _lastBroadcastLon != null)
        ? _calculateDistanceMeters(_lastBroadcastLat!, _lastBroadcastLon!, smoothLat, smoothLon)
        : 999.0;

    // Broadcast only if moving (speed > 1.0 km/h or position moved > 2.0 meters) or initial point
    final bool isMoving = speedKmh > 1.0 || distFromLast >= 2.0 || _lastBroadcastTime == null;

    if (!isThrottled && isMoving) {
      _lastBroadcastTime = now;
      _lastBroadcastLat = smoothLat;
      _lastBroadcastLon = smoothLon;

      final payload = {
        'memberId': myId,
        'name': myName,
        'lat': smoothLat,
        'lon': smoothLon,
        'accuracy': accuracy,
        'speedKmh': speedKmh,
        'altitude': altitude,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };

      // 1. Broadcast to Local Network (UDP port 8888)
      _discovery.broadcastLocation(payload);

      // 2. Broadcast to Firebase (foyers/$familyCode/locations/$deviceId)
      final familyCode = _storage.familyCode;
      if (familyCode.isNotEmpty && myId.isNotEmpty) {
        try {
          final locRef = FirebaseDatabase.instance.ref('foyers/$familyCode/locations/$myId');
          locRef.set(payload);

          final teleRef = FirebaseDatabase.instance.ref('foyers/$familyCode/telemetry/$myId');
          teleRef.set(payload);
        } catch (_) {}
      }
    }
  }

  void _handleRemoteLocationUpdate(Map<String, dynamic> data) {
    final myId = _storage.deviceId;
    final memberId = data['memberId']?.toString() ?? data['id']?.toString() ?? '';
    if (memberId.isEmpty || memberId == myId) return;

    final name = data['name']?.toString() ?? 'Membre';
    final rawLat = (data['lat'] as num?)?.toDouble() ?? (data['latitude'] as num?)?.toDouble();
    final rawLon = (data['lon'] as num?)?.toDouble() ?? (data['longitude'] as num?)?.toDouble();
    final accuracy = (data['accuracy'] as num?)?.toDouble() ?? 15.0;
    final speedKmh = (data['speedKmh'] as num?)?.toDouble() ?? (((data['speed'] as num?)?.toDouble() ?? 0.0) * 3.6);
    final altitude = (data['altitude'] as num?)?.toDouble() ?? 0.0;
    final tsMs = (data['timestamp'] as num?)?.toInt();
    final ts = tsMs != null ? DateTime.fromMillisecondsSinceEpoch(tsMs) : DateTime.now();

    if (rawLat == null || rawLon == null || (rawLat == 0.0 && rawLon == 0.0)) return;

    // Discard outdated packets (> 60 seconds old)
    if (DateTime.now().difference(ts).inSeconds > 60) return;

    // 1. Apply Kalman 2D Filter
    final kalman = _kalmanFilters.putIfAbsent(memberId, () => Kalman2D());
    kalman.update(rawLat, rawLon, accuracy);

    final smoothLat = kalman.lat;
    final smoothLon = kalman.lon;

    // 2. Track history for spline rendering
    final hist = _historyMap.putIfAbsent(memberId, () => []);
    hist.add(Offset(smoothLon, smoothLat));
    if (hist.length > 10) hist.removeAt(0);

    // 3. Fluid 1.2s Tween interpolation setup
    final prev = _telemetryMap[memberId];
    final double animT = _curvedInterpolation.value;
    final double startLat = prev != null ? prev.currentLat(animT) : smoothLat;
    final double startLon = prev != null ? prev.currentLon(animT) : smoothLon;

    final updated = MemberTelemetryData(
      memberId: memberId,
      name: name,
      lat: smoothLat,
      lon: smoothLon,
      startLat: startLat,
      startLon: startLon,
      targetLat: smoothLat,
      targetLon: smoothLon,
      accuracy: accuracy,
      speedKmh: speedKmh,
      altitude: altitude,
      timestamp: ts,
      historyPoints: List.from(hist),
    );

    if (mounted) {
      setState(() {
        _telemetryMap[memberId] = updated;
      });
      _interpolationController.forward(from: 0.0);
    }
  }

  void _initUdpTelemetryListener() {
    _discovery.onLocationReceived = (data) {
      if (mounted) {
        _handleRemoteLocationUpdate(data);
      }
    };
  }

  void _initFirebaseTelemetryListener() {
    final familyCode = _storage.familyCode;
    if (familyCode.isEmpty) return;

    try {
      // Primary real-time locations node
      final locRef = FirebaseDatabase.instance.ref('foyers/$familyCode/locations');
      _firebaseLocationsSubscription = locRef.onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          data.forEach((k, v) {
            if (v is Map) {
              _handleRemoteLocationUpdate(Map<String, dynamic>.from(v));
            }
          });
        }
      });

      // Legacy telemetry node for compatibility
      final teleRef = FirebaseDatabase.instance.ref('foyers/$familyCode/telemetry');
      _firebaseTelemetrySubscription = teleRef.onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          data.forEach((k, v) {
            if (v is Map) {
              _handleRemoteLocationUpdate(Map<String, dynamic>.from(v));
            }
          });
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final activeTelemetry = _telemetryMap.values.toList();

    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'CARTE DU FOYER',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location, size: 20),
            onPressed: () {
              _initHardwareLocation();
            },
            tooltip: 'Recentrer le signal',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Dark Vector Street Canvas Map with Dynamic Geolocation Projection
          Positioned.fill(
            child: activeTelemetry.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_isGpsTimedOut) ...[
                            const SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.nordicSlate,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ] else ...[
                            const Icon(
                              Icons.location_searching_rounded,
                              size: 40,
                              color: AppTheme.nordicSlateLight,
                            ),
                            const SizedBox(height: 12),
                          ],
                          Text(
                            _gpsStatus,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.instrumentSans(fontSize: 14, color: AppTheme.textMuted),
                          ),
                          if (_isGpsTimedOut) ...[
                            const SizedBox(height: 16),
                            FilledButton.tonal(
                              onPressed: _retryGpsAcquisition,
                              child: const Text('Réessayer'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : AnimatedBuilder(
                    animation: Listenable.merge([_haloController, _curvedInterpolation]),
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _DarkVectorStreetPainter(
                          telemetry: activeTelemetry,
                          haloProgress: _haloController.value,
                          interpolationProgress: _curvedInterpolation.value,
                        ),
                      );
                    },
                  ),
          ),

          // Bottom telemetry status bar (M3 minimalist card)
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: Card(
              elevation: 0,
              color: AppTheme.layer1Surface.withValues(alpha: 0.92),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: AppTheme.layer3Border, width: 1),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      _isGpsActive ? Icons.satellite_alt_outlined : Icons.gps_off_outlined,
                      size: 20,
                      color: _isGpsActive ? AppTheme.nordicSlateLight : AppTheme.alertRed,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _gpsStatus,
                        style: GoogleFonts.instrumentSans(fontSize: 13, color: AppTheme.layer4Active),
                      ),
                    ),
                    if (activeTelemetry.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.nordicSlate.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppTheme.nordicSlateLight.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '${activeTelemetry.length} en ligne',
                          style: GoogleFonts.instrumentSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.nordicSlateLight,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter with dynamic coordinate projection and Catmull-Rom spline paths
class _DarkVectorStreetPainter extends CustomPainter {
  final List<MemberTelemetryData> telemetry;
  final double haloProgress;
  final double interpolationProgress;

  _DarkVectorStreetPainter({
    required this.telemetry,
    required this.haloProgress,
    required this.interpolationProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF0A0C10);
    canvas.drawRect(Offset.zero & size, bgPaint);

    if (telemetry.isEmpty) return;

    // Compute bounding box using interpolated coordinates
    double minLat = 90.0, maxLat = -90.0;
    double minLon = 180.0, maxLon = -180.0;

    for (final item in telemetry) {
      final cLat = item.currentLat(interpolationProgress);
      final cLon = item.currentLon(interpolationProgress);
      if (cLat < minLat) minLat = cLat;
      if (cLat > maxLat) maxLat = cLat;
      if (cLon < minLon) minLon = cLon;
      if (cLon > maxLon) maxLon = cLon;
    }

    // Default span if only 1 member or tightly grouped
    double latSpan = maxLat - minLat;
    double lonSpan = maxLon - minLon;
    const double minSpan = 0.005; // ~500m
    if (latSpan < minSpan) {
      final midLat = (minLat + maxLat) / 2.0;
      minLat = midLat - minSpan / 2.0;
      maxLat = midLat + minSpan / 2.0;
      latSpan = minSpan;
    }
    if (lonSpan < minSpan) {
      final midLon = (minLon + maxLon) / 2.0;
      minLon = midLon - minSpan / 2.0;
      maxLon = midLon + minSpan / 2.0;
      lonSpan = minSpan;
    }

    const double margin = 60.0;
    final double usableW = size.width - margin * 2;
    final double usableH = size.height - margin * 2;

    Offset project(double lat, double lon) {
      final normX = (lon - minLon) / lonSpan;
      final normY = 1.0 - ((lat - minLat) / latSpan); // Invert Y (North is up)
      return Offset(
        margin + (normX * usableW).clamp(0.0, usableW),
        margin + (normY * usableH).clamp(0.0, usableH),
      );
    }

    // Grid lines representing dark vector street geometry
    final roadPaint = Paint()
      ..color = const Color(0xFF1E242B)
      ..strokeWidth = 1.5;

    for (double y = 40; y < size.height; y += 70) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), roadPaint);
    }
    for (double x = 30; x < size.width; x += 80) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), roadPaint);
    }

    // Render spline interpolation paths for each member
    for (final item in telemetry) {
      if (item.historyPoints.length >= 2) {
        final path = Path();
        final projectedPoints = item.historyPoints.map((pt) => project(pt.dy, pt.dx)).toList();

        path.moveTo(projectedPoints.first.dx, projectedPoints.first.dy);
        for (int i = 0; i < projectedPoints.length - 1; i++) {
          final p0 = i > 0 ? projectedPoints[i - 1] : projectedPoints[i];
          final p1 = projectedPoints[i];
          final p2 = projectedPoints[i + 1];
          final p3 = i + 2 < projectedPoints.length ? projectedPoints[i + 2] : p2;

          // Catmull-Rom to Cubic Bezier conversion
          final cp1 = Offset(
            p1.dx + (p2.dx - p0.dx) / 6.0,
            p1.dy + (p2.dy - p0.dy) / 6.0,
          );
          final cp2 = Offset(
            p2.dx - (p3.dx - p1.dx) / 6.0,
            p2.dy - (p3.dy - p1.dy) / 6.0,
          );
          path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
        }

        final splinePaint = Paint()
          ..color = AppTheme.nordicSlateLight.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        canvas.drawPath(path, splinePaint);
      }
    }

    // Render member markers
    final now = DateTime.now();
    for (int i = 0; i < telemetry.length; i++) {
      final item = telemetry[i];
      final currentLat = item.currentLat(interpolationProgress);
      final currentLon = item.currentLon(interpolationProgress);
      final pos = project(currentLat, currentLon);
      final cx = pos.dx;
      final cy = pos.dy;

      // Degraded GPS condition: accuracy > 30m or signal loss > 5s
      final bool isDegraded = item.accuracy > 30.0 || now.difference(item.timestamp).inSeconds > 5;

      if (isDegraded) {
        // Subtle red uncertainty halo
        final redHalo = Paint()
          ..color = AppTheme.alertRed.withValues(alpha: (0.2 + 0.25 * haloProgress).clamp(0.0, 1.0))
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(cx, cy), 22.0 + 8.0 * haloProgress, redHalo);

        final redBorder = Paint()
          ..color = AppTheme.alertRed.withValues(alpha: (0.4 + 0.3 * haloProgress).clamp(0.0, 1.0))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        canvas.drawCircle(Offset(cx, cy), 22.0 + 8.0 * haloProgress, redBorder);
      } else {
        // Standard subtle blue halo
        final blueHalo = Paint()
          ..color = AppTheme.nordicSlateLight.withValues(alpha: (0.15 + 0.15 * haloProgress).clamp(0.0, 1.0))
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(cx, cy), 20.0 + 6.0 * haloProgress, blueHalo);

        final blueBorder = Paint()
          ..color = AppTheme.nordicSlateLight.withValues(alpha: (0.35 + 0.25 * haloProgress).clamp(0.0, 1.0))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawCircle(Offset(cx, cy), 20.0 + 6.0 * haloProgress, blueBorder);
      }

      // Marker disk
      final markerPaint = Paint()..color = const Color(0xFF1E293B);
      canvas.drawCircle(Offset(cx, cy), 15.0, markerPaint);

      final markerBorder = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(Offset(cx, cy), 15.0, markerBorder);

      // Initial Letter Monogram
      final monogramPainter = TextPainter(
        text: TextSpan(
          text: item.name.isNotEmpty ? item.name[0].toUpperCase() : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      monogramPainter.paint(
        canvas,
        Offset(cx - monogramPainter.width / 2, cy - monogramPainter.height / 2),
      );

      // Member name label pill above marker
      final namePainter = TextPainter(
        text: TextSpan(
          text: item.name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final nameRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - 24),
          width: namePainter.width + 10,
          height: namePainter.height + 4,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(nameRect, Paint()..color = const Color(0xCC0F172A));
      namePainter.paint(canvas, Offset(cx - namePainter.width / 2, cy - 24 - namePainter.height / 2));

      // Speed telemetry badge (> 15 km/h)
      if (item.speedKmh > 15.0) {
        final speedStr = '${item.speedKmh.round()} km/h';
        final speedPainter = TextPainter(
          text: TextSpan(
            text: speedStr,
            style: const TextStyle(
              color: AppTheme.nordicSlateLight,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final badgeRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, cy + 24),
            width: speedPainter.width + 12,
            height: speedPainter.height + 5,
          ),
          const Radius.circular(6),
        );

        canvas.drawRRect(badgeRect, Paint()..color = const Color(0xDD0F172A));
        canvas.drawRRect(
          badgeRect,
          Paint()
            ..color = AppTheme.nordicSlateLight.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
        speedPainter.paint(canvas, Offset(cx - speedPainter.width / 2, cy + 24 - speedPainter.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DarkVectorStreetPainter oldDelegate) => true;
}
