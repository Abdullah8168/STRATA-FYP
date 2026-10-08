import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper around [FlutterSecureStorage] that holds the wallet mnemonic.
///
/// Storage key is versioned (`strata.wallet.mnemonic.v1`) so future migrations
/// can co-exist without overwriting existing wallets in place.
///
/// Use [SecureWalletStorage.forTesting] in unit tests; it returns an
/// in-memory implementation backed by a caller-owned Map so tests don't
/// touch native keystores.
class SecureWalletStorage {
  static const String _mnemonicKey = 'strata.wallet.mnemonic.v1';

  final FlutterSecureStorage? _real;
  final Map<String, String>? _memory;

  SecureWalletStorage()
      : _real = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        ),
        _memory = null;

  SecureWalletStorage._memory(Map<String, String> backing)
      : _real = null,
        _memory = backing;

  /// Test-only factory: returns an in-memory store. The caller supplies the
  /// backing map, so multiple [SecureWalletStorage] instances can share one
  /// store (useful for "open app twice" tests).
  @visibleForTesting
  static SecureWalletStorage forTesting(Map<String, String> backing) {
    return SecureWalletStorage._memory(backing);
  }

  Future<void> writeMnemonic(String mnemonic) async {
    final memory = _memory;
    if (memory != null) {
      memory[_mnemonicKey] = mnemonic;
      return;
    }
    await _real!.write(key: _mnemonicKey, value: mnemonic);
  }

  Future<String?> readMnemonic() async {
    final memory = _memory;
    if (memory != null) {
      return memory[_mnemonicKey];
    }
    return _real!.read(key: _mnemonicKey);
  }

  Future<void> deleteMnemonic() async {
    final memory = _memory;
    if (memory != null) {
      memory.remove(_mnemonicKey);
      return;
    }
    await _real!.delete(key: _mnemonicKey);
  }

  Future<bool> exists() async {
    final memory = _memory;
    if (memory != null) {
      return memory.containsKey(_mnemonicKey);
    }
    return _real!.containsKey(key: _mnemonicKey);
  }
}
