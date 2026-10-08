import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sidebar.dart';
import '../../widgets/account_menu_button.dart';
import '../../providers/app_provider.dart';
import '../../core/constants/chain_config.dart';
import '../../services/host_api_service.dart';

class GuestDashboardScreen extends StatefulWidget {
  const GuestDashboardScreen({super.key});

  @override
  State<GuestDashboardScreen> createState() => _GuestDashboardScreenState();
}

class _GuestDashboardScreenState extends State<GuestDashboardScreen> {
  bool _isConnected = true;
  bool _showPassword = false;
  int _rating = 0;
  final _commentController = TextEditingController();
  StreamSubscription<SessionStatus>? _statusSub;
  int _bytesUsed = 0;
  int _quotaBytes = 1;
  bool _terminalNavigationScheduled = false;
  bool _skipTerminalNavForSettle = false;

  // Session clock (replaces the old hard-coded "12:34:56").
  DateTime? _startedAt;
  DateTime? _stoppedAt;
  Timer? _clock;

  // Live speed from the router's byte counters + measured ping to the host.
  final List<({DateTime at, int inB, int outB})> _samples = [];
  double? _downMbps;
  double? _upMbps;
  int? _pingMs;

  /// After Disconnect: keeps fetching /session/status until the router reports
  /// a settlement, so the Settle card always appears (and disappears once the
  /// router settles on its own).
  Timer? _settlePoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<AppProvider>();
      provider.stopSessionMonitor();
      final session = provider.currentSession;
      if (session == null) return;
      const gib = 1024 * 1024 * 1024;
      _quotaBytes =
          session.quotaGb <= 0 ? gib : session.quotaGb * gib;
      setState(() => _startedAt = session.startedAt);
      _clock?.cancel();
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isConnected && _stoppedAt == null) setState(() {});
      });
      _statusSub?.cancel();
      _terminalNavigationScheduled = false;
      final sid = session.id;
      _statusSub = provider.hostApiService.watchStatus(sid).listen((s) async {
        if (!mounted || _terminalNavigationScheduled) return;
        final hist = provider.sessionHistoryService;
        // Keep provider settle state in sync (dashboard owns this stream).
        provider.updateHostChainSessionStatus(s);
        setState(() {
          _bytesUsed = s.bytesUsed;
          final qb = s.quotaBytes <= 0 ? _quotaBytes : s.quotaBytes;
          _quotaBytes = qb;
          _isConnected = s.status == 'active';
          if (s.startedAt != null) _startedAt = s.startedAt;
          if (s.status == 'stopped') {
            _stoppedAt = s.stoppedAt ?? _stoppedAt ?? DateTime.now();
          }
          _updateSpeed(s, provider.hostApiService.lastStatusRtt);
        });
        try {
          if (s.status != 'stopped') {
            await hist.updateMetering(sid, s.bytesUsed);
          }
        } catch (_) {/* best-effort */}

        if (s.status != 'stopped' || !mounted) return;

        final needSettle = ChainConfig.isOnChainEnabled &&
            s.chainSessionId != null &&
            (s.hostSettlementSigHex != null && s.hostSettlementSigHex!.isNotEmpty);
        if (needSettle) {
          setState(() => _skipTerminalNavForSettle = true);
          await _statusSub?.cancel();
          _startSettlePoll(provider, sid);
          return;
        }

        if (_skipTerminalNavForSettle) return;
        _terminalNavigationScheduled = true;
        await _statusSub?.cancel();

        await context.read<AppProvider>().clearPersistedGuestSession();
        try {
          await hist.updateOnStop(
            sid,
            bytesUsed: s.bytesUsed,
            reason: s.stopReason ?? 'stopped',
            endedAt: DateTime.now(),
            txHash: s.txHash,
            chainSessionId: s.chainSessionId,
          );
        } catch (_) {}

        if (!mounted) return;
        final r = s.stopReason ?? '';
        final route = r == 'quota_exhausted'
            ? '/guest/revoked?reason=quota'
            : (r == 'host_revoked'
                ? '/guest/revoked?reason=revoked'
                : '/guest/revoked?reason=${Uri.encodeComponent(r)}');
        context.go(route);
      });
    });
  }

  /// Download/upload Mbps over the last ~10 s of polls. The router meters in
  /// batches, so a sliding window gives a steadier figure than poll-to-poll.
  void _updateSpeed(SessionStatus s, Duration? rtt) {
    if (rtt != null) _pingMs = rtt.inMilliseconds;
    if (s.status != 'active') {
      _samples.clear();
      _downMbps = null;
      _upMbps = null;
      _pingMs = null;
      return;
    }
    final now = DateTime.now();
    _samples.add((
      at: now,
      inB: s.bytesIn ?? s.bytesUsed,
      outB: s.bytesOut ?? 0,
    ));
    while (_samples.length > 2 &&
        now.difference(_samples.first.at) > const Duration(seconds: 10)) {
      _samples.removeAt(0);
    }
    if (_samples.length < 2) return;
    final first = _samples.first;
    final last = _samples.last;
    final secs = last.at.difference(first.at).inMilliseconds / 1000;
    if (secs <= 0) return;
    double mbps(int bytes) => (bytes < 0 ? 0 : bytes) * 8 / secs / 1e6;
    _downMbps = mbps(last.inB - first.inB);
    _upMbps = s.bytesOut == null ? null : mbps(last.outB - first.outB);
  }

  Future<void> _refreshSettleStatus(AppProvider provider, String sid) async {
    try {
      final s = await provider.hostApiService.getSessionStatus(sid);
      if (!mounted) return;
      provider.updateHostChainSessionStatus(s);
      setState(() {
        if (s.status == 'stopped') {
          _stoppedAt = s.stoppedAt ?? _stoppedAt;
        }
      });
      if (s.settlementStatus != null) _settlePoll?.cancel();
    } catch (_) {/* host unreachable - next tick retries */}
  }

  void _startSettlePoll(AppProvider provider, String sid) {
    _settlePoll?.cancel();
    _settlePoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshSettleStatus(provider, sid),
    );
  }

  static String _formatDuration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  String get _sessionTimeText {
    final start = _startedAt;
    if (start == null) return '--:--:--';
    return _formatDuration((_stoppedAt ?? DateTime.now()).difference(start));
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _clock?.cancel();
    _settlePoll?.cancel();
    _commentController.dispose();
    super.dispose();
  }

  void _showRatingSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Rate Your Host',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  return IconButton(
                    onPressed: () => setModalState(() => _rating = i + 1),
                    icon: Icon(
                      i < _rating ? Icons.star : Icons.star_border,
                      color: const Color(0xFFFFB300),
                      size: 36,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _commentController,
                maxLines: 3,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Leave a comment (optional)',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.card,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.divider),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final rootContext = this.context;
                    final provider = context.read<AppProvider>();
                    final host = provider.selectedHost;
                    final sess = provider.currentSession;
                    if (host == null || sess == null) {
                      Navigator.pop(rootContext);
                      return;
                    }
                    final userName =
                        provider.currentUser?.name.isNotEmpty == true
                            ? provider.currentUser!.name
                            : 'Guest';
                    if (_rating == 0 &&
                        _commentController.text.trim().isEmpty) {
                      Navigator.pop(rootContext);
                      return;
                    }
                    final stars = _rating == 0 ? 5 : _rating;
                    await provider.ratingService.submitRating(
                      hostId: host.id,
                      hostAddress: host.walletAddress,
                      sessionId: sess.id,
                      stars: stars,
                      comment: _commentController.text.trim(),
                      userId: provider.currentUser?.id ??
                          provider.walletCredentials?.hexAddress ??
                          'guest',
                      userName: userName,
                    );
                    provider.addReview(
                      hostId: host.id,
                      userName: userName,
                      rating: stars,
                      comment: _commentController.text.trim(),
                    );
                    if (!rootContext.mounted) return;
                    Navigator.pop(rootContext);
                    ScaffoldMessenger.of(rootContext).showSnackBar(
                      const SnackBar(
                        content: Text('Thank you for your review.'),
                      ),
                    );
                  },
                  child: const Text('Submit Rating'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final host = provider.selectedHost;
    if (host == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: const Text('Active Session'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_find_outlined, color: AppColors.textSecondary, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'No active session',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Pick a nearby host to start a session and see usage here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => context.go('/guest/nearby'),
                    child: const Text('Find Nearby Hosts'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final quotaGbUi = provider.selectedQuota.toDouble();
    const gibBytes = 1024.0 * 1024 * 1024;
    final denom = _quotaBytes <= 0 ? gibBytes : _quotaBytes.toDouble();
    final usedFraction = (_bytesUsed / denom).clamp(0.0, 1.0);
    final remainingGb =
        ((denom - _bytesUsed) / gibBytes).clamp(0.0, double.infinity);

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 800;
      return Scaffold(
        backgroundColor: AppColors.background,
        drawer: isWide ? null : const Sidebar(role: 'guest', currentRoute: '/guest/dashboard'),
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          leading: isWide
              ? null
              : Builder(
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.menu, color: AppColors.textPrimary),
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                  ),
                ),
          title: const Text('Active Session'),
          actions: [
            TextButton.icon(
              onPressed: _showRatingSheet,
              icon: const Icon(Icons.star_outline, color: AppColors.primary, size: 18),
              label: const Text('Rate Host', style: TextStyle(color: AppColors.primary, fontSize: 13)),
            ),
            const AccountMenuButton(),
          ],
        ),
        body: Row(
          children: [
            if (isWide) const Sidebar(role: 'guest', currentRoute: '/guest/dashboard'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // Connection status card
                    _buildStatusCard(host.name),
                    const SizedBox(height: 16),
                    // Credentials
                    _buildCredentialsCard(host.ssid),
                    const SizedBox(height: 16),
                    // Data usage
                    _buildDataUsageCard(remainingGb, quotaGbUi, usedFraction),
                    const SizedBox(height: 16),
                    // Speed
                    _buildSpeedCard(),
                    const SizedBox(height: 16),
                    _buildOnChainSettleCard(context, provider),
                    const SizedBox(height: 24),
                    // Disconnect button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final sid = provider.currentSession?.id;
                          await provider.stopGuestSession();
                          await _statusSub?.cancel();
                          if (!context.mounted) return;
                          setState(() {
                            _isConnected = false;
                            _stoppedAt ??= DateTime.now();
                            _samples.clear();
                            _downMbps = null;
                            _upMbps = null;
                            _pingMs = null;
                          });
                          final onChain = ChainConfig.isOnChainEnabled && sid != null;
                          if (onChain) {
                            // Fetch the stopped status (with the host's
                            // settlement signature) right away instead of
                            // relying on a poll that the cancel above may
                            // have cut off - this was why Settle only
                            // appeared sometimes.
                            _skipTerminalNavForSettle = true;
                            await _refreshSettleStatus(provider, sid);
                            _startSettlePoll(provider, sid);
                            if (!context.mounted) return;
                          }
                          showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              backgroundColor: AppColors.surface,
                              title: const Text('Disconnected', style: TextStyle(color: AppColors.textPrimary)),
                              content: Text(
                                onChain
                                    ? 'You have been disconnected from the network.\n\nTap OK, then "Settle on-chain" to get your unused balance refunded now. Otherwise the host settles automatically in about 2 minutes.'
                                    : 'You have been disconnected from the network.',
                                style: const TextStyle(color: AppColors.textSecondary),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    context.go('/guest/nearby');
                                  },
                                  child: const Text('Find New Host'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('OK'),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.power_settings_new, size: 18),
                        label: const Text('Disconnect'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error,
                          side: BorderSide(color: AppColors.error.withAlpha(120)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildStatusCard(String hostName) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withAlpha(40),
            AppColors.primaryDark.withAlpha(20),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withAlpha(120)),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: _isConnected ? const Color(0xFF4CAF50) : AppColors.error,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (_isConnected ? const Color(0xFF4CAF50) : AppColors.error).withAlpha(120),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isConnected ? 'CONNECTED' : 'DISCONNECTED',
                  style: TextStyle(
                    color: _isConnected ? const Color(0xFF4CAF50) : AppColors.error,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  hostName,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _sessionTimeText,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Text('Session time', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCredentialsCard(String ssid) {
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
          const Text('Network Credentials', style: TextStyle(color: AppColors.textSecondary, fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 12),
          _buildCredRow('SSID', ssid, false),
          const SizedBox(height: 8),
          _buildCredRow('Password', _showPassword ? 'Str@ta2024!' : '••••••••••••', true),
        ],
      ),
    );
  }

  Widget _buildCredRow(String label, String value, bool hasToggle) {
    return Row(
      children: [
        Text('$label:', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ),
        if (hasToggle)
          IconButton(
            icon: Icon(
              _showPassword ? Icons.visibility_off : Icons.visibility,
              color: AppColors.textSecondary,
              size: 18,
            ),
            onPressed: () => setState(() => _showPassword = !_showPassword),
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
          ),
      ],
    );
  }

  Widget _buildDataUsageCard(double remaining, double quota, double usedFraction) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                'Data Usage',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${remaining.toStringAsFixed(1)} GB remaining',
                style: const TextStyle(color: AppColors.primary, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 100,
                height: 100,
                child: CustomPaint(
                  painter: _CircularProgressPainter(progress: usedFraction),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${(usedFraction * 100).toInt()}%',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Text(
                          'used',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDataItem('Used', '${(quota - remaining).toStringAsFixed(1)} GB', AppColors.primary),
                    const SizedBox(height: 8),
                    _buildDataItem('Remaining', '${remaining.toStringAsFixed(1)} GB', AppColors.accent),
                    const SizedBox(height: 8),
                    _buildDataItem('Total', '${quota.toStringAsFixed(0)} GB', AppColors.textSecondary),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDataItem(String label, String value, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text('$label: ', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildOnChainSettleCard(BuildContext context, AppProvider provider) {
    final st = provider.lastHostChainSessionStatus;
    if (st == null || st.status != 'stopped') return const SizedBox.shrink();

    if (ChainConfig.isOnChainEnabled && st.isSettled) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF4CAF50).withAlpha(120)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              st.settlementStatus == 'closed_by_guest'
                  ? 'Payment settled on-chain. Your unused balance has been refunded.'
                  : 'The host settled this session on-chain. Your unused balance has been refunded.',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                await provider.clearPersistedGuestSession();
                if (!context.mounted) return;
                context.go('/guest/nearby');
              },
              child: const Text('Find New Host'),
            ),
          ],
        ),
      );
    }

    final canSettle = ChainConfig.isOnChainEnabled &&
        !st.isSettled &&
        st.chainSessionId != null &&
        (st.hostSettlementSigHex != null && st.hostSettlementSigHex!.isNotEmpty);

    final canDispute = ChainConfig.isOnChainEnabled &&
        st.chainSessionId != null &&
        (st.hostSettlementSigHex == null || st.hostSettlementSigHex!.isEmpty) &&
        st.stoppedAt != null &&
        DateTime.now().difference(st.stoppedAt!).inHours >= 24;

    if (!canSettle && !canDispute) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            canSettle
                ? 'Settle payment on-chain to receive any unused quota refund.'
                : 'No settlement received — you may dispute after 24h.',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (canSettle)
            ElevatedButton(
              onPressed: () async {
                try {
                  final tx = await provider.executeOnChainCloseSession();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Settlement submitted: $tx')),
                  );
                  await provider.clearPersistedGuestSession();
                  if (!context.mounted) return;
                  context.go('/guest/nearby');
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Settlement failed: $e')),
                  );
                }
              },
              child: const Text('Settle on-chain'),
            ),
          if (canDispute)
            OutlinedButton(
              onPressed: () async {
                try {
                  final tx = await provider.executeOnChainDisputeSession();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Dispute submitted: $tx')),
                  );
                  await provider.clearPersistedGuestSession();
                  if (!context.mounted) return;
                  context.go('/guest/nearby');
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Dispute failed: $e')),
                  );
                }
              },
              child: const Text('Dispute session (24h+)'),
            ),
        ],
      ),
    );
  }

  static String _fmtMbps(double? v) {
    if (v == null) return '--';
    return v >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
  }

  Widget _buildSpeedCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildSpeedIndicator(Icons.arrow_downward, _fmtMbps(_downMbps), 'Mbps', 'Download'),
          Container(width: 1, height: 50, color: AppColors.divider),
          _buildSpeedIndicator(Icons.arrow_upward, _fmtMbps(_upMbps), 'Mbps', 'Upload'),
          Container(width: 1, height: 50, color: AppColors.divider),
          _buildSpeedIndicator(Icons.network_ping, _pingMs?.toString() ?? '--', 'ms', 'Ping'),
        ],
      ),
    );
  }

  Widget _buildSpeedIndicator(IconData icon, String value, String unit, String label) {
    return Column(
      children: [
        Icon(icon, color: AppColors.primary, size: 18),
        const SizedBox(height: 4),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: value,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextSpan(
                text: ' $unit',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
      ],
    );
  }
}

class _CircularProgressPainter extends CustomPainter {
  final double progress;
  const _CircularProgressPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;

    final bgPaint = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke;

    final fgPaint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    const startAngle = -3.14159 / 2;
    final sweepAngle = 2 * 3.14159 * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CircularProgressPainter old) =>
      old.progress != progress;
}
