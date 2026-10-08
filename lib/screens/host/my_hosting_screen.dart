import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_provider.dart';
import '../../services/host_api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_back_button.dart';

/// Live host status for the operator phone.
///
/// Primary data: `GET /host/info` + `GET /host/sessions` (no admin token).
/// Optional enrichment: `GET /admin/firewall/state` when
/// `--dart-define=STRATA_ADMIN_TOKEN` matches the host `ADMIN_TOKEN`.
class MyHostingScreen extends StatefulWidget {
  const MyHostingScreen({super.key});

  @override
  State<MyHostingScreen> createState() => _MyHostingScreenState();
}

class _MyHostingScreenState extends State<MyHostingScreen> {
  Timer? _timer;
  HostNodeInfo? _info;
  List<Map<String, dynamic>> _sessions = const [];
  List<String> _firewallMacs = const [];
  String? _error;
  String? _firewallNote;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = context.read<AppProvider>().hostApiService;
    try {
      final info = await api.getHostInfo();
      final sessions = await api.fetchHostSessions();
      var firewallMacs = const <String>[];
      String? firewallNote;
      if (HostApiService.hasAdminTokenConfigured) {
        try {
          firewallMacs = await api.fetchAdminAuthedMacs();
        } on HostApiException catch (e) {
          firewallNote =
              'Firewall live set unavailable (${e.code}). Showing session store only.';
        }
      } else {
        firewallNote =
            'Optional: pass --dart-define=STRATA_ADMIN_TOKEN matching host ADMIN_TOKEN for live nftables MAC list.';
      }
      if (!mounted) return;
      setState(() {
        _info = info;
        _sessions = sessions;
        _firewallMacs = firewallMacs;
        _firewallNote = firewallNote;
        _error = info == null
            ? 'Host node unreachable at ${api.baseUrlHint}. Is host_node running?'
            : null;
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

  String _short(String v) {
    if (v.length < 12) return v;
    return '${v.substring(0, 6)}…${v.substring(v.length - 4)}';
  }

  String _fmtBytes(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '$b B';
  }

  double _strt(String? wei) {
    final v = BigInt.tryParse(wei ?? '0') ?? BigInt.zero;
    return v.toDouble() / 1e18;
  }

  List<Map<String, dynamic>> get _activeSessions =>
      _sessions.where((s) => (s['status'] as String?) == 'active').toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const AppBackButton(to: '/host/dashboard'),
        title: const Text('My Hosting'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppColors.error),
                      ),
                    ),
                  if (_info != null) _hostCard(_info!),
                  if (_firewallNote != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _firewallNote!,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Active sessions (${_activeSessions.length})',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_activeSessions.isEmpty)
                    const Text(
                      'No active guest sessions on this host.',
                      style: TextStyle(color: AppColors.textSecondary),
                    )
                  else
                    ..._activeSessions.map(_sessionTile),
                  if (_firewallMacs.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Firewall admitted MACs (${_firewallMacs.length})',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._firewallMacs.map(
                      (m) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          m,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'Recent sessions (${_sessions.length})',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_sessions.isEmpty)
                    const Text(
                      'No sessions recorded yet. When a guest opens a SessionEscrow session against this host, it appears here.',
                      style: TextStyle(color: AppColors.textSecondary),
                    )
                  else
                    ..._sessions.map(_sessionTile),
                ],
              ),
            ),
    );
  }

  Widget _hostCard(HostNodeInfo info) {
    final online = _error == null;
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
          Row(
            children: [
              Icon(
                online ? Icons.cloud_done : Icons.cloud_off,
                color: online ? AppColors.primary : AppColors.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  info.displayName,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: online
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : AppColors.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  online ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: online ? AppColors.primary : AppColors.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _kv('SSID', info.ssid.isEmpty ? '—' : info.ssid),
          _kv('Host wallet', _short(info.walletAddress)),
          _kv(
            'Price',
            info.pricePerGB != null
                ? '${info.pricePerGB} STRATA / GB'
                : '${_strt(info.pricePerGbWei).toStringAsFixed(4)} STRATA / GB',
          ),
          _kv('Chain', info.chainEnabled ? 'SessionEscrow enabled' : 'Off-chain'),
          _kv('Mode', info.demoMode ? 'Demo metering' : 'nf_conntrack metering'),
          if (info.guestIface != null)
            _kv('Guest iface', '${info.guestIface} → ${info.wanIface ?? '—'}'),
          _kv('Version', info.version),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: const TextStyle(color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(v, style: const TextStyle(color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _sessionTile(Map<String, dynamic> s) {
    final status = (s['status'] as String?) ?? 'unknown';
    final guest = (s['guest_wallet_address'] as String?) ?? '';
    final mac = (s['mac_address'] as String?) ?? '';
    final used = (s['bytes_used'] as num?)?.toInt() ?? 0;
    final quota = (s['quota_bytes'] as num?)?.toInt() ?? 0;
    final earned = _strt(s['earned_amount_wei'] as String?);
    final escrow = s['escrow_amount_wei'] as String?;
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
          Text(
            '${status.toUpperCase()} · ${_short(guest)}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (mac.isNotEmpty)
            Text('MAC $mac',
                style: const TextStyle(color: AppColors.textSecondary)),
          Text(
            'Usage ${_fmtBytes(used)} / ${_fmtBytes(quota)}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          Text(
            'Earned (est.) ${earned.toStringAsFixed(4)} STRATA'
            '${escrow != null ? ' · escrow ${_strt(escrow).toStringAsFixed(4)}' : ''}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
