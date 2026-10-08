import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web3dart/web3dart.dart';

import '../core/constants/chain_config.dart';
import '../models/on_chain_activity.dart';
import '../providers/app_provider.dart';
import '../services/chain_client.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_back_button.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  List<OnChainActivity>? _history;
  String? _historyError;
  bool _historyLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<AppProvider>();
      if (provider.walletCredentials == null) {
        await provider.initWallet();
      }
      if (!mounted) return;
      await provider.refreshWalletBalances();
      await _loadHistory();
    });
  }

  Future<void> _refresh() async {
    final provider = context.read<AppProvider>();
    if (provider.walletCredentials == null) {
      await provider.initWallet();
    }
    await provider.refreshWalletBalances();
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    final provider = context.read<AppProvider>();
    final creds = provider.walletCredentials;
    if (creds == null || !ChainConfig.isOnChainEnabled) {
      if (!mounted) return;
      setState(() {
        _history = const [];
        _historyError = ChainConfig.isOnChainEnabled
            ? null
            : 'On-chain history requires STRATA_TOKEN + SESSION_ESCROW dart-defines.';
        _historyLoading = false;
      });
      return;
    }
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final items = await provider.fetchOnChainHistory();
      if (!mounted) return;
      setState(() {
        _history = items;
        _historyLoading = false;
      });
    } on ChainClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _historyError = e.reason;
        _historyLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _historyError = 'Unable to load on-chain history.';
        _historyLoading = false;
      });
    }
  }

  String _truncate(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 6)}…${addr.substring(addr.length - 4)}';
  }

  String _matic(BigInt wei) {
    final amount = EtherAmount.fromBigInt(EtherUnit.wei, wei);
    return amount.getValueInUnit(EtherUnit.ether).toStringAsFixed(4);
  }

  String _strata(BigInt? wei) {
    if (wei == null) return '—';
    final amount = EtherAmount.fromBigInt(EtherUnit.wei, wei);
    return amount.getValueInUnit(EtherUnit.ether).toStringAsFixed(4);
  }

  String _explorerTx(String hash) {
    if (ChainConfig.chainId == 31337) {
      return hash; // local Hardhat — no public explorer
    }
    return 'https://amoy.polygonscan.com/tx/$hash';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final credentials = provider.walletCredentials;
    final info = provider.walletInfo;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(),
        title: const Text('Wallet'),
        actions: [
          IconButton(
            icon: provider.walletBalancesLoading || _historyLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: (provider.walletBalancesLoading || _historyLoading)
                ? null
                : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (credentials == null)
              _noWalletCard(context)
            else ...[
              _addressCard(credentials.hexAddress),
              const SizedBox(height: 16),
              _balancesCard(info),
              if (ChainConfig.isOnChainEnabled) ...[
                const SizedBox(height: 16),
                _testnetFaucetCard(context, provider),
              ],
            ],
            const SizedBox(height: 16),
            const Text(
              'On-chain history',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            _historySection(),
          ],
        ),
      ),
    );
  }

  Widget _historySection() {
    if (_historyLoading && _history == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text(
                'Loading on-chain history…',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    if (_historyError != null && (_history == null || _history!.isEmpty)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _historyError!,
            style: const TextStyle(color: AppColors.error),
          ),
          TextButton(
            onPressed: _loadHistory,
            child: const Text('Retry'),
          ),
        ],
      );
    }
    final items = _history ?? const <OnChainActivity>[];
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No on-chain transactions yet.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    return Column(
      children: [
        if (_historyError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _historyError!,
              style: const TextStyle(color: AppColors.error, fontSize: 12),
            ),
          ),
        ...items.map(_historyTile),
      ],
    );
  }

  Widget _historyTile(OnChainActivity a) {
    final title = switch (a.kind) {
      OnChainActivityKind.tokenTransfer =>
        a.direction == OnChainDirection.incoming
            ? 'STRATA received'
            : 'STRATA sent',
      OnChainActivityKind.paymentSettled =>
        a.direction == OnChainDirection.settlement
            ? 'Session settlement (host)'
            : 'Session settlement (guest)',
    };
    final amount = _strata(a.amountWei);
    final sign = a.direction == OnChainDirection.outgoing ? '−' : '+';
    final when = a.timestamp?.toLocal().toString().split('.').first ??
        (a.blockNumber != null ? 'block ${a.blockNumber}' : '—');
    final hash = a.txHash;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$sign$amount STRATA',
                style: TextStyle(
                  color: a.direction == OnChainDirection.outgoing
                      ? AppColors.textPrimary
                      : AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${a.status.name} · $when',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          if (a.sessionId != null)
            Text(
              'Session #${a.sessionId}',
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          if (hash.isNotEmpty)
            InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: hash));
                if (ChainConfig.chainId != 31337) {
                  final uri = Uri.parse(_explorerTx(hash));
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ChainConfig.chainId == 31337
                          ? 'Tx hash copied'
                          : 'Opening explorer…',
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _truncate(hash),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _noWalletCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No wallet on this device',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Sign in and follow the wallet setup flow to create or import one.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _addressCard(String address) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Address',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _truncate(address),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, color: AppColors.primary),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: address));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied')),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _balancesCard(walletInfo) {
    final BigInt native = walletInfo?.nativeBalanceWei ?? BigInt.zero;
    final BigInt? token = walletInfo?.tokenBalanceWei;
    final nativeLabel = ChainConfig.chainId == 31337 ? 'ETH (local)' : 'MATIC';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            nativeLabel,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            '${_matic(native)} $nativeLabel',
            style: const TextStyle(
              color: AppColors.primary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'STRATA',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            token == null ? '—' : '${_strata(token)} STRATA',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _testnetFaucetCard(BuildContext context, AppProvider provider) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Testnet faucet (demo only)',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Claims STRT via the on-chain faucet() on the configured network. '
            'This is not a payment method and is rate-limited on-chain.',
            style: TextStyle(color: AppColors.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: provider.walletBalancesLoading
                ? null
                : () async {
                    try {
                      final tx = await provider.claimTestnetFaucet();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Faucet tx submitted: $tx')),
                      );
                      await _loadHistory();
                    } on ChainClientException catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Faucet failed: ${e.reason}')),
                      );
                    } on WalletNotFoundException {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('No wallet on this device.')),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Faucet error: $e')),
                      );
                    }
                  },
            icon: const Icon(Icons.water_drop_outlined, size: 18),
            label: const Text('Claim test STRT'),
          ),
        ],
      ),
    );
  }
}
