import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../models/task_item.dart';

class EcranTachesCourses extends StatefulWidget {
  const EcranTachesCourses({super.key});

  @override
  State<EcranTachesCourses> createState() => _EcranTachesCoursesState();
}

class _EcranTachesCoursesState extends State<EcranTachesCourses> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final StorageService _storage = StorageService();

  List<TaskItem> _tasks = [];
  List<TaskItem> _groceries = [];
  StreamSubscription? _tasksSubscription;
  StreamSubscription? _groceriesSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadItems();
    _syncFirebaseItems();

    // Trigger midnight purge evaluator
    _storage.evaluateMidnightPurge();

    // Listen for purge events to remove from Firebase as well
    _storage.onTasksPurged = (purgedIds) {
      final familyCode = _storage.familyCode;
      if (familyCode.isNotEmpty) {
        for (final id in purgedIds) {
          FirebaseDatabase.instance.ref('foyers/$familyCode/tasks/$id').remove();
        }
      }
      _loadItems();
    };
  }

  @override
  void dispose() {
    _tasksSubscription?.cancel();
    _groceriesSubscription?.cancel();
    _storage.onTasksPurged = null;
    _tabController.dispose();
    super.dispose();
  }

  void _loadItems() {
    setState(() {
      _tasks = _storage.getTasks();
      _groceries = _storage.getGroceries();
    });
  }

  void _syncFirebaseItems() {
    final familyCode = _storage.familyCode;
    if (familyCode.isEmpty) return;

    try {
      // Sync tasks
      _tasksSubscription?.cancel();
      _tasksSubscription = FirebaseDatabase.instance.ref('foyers/$familyCode/tasks').onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          final List<TaskItem> list = [];
          data.forEach((k, v) {
            if (v is Map) {
              list.add(TaskItem.fromMap(v));
            }
          });
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          if (mounted) {
            setState(() => _tasks = list);
            for (final t in list) {
              _storage.saveTask(t);
            }
          }
        }
      });

      // Sync groceries
      _groceriesSubscription?.cancel();
      _groceriesSubscription = FirebaseDatabase.instance.ref('foyers/$familyCode/groceries').onValue.listen((event) {
        final data = event.snapshot.value;
        if (data is Map) {
          final List<TaskItem> list = [];
          data.forEach((k, v) {
            if (v is Map) {
              list.add(TaskItem.fromMap(v));
            }
          });
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          if (mounted) {
            setState(() => _groceries = list);
            for (final g in list) {
              _storage.saveGrocery(g);
            }
          }
        }
      });
    } catch (e) {
      debugPrint('Erreur sync Firebase items: $e');
    }
  }

  Future<void> _toggleTask(TaskItem task) async {
    final updatedIsDone = !task.isDone;
    final updated = task.copyWith(
      isDone: updatedIsDone,
      completedAt: updatedIsDone ? DateTime.now() : null,
    );

    await _storage.saveTask(updated);

    final familyCode = _storage.familyCode;
    if (familyCode.isNotEmpty) {
      try {
        await FirebaseDatabase.instance
            .ref('foyers/$familyCode/tasks/${task.id}')
            .set(updated.toMap());
      } catch (e) {
        debugPrint('Erreur toggle task: $e');
      }
    }

    _loadItems();
  }

  Future<void> _deleteTask(String id) async {
    await _storage.deleteTask(id);
    final familyCode = _storage.familyCode;
    if (familyCode.isNotEmpty) {
      FirebaseDatabase.instance.ref('foyers/$familyCode/tasks/$id').remove();
    }
    _loadItems();
  }

  Future<void> _toggleGrocery(TaskItem item) async {
    final updatedIsDone = !item.isDone;
    final updated = item.copyWith(
      isDone: updatedIsDone,
      completedAt: updatedIsDone ? DateTime.now() : null,
    );

    await _storage.saveGrocery(updated);

    final familyCode = _storage.familyCode;
    if (familyCode.isNotEmpty) {
      try {
        await FirebaseDatabase.instance
            .ref('foyers/$familyCode/groceries/${item.id}')
            .set(updated.toMap());
      } catch (e) {
        debugPrint('Erreur toggle grocery: $e');
      }
    }

    _loadItems();
  }

  Future<void> _deleteGrocery(String id) async {
    await _storage.deleteGrocery(id);
    final familyCode = _storage.familyCode;
    if (familyCode.isNotEmpty) {
      FirebaseDatabase.instance.ref('foyers/$familyCode/groceries/$id').remove();
    }
    _loadItems();
  }

  void _showAddItemDialog({required bool isGrocery}) {
    final textController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
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
              isGrocery ? 'Nouvel article de courses' : 'Nouvelle tâche familiale',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: textController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: isGrocery ? 'Nom de l\'article' : 'Description de la tâche',
                hintText: isGrocery ? 'Ex: Lait, Pain' : 'Ex: Nettoyer le garage',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                final text = textController.text.trim();
                if (text.isEmpty) return;

                final item = TaskItem(
                  id: '${isGrocery ? 'groc' : 'task'}_${DateTime.now().millisecondsSinceEpoch}',
                  title: text,
                  isGrocery: isGrocery,
                  createdBy: _storage.memberName,
                  createdAt: DateTime.now(),
                );

                if (isGrocery) {
                  await _storage.saveGrocery(item);
                } else {
                  await _storage.saveTask(item);
                }

                final familyCode = _storage.familyCode;
                if (familyCode.isNotEmpty) {
                  try {
                    final path = isGrocery ? 'groceries' : 'tasks';
                    await FirebaseDatabase.instance
                        .ref('foyers/$familyCode/$path/${item.id}')
                        .set(item.toMap());
                  } catch (e) {
                    debugPrint('Erreur add item Firebase: $e');
                  }
                }

                if (mounted) {
                  _loadItems();
                  Navigator.pop(ctx);
                }
              },
              child: const Text(
                'Ajouter',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
          'ORGANISATION',
          style: GoogleFonts.redRose(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: AppTheme.layer4Active,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Tâches en cours'),
            Tab(text: 'Liste des courses'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.layer4Active,
        foregroundColor: AppTheme.layer1Surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () => _showAddItemDialog(isGrocery: _tabController.index == 1),
        child: const Icon(Icons.add, size: 24),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildTaskList(),
          _buildGroceryList(),
        ],
      ),
    );
  }

  Widget _buildTaskList() {
    if (_tasks.isEmpty) {
      return Center(
        child: Text(
          'Aucune tâche en cours',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppTheme.textMuted,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _tasks.length,
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: task.isDone,
                onChanged: (_) => _toggleTask(task),
              ),
            ),
            title: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.instrumentSans(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: task.isDone ? AppTheme.textMuted : AppTheme.layer4Active,
                decoration: task.isDone ? TextDecoration.lineThrough : null,
              ),
            ),
            subtitle: task.createdBy != null
                ? Text(
                    'Par ${task.createdBy}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  )
                : null,
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 16, color: AppTheme.textMuted),
              onPressed: () => _deleteTask(task.id),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGroceryList() {
    if (_groceries.isEmpty) {
      return Center(
        child: Text(
          'Liste des courses vide',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppTheme.textMuted,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _groceries.length,
      itemBuilder: (context, index) {
        final item = _groceries[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: item.isDone,
                onChanged: (_) => _toggleGrocery(item),
              ),
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.instrumentSans(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: item.isDone ? AppTheme.textMuted : AppTheme.layer4Active,
                decoration: item.isDone ? TextDecoration.lineThrough : null,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 16, color: AppTheme.textMuted),
              onPressed: () => _deleteGrocery(item.id),
            ),
          ),
        );
      },
    );
  }
}
