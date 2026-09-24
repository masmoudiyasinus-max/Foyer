import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/services/foyer_manager_service.dart';
import '../../../models/foyer_context.dart';

/// Discreet Google Account-style active foyer pill for the AppBar
class FoyerSelectorAppBarTitle extends StatelessWidget {
  const FoyerSelectorAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final foyerManager = FoyerManagerService();

    return ValueListenableBuilder<FoyerContext>(
      valueListenable: foyerManager.activeFoyerNotifier,
      builder: (context, activeFoyer, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showFoyerSelectorModal(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.home_outlined,
                  size: 16,
                  color: AppTheme.nordicSlateLight,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    activeFoyer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.redRose(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.layer4Active,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: AppTheme.nordicSlateLight,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// M3 Modal Bottom Sheet listing all registered foyers with radio indicator & flat add action
void showFoyerSelectorModal(BuildContext context) {
  final foyerManager = FoyerManagerService();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppTheme.layer1Surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      side: BorderSide(color: AppTheme.layer3Border, width: 1),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final foyers = foyerManager.getFoyers();
          final current = foyerManager.getCurrentFoyer();

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'RÉSIDENCES & FOYERS',
                        style: GoogleFonts.redRose(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.layer4Active,
                          letterSpacing: 1.0,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20, color: AppTheme.textMuted),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Foyers list with radio indicator
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: foyers.map((f) {
                          final isCurrent = f.id == current.id;
                          return Card(
                            elevation: 0,
                            margin: const EdgeInsets.only(bottom: 8),
                            color: isCurrent
                                ? Theme.of(sheetCtx).colorScheme.surfaceContainer
                                : Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: isCurrent ? AppTheme.nordicSlate : AppTheme.layer3Border,
                                width: 1,
                              ),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                              leading: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isCurrent ? AppTheme.nordicSlateLight : AppTheme.textMuted,
                                    width: 2,
                                  ),
                                ),
                                child: isCurrent
                                    ? Center(
                                        child: Container(
                                          width: 12,
                                          height: 12,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: AppTheme.nordicSlateLight,
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                              title: Text(
                                f.name,
                                style: GoogleFonts.redRose(
                                  fontSize: 15,
                                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                  color: AppTheme.layer4Active,
                                ),
                              ),
                              subtitle: Text(
                                f.wifiBssids.isNotEmpty
                                    ? 'Wi-Fi associé : ${f.wifiBssids.first}'
                                    : 'Aucun routeur associé',
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 11,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  Icons.wifi,
                                  size: 20,
                                  color: f.wifiBssids.isNotEmpty
                                      ? AppTheme.nordicSlateLight
                                      : AppTheme.textMuted,
                                ),
                                tooltip: 'Associer au Wi-Fi actuel',
                                onPressed: () async {
                                  final success = await foyerManager.associateCurrentWifiWithFoyer(f.id);
                                  setSheetState(() {});
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          success
                                              ? 'Wi-Fi associé au foyer ${f.name}'
                                              : 'Impossible d\'obtenir le BSSID Wi-Fi',
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                              onTap: () async {
                                if (!isCurrent) {
                                  await foyerManager.switchFoyer(f.id);
                                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                                }
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Flat Action Button: + Ajouter / Rejoindre un foyer
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.layer4Active,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: const BorderSide(color: AppTheme.layer3Border),
                      ),
                      icon: const Icon(Icons.add_home_outlined, size: 20),
                      label: const Text(
                        '+ Ajouter / Rejoindre un foyer',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        showAddOrJoinFoyerDialog(context);
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Dialog to add or join a new foyer with optional automatic Wi-Fi BSSID association
void showAddOrJoinFoyerDialog(BuildContext context) {
  final foyerManager = FoyerManagerService();
  final nameCtrl = TextEditingController();
  final codeCtrl = TextEditingController();
  bool associateCurrentWifi = true;
  String? currentBssid;

  foyerManager.getCurrentWifiBssid().then((b) {
    currentBssid = b;
  });

  showDialog(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: AppTheme.layer1Surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.layer3Border),
        ),
        title: Text(
          'Ajouter ou rejoindre un foyer',
          style: GoogleFonts.redRose(
            color: AppTheme.layer4Active,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: nameCtrl,
              style: const TextStyle(color: AppTheme.layer4Active),
              decoration: const InputDecoration(
                labelText: 'Nom du foyer (ex: Maison de Campagne)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: AppTheme.layer4Active),
              decoration: const InputDecoration(
                labelText: 'Code Foyer partagé (ex: FOYER-CAMPAGNE)',
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Checkbox(
                  value: associateCurrentWifi,
                  activeColor: AppTheme.nordicSlateLight,
                  onChanged: (val) {
                    setDialogState(() {
                      associateCurrentWifi = val ?? true;
                    });
                  },
                ),
                Expanded(
                  child: Text(
                    currentBssid != null && currentBssid!.isNotEmpty && currentBssid != '02:00:00:00:00:00'
                        ? 'Associer au Wi-Fi actuel ($currentBssid)'
                        : 'Associer automatiquement au Wi-Fi actuel',
                    style: GoogleFonts.instrumentSans(fontSize: 12, color: AppTheme.textMuted),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.nordicSlate),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final code = codeCtrl.text.trim().toUpperCase();
              if (name.isNotEmpty && code.isNotEmpty) {
                final List<String> bssids = [];
                if (associateCurrentWifi) {
                  final bssid = await foyerManager.getCurrentWifiBssid();
                  if (bssid != null && bssid.isNotEmpty && bssid != '02:00:00:00:00:00') {
                    bssids.add(bssid);
                  }
                }
                await foyerManager.addFoyer(
                  name: name,
                  familyCode: code,
                  wifiBssids: bssids,
                  switchToNew: true,
                );
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('Rejoindre & Activer'),
          ),
        ],
      ),
    ),
  );
}
