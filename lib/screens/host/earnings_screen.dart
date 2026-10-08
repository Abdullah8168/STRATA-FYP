import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../services/host_api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_back_button.dart';

/// Optional FX for local display only — not an on-chain price oracle.
const double _kPkrPerStrt = 290;

class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  List<Map<String, dynamic>> _rows = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<AppProvider>().hostApiService;
    try {
      final list = await api.fetchHostSessions();
      if (!mounted) return;
      setState(() {
        _rows = list;
        _error = null;
        _loading = false;
      });
    } on HostApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  double _strtFromWei(String? w) {
    final v = BigInt.tryParse(w ?? '0') ?? BigInt.zero;
    return v.toDouble() / 1e18;
  }

  /// Prefer host-computed `earned_amount_wei` (SessionEscrow formula).
  double _earnedStrt(Map<String, dynamic> row) {
    final earned = row['earned_amount_wei'] as String?;
    if (earned != null && earned.isNotEmpty) {
      return _strtFromWei(earned);
    }
    final legacy = row['strt_amount_wei'] as String?;
    return _strtFromWei(legacy);
  }

  String _short(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 6)}…${addr.substring(addr.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    final totalStrt = _rows.fold<double>(0, (s, r) => s + _earnedStrt(r));
    final totalPkr = totalStrt * _kPkrPerStrt;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(to: '/host/dashboard'),
        title: const Text('Earnings'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!,
                          style: const TextStyle(color: AppColors.error)),
                    ),
                  Container(
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
                        Text(
                          '${totalStrt.toStringAsFixed(4)} STRATA',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '≈ Rs ${totalPkr.toStringAsFixed(0)} (display FX only)',
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Earned amounts use SessionEscrow settlement math: '
                          'escrow × min(bytes, quota) / quota from GET /host/sessions. '
                          'Zero is correct when no sessions have run yet.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: _rows.isEmpty
                        ? const Center(
                            child: Text(
                              'No session earnings yet.',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _rows.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final row = _rows[index];
                              final wallet =
                                  (row['guest_wallet_address'] as String?) ?? '';
                              final status =
                                  (row['status'] as String?) ?? 'unknown';
                              final used =
                                  (row['bytes_used'] as num?)?.toInt() ?? 0;
                              final quota =
                                  (row['quota_bytes'] as num?)?.toInt() ?? 0;
                              final strt = _earnedStrt(row);
                              final escrow = row['escrow_amount_wei'] as String?;
                              return Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppColors.card,
                                  borderRadius: BorderRadius.circular(12),
                                  border:
                                      Border.all(color: AppColors.divider),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _short(wallet),
                                            style: const TextStyle(
                                              color: AppColors.textPrimary,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${strt.toStringAsFixed(4)} STRATA',
                                          style: const TextStyle(
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '$status · $used / $quota bytes'
                                      '${escrow != null ? ' · lock ${_strtFromWei(escrow).toStringAsFixed(4)}' : ''}',
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
