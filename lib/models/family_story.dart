import 'package:flutter/material.dart';

class StoryTextBlock {
  String text;
  Offset position;
  double scale;
  double rotation;

  StoryTextBlock({
    required this.text,
    this.position = const Offset(120, 200),
    this.scale = 1.0,
    this.rotation = 0.0,
  });

  Map<String, dynamic> toMap() => {
    'text': text,
    'x': position.dx,
    'y': position.dy,
    'scale': scale,
    'rotation': rotation,
  };

  factory StoryTextBlock.fromMap(Map<dynamic, dynamic> map) => StoryTextBlock(
    text: map['text']?.toString() ?? '',
    position: Offset(
      (map['x'] as num?)?.toDouble() ?? 120.0,
      (map['y'] as num?)?.toDouble() ?? 200.0,
    ),
    scale: (map['scale'] as num?)?.toDouble() ?? 1.0,
    rotation: (map['rotation'] as num?)?.toDouble() ?? 0.0,
  );
}

class FamilyStory {
  final String id;
  final String authorId;
  final String authorName;
  final String? imagePath;
  final List<StoryTextBlock> textBlocks;
  final DateTime createdAt;
  final DateTime expiresAt;

  FamilyStory({
    required this.id,
    required this.authorId,
    required this.authorName,
    this.imagePath,
    List<StoryTextBlock>? textBlocks,
    List<StoryTextBlock>? textElements,
    required this.createdAt,
    required this.expiresAt,
  }) : textBlocks = textBlocks ?? textElements ?? [];

  List<StoryTextBlock> get textElements => textBlocks;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toMap() => {
    'id': id,
    'authorId': authorId,
    'authorName': authorName,
    'imagePath': imagePath,
    'textBlocks': textBlocks.map((b) => b.toMap()).toList(),
    'textElements': textBlocks.map((b) => b.toMap()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  };

  factory FamilyStory.fromMap(Map<dynamic, dynamic> map) {
    final rawBlocks = map['textBlocks'] ?? map['textElements'];
    final List<dynamic> blocksList = rawBlocks is List
        ? rawBlocks
        : (rawBlocks is Map ? rawBlocks.values.toList() : []);
    return FamilyStory(
      id: map['id']?.toString() ?? '',
      authorId: map['authorId']?.toString() ?? '',
      authorName: map['authorName']?.toString() ?? 'Membre',
      imagePath: map['imagePath']?.toString(),
      textBlocks: blocksList
          .where((b) => b is Map)
          .map((b) => StoryTextBlock.fromMap(b as Map))
          .toList(),
      createdAt: DateTime.tryParse(map['createdAt']?.toString() ?? '') ?? DateTime.now(),
      expiresAt: DateTime.tryParse(map['expiresAt']?.toString() ?? '') ??
          DateTime.now().add(const Duration(hours: 24)),
    );
  }
}
