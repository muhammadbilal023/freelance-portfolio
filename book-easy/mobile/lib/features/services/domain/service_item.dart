/// A bookable service offered by the business (e.g. "Haircut", "Dental checkup").
/// Stored in Firestore `services/{id}`.
class ServiceItem {
  const ServiceItem({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.durationMinutes,
    required this.priceCents,
    this.currency = 'usd',
    this.isActive = true,
  });

  final String id;
  final String name;
  final String description;
  final String category;
  final int durationMinutes;

  /// Price in the smallest currency unit (cents) — integers avoid rounding bugs.
  final int priceCents;
  final String currency;
  final bool isActive;

  factory ServiceItem.fromFirestore(String id, Map<String, dynamic> data) {
    return ServiceItem(
      id: id,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      category: data['category'] as String? ?? 'General',
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 30,
      priceCents: (data['priceCents'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'usd',
      isActive: data['isActive'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'description': description,
        'category': category,
        'durationMinutes': durationMinutes,
        'priceCents': priceCents,
        'currency': currency,
        'isActive': isActive,
      };

  ServiceItem copyWith({
    String? name,
    String? description,
    String? category,
    int? durationMinutes,
    int? priceCents,
    bool? isActive,
  }) {
    return ServiceItem(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      category: category ?? this.category,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      priceCents: priceCents ?? this.priceCents,
      currency: currency,
      isActive: isActive ?? this.isActive,
    );
  }
}
