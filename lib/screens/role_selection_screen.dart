import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/settings/strata_secure_settings.dart';
import '../theme/app_theme.dart';

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowRolesIntro());
  }

  Future<void> _maybeShowRolesIntro() async {
    if (!mounted) return;
    if (await StrataSecureSettings.instance.hasSeenRolesIntro()) return;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final page = PageController();
        final step = ValueNotifier<int>(0);
        return AlertDialog(
          backgroundColor: AppColors.surface,
          content: SizedBox(
            width: 320,
            height: 340,
            child: Column(
              children: [
                const Text(
                  'How STRATA roles work',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: PageView(
                    controller: page,
                    onPageChanged: (i) => step.value = i,
                    children: [
                      _introSlide(
                        title: 'Hosts',
                        body:
                            'Run a gateway that meters Wi‑Fi bandwidth and settles STRATA payouts from guests who buy data bundles.',
                      ),
                      _introSlide(
                        title: 'Guests',
                        body:
                            'Discover hosts on LAN or curated demo nodes, stake STRATA on-chain where enabled, then surf with live quota metering.',
                      ),
                      _introSlide(
                        title: 'Non-custodial wallet',
                        body:
                            'STRATA keeps your keys on-device. OTP unlocks onboarding; you always control your recovery phrase.',
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: step,
                  builder: (_, i, __) =>
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          3,
                          (j) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(
                              j == i ? Icons.circle : Icons.circle_outlined,
                              size: 10,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<int>(
                  valueListenable: step,
                  builder: (_, i, __) => Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Skip'),
                      ),
                      const Spacer(),
                      ElevatedButton(
                        onPressed: () {
                          if (i < 2) {
                            page.nextPage(
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOut,
                            );
                            return;
                          }
                          Navigator.of(ctx).pop();
                        },
                        child: Text(i < 2 ? 'Next' : 'Done'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    await StrataSecureSettings.instance.markRolesIntroSeen();
  }

  Widget _introSlide({required String title, required String body}) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: const TextStyle(
              color: AppColors.textSecondary,
              height: 1.45,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxHeight - 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: constraints.maxHeight < 720 ? 12 : 24),
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(25),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.primary,
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(Icons.hub,
                              color: AppColors.primary, size: 20),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'STRATA',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 3,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: constraints.maxHeight < 720 ? 24 : 40),
                    const Text(
                      'Welcome to\nSTRATA',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 38,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Choose how you want to participate\nin the decentralized bandwidth network.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),
                    SizedBox(height: constraints.maxHeight < 720 ? 20 : 36),
                    LayoutBuilder(builder: (context, lc) {
                      if (lc.maxWidth > 500) {
                        return Row(
                          children: [
                            Expanded(child: _buildRoleCard(context, 'host')),
                            const SizedBox(width: 16),
                            Expanded(child: _buildRoleCard(context, 'guest')),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          _buildRoleCard(context, 'host'),
                          const SizedBox(height: 16),
                          _buildRoleCard(context, 'guest'),
                        ],
                      );
                    }),
                    SizedBox(height: constraints.maxHeight < 720 ? 20 : 32),
                    Center(
                      child: Text(
                        'Powered by STRATA Protocol v1.0',
                        style: TextStyle(
                          color: AppColors.textSecondary.withAlpha(100),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRoleCard(BuildContext context, String role) {
    final isHost = role == 'host';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.go('/login/$role'),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.primary.withAlpha(100),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withAlpha(20),
                blurRadius: 20,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  isHost ? Icons.router : Icons.person_pin_circle,
                  color: AppColors.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isHost ? 'HOST' : 'GUEST',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                isHost
                    ? 'Share your bandwidth,\nearn crypto rewards'
                    : 'Find nearby networks,\nbuy data securely',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                isHost
                    ? 'Set up your node, configure pricing and start earning STRATA tokens passively.'
                    : 'Connect to nearby peer-hosted networks with pay-per-use data packages.',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              const Row(
                children: [
                  Text(
                    'Get Started',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(Icons.arrow_forward, color: AppColors.primary, size: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
