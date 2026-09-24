class Announcement {
  final String id;
  final String title;
  final String text;
  final String? url;
  final String? imagePath;
  final DateTime createdAt;

  const Announcement({
    required this.id,
    required this.title,
    required this.text,
    this.url,
    this.imagePath,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'text': text,
      'url': url,
      'imagePath': imagePath,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Announcement.fromMap(Map<dynamic, dynamic> map) {
    return Announcement(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      text: map['text']?.toString() ?? '',
      url: map['url']?.toString(),
      imagePath: map['imagePath']?.toString(),
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
