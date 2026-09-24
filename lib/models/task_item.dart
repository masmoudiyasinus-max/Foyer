class TaskItem {
  final String id;
  final String title;
  final bool isDone;
  final DateTime? completedAt;
  final String? createdBy;
  final bool isGrocery;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isDeleted;
  final DateTime? deletedAt;

  const TaskItem({
    required this.id,
    required this.title,
    this.isDone = false,
    this.completedAt,
    this.createdBy,
    this.isGrocery = false,
    required this.createdAt,
    this.updatedAt,
    this.isDeleted = false,
    this.deletedAt,
  });

  TaskItem copyWith({
    String? id,
    String? title,
    bool? isDone,
    DateTime? completedAt,
    String? createdBy,
    bool? isGrocery,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
    DateTime? deletedAt,
  }) {
    return TaskItem(
      id: id ?? this.id,
      title: title ?? this.title,
      isDone: isDone ?? this.isDone,
      completedAt: completedAt ?? this.completedAt,
      createdBy: createdBy ?? this.createdBy,
      isGrocery: isGrocery ?? this.isGrocery,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'isDone': isDone,
      'completedAt': completedAt?.toIso8601String(),
      'createdBy': createdBy,
      'isGrocery': isGrocery,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory TaskItem.fromMap(Map<dynamic, dynamic> map) {
    return TaskItem(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      isDone: map['isDone'] == true,
      completedAt: map['completedAt'] != null
          ? DateTime.tryParse(map['completedAt'].toString())
          : null,
      createdBy: map['createdBy']?.toString(),
      isGrocery: map['isGrocery'] == true,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: map['updatedAt'] != null
          ? DateTime.tryParse(map['updatedAt'].toString())
          : null,
      isDeleted: map['isDeleted'] == true,
      deletedAt: map['deletedAt'] != null
          ? DateTime.tryParse(map['deletedAt'].toString())
          : null,
    );
  }
}
