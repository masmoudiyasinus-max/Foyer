import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';

enum AmbientWeatherState {
  rainDay,
  rainNight,
  clearNight,
  clearDay,
  overcast,
  dusk,
  twilight,
  dawn,
  storm,
}

class AmbientHeaderCard extends StatefulWidget {
  final AmbientWeatherState? forcedState;
  const AmbientHeaderCard({super.key, this.forcedState});

  @override
  State<AmbientHeaderCard> createState() => _AmbientHeaderCardState();
}

class _AmbientHeaderCardState extends State<AmbientHeaderCard> with SingleTickerProviderStateMixin {
  late AmbientWeatherState _currentState;
  late AnimationController _rainController;
  Timer? _weatherPollTimer;

  bool _showFirst = true;
  AmbientWeatherState? _firstState;
  AmbientWeatherState? _secondState;

  @override
  void initState() {
    super.initState();
    _currentState = widget.forcedState ?? AmbientWeatherState.clearDay;
    _firstState = _currentState;
    _secondState = _currentState;

    _rainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    if (widget.forcedState == null) {
      _fetchOpenMeteoWeather();
      // Poll weather every 30 minutes
      _weatherPollTimer = Timer.periodic(const Duration(minutes: 30), (_) {
        _fetchOpenMeteoWeather();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AmbientHeaderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.forcedState != null && widget.forcedState != _currentState) {
      _transitionToState(widget.forcedState!);
    }
  }

  @override
  void dispose() {
    _weatherPollTimer?.cancel();
    _rainController.dispose();
    super.dispose();
  }

  Future<void> _fetchOpenMeteoWeather() async {
    try {
      double lat = 36.8065;
      double lon = 10.1815;

      // Try fast network IP geo-detection, fallback to Tunisia default
      try {
        final geoClient = HttpClient()..connectionTimeout = const Duration(milliseconds: 1500);
        final geoReq = await geoClient.getUrl(Uri.parse('https://ipapi.co/json/'));
        final geoResp = await geoReq.close();
        if (geoResp.statusCode == 200) {
          final geoBody = await geoResp.transform(utf8.decoder).join();
          final geoData = jsonDecode(geoBody);
          if (geoData is Map && geoData['latitude'] is num && geoData['longitude'] is num) {
            lat = (geoData['latitude'] as num).toDouble();
            lon = (geoData['longitude'] as num).toDouble();
          }
        }
      } catch (_) {
        // Fallback default: Tunisia (lat: 36.8065, lon: 10.1815)
      }

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=weather_code,is_day',
      );
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> data = jsonDecode(body);
        final current = data['current'];
        if (current is Map) {
          final int weatherCode = (current['weather_code'] as num?)?.toInt() ?? 0;
          final int isDay = (current['is_day'] as num?)?.toInt() ?? 1;
          final newState = _wmoToAmbientState(weatherCode, isDay);
          if (mounted && widget.forcedState == null) {
            _transitionToState(newState);
          }
        }
      }
    } catch (_) {}
  }

  AmbientWeatherState _wmoToAmbientState(int weatherCode, int isDay) {
    // 51..67, 80..82: Pluie réelle
    if ((weatherCode >= 51 && weatherCode <= 67) || (weatherCode >= 80 && weatherCode <= 82)) {
      return isDay == 1 ? AmbientWeatherState.rainDay : AmbientWeatherState.rainNight;
    }
    // 95..99: Orageux
    if (weatherCode >= 95 && weatherCode <= 99) {
      return isDay == 1 ? AmbientWeatherState.storm : AmbientWeatherState.rainNight;
    }
    // 2, 3: Ciel voilé / Couvert
    if (weatherCode == 2 || weatherCode == 3) {
      return isDay == 1 ? AmbientWeatherState.overcast : AmbientWeatherState.dusk;
    }
    // 0, 1: Ciel dégagé
    return isDay == 1 ? AmbientWeatherState.clearDay : AmbientWeatherState.clearNight;
  }

  void _transitionToState(AmbientWeatherState newState) {
    if (!mounted || newState == _currentState) return;
    setState(() {
      if (_showFirst) {
        _secondState = newState;
        _showFirst = false;
      } else {
        _firstState = newState;
        _showFirst = true;
      }
      _currentState = newState;
    });
  }

  Color _getBackgroundColor(AmbientWeatherState state) {
    switch (state) {
      case AmbientWeatherState.rainDay:
        return const Color(0xFF1E242B);
      case AmbientWeatherState.rainNight:
      case AmbientWeatherState.storm:
        return const Color(0xFF0F1115);
      case AmbientWeatherState.clearNight:
        return const Color(0xFF08090C);
      case AmbientWeatherState.clearDay:
        return const Color(0xFF172554);
      case AmbientWeatherState.overcast:
      case AmbientWeatherState.dusk:
      case AmbientWeatherState.twilight:
      case AmbientWeatherState.dawn:
        return const Color(0xFF2A1810);
    }
  }

