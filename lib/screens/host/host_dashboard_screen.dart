import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sidebar.dart';
import '../../widgets/account_menu_button.dart';
import '../../providers/app_provider.dart';
import '../../services/host_api_service.dart';

class HostDashboardScreen extends StatefulWidget {
  const HostDashboardScreen({super.key});

  @override
  State<HostDashboardScreen> createState() => _HostDashboardScreenState();
}

class _HostDashboardScreenState extends State<HostDashboardScreen> {
  List<Map<String, dynamic>> _sessions = const [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<AppProvider>().hostApiService;
    try {
      final rows = await api.fetchHostSessions();
      if (!mounted) return;
      setState(() {
        _sessions = rows;
        _loadError = null;
      });
    } on HostApiException catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  String _shortWallet(String w) {
    if (w.length < 12) return w;
    return '${w.substring(0, 6)}…${w.substring(w.length - 4)}';
  }

  String _relativeTime(String? iso) {
    if (iso == null) return '';
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final diff = DateTime.now().difference(t.toLocal());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} d ago';
  }

  double _strtDisplay(String weiStr) {
    final v = BigInt.tryParse(weiStr) ?? BigInt.zero;
    return v.toDouble() / 1e18;
  }

  int _activeCount() =>
      _sessions.where((s) => (s['status'] as String?) == 'active').length;

  int _bytesToday() {
    final now = DateTime.now();
    var sum = 0;
    for (final s in _sessions) {
      final iso = s['started_at'] as String?;
      final st = iso == null ? null : DateTime.tryParse(iso);
      if (st == null) continue;
      if (st.year != now.year || st.month != now.month || st.day != now.day) {
        continue;
      }
      sum += (s['bytes_used'] as num?)?.toInt() ?? 0;
    }
    return sum;
  }

  double _earningsTodayStrt() {
    var sum = 0.0;
    final now = DateTime.now();
    for (final s in _sessions) {
      final iso = s['started_at'] as String?;
      final st = iso == null ? null : DateTime.tryParse(iso);
      if (st == null) continue;
      if (st.year != now.year || st.month != now.month || st.day != now.day) {
        continue;
      }
      final w = (s['earned_amount_wei'] as String?) ??
          (s['strt_amount_wei'] as String?) ??
          '0';
      sum += _strtDisplay(w);
    }
    return sum;
  }

