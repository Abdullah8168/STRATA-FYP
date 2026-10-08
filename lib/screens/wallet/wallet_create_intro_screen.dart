import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_back_button.dart';
import '../../widgets/custom_button.dart';

class WalletCreateIntroScreen extends StatefulWidget {
  const WalletCreateIntroScreen({super.key});

  @override
  State<WalletCreateIntroScreen> createState() =>
      _WalletCreateIntroScreenState();
}

class _WalletCreateIntroScreenState extends State<WalletCreateIntroScreen> {
  bool _busy = false;

  Future<void> _createNew() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final provider = context.read<AppProvider>();
      final result = await provider.createNewWallet();
      if (!mounted) return;
      context.go(
        '/wallet/show-mnemonic',
        extra: {'mnemonic': result.mnemonic},
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wallet creation failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(),
        title: const Text('Set up your wallet'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(25),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: AppColors.primary,
                  size: 32,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Set up your STRATA wallet',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'STRATA is non-custodial — only you hold the keys. '
                'Back up your recovery phrase. Without it, you cannot recover funds.',
                style:
                    TextStyle(color: AppColors.textSecondary, height: 1.4, fontSize: 14),
              ),
              const SizedBox(height: 28),
              CustomButton(
                label: 'Create new wallet',
                onPressed: _busy ? null : _createNew,
                loading: _busy,
                icon: Icons.add_circle_outline,
              ),
              const SizedBox(height: 12),
              CustomButton(
                label: 'Import existing',
                outlined: true,
                onPressed: _busy ? null : () => context.go('/wallet/import'),
                icon: Icons.download_outlined,
              ),
              const SizedBox(height: 24),
              _securityNote(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _securityNote() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: AppColors.primary, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Your recovery phrase is stored on this device only, encrypted '
              'by your platform keystore. STRATA never sees it.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
