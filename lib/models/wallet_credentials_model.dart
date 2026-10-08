import 'package:web3dart/web3dart.dart';

/// In-memory holder for the active session's key material.
///
/// SECURITY: This object is constructed only from secure-storage reads or
/// freshly-generated entropy. It is intentionally never serialized; the
/// mnemonic itself lives in flutter_secure_storage and can be re-derived
/// when needed for backup display.
class WalletCredentials {
  final EthPrivateKey privateKey;
  final EthereumAddress address;

  WalletCredentials({required this.privateKey, required this.address});

  /// Convenience: 0x-prefixed lowercase address.
  String get hexAddress => address.hexEip55.toLowerCase();
}
