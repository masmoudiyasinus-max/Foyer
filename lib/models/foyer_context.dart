class FoyerContext {
  final String id;
  final String name;
  final String familyCode;
  final List<String> wifiBssids;
  final bool isCurrent;
  final DateTime createdAt;

  const FoyerContext({
    required this.id,
    required this.name,
    required this.familyCode,
    this.wifiBssids = const [],
    this.isCurrent = false,
    required this.createdAt,
  });

  FoyerContext copyWith({
    String? id,
    String? name,
    String? familyCode,
    List<String>? wifiBssids,
    bool? isCurrent,
    DateTime? createdAt,
  }) {
    return FoyerContext(
      id: id ?? this.id,
      name: name ?? this.name,
      familyCode: familyCode ?? this.familyCode,
      wifiBssids: wifiBssids ?? this.wifiBssids,
      isCurrent: isCurrent ?? this.isCurrent,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'familyCode': familyCode,
      'wifiBssids': wifiBssids,
      'isCurrent': isCurrent,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory FoyerContext.fromMap(Map<dynamic, dynamic> map) {
    final rawBssids = map['wifiBssids'];
    final List<String> bssids = [];
    if (rawBssids is List) {
      for (final b in rawBssids) {
        if (b != null) bssids.add(b.toString());
      }
    }

    return FoyerContext(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Foyer',
      familyCode: map['familyCode']?.toString() ?? '',
      wifiBssids: bssids,
      isCurrent: map['isCurrent'] == true,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
