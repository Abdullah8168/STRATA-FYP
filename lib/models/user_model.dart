/// Identity record sourced from Firebase Auth (Phase B).
///
/// Phase D NOTE: this model is *only* an identity bag now. The on-chain
/// wallet balance lives on [WalletModel] in `AppProvider._walletInfo`.
/// The legacy `walletBalance` field is retained as zero for backward
/// compatibility with older code paths and is not read by new screens.
class UserModel {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String role;
  final double walletBalance;
  final String dateOfBirth;

  const UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.role,
    this.walletBalance = 0,
    this.dateOfBirth = '',
  });

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      id: map['id'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
      phone: map['phone'] as String,
      role: map['role'] as String,
      walletBalance: ((map['walletBalance'] as num?) ?? 0).toDouble(),
      dateOfBirth: (map['dateOfBirth'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'phone': phone,
      'role': role,
      'walletBalance': walletBalance,
      'dateOfBirth': dateOfBirth,
    };
  }

  UserModel copyWith({
    String? id,
    String? name,
    String? email,
    String? phone,
    String? role,
    double? walletBalance,
    String? dateOfBirth,
  }) {
    return UserModel(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      walletBalance: walletBalance ?? this.walletBalance,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
    );
  }
}
