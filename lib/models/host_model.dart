class HostModel {
  final String id;
  final String name;
  final String ssid;
  final double pricePerGB;
  final double rating;
  final double distance;
  final int availableGB;
  final bool isActive;

  /// EVM address (0x-prefixed) of the host's payout wallet.
  /// LAN hosts populate this from `GET /host/info`; marketplace demo cards
  /// may use placeholders until a real host is selected.
  final String walletAddress;

  /// Per-GB price in wei, sent as a string to preserve full uint256 range.
  final String pricePerGbWei;

  const HostModel({
    required this.id,
    required this.name,
    required this.ssid,
    required this.pricePerGB,
    required this.rating,
    required this.distance,
    required this.availableGB,
    required this.isActive,
    this.walletAddress = '0x0000000000000000000000000000000000000000',
    this.pricePerGbWei = '1000000000000000',
  });

  factory HostModel.fromMap(Map<String, dynamic> map) {
    return HostModel(
      id: map['id'] as String,
      name: map['name'] as String,
      ssid: map['ssid'] as String,
      pricePerGB: (map['pricePerGB'] as num).toDouble(),
      rating: (map['rating'] as num).toDouble(),
      distance: (map['distance'] as num).toDouble(),
      availableGB: map['availableGB'] as int,
      isActive: map['isActive'] as bool,
      walletAddress: (map['walletAddress'] as String?) ??
          '0x0000000000000000000000000000000000000000',
      pricePerGbWei:
          (map['pricePerGbWei'] as String?) ?? '1000000000000000',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'ssid': ssid,
      'pricePerGB': pricePerGB,
      'rating': rating,
      'distance': distance,
      'availableGB': availableGB,
      'isActive': isActive,
      'walletAddress': walletAddress,
      'pricePerGbWei': pricePerGbWei,
    };
  }

  HostModel copyWith({
    String? id,
    String? name,
    String? ssid,
    double? pricePerGB,
    double? rating,
    double? distance,
    int? availableGB,
    bool? isActive,
    String? walletAddress,
    String? pricePerGbWei,
  }) {
    return HostModel(
      id: id ?? this.id,
      name: name ?? this.name,
      ssid: ssid ?? this.ssid,
      pricePerGB: pricePerGB ?? this.pricePerGB,
      rating: rating ?? this.rating,
      distance: distance ?? this.distance,
      availableGB: availableGB ?? this.availableGB,
      isActive: isActive ?? this.isActive,
      walletAddress: walletAddress ?? this.walletAddress,
      pricePerGbWei: pricePerGbWei ?? this.pricePerGbWei,
    );
  }
}
