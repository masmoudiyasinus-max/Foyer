import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

class UpdateInfo {
  final int versionCode;
  final String versionName;
  final int minRequiredVersionCode;
  final String apkUrl;
  final String releaseNotes;
  final bool isMandatory;

  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.minRequiredVersionCode,
    required this.apkUrl,
    required this.releaseNotes,
    required this.isMandatory,
  });
}

class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  static const int currentVersionCode = 8;
  static const String currentVersionName = '1.0.7';
  static const MethodChannel _channel = MethodChannel('com.foyer.intercom/audio');

  // Remote metadata URL endpoint
  static const String updateUrl =
      'https://raw.githubusercontent.com/masmoudiyasinus-max/Foyer/main/version.json';

  /// Vérifie la présence d'une mise à jour de façon 100% résiliente
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 4);
      final request = await client.getUrl(Uri.parse(updateUrl));
      final response = await request.close();

      if (response.statusCode == HttpStatus.ok) {
        final body = await response.transform(utf8.decoder).join();
        final dynamic decoded = jsonDecode(body);
        if (decoded is Map) {
          final data = Map<String, dynamic>.from(decoded);
          final remoteCode = (data['versionCode'] as num?)?.toInt() ?? currentVersionCode;
          final minRequired = (data['minRequiredVersionCode'] as num?)?.toInt() ?? currentVersionCode;
          final remoteName = data['versionName']?.toString() ?? '1.0.7';
          final apkUrl = data['apkUrl']?.toString() ?? '';
          final releaseNotes = data['releaseNotes']?.toString() ?? '';

          final isMandatory = currentVersionCode < minRequired;
          final hasUpdate = remoteCode > currentVersionCode || isMandatory;

          if (hasUpdate && apkUrl.isNotEmpty) {
            return UpdateInfo(
              versionCode: remoteCode,
              versionName: remoteName,
              minRequiredVersionCode: minRequired,
              apkUrl: apkUrl,
              releaseNotes: releaseNotes,
              isMandatory: isMandatory,
            );
          }
        }
      } else {
        developer.log('Update check server response: ${response.statusCode}', name: 'UpdateService');
      }
    } catch (e) {
      developer.log('Self-update check skipped (offline or unreachable): $e', name: 'UpdateService');
    }
    return null;
  }

  /// Vérification manuelle déclenchée par l'utilisateur (avec feedback SnackBar M3)
  Future<void> checkForUpdateManual(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final updateInfo = await checkForUpdate();
    if (!context.mounted) return;

    if (updateInfo != null) {
      showUpdateDialog(context, updateInfo);
    } else {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          content: Text(
            'Votre application est à jour (v$currentVersionName)',
            style: GoogleFonts.instrumentSans(),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Émission d'un flux de progression (0.0 à 1.0) pour le téléchargement de l'APK
  Stream<double> downloadApkProgress({
    required String apkUrl,
    required File targetFile,
  }) async* {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.getUrl(Uri.parse(apkUrl));
    final response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Téléchargement impossible (Code HTTP ${response.statusCode})');
    }

    final totalBytes = response.contentLength;
    int receivedBytes = 0;

    if (targetFile.existsSync()) {
      try {
        targetFile.deleteSync();
      } catch (_) {}
    }

    final sink = targetFile.openWrite();
    try {
      yield 0.0;
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          yield (receivedBytes / totalBytes).clamp(0.0, 1.0);
        } else {
          yield 0.5; // Débit indéterminé
        }
      }
      await sink.flush();
      yield 1.0;
    } finally {
      await sink.close();
    }
  }

  /// Déclenchement de l'intent d'installation natif via FileProvider
  Future<bool> triggerNativeInstall(String filePath, {BuildContext? context}) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
      if (success == false && context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Veuillez autoriser l\'installation des applications inconnues'),
          ),
        );
      }
      return success ?? false;
    } on PlatformException catch (e) {
      developer.log('Erreur plateforme installApk: $e', name: 'UpdateService');
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : ${e.message}')),
        );
      }
      return false;
    } catch (e) {
      developer.log('Erreur inattendue installApk: $e', name: 'UpdateService');
      return false;
    }
  }

  /// Télécharge et déclenche l'installation de l'APK avec jauge LinearProgressIndicator M3
  Future<void> downloadAndInstall({
    required String apkUrl,
    required BuildContext context,
    bool isMandatory = false,
  }) async {
    final tempDir = Directory.systemTemp;
    final apkFile = File('${tempDir.path}/foyer_update.apk');
    final progressController = StreamController<double>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => PopScope(
        canPop: false,
        child: AlertDialog(
          elevation: 0,
          backgroundColor: Theme.of(dialogCtx).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'Mise à jour',
            style: GoogleFonts.redRose(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.layer4Active,
            ),
          ),
          content: StreamBuilder<double>(
            stream: progressController.stream,
            initialData: 0.0,
            builder: (ctx, snapshot) {
              final progress = snapshot.data ?? 0.0;
              final percent = (progress * 100).toInt().clamp(0, 100);

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      minHeight: 6,
                      backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.nordicSlate),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        progress < 1.0 ? 'Téléchargement' : 'Installation',
                        style: GoogleFonts.instrumentSans(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      Text(
                        '$percent%',
                        style: GoogleFonts.instrumentSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.layer4Active,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    try {
      await for (final progress in downloadApkProgress(apkUrl: apkUrl, targetFile: apkFile)) {
        if (!progressController.isClosed) {
          progressController.add(progress);
        }
      }

      // Fermeture de la boîte de téléchargement une fois le fichier complet
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      // Déclenchement automatique de l'intent d'installation dès que le fichier est téléchargé à 100%
      await triggerNativeInstall(apkFile.path, context: context);
    } catch (e) {
      developer.log('Erreur de téléchargement: $e', name: 'UpdateService');
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.alertRed,
            content: Text(
              'Erreur lors du téléchargement',
              style: GoogleFonts.instrumentSans(color: Colors.white),
            ),
          ),
        );
      }
    } finally {
      await progressController.close();
    }
  }

  /// Dialogue M3 : non-fermable (barrierDismissible: false) si mise à jour obligatoire
  void showUpdateDialog(BuildContext context, UpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: !info.isMandatory,
      builder: (dialogCtx) => PopScope(
        canPop: !info.isMandatory,
        child: AlertDialog(
          elevation: 0,
          backgroundColor: Theme.of(dialogCtx).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: info.isMandatory
                ? const BorderSide(color: AppTheme.alertRed, width: 1.5)
                : BorderSide.none,
          ),
          icon: Icon(
            info.isMandatory ? Icons.system_update_alt_rounded : Icons.update_rounded,
            color: info.isMandatory ? AppTheme.alertRed : AppTheme.nordicSlate,
            size: 32,
          ),
          title: Text(
            info.isMandatory ? 'Mise à jour obligatoire' : 'Mise à jour disponible',
            style: GoogleFonts.redRose(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.layer4Active,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Version ${info.versionName}',
                style: GoogleFonts.instrumentSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.nordicSlateLight,
                ),
              ),
              if (info.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  info.releaseNotes,
                  style: GoogleFonts.instrumentSans(
                    fontSize: 13,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (!info.isMandatory)
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: Text(
                  'Plus tard',
                  style: GoogleFonts.instrumentSans(
                    color: AppTheme.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: info.isMandatory ? AppTheme.alertRed : AppTheme.nordicSlate,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                downloadAndInstall(
                  apkUrl: info.apkUrl,
                  context: context,
                  isMandatory: info.isMandatory,
                );
              },
              child: Text(
                'Mettre à jour',
                style: GoogleFonts.instrumentSans(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
