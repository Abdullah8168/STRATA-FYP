import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local flags persisted in Secure Storage (Phase H).
class StrataSecureSettings {
  StrataSecureSettings._();
  static final StrataSecureSettings instance = StrataSecureSettings._();

  // v2: the option now defaults to OFF. New key so an old stored "on" from
  // earlier builds doesn't carry over; users turn it on in Settings if wanted.
  static const _biometricRequiredKey = 'strata.settings.biometric_required.v2';
  static const _onboardedRolesKey = 'strata.onboarded.v1';
  static const _onboardLanHintKey = 'strata.onboard.lan_tooltip.v1';
  static const _onboardMnemonicKey = 'strata.onboard.mnemonic_tooltip.v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<bool> isBiometricRequired() async {
    final v = await _storage.read(key: _biometricRequiredKey);
    if (v == null) return false;
    return v == 'true';
  }

  Future<void> setBiometricRequired(bool value) =>
      _storage.write(key: _biometricRequiredKey, value: value.toString());

  Future<bool> hasSeenRolesIntro() async =>
      (await _storage.read(key: _onboardedRolesKey)) == 'true';

  Future<void> markRolesIntroSeen() =>
      _storage.write(key: _onboardedRolesKey, value: 'true');

  Future<bool> hasSeenLanCoachmark() async =>
      (await _storage.read(key: _onboardLanHintKey)) == 'true';

  Future<void> markLanCoachmarkSeen() =>
      _storage.write(key: _onboardLanHintKey, value: 'true');

  Future<bool> hasSeenMnemonicCoachmark() async =>
      (await _storage.read(key: _onboardMnemonicKey)) == 'true';

  Future<void> markMnemonicCoachmarkSeen() =>
      _storage.write(key: _onboardMnemonicKey, value: 'true');
}
