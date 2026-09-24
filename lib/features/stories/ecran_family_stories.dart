import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/storage_service.dart';
import '../../models/family_story.dart';

class EcranFamilyStories extends StatefulWidget {
  final String? initialImagePath;
  final FamilyStory? storyToView;
  final List<FamilyStory>? storiesToView;
  final int initialStoryIndex;

  const EcranFamilyStories({
    super.key,
    this.initialImagePath,
    this.storyToView,
    this.storiesToView,
    this.initialStoryIndex = 0,
  });

  @override
  State<EcranFamilyStories> createState() => _EcranFamilyStoriesState();
}

class _EcranFamilyStoriesState extends State<EcranFamilyStories>
    with SingleTickerProviderStateMixin {
  final StorageService _storage = StorageService();

  // --- Editor State ---
  String? _selectedImagePath;
  final List<StoryTextBlock> _textBlocks = [];
  final TextEditingController _textInputCtrl = TextEditingController();

  int? _activeBlockIndex;
  double _baseScale = 1.0;
  double _baseRotation = 0.0;
  bool _isPublishing = false;

  // --- Viewer State ---
  bool _isViewingMode = false;
  late List<FamilyStory> _viewingStories;
  int _currentStoryIndex = 0;
  AnimationController? _storyTimerController;

  @override
  void initState() {
    super.initState();
    _selectedImagePath = widget.initialImagePath;

    if (widget.storiesToView != null && widget.storiesToView!.isNotEmpty) {
      _isViewingMode = true;
      _viewingStories = List.from(widget.storiesToView!);
      _currentStoryIndex = widget.initialStoryIndex.clamp(0, _viewingStories.length - 1);
    } else if (widget.storyToView != null) {
      _isViewingMode = true;
      _viewingStories = [widget.storyToView!];
      _currentStoryIndex = 0;
    } else {
      _isViewingMode = false;
      _viewingStories = [];
    }

    if (_isViewingMode) {
      _initStoryTimer();
    }
  }

  void _initStoryTimer() {
    _storyTimerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );

    _storyTimerController!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _goToNextStory();
      }
    });

    _storyTimerController!.forward();
  }

  void _goToNextStory() {
    if (!mounted) return;
    if (_currentStoryIndex < _viewingStories.length - 1) {
      setState(() {
        _currentStoryIndex++;
      });
      _storyTimerController?.reset();
      _storyTimerController?.forward();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _goToPreviousStory() {
    if (!mounted) return;
    if (_currentStoryIndex > 0) {
      setState(() {
        _currentStoryIndex--;
      });
      _storyTimerController?.reset();
      _storyTimerController?.forward();
    } else {
      _storyTimerController?.reset();
      _storyTimerController?.forward();
    }
  }

  @override
  void dispose() {
    _textInputCtrl.dispose();
    _storyTimerController?.dispose();
    super.dispose();
  }

  // --- Editor Actions ---

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedImagePath = result.files.single.path;
      });
    }
  }

  void _addTextBlock() {
    _textInputCtrl.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.layer1Surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.layer3Border),
        ),
        title: const Text('Ajouter un texte libre', style: TextStyle(color: AppTheme.layer4Active)),
        content: TextField(
          controller: _textInputCtrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.layer4Active),
          decoration: const InputDecoration(hintText: 'Votre message...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3B82F6)),
            onPressed: () {
              final val = _textInputCtrl.text.trim();
              if (val.isNotEmpty) {
                setState(() {
                  _textBlocks.add(
                    StoryTextBlock(
                      text: val,
                      position: const Offset(100, 250),
                      scale: 1.0,
                      rotation: 0.0,
                    ),
                  );
                  _activeBlockIndex = _textBlocks.length - 1;
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Poser'),
          ),
        ],
      ),
    );
  }

  void _editTextBlock(int index) {
    _textInputCtrl.text = _textBlocks[index].text;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.layer1Surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.layer3Border),
        ),
        title: const Text('Modifier le texte', style: TextStyle(color: AppTheme.layer4Active)),
        content: TextField(
          controller: _textInputCtrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.layer4Active),
          decoration: const InputDecoration(hintText: 'Votre message...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3B82F6)),
            onPressed: () {
              final val = _textInputCtrl.text.trim();
              if (val.isNotEmpty && index < _textBlocks.length) {
                setState(() {
                  _textBlocks[index].text = val;
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Valider'),
          ),
        ],
      ),
    );
  }

  Future<void> _publishStory() async {
    if (_isPublishing) return;
    if (_selectedImagePath == null && _textBlocks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Veuillez ajouter une photo ou un texte')),
      );
      return;
    }

    setState(() => _isPublishing = true);

    try {
      final now = DateTime.now();
      final story = FamilyStory(
        id: 'story_${now.millisecondsSinceEpoch}',
        authorId: _storage.deviceId.isNotEmpty ? _storage.deviceId : 'device_local',
        authorName: _storage.memberName.isNotEmpty ? _storage.memberName : 'Foyer',
        imagePath: _selectedImagePath,
        textBlocks: List.from(_textBlocks),
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 24)), // Strictement fixé à DateTime.now() + 24 heures
      );

      await _storage.saveStory(story);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Story partagée au foyer (active 24h)')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur de publication : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPublishing = false);
    }
  }

  // --- Author Deletion ---

  Future<void> _confirmDeleteStory(FamilyStory story) async {
    _storyTimerController?.stop();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.layer1Surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.layer3Border),
        ),
        title: const Text('Supprimer la story ?', style: TextStyle(color: AppTheme.layer4Active)),
        content: const Text(
          'Cette story sera définitivement retirée pour tous les membres du foyer.',
          style: TextStyle(color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.alertRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _storage.deleteStory(story.id);
      if (mounted) {
        setState(() {
          _viewingStories.removeWhere((s) => s.id == story.id);
          if (_currentStoryIndex >= _viewingStories.length) {
            _currentStoryIndex = _viewingStories.length - 1;
          }
        });
        if (_viewingStories.isEmpty) {
          Navigator.pop(context, true);
        } else {
          _storyTimerController?.reset();
          _storyTimerController?.forward();
        }
      }
    } else {
      _storyTimerController?.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isViewingMode && _viewingStories.isNotEmpty) {
      return _buildViewerScreen();
    }

    return _buildEditorScreen();
  }

  // --- Visual Editor Screen ---

  Widget _buildEditorScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'STORY DU FOYER',
          style: GoogleFonts.redRose(fontSize: 18, color: AppTheme.layer4Active),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.title, color: AppTheme.layer4Active),
            onPressed: _addTextBlock,
            tooltip: 'Ajouter du texte',
          ),
          IconButton(
            icon: const Icon(Icons.add_photo_alternate_outlined, color: AppTheme.layer4Active),
            onPressed: _pickImage,
            tooltip: 'Choisir photo',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Background Canvas / Image with tap to deselect
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() => _activeBlockIndex = null);
              },
              child: _selectedImagePath != null && File(_selectedImagePath!).existsSync()
                  ? Image.file(
                      File(_selectedImagePath!),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    )
                  : Container(
                      color: AppTheme.layer1Surface,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              iconSize: 64,
                              icon: const Icon(Icons.add_a_photo_outlined, color: AppTheme.nordicSlateLight),
                              onPressed: _pickImage,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Sélectionnez une photo pour votre story',
                              style: GoogleFonts.instrumentSans(fontSize: 14, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),

          // Multi-Touch Tactile Draggable, Scalable & Rotatable Text Blocks
          for (int i = 0; i < _textBlocks.length; i++)
            _buildTactileTextBlock(i, _textBlocks[i]),

          // Clear M3 Action Button at Bottom: "Partager au Foyer"
          Positioned(
            bottom: 24,
            left: 20,
            right: 20,
            child: SafeArea(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6), // Bleu Ardoise Nordique
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 6,
                ),
                onPressed: _isPublishing ? null : _publishStory,
                icon: _isPublishing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 20),
                label: Text(
                  'Partager au Foyer',
                  style: GoogleFonts.instrumentSans(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTactileTextBlock(int index, StoryTextBlock block) {
    final bool isSelected = _activeBlockIndex == index;

    return Positioned(
      left: block.position.dx,
      top: block.position.dy,
      child: GestureDetector(
        onScaleStart: (details) {
          setState(() {
            _activeBlockIndex = index;
            _baseScale = block.scale;
            _baseRotation = block.rotation;
          });
        },
        onScaleUpdate: (details) {
          if (_activeBlockIndex == index) {
            setState(() {
              // 1. Fluid finger movement (translation X/Y)
              block.position += details.focalPointDelta;
              // 2. Pinch-to-zoom scale (clamped between 0.5x and 4.0x)
              block.scale = (_baseScale * details.scale).clamp(0.5, 4.0);
              // 3. Free rotation angle
              block.rotation = _baseRotation + details.rotation;
            });
          }
        },
        onTap: () {
          setState(() => _activeBlockIndex = index);
        },
        onDoubleTap: () {
          _editTextBlock(index);
        },
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(block.scale, block.scale, 1.0)
            ..rotateZ(block.rotation),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected ? const Color(0xFF3B82F6) : AppTheme.layer3Border,
                width: isSelected ? 2.0 : 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  block.text,
                  style: GoogleFonts.redRose(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (isSelected) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _editTextBlock(index),
                    child: const Icon(Icons.edit_outlined, size: 16, color: Colors.white70),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _textBlocks.removeAt(index);
                        _activeBlockIndex = null;
                      });
                    },
                    child: const Icon(Icons.close, size: 16, color: AppTheme.alertRed),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Instagram/WhatsApp Style Story Viewer Screen ---

  Widget _buildViewerScreen() {
    final story = _viewingStories[_currentStoryIndex];
    final remainingHours = story.expiresAt.difference(DateTime.now()).inHours;
    final bool isMyStory = story.authorId == _storage.deviceId;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final screenWidth = MediaQuery.of(context).size.width;
            if (details.globalPosition.dx < screenWidth * 0.35) {
              _goToPreviousStory();
            } else {
              _goToNextStory();
            }
          },
          onLongPressStart: (_) {
            _storyTimerController?.stop();
          },
          onLongPressEnd: (_) {
            _storyTimerController?.forward();
          },
          child: Stack(
            children: [
              // Background Image or dark surface
              Positioned.fill(
                child: story.imagePath != null && File(story.imagePath!).existsSync()
                    ? Image.file(
                        File(story.imagePath!),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      )
                    : Container(
                        color: const Color(0xFF0F172A),
                        child: const Center(
                          child: Icon(Icons.auto_stories, size: 64, color: AppTheme.nordicSlateLight),
                        ),
                      ),
              ),

              // Superposed Text Blocks
              for (final block in story.textBlocks)
                Positioned(
                  left: block.position.dx,
                  top: block.position.dy,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(block.scale, block.scale, 1.0)
                      ..rotateZ(block.rotation),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF3B82F6), width: 1.5),
                      ),
                      child: Text(
                        block.text,
                        style: GoogleFonts.redRose(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),

              // Top Story Header: Temporal Progress Bars & Author Details
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Segmented Temporal Progress Bars (Instagram/WhatsApp style)
                    if (_storyTimerController != null)
                      AnimatedBuilder(
                        animation: _storyTimerController!,
                        builder: (context, _) {
                          return Row(
                            children: List.generate(_viewingStories.length, (i) {
                              double fill = 0.0;
                              if (i < _currentStoryIndex) {
                                fill = 1.0;
                              } else if (i == _currentStoryIndex) {
                                fill = _storyTimerController!.value;
                              }
                              return Expanded(
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 2),
                                  height: 3.0,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: fill,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    const SizedBox(height: 12),

                    // Author info & Actions
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: const Color(0xFF3B82F6),
                          radius: 18,
                          child: Text(
                            story.authorName.isNotEmpty ? story.authorName[0].toUpperCase() : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                story.authorName,
                                style: GoogleFonts.redRose(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                remainingHours > 0
                                    ? 'Expire dans $remainingHours h'
                                    : 'Expire bientôt',
                                style: GoogleFonts.instrumentSans(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        if (isMyStory)
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                            tooltip: 'Supprimer ma story',
                            onPressed: () => _confirmDeleteStory(story),
                          ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
