class FamilyMember {
  final String id;
  final String name;
  final String? ip;
  final int? port;
  final bool isOnline;
  final bool isApproved;
  final DateTime? lastSeen;
  final String? phone;
  String? get phoneNumber => phone;
  final String? birthDate;
  final String? bio;
  final String? accountColor;
  final DateTime? updatedAt;
  final String? timetableDocumentPath;
  final String? bannerImagePath;
  final bool isSleepShieldActive;

  const FamilyMember({
    required this.id,
    required this.name,
    this.ip,
    this.port,
    this.isOnline = true,
    this.isApproved = false,
    this.lastSeen,
    String? phone,
    String? phoneNumber,
    this.birthDate,
    this.bio,
    this.accountColor,
    this.updatedAt,
    this.timetableDocumentPath,
    this.bannerImagePath,
    this.isSleepShieldActive = false,
  }) : phone = phone ?? phoneNumber;

  String get monogram => name.isNotEmpty ? name.trim()[0].toUpperCase() : '?';

  FamilyMember copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    bool? isOnline,
    bool? isApproved,
    DateTime? lastSeen,
    String? phone,
    String? phoneNumber,
    String? birthDate,
    String? bio,
    String? accountColor,
    DateTime? updatedAt,
    String? timetableDocumentPath,
    String? bannerImagePath,
    bool? isSleepShieldActive,
  }) {
    return FamilyMember(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      isOnline: isOnline ?? this.isOnline,
      isApproved: isApproved ?? this.isApproved,
      lastSeen: lastSeen ?? this.lastSeen,
      phone: phone ?? phoneNumber ?? this.phone,
      birthDate: birthDate ?? this.birthDate,
      bio: bio ?? this.bio,
      accountColor: accountColor ?? this.accountColor,
      updatedAt: updatedAt ?? this.updatedAt,
      timetableDocumentPath: timetableDocumentPath ?? this.timetableDocumentPath,
      bannerImagePath: bannerImagePath ?? this.bannerImagePath,
      isSleepShieldActive: isSleepShieldActive ?? this.isSleepShieldActive,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'ip': ip,
      'port': port,
      'isOnline': isOnline,
      'isApproved': isApproved,
      'lastSeen': lastSeen?.toIso8601String(),
      'phone': phone,
      'phoneNumber': phone,
      'birthDate': birthDate,
      'bio': bio,
      'accountColor': accountColor,
      'updatedAt': updatedAt?.toIso8601String(),
      'timetableDocumentPath': timetableDocumentPath,
      'bannerImagePath': bannerImagePath,
      'isSleepShieldActive': isSleepShieldActive,
    };
  }

  factory FamilyMember.fromMap(Map<dynamic, dynamic> map) {
    return FamilyMember(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      ip: map['ip']?.toString(),
      port: map['port'] is int ? map['port'] as int : int.tryParse(map['port']?.toString() ?? ''),
      isOnline: map['isOnline'] == true,
      isApproved: map['isApproved'] == true,
      lastSeen: map['lastSeen'] != null ? DateTime.tryParse(map['lastSeen'].toString()) : null,
      phone: (map['phone'] ?? map['phoneNumber'])?.toString(),
      birthDate: map['birthDate']?.toString(),
      bio: map['bio']?.toString(),
      accountColor: map['accountColor']?.toString(),
      updatedAt: map['updatedAt'] != null ? DateTime.tryParse(map['updatedAt'].toString()) : null,
      timetableDocumentPath: map['timetableDocumentPath']?.toString(),
      bannerImagePath: map['bannerImagePath']?.toString(),
      isSleepShieldActive: map['isSleepShieldActive'] == true,
    );
  }
}
