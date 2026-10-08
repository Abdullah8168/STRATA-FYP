// SECURITY NOTICE
// ================================================================
// This file handles real cryptographic key material for the STRATA
// wallet. Reviewers MUST verify the following invariants before
// merging any change to this file:
//
//   1. The mnemonic and EthPrivateKey are NEVER passed to any
//      logging call (debugPrint / print / log / Sentry / Crashlytics).
//   2. The mnemonic is only persisted via SecureWalletStorage.
//      It is never written to SharedPreferences, hive, files, or
//      sent over the network.
//   3. EthPrivateKey instances are scoped to local variables and
//      WalletCredentials. They are not cached on the service.
//   4. signMessage and signSessionStart MUST hash the message via
//      EIP-191 personal_sign; we do NOT raw-sign user-controlled
//      bytes (replay safety).
//   5. Every public method that returns a private key, mnemonic, or
//      signed payload is covered by a unit test with a known-vector.
// ================================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';

import '../models/wallet_credentials_model.dart';
import 'secure_wallet_storage.dart';

/// Canonical message template for `POST /session/start`. Both this client
/// and the host node MUST agree on this exact format byte-for-byte.
///
/// Fields are joined with `\n` (LF) — there is no trailing newline.
const String strataSessionStartMessageTemplate = 'STRATA-SESSION-START\n'
    'guest:{guest}\n'
    'host:{host}\n'
    'mac:{mac}\n'
    'quota:{quota}\n'
    'nonce:{nonce}';

/// BIP-44 derivation path for the first Ethereum account.
const String _ethDerivationPath = "m/44'/60'/0'/0/0";

class WalletNotFoundException implements Exception {
  const WalletNotFoundException();
  @override
  String toString() => 'WalletNotFoundException: no wallet on this device';
}

class WalletImportException implements Exception {
  final String reason;
  const WalletImportException(this.reason);
  @override
  String toString() => 'WalletImportException: $reason';
}

class WalletStorageException implements Exception {
  final String reason;
  const WalletStorageException(this.reason);
  @override
  String toString() => 'WalletStorageException: $reason';
}

class WalletSigningException implements Exception {
  final String reason;
  const WalletSigningException(this.reason);
  @override
  String toString() => 'WalletSigningException: $reason';
}

class WalletService {
  WalletService({SecureWalletStorage? storage})
      : _storage = storage ?? SecureWalletStorage();

  final SecureWalletStorage _storage;

  /// Generates a fresh BIP-39 mnemonic and derives the first Ethereum
  /// credentials from it.
  ///
  /// IMPORTANT: This does NOT persist to secure storage. The caller is
  /// expected to display the mnemonic, have the user confirm a few words,
  /// and only then call [persistMnemonic] (or
  /// [WalletProvider.commitWalletAfterConfirmation]). This guarantees that
  /// any wallet ever found in storage has been verified by the user.
  Future<({String mnemonic, WalletCredentials credentials})> createWallet({
    int strength = 128,
  }) async {
    final mnemonic = bip39.generateMnemonic(strength: strength);
    final credentials = _credentialsFromMnemonic(mnemonic);
    return (mnemonic: mnemonic, credentials: credentials);
  }

  /// Imports an existing BIP-39 mnemonic and persists it to secure storage.
  Future<WalletCredentials> importWallet(String mnemonic) async {
    final normalized = mnemonic.trim().toLowerCase();
    if (!bip39.validateMnemonic(normalized)) {
      throw const WalletImportException(
          'That is not a valid 12 or 24 word phrase');
    }
    final credentials = _credentialsFromMnemonic(normalized);
    try {
      await _storage.writeMnemonic(normalized);
    } catch (e) {
      throw WalletStorageException(
          'Failed to write mnemonic to secure storage: ${e.runtimeType}');
    }
    return credentials;
  }

  /// Persists a previously-generated mnemonic. Idempotent: if a mnemonic is
  /// already stored, this is a no-op.
  Future<void> persistMnemonic(String mnemonic) async {
    final normalized = mnemonic.trim().toLowerCase();
    if (!bip39.validateMnemonic(normalized)) {
      throw const WalletImportException('Refusing to persist invalid mnemonic');
    }
    try {
      if (await _storage.exists()) return;
      await _storage.writeMnemonic(normalized);
    } catch (e) {
      throw WalletStorageException(
          'Failed to write mnemonic to secure storage: ${e.runtimeType}');
    }
  }

