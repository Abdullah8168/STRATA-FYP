import 'package:flutter/material.dart';

import '../core/settings/strata_secure_settings.dart';
import '../services/biometric_auth_service.dart';

/// Runs [BiometricAuthService.authenticate]; on failure opens a single
/// Continue/Cancel fallback dialog (Phase H gate for backup + payments).
Future<bool> requireBiometricOrDialog(
  BuildContext context, {
  required String reason,
}) async {
  if (!await StrataSecureSettings.instance.isBiometricRequired()) {
    return true;
  }
  final svc = BiometricAuthService.instance;
  final ok = await svc.authenticate(localizedReason: reason);
  if (ok && context.mounted) return true;
  if (!context.mounted) return false;
  final proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('Could not authenticate'),
      content: const Text(
        'Biometric or device PIN verification did not succeed. You can '
        'continue anyway for this step, or cancel and try again. '
        '(Disable “Require biometric for payments” under Guest Settings to skip.)',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return proceed ?? false;
}
