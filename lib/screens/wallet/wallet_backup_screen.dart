import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/biometric_prompt.dart';
import '../../widgets/app_back_button.dart';
import '../../widgets/mnemonic_grid.dart';

class WalletBackupScreen extends StatefulWidget {
  const WalletBackupScreen({super.key});

  @override
  State<WalletBackupScreen> createState() => _WalletBackupScreenState();
}

class _WalletBackupScreenState extends State<WalletBackupScreen> {
  String? _mnemonic;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ok = await requireBiometricOrDialog(
      context,
      reason: 'Reveal recovery phrase',
    );
    if (!ok || !mounted) return;
    try {
      final mnemonic =
          await context.read<AppProvider>().revealWalletMnemonic();
      if (!mounted) return;
      setState(() => _mnemonic = mnemonic);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(to: '/profile'),
        title: const Text('Backup wallet'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withAlpha(40),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.error),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_outlined,
                        color: AppColors.error, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Anyone with this phrase can spend your funds. Do not '
                        'screenshot. Do not share.',
                        style: TextStyle(
                            color: AppColors.textPrimary, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (_error != null)
                Text('Could not load mnemonic: $_error',
                    style: const TextStyle(color: AppColors.error))
              else if (_mnemonic == null)
                const Center(child: CircularProgressIndicator())
              else
                MnemonicGrid(
                    words: _mnemonic!.split(RegExp(r'\s+'))),
              const SizedBox(height: 12),
              const Text(
                'Caveat: on a release iOS/Android build, this wallet survives '
                'an app reinstall ONLY if the user has iCloud Keychain or '
                'Google account-level keystore backup enabled.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
