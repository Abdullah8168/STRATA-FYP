import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../widgets/app_back_button.dart';
import '../widgets/custom_button.dart';
import '../widgets/custom_text_field.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _usernameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _dobController;

  @override
  void initState() {
    super.initState();
    final user = context.read<AppProvider>().currentUser;
    _usernameController =
        TextEditingController(text: user?.name ?? 'Guest User');
    _emailController = TextEditingController(text: user?.email ?? '');
    _phoneController = TextEditingController(text: user?.phone ?? '');
    _dobController = TextEditingController(text: user?.dateOfBirth ?? '');
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  void _saveProfile() {
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<AppProvider>();
    final user = provider.currentUser;
    if (user != null) {
      provider.setUser(
        user.copyWith(
          name: _usernameController.text.trim(),
          email: _emailController.text.trim(),
          phone: _phoneController.text.trim(),
          dateOfBirth: _dobController.text.trim(),
        ),
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile updated')),
    );
  }

  void _logout() {
    context.read<AppProvider>().resetSession();
    context.go('/role');
  }

  Future<void> _showAddress() async {
    final provider = context.read<AppProvider>();
    if (provider.walletCredentials == null) {
      // Hydrate from secure storage in case a page refresh dropped the
      // in-memory cache before this screen was reached.
      await provider.initWallet();
    }
    if (!mounted) return;
    final credentials = provider.walletCredentials;
    if (credentials == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No wallet on this device.')),
      );
      return;
    }
    final address = credentials.hexAddress;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Wallet: $address'),
        action: SnackBarAction(
          label: 'Copy',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: address));
          },
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(),
        title: const Text('Profile'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              CustomTextField(
                label: 'Username',
                controller: _usernameController,
                prefixIcon: const Icon(Icons.person_outline),
                validator: (v) => Validators.requiredMin(v, 2, 'Username'),
              ),
              const SizedBox(height: 12),
              CustomTextField(
                label: 'Email',
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                prefixIcon: const Icon(Icons.email_outlined),
                validator: Validators.email,
              ),
              const SizedBox(height: 12),
              CustomTextField(
                label: 'Phone Number',
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                prefixIcon: const Icon(Icons.phone_iphone_outlined),
                validator: Validators.phone,
              ),
              const SizedBox(height: 12),
              CustomTextField(
                label: 'Date of Birth (YYYY-MM-DD)',
                controller: _dobController,
                keyboardType: TextInputType.datetime,
                prefixIcon: const Icon(Icons.cake_outlined),
                validator: Validators.date,
              ),
              const SizedBox(height: 16),
              CustomButton(
                label: 'Save Changes',
                onPressed: _saveProfile,
                icon: Icons.save_outlined,
              ),
              const SizedBox(height: 12),
              CustomButton(
                label: 'Backup wallet',
                outlined: true,
                onPressed: () => context.go('/wallet/backup'),
                icon: Icons.shield_outlined,
              ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Caveat: on a release iOS/Android build, your wallet survives '
                  'an app reinstall ONLY if iCloud Keychain or Google account-level '
                  'keystore backup is enabled.',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
              ),
              const SizedBox(height: 12),
              CustomButton(
                label: 'Wallet address',
                outlined: true,
                onPressed: _showAddress,
                icon: Icons.alternate_email,
              ),
              const SizedBox(height: 12),
              CustomButton(
                label: 'Logout',
                outlined: true,
                onPressed: _logout,
                icon: Icons.logout,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
