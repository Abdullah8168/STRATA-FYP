import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:web3dart/web3dart.dart';

import '../../core/constants/chain_config.dart';
import 'package:flutter/services.dart';
import '../../providers/app_provider.dart';
import '../../services/host_api_service.dart';
import '../../services/wallet_service.dart';
import '../../services/chain_client.dart';
import '../../services/pending_payment_store.dart';
import '../../theme/app_theme.dart';
import '../../utils/biometric_prompt.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/custom_text_field.dart';

/// Payment screen.
///
/// **Iteration 2 (default):** sign EIP-191 session message → POST /session/start
/// → host admits MAC (CHAIN_ENABLED=false). No Amoy escrow.
///
/// **Iteration 3+ (when contracts are dart-defined):** also approve STRT,
/// SessionEscrow.openSession, then wait for host chain confirmation.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

enum _StepState { pending, running, done, error }

class _PaymentStep {
  final String label;
  final String inFlight;
  _StepState state;
  String? error;
  _PaymentStep(this.label, this.inFlight) : state = _StepState.pending;
}

class _PaymentScreenState extends State<PaymentScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = false;
  Object? _failureDetail;
  String? _activeSessionId;
  late final List<_PaymentStep> _steps;
  // Card tab is debug-only; production builds hide it.
  final _cardController = TextEditingController(text: '4242 4242 4242 4242');
  final _expiryController = TextEditingController(text: '12/27');
  final _cvvController = TextEditingController(text: '•••');

  @override
  void initState() {
    super.initState();
    final tabCount = kDebugMode ? 2 : 1;
    _tabController = TabController(length: tabCount, vsync: this);
    // Iteration 2 default: verified off-chain session start (no Amoy escrow).
    // On-chain steps appear only when STRATA_TOKEN + SESSION_ESCROW are set.
    _steps = ChainConfig.isOnChainEnabled
        ? [
            _PaymentStep('Sign session message', 'Signing…'),
            _PaymentStep('Reserve session on host', 'Reserving…'),
            _PaymentStep('Approve STRT for escrow', 'Approving…'),
            _PaymentStep('Open on-chain session', 'Opening…'),
            _PaymentStep('Wait for host confirmation', 'Confirming…'),
          ]
        : [
            _PaymentStep('Sign session message', 'Signing…'),
            _PaymentStep('Start session on host', 'Starting…'),
            _PaymentStep('Admit through firewall', 'Admitting…'),
          ];
    Future.microtask(() async {
      if (!mounted) return;
      final provider = context.read<AppProvider>();
      if (provider.walletCredentials == null) {
        await provider.initWallet();
      }
      if (!mounted) return;
      provider.refreshWalletBalances();
      // Resume interrupted on-chain payment if present.
      final pending = await provider.loadPendingPayment();
      if (!mounted || pending == null || pending.sessionId == null) return;
      if (!ChainConfig.isOnChainEnabled) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Incomplete payment found (step: ${pending.failedAt.name}). '
            'Tap Confirm Payment to resume.',
          ),
          action: SnackBarAction(
            label: 'Discard',
            onPressed: () => provider.clearPendingPayment(),
          ),
        ),
      );
      setState(() {
        _activeSessionId = pending.sessionId;
      });
    });
  }

  void _setStepState(int idx, _StepState state, [String? error]) {
    if (!mounted) return;
    setState(() {
      _steps[idx].state = state;
      if (error != null) _steps[idx].error = error;
    });
  }

  void _resetSteps() {
    setState(() {
      for (final s in _steps) {
        s.state = _StepState.pending;
        s.error = null;
      }
      _activeSessionId = null;
      _failureDetail = null;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _cardController.dispose();
    _expiryController.dispose();
    _cvvController.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    final provider = context.read<AppProvider>();
    final host = provider.selectedHost;
    if (host == null) return;
    final credentials = provider.walletCredentials;
    if (credentials == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No wallet on this device.')),
      );
      return;
    }
    _resetSteps();
    _failureDetail = null;
    final ok = await requireBiometricOrDialog(
      context,
      reason: 'Authorize payment',
    );
    if (!ok || !mounted) return;
    setState(() {
      _loading = true;
      _failureDetail = null;
    });

    final overall = Stopwatch()..start();
    const totalBudget = Duration(seconds: 90);

    try {
      const oneGiB = 1024 * 1024 * 1024;
      final quotaBytes = provider.selectedQuota * oneGiB;

      // Resume path: reuse reserved session when PendingPaymentStore has one.
      final pending = await provider.loadPendingPayment();
      final resume = pending != null &&
          pending.sessionId != null &&
          pending.sessionRefHex != null &&
          pending.hostWallet != null &&
          pending.hostWallet!.toLowerCase() == host.walletAddress.toLowerCase() &&
          ChainConfig.isOnChainEnabled;

      late final dynamic start;
      if (resume) {
        _activeSessionId = pending!.sessionId;
        _setStepState(0, _StepState.done);
        _setStepState(1, _StepState.done);
        start = _ResumeStart(
          sessionId: pending.sessionId!,
          sessionRef: pending.sessionRefHex,
        );
      } else {
        _setStepState(0, _StepState.running);
        _setStepState(1, _StepState.running);
        start = await provider.startPaidSession(
          hostWalletAddress: host.walletAddress,
          quotaBytes: quotaBytes,
          pricePerGbWei: host.pricePerGbWei,
        );
        _activeSessionId = start.sessionId as String;
        _setStepState(0, _StepState.done);
        _setStepState(1, _StepState.done);
        if (ChainConfig.isOnChainEnabled && start.sessionRef != null) {
          await provider.pendingPaymentStore.save(
            PendingPaymentSnapshot(
              failedAt: PaymentPipelineStep.approve,
              sessionId: start.sessionId as String,
              sessionRefHex: start.sessionRef as String?,
              nonce: null,
              hostWallet: host.walletAddress,
              quotaBytes: quotaBytes,
              pricePerGbWei: host.pricePerGbWei,
              approveUnlimited: true,
              amountWei: _resolvePaymentAmountWei(
                quotaBytes: quotaBytes,
                pricePerGbWei: host.pricePerGbWei,
              ),
            ),
          );
        }
      }

      if (ChainConfig.isOnChainEnabled) {
        final ref = start.sessionRef as String?;
        if (ref == null || ref.isEmpty) {
          throw const _PaymentFailedException(
            'Host did not return session_ref — cannot open on-chain escrow. '
            'Ensure CHAIN_ENABLED=true on the host.',
          );
        }
        final amountWei = pending?.amountWei ??
            _resolvePaymentAmountWei(
              quotaBytes: quotaBytes,
              pricePerGbWei: host.pricePerGbWei,
            );
        _setStepState(2, _StepState.running);
        try {
          final txHash = await provider.executeOnChainOpenSession(
            sessionId: start.sessionId as String,
            sessionRefHex: ref,
            hostWalletAddress: host.walletAddress,
            amountWei: amountWei,
            approveTxHash: pending?.approveTxHash,
            openTxHash: pending?.openTxHash,
          );
          _setStepState(2, _StepState.done);
          _setStepState(3, _StepState.done);
          _setStepState(4, _StepState.running);
          if (overall.elapsed > totalBudget) {
            throw _ChainTimeoutException(
              'Payment took longer than 90 seconds. Tx hash: ${_short(txHash)}.',
            );
          }
          final remaining = totalBudget - overall.elapsed;
          final finalStatus = await provider.waitForSessionActive(
            sessionId: start.sessionId as String,
            timeout: remaining,
          );
          if (finalStatus != 'active') {
            throw _ChainTimeoutException(
              'Session did not activate after on-chain payment. '
              'Tx: ${_short(txHash)}. Last status: $finalStatus.',
            );
          }
          _setStepState(4, _StepState.done);
          await provider.clearPendingPayment();
        } on ChainClientException catch (e) {
          for (int i = 2; i < _steps.length; i++) {
            if (_steps[i].state == _StepState.running) {
              _setStepState(i, _StepState.error, e.reason);
              break;
            }
          }
          _failWith('Chain error: ${e.reason}', e);
          return;
        }
      } else {
        // Iteration 2 — admit already happened inside POST /session/start.
        if (_steps.length > 2) {
          _setStepState(2, _StepState.done);
        }
        await provider.clearPendingPayment();
      }

      if (!mounted) return;
      await provider.persistActiveGuestSession();
      setState(() => _loading = false);
      context.go('/guest/dashboard');
    } on _ChainTimeoutException catch (e) {
      _failWith(e.message);
    } on _PaymentFailedException catch (e) {
      _failWith(e.message);
    } on HostApiException catch (e) {
      _failWith('Host node error: ${e.message}', e);
    } on WalletNotFoundException {
      _failWith('No wallet on this device.');
    } on WalletSigningException catch (e) {
      _failWith('Signing failed: ${e.reason}', e);
    } catch (e) {
      _failWith('Could not complete payment: ${e.runtimeType}');
    }
  }


  Future<void> _cancelSession() async {
    final id = _activeSessionId;
    if (id == null) return;
    try {
      await context.read<AppProvider>().hostApiService.stopSession(
            sessionId: id,
            reason: StopReason.guestStopped,
          );
    } on HostApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not cancel: ${e.code}')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Session cancelled.')),
    );
    setState(() {
      _activeSessionId = null;
      _loading = false;
    });
  }

  void _failWith(String msg, [Object? detail]) {
    if (!mounted) return;
    _failureDetail = detail ?? msg;
    // Mark the running step (if any) as failed so the user sees where
    // the flow broke.
    for (int i = 0; i < _steps.length; i++) {
      if (_steps[i].state == _StepState.running) {
        _steps[i].state = _StepState.error;
        _steps[i].error = msg;
        break;
      }
    }
    setState(() {
      _loading = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _buildStepsList() {
    return Column(
      children: List.generate(_steps.length, (i) {
        final step = _steps[i];
        Widget icon;
        Color color;
        switch (step.state) {
          case _StepState.pending:
            color = AppColors.textSecondary;
            icon = const Icon(Icons.radio_button_unchecked,
                color: AppColors.textSecondary, size: 18);
            break;
          case _StepState.running:
            color = AppColors.primary;
            icon = const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            );
            break;
          case _StepState.done:
            color = const Color(0xFF22C55E);
            icon = const Icon(Icons.check_circle,
                color: Color(0xFF22C55E), size: 18);
            break;
          case _StepState.error:
            color = const Color(0xFFEF4444);
            icon = const Icon(Icons.error,
                color: Color(0xFFEF4444), size: 18);
            break;
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 22, child: Center(child: icon)),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}. ${step.label}',
                      style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: step.state == _StepState.running
                              ? FontWeight.w700
                              : FontWeight.w500),
                    ),
                    if (step.state == _StepState.running)
                      Text(step.inFlight,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 11)),
                    if (step.state == _StepState.error && step.error != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              step.error!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(0xFFEF4444), fontSize: 11),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              final d = _failureDetail;
                              late String clip;
                              if (d is HostApiException) {
                                clip =
                                    '${d.code}\n${d.message}\nrequest_id: ${d.requestId ?? ''}';
                              } else {
                                clip = step.error!;
                              }
                              await Clipboard.setData(ClipboardData(text: clip));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Details copied')),
                              );
                            },
                            child: const Text('Copy details',
                                style: TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  /// Phase E payment amount in wei. Falls back to a price-based estimate
  /// when the host hasn't set a per-GB rate.
  BigInt _resolvePaymentAmountWei({
    required int quotaBytes,
    required String pricePerGbWei,
  }) {
    final perGb = BigInt.tryParse(pricePerGbWei) ?? BigInt.zero;
    if (perGb == BigInt.zero) {
      // Default: 1 STRT per GiB so the demo always has SOMETHING to escrow.
      const oneGiB = 1024 * 1024 * 1024;
      return BigInt.from(quotaBytes ~/ oneGiB) * BigInt.from(10).pow(18);
    }
    const oneGB = 1000000000;
    final gigabytes = BigInt.from(quotaBytes ~/ oneGB);
    return perGb * gigabytes;
  }

  String _short(String s) => s.length > 12 ? '${s.substring(0, 10)}…' : s;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final host = provider.selectedHost;
    if (host == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
            onPressed: () => context.go('/guest/nearby'),
          ),
          title: const Text('Complete Payment'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.payment_outlined,
                    color: AppColors.textSecondary, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Missing session details',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Please select a host and package before paying.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => context.go('/guest/nearby'),
                    child: const Text('Start Again'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final quota = provider.selectedQuota;
    final total = (quota * host.pricePerGB).toStringAsFixed(2);
    final BigInt nativeWei =
        provider.walletInfo?.nativeBalanceWei ?? BigInt.zero;
    final maticDisplay = EtherAmount.fromBigInt(EtherUnit.wei, nativeWei)
        .getValueInUnit(EtherUnit.ether)
        .toStringAsFixed(4);

    final tabs = <Tab>[
      const Tab(text: 'STRATA Wallet'),
      if (kDebugMode) const Tab(text: 'Card (debug)'),
    ];
    final tabViews = <Widget>[
      _buildWalletTab(maticDisplay, total),
      if (kDebugMode) _buildCardTab(),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon:
              const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => context.go('/guest/quota'),
        ),
        title: const Text('Complete Payment'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Order Summary',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _buildOrderRow('Host', host.name),
                          _buildOrderRow('Data Package', '$quota GB'),
                          _buildOrderRow('Rate', 'Rs ${host.pricePerGB}/GB'),
                          _buildOrderRow('Host wallet',
                              _truncate(host.walletAddress)),
                          if (ChainConfig.isOnChainEnabled)
                            _buildOrderRow('Settlement', 'On-chain (Amoy)'),
                          const Divider(color: AppColors.divider, height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                'Rs $total',
                                style: const TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Payment Method',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
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
                        labelStyle:
                            const TextStyle(fontWeight: FontWeight.w600),
                        dividerColor: Colors.transparent,
                        tabs: tabs,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 180,
                      child: TabBarView(
                        controller: _tabController,
                        children: tabViews,
                      ),
                    ),
                    if (_loading || _activeSessionId != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Payment progress',
                              style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11,
                                  letterSpacing: 1.2),
                            ),
                            const SizedBox(height: 6),
                            _buildStepsList(),
                            if (_activeSessionId != null && _loading) ...[
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: _cancelSession,
                                  icon: const Icon(Icons.cancel_outlined,
                                      size: 16),
                                  label: const Text('Cancel session'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              color: AppColors.surface,
              child: CustomButton(
                label: 'Confirm Payment',
                onPressed: _pay,
                loading: _loading,
                icon: Icons.lock_outlined,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _truncate(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 6)}…${addr.substring(addr.length - 4)}';
  }

  Widget _buildOrderRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14)),
          Text(value,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildWalletTab(String maticDisplay, String total) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet,
                  color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              const Text(
                'STRATA Wallet',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$maticDisplay MATIC',
                  style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            ChainConfig.isOnChainEnabled
                ? 'On-chain settlement is wired up. Confirming payment will '
                    'approve STRT for the escrow and call openSession() on '
                    'Polygon Amoy. The host admits your MAC after the '
                    'SessionOpened event lands.'
                : 'Iteration 2: Confirming signs a session message with your '
                    'BIP-39 wallet and POSTs /session/start. The host verifies '
                    'the signature, resolves your MAC from ARP, and admits you '
                    'through nftables. On-chain escrow is Iteration 3 '
                    '(--dart-define=STRATA_TOKEN + SESSION_ESCROW).',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildCardTab() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          CustomTextField(
            label: 'Card Number',
            controller: _cardController,
            keyboardType: TextInputType.number,
            prefixIcon: const Icon(Icons.credit_card),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CustomTextField(
                  label: 'Expiry (MM/YY)',
                  controller: _expiryController,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CustomTextField(
                  label: 'CVV',
                  controller: _cvvController,
                  obscureText: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResumeStart {
  final String sessionId;
  final String? sessionRef;
  const _ResumeStart({required this.sessionId, required this.sessionRef});
}

class _ChainTimeoutException implements Exception {
  final String message;
  const _ChainTimeoutException(this.message);
}

class _PaymentFailedException implements Exception {
  final String message;
  const _PaymentFailedException(this.message);
}