  /// Loads the persisted wallet's credentials. Throws
  /// [WalletNotFoundException] if no wallet is on this device.
  Future<WalletCredentials> loadWallet() async {
    String? mnemonic;
    try {
      mnemonic = await _storage.readMnemonic();
    } catch (e) {
      throw WalletStorageException(
          'Failed to read mnemonic: ${e.runtimeType}');
    }
    if (mnemonic == null || mnemonic.isEmpty) {
      throw const WalletNotFoundException();
    }
    return _credentialsFromMnemonic(mnemonic);
  }

  Future<bool> hasWallet() async {
    try {
      return await _storage.exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns the stored mnemonic for backup display.
  ///
  /// TODO(Phase G): gate this behind biometric / PIN re-authentication.
  /// Phase D leaves this unguarded so the demo flow is uninterrupted.
  Future<String> revealMnemonic() async {
    final mnemonic = await _storage.readMnemonic();
    if (mnemonic == null || mnemonic.isEmpty) {
      throw const WalletNotFoundException();
    }
    return mnemonic;
  }

  Future<void> deleteWallet() async {
    try {
      await _storage.deleteMnemonic();
    } catch (e) {
      throw WalletStorageException(
          'Failed to delete mnemonic: ${e.runtimeType}');
    }
  }

  /// EIP-191 personal_sign over a UTF-8 string.
  ///
  /// Returns a 0x-prefixed 65-byte signature (`r || s || v` with v in 27/28).
  Future<String> signMessage(String message) async {
    final mnemonic = await _storage.readMnemonic();
    if (mnemonic == null || mnemonic.isEmpty) {
      throw const WalletNotFoundException();
    }
    final credentials = _credentialsFromMnemonic(mnemonic);
    return _sign(credentials, message);
  }

  /// Builds the canonical session-start message and signs it.
  ///
  /// Returns both the canonical message and the signature so that the caller
  /// can include both in the host-node request envelope.
  Future<({String canonicalMessage, String signature})> signSessionStart({
    required String guestAddress,
    required String hostAddress,
    required String macAddress,
    required BigInt quotaBytes,
    required String nonce,
  }) async {
    final mnemonic = await _storage.readMnemonic();
    if (mnemonic == null || mnemonic.isEmpty) {
      throw const WalletNotFoundException();
    }
    final credentials = _credentialsFromMnemonic(mnemonic);
    final canonical = _buildSessionStartMessage(
      guestAddress: guestAddress,
      hostAddress: hostAddress,
      macAddress: macAddress,
      quotaBytes: quotaBytes,
      nonce: nonce,
    );
    final signature = _sign(credentials, canonical);
    return (canonicalMessage: canonical, signature: signature);
  }

  // ------------------------- internals -------------------------

  WalletCredentials _credentialsFromMnemonic(String mnemonic) {
    final seed = bip39.mnemonicToSeed(mnemonic);
    final root = bip32.BIP32.fromSeed(seed);
    final child = root.derivePath(_ethDerivationPath);
    final privateBytes = child.privateKey;
    if (privateBytes == null) {
      throw const WalletSigningException(
          'BIP32 derivation produced no private key');
    }
    final ethKey = EthPrivateKey.fromHex(bytesToHex(privateBytes));
    return WalletCredentials(privateKey: ethKey, address: ethKey.address);
  }

  String _sign(WalletCredentials credentials, String message) {
    try {
      final bytes = Uint8List.fromList(utf8.encode(message));
      final sig = credentials.privateKey.signPersonalMessageToUint8List(bytes);
      return bytesToHex(sig, include0x: true);
    } catch (e) {
      throw WalletSigningException('signPersonalMessage failed: ${e.runtimeType}');
    }
  }

  String _buildSessionStartMessage({
    required String guestAddress,
    required String hostAddress,
    required String macAddress,
    required BigInt quotaBytes,
    required String nonce,
  }) {
    return strataSessionStartMessageTemplate
        .replaceFirst('{guest}', guestAddress.toLowerCase())
        .replaceFirst('{host}', hostAddress.toLowerCase())
        .replaceFirst('{mac}', macAddress.toLowerCase())
        .replaceFirst('{quota}', quotaBytes.toString())
        .replaceFirst('{nonce}', nonce);
  }
}
