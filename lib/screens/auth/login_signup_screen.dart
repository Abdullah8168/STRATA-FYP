import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/custom_text_field.dart';
import '../../providers/app_provider.dart';
import '../../models/user_model.dart';
import '../../utils/validators.dart';

class LoginSignupScreen extends StatefulWidget {
  final String role;

  const LoginSignupScreen({super.key, required this.role});

  @override
  State<LoginSignupScreen> createState() => _LoginSignupScreenState();
}

class _LoginSignupScreenState extends State<LoginSignupScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _loginContactController = TextEditingController();

  // Sign up controllers
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _dobController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _signupSendToPhone = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _loginContactController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final isSignup = _tabController.index == 1;
    final provider = context.read<AppProvider>();

    String email;
    String phone;
    String otpEmail;
    String otpPhone;
    String displayName;

    if (isSignup) {
      email = _emailController.text.trim();
      phone = _phoneController.text.trim();
      otpEmail = _signupSendToPhone ? '' : email;
      otpPhone = _signupSendToPhone ? phone : '';
      displayName =
          '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}';
    } else {
      final contact = _loginContactController.text.trim();
      if (contact.contains('@')) {
        email = contact;
        phone = '';
        otpEmail = contact;
        otpPhone = '';
      } else {
        email = '';
        phone = contact;
        otpEmail = '';
        otpPhone = contact;
      }
      displayName = 'User';
    }

    provider.setUser(
      UserModel(
        id: '1',
        name: displayName.isEmpty ? 'Demo User' : displayName,
        email: email,
        phone: phone,
        role: widget.role,
      ),
    );
    provider.setRole(widget.role);

    provider.sendOtp(email: otpEmail, phone: otpPhone).then((_) {
      if (!mounted) return;
      setState(() => _loading = false);

      if (provider.usedRealOtp) {
        final target = provider.useEmailOtp ? 'email' : 'phone';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('OTP sent to your $target — check your inbox')),
        );
      } else {
        if (kDebugMode) {
          final demoOtp = provider.lastOtpCode;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Debug mock OTP: $demoOtp')),
          );
        }
      }

      final contactLabel = otpEmail.isNotEmpty ? otpEmail : otpPhone;
      final uri = Uri(
        path: '/otp/${widget.role}',
        queryParameters: {'contact': contactLabel},
      );
      context.go(uri.toString());
    }).catchError((error) {
      if (!mounted) return;
      setState(() => _loading = false);

      final demoOtp = provider.lastOtpCode;
      if (kDebugMode) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not send OTP. Debug mock code: $demoOtp'),
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not send OTP: $error'),
            duration: const Duration(seconds: 5),
          ),
        );
      }

      final contactLabel = otpEmail.isNotEmpty ? otpEmail : otpPhone;
      final uri = Uri(
        path: '/otp/${widget.role}',
        queryParameters: {'contact': contactLabel},
      );
      context.go(uri.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    final isHost = widget.role == 'host';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => context.go('/role'),
        ),
        title: Row(
          children: [
            const Text('Sign In  '),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(25),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.primary),
              ),
              child: Text(
                isHost ? 'HOST' : 'GUEST',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Text(
                isHost ? 'Host your\nbandwidth' : 'Connect to the\nnetwork',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter your details to continue',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 18),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelColor: Colors.black,
                  unselectedLabelColor: AppColors.textSecondary,
                  labelStyle: const TextStyle(fontWeight: FontWeight.w600),
                  dividerColor: Colors.transparent,
                  tabs: const [
                    Tab(text: 'Login'),
                    Tab(text: 'Sign Up'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    // TabBarView inside a scroll view can hit unbounded-height
                    // layout exceptions on some platforms. Since we don't allow
                    // swipe anyway, use IndexedStack for a stable layout.
                    AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        if (_tabController.index == 0) {
                          return Column(
                            children: [
                              CustomTextField(
                                label: 'Email or Phone Number',
                                controller: _loginContactController,
                                keyboardType: TextInputType.emailAddress,
                                prefixIcon: const Icon(Icons.alternate_email),
                                validator: (v) => (v == null || v.isEmpty)
                                    ? 'Email or phone is required'
                                    : null,
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            CustomTextField(
                              label: 'First Name',
                              controller: _firstNameController,
                              prefixIcon: const Icon(Icons.person_outline),
                              validator: (v) => _tabController.index == 1
                                  ? Validators.requiredMin(v, 2, 'First name')
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            CustomTextField(
                              label: 'Last Name',
                              controller: _lastNameController,
                              prefixIcon: const Icon(Icons.person_outline),
                              validator: (v) => _tabController.index == 1
                                  ? Validators.requiredMin(v, 2, 'Last name')
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            CustomTextField(
                              label: 'Email Address',
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              prefixIcon: const Icon(Icons.email_outlined),
                              validator: (v) => _tabController.index == 1
                                  ? Validators.email(v)
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            CustomTextField(
                              label: 'Phone Number',
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              prefixIcon:
                                  const Icon(Icons.phone_iphone_outlined),
                              validator: (v) => _tabController.index == 1
                                  ? Validators.phone(v)
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            CustomTextField(
                              label: 'Date of Birth (YYYY-MM-DD)',
                              controller: _dobController,
                              keyboardType: TextInputType.datetime,
                              prefixIcon: const Icon(Icons.cake_outlined),
                              validator: (v) => _tabController.index == 1
                                  ? Validators.date(v)
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.divider),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Send OTP To',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ChoiceChip(
                                          label: const Text('Phone'),
                                          selected: _signupSendToPhone,
                                          onSelected: (_) {
                                            setState(() {
                                              _signupSendToPhone = true;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: ChoiceChip(
                                          label: const Text('Email'),
                                          selected: !_signupSendToPhone,
                                          onSelected: (_) {
                                            setState(() {
                                              _signupSendToPhone = false;
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                    CustomButton(
                      label: 'Send OTP',
                      onPressed: _submit,
                      loading: _loading,
                      icon: Icons.send_outlined,
                    ),
                    const SizedBox(height: 10),
                    if (kDebugMode) ...[
                      const Row(
                        children: [
                          Expanded(child: Divider(color: AppColors.divider)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              'or',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ),
                          Expanded(child: Divider(color: AppColors.divider)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      CustomButton(
                        label: 'Continue as Demo User',
                        onPressed: () {
                          context.read<AppProvider>().setUser(UserModel(
                                id: 'demo',
                                name: 'Demo User',
                                email: 'demo@strata.io',
                                phone: '+1234567890',
                                role: widget.role,
                              ));
                          context.read<AppProvider>().setRole(widget.role);
                          if (widget.role == 'host') {
                            context.go('/host/onboarding');
                          } else {
                            context.go('/guest/location');
                          }
                        },
                        outlined: true,
                        icon: Icons.play_arrow_outlined,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
