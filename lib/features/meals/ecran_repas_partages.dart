import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/discovery_service.dart';
import '../../models/meal_item.dart';

class EcranRepasPartages extends StatefulWidget {
  const EcranRepasPartages({super.key});

  @override
  State<EcranRepasPartages> createState() => _EcranRepasPartagesState();
}

class _EcranRepasPartagesState extends State<EcranRepasPartages> {
  final StorageService _storage = StorageService();
  final DiscoveryService _discovery = DiscoveryService();

  List<MealItem> _meals = [];
  final Set<String> _diningMemberIds = {};

  @override
  void initState() {
    super.initState();
    _diningMemberIds.add(_storage.deviceId);
    _loadMeals();
    _storage.startMealsSync(() {
      if (mounted) _loadMeals();
    });
  }

  void _loadMeals() {
    setState(() {
      _meals = _storage.getMeals()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
  }

  void _addDish() {
    final dishCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.layer1Surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.layer3Border),
        ),
        title: Text(
          'Proposer un plat',
          style: GoogleFonts.redRose(color: AppTheme.layer4Active, fontSize: 18),
        ),
        content: TextField(
          controller: dishCtrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.layer4Active),
          decoration: const InputDecoration(
            hintText: 'Ex: Tarte aux pommes',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.nordicSlate),
            onPressed: () async {
              final val = dishCtrl.text.trim();
              if (val.isNotEmpty) {
                final newMeal = MealItem(
                  id: 'meal_${DateTime.now().millisecondsSinceEpoch}',
                  title: val,
                  authorId: _storage.deviceId,
                  authorName: _storage.memberName.isNotEmpty ? _storage.memberName : 'Membre',
                  isPrepared: false,
                  createdAt: DateTime.now(),
                );
                await _storage.saveMeal(newMeal);
                _loadMeals();
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
    final members = _discovery.membersNotifier.value;

    return Scaffold(
      backgroundColor: AppTheme.layer1Surface,
      appBar: AppBar(
        title: Text(
          'REPAS DU FOYER',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.nordicSlate,
        foregroundColor: Colors.white,
        onPressed: _addDish,
        child: const Icon(Icons.restaurant),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: [
            // Dining Status Section
            Text(
              'Présence au dîner',
              style: GoogleFonts.redRose(fontSize: 16, color: AppTheme.layer4Active),
            ),
            const SizedBox(height: 12),
            Card(
              color: AppTheme.layer2Container,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.layer3Border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: members.map((m) {
                    final isDining = _diningMemberIds.contains(m.id);
                    return FilterChip(
                      selected: isDining,
                      selectedColor: AppTheme.nordicSlate.withValues(alpha: 0.25),
                      checkmarkColor: AppTheme.nordicSlateLight,
                      label: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      labelStyle: TextStyle(
                        color: isDining ? AppTheme.nordicSlateLight : AppTheme.textMuted,
                        fontWeight: isDining ? FontWeight.bold : FontWeight.normal,
                      ),
                      onSelected: (val) {
                        setState(() {
                          if (val) {
                            _diningMemberIds.add(m.id);
                          } else {
                            _diningMemberIds.remove(m.id);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Dishes Contribution Section
            Text(
              'Tableau des Plats Partagés',
              style: GoogleFonts.redRose(fontSize: 16, color: AppTheme.layer4Active),
            ),
            const SizedBox(height: 12),
            if (_meals.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'Aucun plat proposé pour ce soir',
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
              )
            else
              ..._meals.map((meal) {
                final myVote = meal.votes[_storage.deviceId];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: AppTheme.layer2Container,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppTheme.layer3Border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                          leading: Checkbox(
                            value: meal.isPrepared,
                            activeColor: AppTheme.nordicSlate,
                            onChanged: (_) async {
                              await _storage.toggleMealPrepared(meal.id);
                              _loadMeals();
                            },
                          ),
                          title: Text(
                            meal.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: meal.isPrepared ? AppTheme.textMuted : AppTheme.layer4Active,
                              decoration: meal.isPrepared ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w500,
                              fontSize: 15,
                            ),
                          ),
                          subtitle: Text(
                            'Proposé par ${meal.authorName}',
                            style: GoogleFonts.instrumentSans(fontSize: 12, color: AppTheme.textMuted),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textMuted),
                            onPressed: () async {
                              await _storage.deleteMeal(meal.id);
                              _loadMeals();
                            },
                          ),
                        ),
                        // Live Voting Row
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 4),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                avatar: Icon(
                                  Icons.thumb_up_alt_outlined,
                                  size: 14,
                                  color: myVote == 'like' ? AppTheme.nordicSlateLight : AppTheme.textMuted,
                                ),
                                label: Text(
                                  'J\'aime (${meal.likesCount})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: myVote == 'like' ? AppTheme.nordicSlateLight : AppTheme.textMuted,
                                    fontWeight: myVote == 'like' ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                selected: myVote == 'like',
                                selectedColor: AppTheme.nordicSlate.withValues(alpha: 0.25),
                                side: BorderSide(
                                  color: myVote == 'like' ? AppTheme.nordicSlate : AppTheme.layer3Border,
                                ),
                                onSelected: (_) async {
                                  await _storage.voteMeal(meal.id, _storage.deviceId, 'like');
                                  _loadMeals();
                                },
                              ),
                              ChoiceChip(
                                avatar: Icon(
                                  Icons.thumb_down_alt_outlined,
                                  size: 14,
                                  color: myVote == 'dislike' ? AppTheme.alertRed : AppTheme.textMuted,
                                ),
                                label: Text(
                                  'Pas ce soir (${meal.dislikesCount})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: myVote == 'dislike' ? AppTheme.alertRed : AppTheme.textMuted,
                                    fontWeight: myVote == 'dislike' ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                selected: myVote == 'dislike',
                                selectedColor: AppTheme.alertRed.withValues(alpha: 0.2),
                                side: BorderSide(
                                  color: myVote == 'dislike' ? AppTheme.alertRed : AppTheme.layer3Border,
                                ),
                                onSelected: (_) async {
                                  await _storage.voteMeal(meal.id, _storage.deviceId, 'dislike');
                                  _loadMeals();
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
