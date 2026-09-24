class MealItem {
  final String id;
  final String title;
  final String authorId;
  final String authorName;
  final bool isPrepared;
  final Map<String, String> votes; // memberId -> 'like' | 'dislike'
  final DateTime createdAt;

  const MealItem({
    required this.id,
    required this.title,
    required this.authorId,
    required this.authorName,
    this.isPrepared = false,
    this.votes = const {},
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'authorId': authorId,
      'authorName': authorName,
      'isPrepared': isPrepared,
      'votes': votes,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory MealItem.fromMap(Map<dynamic, dynamic> map) {
    return MealItem(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      authorId: map['authorId']?.toString() ?? '',
      authorName: map['authorName']?.toString() ?? '',
      isPrepared: map['isPrepared'] == true,
      votes: map['votes'] is Map
          ? Map<String, String>.from((map['votes'] as Map).map((k, v) => MapEntry(k.toString(), v.toString())))
          : const {},
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  MealItem copyWith({
    String? id,
    String? title,
    String? authorId,
    String? authorName,
    bool? isPrepared,
    Map<String, String>? votes,
    DateTime? createdAt,
  }) {
    return MealItem(
      id: id ?? this.id,
      title: title ?? this.title,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      isPrepared: isPrepared ?? this.isPrepared,
      votes: votes ?? this.votes,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  int get likesCount => votes.values.where((v) => v == 'like').length;
  int get dislikesCount => votes.values.where((v) => v == 'dislike').length;
}
