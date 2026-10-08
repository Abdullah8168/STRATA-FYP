import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';
import '../../providers/app_provider.dart';
import '../../core/settings/strata_secure_settings.dart';
import '../../widgets/custom_text_field.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/app_back_button.dart';
import '../../utils/validators.dart';

class GuestSettingsScreen extends StatefulWidget {
  const GuestSettingsScreen({super.key});

  @override
  State<GuestSettingsScreen> createState() => _GuestSettingsScreenState();
}

class _GuestSettingsScreenState extends State<GuestSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _phone;
  late final TextEditingController _username;
  late final TextEditingController _email;
  late final TextEditingController _dob;
  bool _requireBiometric = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AppProvider>().currentUser;
    final nameParts = (user?.name ?? 'Guest User').split(' ');
    _firstName = TextEditingController(
        text: nameParts.isNotEmpty ? nameParts.first : '');
    _lastName = TextEditingController(
      text: nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '',
    );
    _phone = TextEditingController(text: user?.phone ?? '');
    _username = TextEditingController(text: nameParts.first.toLowerCase());
    _email = TextEditingController(text: user?.email ?? '');
    _dob = TextEditingController(text: user?.dateOfBirth ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final v = await StrataSecureSettings.instance.isBiometricRequired();
      if (!mounted) return;
      setState(() => _requireBiometric = v);
    });
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _phone.dispose();
    _username.dispose();
    _email.dispose();
    _dob.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<AppProvider>();
    final user = provider.currentUser;
    if (user != null) {
      final updatedName = '${_firstName.text.trim()} ${_lastName.text.trim()}';
      provider.setUser(
        user.copyWith(
          name: updatedName.trim().isEmpty ? user.name : updatedName.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          dateOfBirth: _dob.text.trim(),
        ),
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings updated')),
    );
  }

  void _logout() {
    context.read<AppProvider>().resetSession();
    context.go('/role');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(to: '/guest/nearby'),
        title: const Text('Settings'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Profile',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                CustomTextField(
                  label: 'First Name',
                  controller: _firstName,
                  prefixIcon: const Icon(Icons.person_outline),
                  validator: (v) => Validators.requiredMin(v, 2, 'First name'),
                ),
                const SizedBox(height: 12),
                CustomTextField(
                  label: 'Last Name',
                  controller: _lastName,
                  prefixIcon: const Icon(Icons.person_outline),
                  validator: (v) => Validators.requiredMin(v, 2, 'Last name'),
                ),
                const SizedBox(height: 12),
                CustomTextField(
                  label: 'Phone Number',
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  prefixIcon: const Icon(Icons.phone_iphone_outlined),
                  validator: Validators.phone,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Account',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                CustomTextField(
                  label: 'Username',
                  controller: _username,
                  prefixIcon: const Icon(Icons.alternate_email),
                  validator: (v) => Validators.requiredMin(v, 3, 'Username'),
                ),
                const SizedBox(height: 12),
                CustomTextField(
                  label: 'Email',
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: const Icon(Icons.email_outlined),
                  validator: Validators.email,
                ),
                const SizedBox(height: 12),
                CustomTextField(
                  label: 'Date of Birth (YYYY-MM-DD)',
                  controller: _dob,
                  keyboardType: TextInputType.datetime,
                  prefixIcon: const Icon(Icons.cake_outlined),
                  validator: Validators.date,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Security',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Require biometric before payments',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Face ID / fingerprint / device PIN before signing and '
                    'viewing your recovery phrase.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                  ),
                  value: _requireBiometric,
                  onChanged: (v) async {
                    setState(() => _requireBiometric = v);
                    await StrataSecureSettings.instance.setBiometricRequired(v);
                  },
                ),
                const SizedBox(height: 8),
                CustomButton(
                  label: 'Save Changes',
                  onPressed: _save,
                  icon: Icons.save_outlined,
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
      ),
    );
  }
}
