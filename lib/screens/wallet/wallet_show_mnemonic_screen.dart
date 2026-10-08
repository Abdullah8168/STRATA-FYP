import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/settings/strata_secure_settings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_back_button.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/mnemonic_grid.dart';

class WalletShowMnemonicScreen extends StatefulWidget {
  final String mnemonic;
  const WalletShowMnemonicScreen({super.key, required this.mnemonic});

  @override
  State<WalletShowMnemonicScreen> createState() =>
      _WalletShowMnemonicScreenState();
}

class _WalletShowMnemonicScreenState extends State<WalletShowMnemonicScreen> {
  bool _ackEnabled = false;
  Timer? _enableTimer;
  Timer? _clipboardClearTimer;

  @override
  void initState() {
    super.initState();
    _enableTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _ackEnabled = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (await StrataSecureSettings.instance.hasSeenMnemonicCoachmark()) {
        return;
      }
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.surface,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Security tip',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Follow the red warning above before you copy or continue. '
                  'Anyone with this phrase controls your wallet.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await StrataSecureSettings.instance.markMnemonicCoachmarkSeen();
    });
  }

  @override
  void dispose() {
    _enableTimer?.cancel();
    _clipboardClearTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.mnemonic));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Phrase copied — clipboard auto-clears in 30s'),
      ),
    );
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = Timer(const Duration(seconds: 30), () async {
      await Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.mnemonic.split(RegExp(r'\s+'));
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(to: '/wallet/create-intro'),
        title: const Text('Recovery Phrase'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _warningBanner(),
              const SizedBox(height: 16),
              MnemonicGrid(words: words),
              const SizedBox(height: 16),
              CustomButton(
                label: 'Copy to clipboard',
                outlined: true,
                onPressed: _copy,
                icon: Icons.copy_outlined,
              ),
              const SizedBox(height: 12),
              CustomButton(
                label: _ackEnabled
                    ? "I've written it down"
                    : "Read carefully…",
                onPressed: _ackEnabled
                    ? () => context.go(
                          '/wallet/confirm-mnemonic',
                          extra: {'mnemonic': widget.mnemonic},
                        )
                    : null,
                icon: Icons.arrow_forward,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _warningBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.error.withAlpha(40),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, color: AppColors.error, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Don’t screenshot this — it cannot be recovered if lost. '
              'Write it on paper and store somewhere safe.',
              style: TextStyle(color: AppColors.textPrimary, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
