class EventComment {
  final String id;
  final String authorId;
  final String authorName;
  final String text;
  final DateTime timestamp;

  const EventComment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.timestamp,
  });

  String get authorMonogram =>
      authorName.isNotEmpty ? authorName.trim()[0].toUpperCase() : '?';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'authorId': authorId,
      'authorName': authorName,
      'text': text,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory EventComment.fromMap(Map<dynamic, dynamic> map) {
    return EventComment(
      id: map['id']?.toString() ?? '',
      authorId: map['authorId']?.toString() ?? '',
      authorName: map['authorName']?.toString() ?? '',
      text: map['text']?.toString() ?? '',
      timestamp: map['timestamp'] != null
          ? DateTime.tryParse(map['timestamp'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class FamilyMeetingEvent {
  final String id;
  final String title;
  final String location;
  final String dateTimeDisplay; // e.g. "Dimanche 25 Octobre à 15:00"
  final List<EventComment> comments;
  final DateTime createdAt;
  final bool isDeleted;
  final DateTime? deletedAt;

  const FamilyMeetingEvent({
    required this.id,
    required this.title,
    required this.location,
    required this.dateTimeDisplay,
    this.comments = const [],
    required this.createdAt,
    this.isDeleted = false,
    this.deletedAt,
  });

  FamilyMeetingEvent copyWith({
    String? id,
    String? title,
    String? location,
    String? dateTimeDisplay,
    List<EventComment>? comments,
    DateTime? createdAt,
    bool? isDeleted,
    DateTime? deletedAt,
  }) {
    return FamilyMeetingEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      location: location ?? this.location,
      dateTimeDisplay: dateTimeDisplay ?? this.dateTimeDisplay,
      comments: comments ?? this.comments,
      createdAt: createdAt ?? this.createdAt,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'location': location,
      'dateTimeDisplay': dateTimeDisplay,
      'comments': comments.map((c) => c.toMap()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory FamilyMeetingEvent.fromMap(Map<dynamic, dynamic> map) {
    final rawComments = map['comments'];
    final List<EventComment> parsedComments = [];
    if (rawComments is List) {
      for (final c in rawComments) {
        if (c is Map) {
          parsedComments.add(EventComment.fromMap(c));
        }
      }
    } else if (rawComments is Map) {
      rawComments.forEach((_, v) {
        if (v is Map) {
          parsedComments.add(EventComment.fromMap(v));
        }
      });
    }

    return FamilyMeetingEvent(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      location: map['location']?.toString() ?? '',
      dateTimeDisplay: map['dateTimeDisplay']?.toString() ?? '',
      comments: parsedComments,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      isDeleted: map['isDeleted'] == true,
      deletedAt: map['deletedAt'] != null
          ? DateTime.tryParse(map['deletedAt'].toString())
          : null,
    );
  }
}
