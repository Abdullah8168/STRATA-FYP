import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/otp_input.dart';
import '../../widgets/custom_button.dart';
import '../../providers/app_provider.dart';

class OtpScreen extends StatefulWidget {
  final String role;
  final String contact;

  const OtpScreen({super.key, required this.role, required this.contact});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  String _otp = '';
  bool _loading = false;
  bool _resent = false;
  int _secondsRemaining = 30;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _secondsRemaining = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_secondsRemaining == 0) {
        t.cancel();
      } else {
        setState(() => _secondsRemaining--);
      }
    });
  }

  Future<void> _verify() async {
    if (_otp.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a 6-digit OTP'),
          backgroundColor: AppColors.primaryDark,
        ),
      );
      return;
    }
    setState(() => _loading = true);
    final provider = context.read<AppProvider>();
    try {
      final ok = await provider.verifyOtp(_otp);
      if (!mounted) return;
      if (!ok) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid OTP. Please try again.'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }
      // Phase D: detour through wallet creation when no wallet is on device.
      // initWallet is idempotent — calling it here guarantees the credentials
      // are hydrated for whatever screen we navigate to next, which avoids
      // the wallet appearing "missing" right after a page refresh on web.
      await provider.initWallet();
      final hasWallet = await provider.walletService.hasWallet();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verified successfully!')),
      );
      setState(() => _loading = false);
      if (!hasWallet) {
        context.go('/wallet/create-intro');
        return;
      }
      if (widget.role == 'host') {
        context.go('/host/onboarding');
      } else {
        context.go('/guest/location');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Verification failed: $error'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final isRealOtp = provider.usedRealOtp;
    final displayContact = widget.contact.isEmpty ? '•••@strata.io' : widget.contact;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => context.go('/login/${widget.role}'),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.lock_open_outlined,
                  color: AppColors.primary,
                  size: 36,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Verify OTP',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                    height: 1.5,
                  ),
                  children: [
                    TextSpan(
                      text: isRealOtp
                          ? 'A 6-digit code was sent to\n'
                          : 'Enter the 6-digit verification code for\n',
                    ),
                    TextSpan(
                      text: displayContact,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (isRealOtp)
                      const TextSpan(text: '\nCheck your inbox (and spam folder)'),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              OtpInput(
                onCompleted: (otp) => setState(() => _otp = otp),
              ),
              const SizedBox(height: 36),
              CustomButton(
                label: 'Verify & Continue',
                onPressed: _verify,
                loading: _loading,
              ),
              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: _secondsRemaining > 0
                      ? null
                      : () {
                          setState(() => _resent = true);
                          final provider = context.read<AppProvider>();
                          provider
                              .sendOtp(
                                email: widget.contact.contains('@')
                                    ? widget.contact
                                    : '',
                                phone: widget.contact.contains('@')
                                    ? ''
                                    : widget.contact,
                              )
                              .then((_) {
                            if (!mounted) return;
                            _startTimer();
                            Future.delayed(const Duration(seconds: 1), () {
                              if (mounted) {
                                setState(() => _resent = false);
                              }
                            });
                          });
                        },
                  child: Text(
                    _secondsRemaining > 0
                        ? 'Resend in ${_secondsRemaining}s'
                        : (_resent ? 'OTP Resent ✓' : 'Resend OTP'),
                    style: TextStyle(
                      color: _resent ? AppColors.primary : AppColors.textSecondary,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
