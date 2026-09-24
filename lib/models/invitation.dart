class Invitation {
  final String id;
  final String title;
  final String description;
  final String dateTimeDisplay; // Explicit static date & time, e.g., "Samedi 24 Octobre à 19:30"
  final String? imagePath;
  final Map<String, bool> rsvpResponses; // MemberId -> true (Accepted) / false (Refused)
  final DateTime createdAt;
  final bool isDeleted;
  final DateTime? deletedAt;

  const Invitation({
    required this.id,
    required this.title,
    required this.description,
    required this.dateTimeDisplay,
    this.imagePath,
    this.rsvpResponses = const {},
    required this.createdAt,
    this.isDeleted = false,
    this.deletedAt,
  });

  Invitation copyWith({
    String? id,
    String? title,
    String? description,
    String? dateTimeDisplay,
    String? imagePath,
    Map<String, bool>? rsvpResponses,
    DateTime? createdAt,
    bool? isDeleted,
    DateTime? deletedAt,
  }) {
    return Invitation(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      dateTimeDisplay: dateTimeDisplay ?? this.dateTimeDisplay,
      imagePath: imagePath ?? this.imagePath,
      rsvpResponses: rsvpResponses ?? this.rsvpResponses,
      createdAt: createdAt ?? this.createdAt,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'dateTimeDisplay': dateTimeDisplay,
      'imagePath': imagePath,
      'rsvpResponses': rsvpResponses,
      'createdAt': createdAt.toIso8601String(),
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory Invitation.fromMap(Map<dynamic, dynamic> map) {
    final rawRsvp = map['rsvpResponses'];
    final Map<String, bool> parsedRsvp = {};
    if (rawRsvp is Map) {
      rawRsvp.forEach((k, v) {
        parsedRsvp[k.toString()] = v == true;
      });
    }

    return Invitation(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      dateTimeDisplay: map['dateTimeDisplay']?.toString() ?? '',
      imagePath: map['imagePath']?.toString(),
      rsvpResponses: parsedRsvp,
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
