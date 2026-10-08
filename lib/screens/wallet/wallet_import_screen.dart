import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_back_button.dart';
import '../../widgets/custom_button.dart';

class WalletImportScreen extends StatefulWidget {
  const WalletImportScreen({super.key});

  @override
  State<WalletImportScreen> createState() => _WalletImportScreenState();
}

class _WalletImportScreenState extends State<WalletImportScreen> {
  final _controller = TextEditingController();
  bool _valid = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final ok = bip39.validateMnemonic(value.trim().toLowerCase());
    setState(() {
      _valid = ok;
      _error = null;
    });
  }

  Future<void> _import() async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final provider = context.read<AppProvider>();
      await provider.importExistingWallet(_controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wallet imported ✓')),
      );
      final role = provider.selectedRole;
      if (role == 'host') {
        context.go('/host/onboarding');
      } else {
        context.go('/guest/location');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(to: '/wallet/create-intro'),
        title: const Text('Import wallet'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your 12 or 24 word recovery phrase. Words are space '
                'separated.',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                onChanged: _onChanged,
                minLines: 4,
                maxLines: 6,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: 'e.g. legal winner thank year wave sausage worth ...',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  "That's not a valid 12 or 24 word phrase",
                  style: const TextStyle(color: AppColors.error),
                ),
              ],
              const SizedBox(height: 16),
              CustomButton(
                label: 'Import',
                onPressed: _valid && !_busy ? _import : null,
                loading: _busy,
                icon: Icons.lock_open_outlined,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