  double _earningsTotalStrt() {
    var sum = 0.0;
    for (final s in _sessions) {
      final w = (s['earned_amount_wei'] as String?) ??
          (s['strt_amount_wei'] as String?) ??
          '0';
      sum += _strtDisplay(w);
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final isActive = provider.isHostActive;

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 800;
      final scaffold = Scaffold(
        backgroundColor: AppColors.background,
        drawer: isWide ? null : const Sidebar(role: 'host', currentRoute: '/host/dashboard'),
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
          title: const Text('Host Dashboard'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: AppColors.textPrimary),
              onPressed: _load,
            ),
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined, color: AppColors.textPrimary),
                  onPressed: () => context.go('/host/booking'),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
            const AccountMenuButton(),
          ],
        ),
        body: Row(
          children: [
            if (isWide)
              const Sidebar(role: 'host', currentRoute: '/host/dashboard'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildToggleCard(isActive, provider),
                    const SizedBox(height: 10),
                    if (_loadError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _loadError!,
                          style: const TextStyle(color: AppColors.error, fontSize: 12),
                        ),
                      ),
                    _buildStatsRow(),
                    const SizedBox(height: 20),
                    _buildChartCard(),
                    const SizedBox(height: 20),
                    _buildTransactions(),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => context.go('/host/access-key'),
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Generate Access Key'),
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
      return scaffold;
    });
  }

  Widget _buildToggleCard(bool isActive, AppProvider provider) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isActive
              ? [AppColors.primary.withAlpha(40), AppColors.primaryDark.withAlpha(30)]
              : [AppColors.surface, AppColors.card],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? AppColors.primary.withAlpha(120) : AppColors.divider,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.primary.withAlpha(30)
                  : AppColors.divider.withAlpha(100),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              isActive ? Icons.router : Icons.router_outlined,
              color: isActive ? AppColors.primary : AppColors.textSecondary,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Node Sharing',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
                Text(
                  isActive ? 'ACTIVE' : 'INACTIVE',
                  style: TextStyle(
                    color: isActive ? AppColors.primary : AppColors.textSecondary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: isActive,
            onChanged: (v) {
              if (v) {
                provider.activateHostSharing();
              } else {
                provider.deactivateHostSharing();
              }
            },
            thumbColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? AppColors.primary
                  : AppColors.textSecondary,
            ),
            trackColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? AppColors.primary.withAlpha(50)
                  : AppColors.divider,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final gbToday = _bytesToday() / (1024 * 1024 * 1024);
    final stats = [
      {
        'label': "Today's Earnings",
        'value': _earningsTodayStrt().toStringAsFixed(2),
        'unit': 'STRATA',
        'icon': Icons.attach_money,
      },
      {
        'label': 'Total Earnings',
        'value': _earningsTotalStrt().toStringAsFixed(2),
        'unit': 'STRATA',
        'icon': Icons.account_balance_wallet_outlined,
      },
      {
        'label': 'Active Users',
        'value': '${_activeCount()}',
        'unit': 'guests',
        'icon': Icons.people_outline,
      },
      {
        'label': 'Data Shared',
        'value': gbToday.toStringAsFixed(2),
        'unit': 'GB today',
        'icon': Icons.data_usage,
      },
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.8,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: stats.length,
      itemBuilder: (context, i) {
        final s = stats[i];
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(s['icon'] as IconData, color: AppColors.primary, size: 20),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s['value'] as String,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${s['unit']}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                  ),
                  Text(
                    s['label'] as String,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChartCard() {
    return Container(
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
            'Earnings This Week',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 80,
            child: CustomPaint(
              painter: _WavePainter(),
              child: Container(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
                .map((d) => Text(
                      d,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactions() {
    final rows = [..._sessions]
      ..sort((a, b) {
        final ta = DateTime.tryParse((a['started_at'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final tb = DateTime.tryParse((b['started_at'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Sessions',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Text(
            'No sessions yet.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          )
        else
          ...rows.take(12).map((t) => _buildTransactionItem(t)),
      ],
    );
  }

  Widget _buildTransactionItem(Map<String, dynamic> t) {
    final wallet = (t['guest_wallet_address'] as String?) ?? '';
    final used = (t['bytes_used'] as num?)?.toInt() ?? 0;
    final gb = used / (1024 * 1024 * 1024);
    final wei = (t['strt_amount_wei'] as String?) ?? '0';
    final amount = _strtDisplay(wei).toStringAsFixed(3);
    final started = t['started_at'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.primary.withAlpha(25),
            child: const Icon(Icons.person, color: AppColors.primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortWallet(wallet),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${gb.toStringAsFixed(2)} GB · ${_relativeTime(started)} · ${t['status']}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            '+$amount STRATA',
            style: const TextStyle(
              color: AppColors.primary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [AppColors.primary.withAlpha(60), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final points = [
      Offset(0, size.height * 0.7),
      Offset(size.width * 0.14, size.height * 0.5),
      Offset(size.width * 0.28, size.height * 0.6),
      Offset(size.width * 0.43, size.height * 0.3),
      Offset(size.width * 0.57, size.height * 0.4),
      Offset(size.width * 0.71, size.height * 0.15),
      Offset(size.width * 0.85, size.height * 0.35),
      Offset(size.width, size.height * 0.2),
    ];

    final linePath = Path()..moveTo(points[0].dx, points[0].dy);
    for (int i = 0; i < points.length - 1; i++) {
      final mid = Offset(
        (points[i].dx + points[i + 1].dx) / 2,
        (points[i].dy + points[i + 1].dy) / 2,
      );
      linePath.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    linePath.lineTo(points.last.dx, points.last.dy);

    final fillPath = Path.from(linePath)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(linePath, paint);

    // Dots on data points
    final dotPaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.fill;
    for (final p in [points[3], points[5], points[7]]) {
      canvas.drawCircle(p, 4, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