  String _getContextualLabel(AmbientWeatherState state) {
    switch (state) {
      case AmbientWeatherState.rainDay:
      case AmbientWeatherState.rainNight:
      case AmbientWeatherState.storm:
        return 'Ciel pluvieux';
      case AmbientWeatherState.clearNight:
        return 'Nuit étoilée';
      case AmbientWeatherState.clearDay:
        return 'Ciel dégagé';
      case AmbientWeatherState.overcast:
      case AmbientWeatherState.dusk:
      case AmbientWeatherState.twilight:
        return 'Temps couvert';
      case AmbientWeatherState.dawn:
        return 'Aube sereine';
    }
  }

  IconData _getContextualIcon(AmbientWeatherState state) {
    switch (state) {
      case AmbientWeatherState.rainDay:
      case AmbientWeatherState.rainNight:
        return Icons.water_drop_outlined;
      case AmbientWeatherState.storm:
        return Icons.thunderstorm_outlined;
      case AmbientWeatherState.clearNight:
        return Icons.nights_stay_outlined;
      case AmbientWeatherState.clearDay:
        return Icons.wb_sunny_outlined;
      case AmbientWeatherState.overcast:
        return Icons.cloud_outlined;
      case AmbientWeatherState.dusk:
      case AmbientWeatherState.twilight:
      case AmbientWeatherState.dawn:
        return Icons.wb_twilight_outlined;
    }
  }

  Widget _buildStateContent(AmbientWeatherState state) {
    final label = _getContextualLabel(state);
    final icon = _getContextualIcon(state);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: AppTheme.layer4Active),
        const SizedBox(width: 8),
        Text(
          label,
          style: GoogleFonts.redRose(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppTheme.layer4Active,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _getBackgroundColor(_currentState);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOutCubic,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      height: 60,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.layer3Border, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Stack(
          children: [
            // Lightweight Canvas Background
            if (_currentState == AmbientWeatherState.rainDay)
              AnimatedBuilder(
                animation: _rainController,
                builder: (context, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _RainCanvasPainter(progress: _rainController.value, isNight: false),
                ),
              )
            else if (_currentState == AmbientWeatherState.rainNight || _currentState == AmbientWeatherState.storm)
              AnimatedBuilder(
                animation: _rainController,
                builder: (context, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _RainCanvasPainter(progress: _rainController.value, isNight: true),
                ),
              )
            else if (_currentState == AmbientWeatherState.clearNight)
              const CustomPaint(
                size: Size.infinite,
                painter: _StarfieldCanvasPainter(),
              )
            else if (_currentState == AmbientWeatherState.overcast ||
                _currentState == AmbientWeatherState.dusk ||
                _currentState == AmbientWeatherState.twilight ||
                _currentState == AmbientWeatherState.dawn)
              const CustomPaint(
                size: Size.infinite,
                painter: _HorizonCanvasPainter(),
              ),

            // Foreground Text & Ambient Icon with smoothly switching AnimatedCrossFade
            Center(
              child: AnimatedCrossFade(
                duration: const Duration(milliseconds: 800),
                firstCurve: Curves.easeInOutCubic,
                secondCurve: Curves.easeInOutCubic,
                sizeCurve: Curves.easeInOutCubic,
                crossFadeState: _showFirst ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                firstChild: _buildStateContent(_firstState ?? _currentState),
                secondChild: _buildStateContent(_secondState ?? _currentState),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lightweight rain particle painter
class _RainCanvasPainter extends CustomPainter {
  final double progress;
  final bool isNight;
  _RainCanvasPainter({required this.progress, this.isNight = false});

  static final List<Offset> _fixedRainPositions = List.generate(
    18,
    (i) => Offset((i * 21.0) % 360, (i * 17.0) % 60),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isNight
          ? Colors.white.withValues(alpha: 0.38)
          : Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    for (final pos in _fixedRainPositions) {
      final double x = (pos.dx) % size.width;
      final double y = (pos.dy + progress * 60) % size.height;
      canvas.drawLine(Offset(x, y), Offset(x, y + 6), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RainCanvasPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.isNight != isNight;
}

/// Static micro-stars painter without orbital calculations
class _StarfieldCanvasPainter extends CustomPainter {
  const _StarfieldCanvasPainter();

  static final List<Offset> _fixedStars = List.generate(
    16,
    (i) => Offset(
      ((i * 29.0) % 360) / 360.0,
      ((i * 13.0) % 60) / 60.0,
    ),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.45);
    for (int i = 0; i < _fixedStars.length; i++) {
      final star = _fixedStars[i];
      final double x = star.dx * size.width;
      final double y = star.dy * size.height;
      final double radius = (i % 3 == 0) ? 1.2 : 0.8;
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Sienna horizon painter for twilight / dawn / overcast
class _HorizonCanvasPainter extends CustomPainter {
  const _HorizonCanvasPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD97706).withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(0, size.height - 2),
      Offset(size.width, size.height - 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
