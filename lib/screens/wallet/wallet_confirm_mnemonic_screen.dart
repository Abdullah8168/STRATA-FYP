import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_back_button.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/custom_text_field.dart';

class WalletConfirmMnemonicScreen extends StatefulWidget {
  final String mnemonic;
  const WalletConfirmMnemonicScreen({super.key, required this.mnemonic});

  @override
  State<WalletConfirmMnemonicScreen> createState() =>
      _WalletConfirmMnemonicScreenState();
}

class _WalletConfirmMnemonicScreenState
    extends State<WalletConfirmMnemonicScreen>
    with SingleTickerProviderStateMixin {
  late final List<int> _challengeIndexes;
  late final List<TextEditingController> _controllers;
  late final List<String> _words;
  bool _busy = false;
  late final AnimationController _shakeController;
  late final Animation<double> _shake;

  @override
  void initState() {
    super.initState();
    _words = widget.mnemonic.split(RegExp(r'\s+'));
    _challengeIndexes = _pickIndexes(_words.length);
    _controllers =
        List.generate(_challengeIndexes.length, (_) => TextEditingController());
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shake = Tween<double>(begin: 0, end: 12)
        .chain(CurveTween(curve: Curves.elasticIn))
        .animate(_shakeController);
  }

  List<int> _pickIndexes(int total) {
    final rnd = Random.secure();
    final picks = <int>{};
    while (picks.length < 3) {
      picks.add(rnd.nextInt(total));
    }
    final list = picks.toList()..sort();
    return list;
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    bool allOk = true;
    for (var i = 0; i < _challengeIndexes.length; i++) {
      final expected = _words[_challengeIndexes[i]].trim().toLowerCase();
      final got = _controllers[i].text.trim().toLowerCase();
      if (got != expected) {
        allOk = false;
        break;
      }
    }
    if (!allOk) {
      _shakeController.forward(from: 0);
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Some words did not match. Try again.')),
      );
      return;
    }

    final provider = context.read<AppProvider>();
    try {
      await provider.commitWalletAfterConfirmation(widget.mnemonic);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wallet ready ✓')),
      );
      final role = provider.selectedRole;
      if (role == 'host') {
        context.go('/host/onboarding');
      } else {
        context.go('/guest/location');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save wallet: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: AppBackButton(
          to: '/wallet/show-mnemonic',
          extra: {'mnemonic': widget.mnemonic},
        ),
        title: const Text('Confirm Phrase'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AnimatedBuilder(
            animation: _shake,
            builder: (_, child) {
              return Transform.translate(
                offset: Offset(_shake.value * (1 - _shakeController.value), 0),
                child: child,
              );
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Type the words from your phrase to confirm you saved them.',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 18),
                for (var i = 0; i < _challengeIndexes.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: CustomTextField(
                      label: 'Word #${_challengeIndexes[i] + 1}',
                      controller: _controllers[i],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                CustomButton(
                  label: 'Confirm & continue',
                  onPressed: _busy ? null : _confirm,
                  loading: _busy,
                  icon: Icons.check_circle_outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
