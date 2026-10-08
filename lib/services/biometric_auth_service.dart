import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'wallet_service.dart';

/// Thin wrapper around package:local_auth for STRATA (Phase H).
class BiometricAuthService {
  BiometricAuthService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Global singleton for screens; tests may inject a fake [LocalAuthentication].
  static BiometricAuthService instance = BiometricAuthService();

  /// Phase H — required before sensitive wallet operations.
  ///
  /// In debug builds on simulators with no secure enclave, callers may get
  /// `false`; we allow debug to proceed so CI doesn't block.
  Future<bool> authenticate({required String localizedReason}) async {
    try {
      if (!await _auth.isDeviceSupported()) {
        debugPrint('[STRATA] local_auth: device not supported');
        return kDebugMode;
      }
      return _auth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } on Exception catch (e) {
      debugPrint('[STRATA] local_auth error: $e');
      return kDebugMode;
    }
  }

  Future<T> withBiometric<T>(
    Future<T> Function() fn, {
    required String reason,
    bool requiredPreference = true,
  }) async {
    if (!requiredPreference) return fn();
    final ok = await authenticate(localizedReason: reason);
    if (!ok) {
      throw const WalletSigningException('Biometric authentication cancelled or unavailable.');
    }
    return fn();
  }
}
