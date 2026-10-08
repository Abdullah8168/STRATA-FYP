/// On-chain snapshot of the user's wallet.
///
/// Phase D fills [nativeBalanceWei] from the configured RPC.
/// [tokenBalanceWei] is null until [ChainConfig.strataTokenContract] is set.
class WalletModel {
  final String address;
  final BigInt nativeBalanceWei;
  final BigInt? tokenBalanceWei;
  final DateTime fetchedAt;

  const WalletModel({
    required this.address,
    required this.nativeBalanceWei,
    required this.tokenBalanceWei,
    required this.fetchedAt,
  });

  WalletModel copyWith({
    String? address,
    BigInt? nativeBalanceWei,
    BigInt? tokenBalanceWei,
    DateTime? fetchedAt,
  }) {
    return WalletModel(
      address: address ?? this.address,
      nativeBalanceWei: nativeBalanceWei ?? this.nativeBalanceWei,
      tokenBalanceWei: tokenBalanceWei ?? this.tokenBalanceWei,
      fetchedAt: fetchedAt ?? this.fetchedAt,
    );
  }
}
