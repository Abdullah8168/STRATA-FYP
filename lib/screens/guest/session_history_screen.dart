import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/app_provider.dart';
import '../../services/session_history_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/account_menu_button.dart';
import '../../widgets/sidebar.dart';

class SessionHistoryScreen extends StatefulWidget {
  const SessionHistoryScreen({super.key});

  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  late Future<List<SessionHistoryRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppProvider>().sessionHistoryService.recentSessions();
  }

  void _reload() {
    setState(() {
      _future = context.read<AppProvider>().sessionHistoryService.recentSessions();
    });
  }

  Future<void> _openTx(BuildContext ctx, String hash) async {
    final uri = Uri.parse('https://amoy.polygonscan.com/tx/$hash');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('Could not open browser')),
      );
    }
  }

  static String _formatGb(int quotaBytes, int bytesUsed) {
    const g = 1024 * 1024 * 1024;
    final usedGb = bytesUsed / g;
    final totalGb = quotaBytes / g;
    return '${usedGb.toStringAsFixed(2)} / ${totalGb.toStringAsFixed(1)} GB';
  }

  static String _costLine(SessionHistoryRecord r) {
    const g = 1024 * 1024 * 1024;
    if (r.rateRsPerGb == null) {
      return 'Rate not recorded for this session';
    }
    final usedGb = r.bytesUsed / g;
    return 'Rs ${(usedGb * r.rateRsPerGb!).toStringAsFixed(2)} (usage × rate)';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        return Scaffold(
          backgroundColor: AppColors.background,
          drawer: isWide ? null : const Sidebar(role: 'guest', currentRoute: '/guest/sessions'),
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            leading: isWide
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
                    onPressed: () => context.pop(),
                  )
                : Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu, color: AppColors.textPrimary),
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
            title: const Text('Recent sessions'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, color: AppColors.textPrimary),
                onPressed: _reload,
              ),
              const AccountMenuButton(),
            ],
          ),
          body: Row(
            children: [
              if (isWide) const Sidebar(role: 'guest', currentRoute: '/guest/sessions'),
              Expanded(
                child: FutureBuilder<List<SessionHistoryRecord>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Could not load sessions.\n${snap.error}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.error),
                          ),
                        ),
                      );
                    }
                    final rows = snap.data!;
                    if (rows.isEmpty) {
                      return const Center(
                        child: Text(
                          'No sessions recorded yet.',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final r = rows[index];
                        final started = DateTime.fromMillisecondsSinceEpoch(r.startedAtMs);
                        final ended = r.endedAtMs != null
                            ? DateTime.fromMillisecondsSinceEpoch(r.endedAtMs!)
                            : null;
                        final subtitle = '${DateFormat.yMMMd().add_jm().format(started)}'
                            '${ended != null ? ' → ${DateFormat.yMMMd().add_jm().format(ended)}' : ''}';
                        final settlement = _costLine(r);
                        return Container(
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
                                r.hostName.isEmpty ? 'Unknown host' : r.hostName,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(
                                    'Data used: ${_formatGb(r.quotaBytes, r.bytesUsed)}',
                                    style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    settlement,
                                    style: const TextStyle(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              if (r.endReason != null && r.endReason!.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    'End: ${r.endReason}',
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              if (r.txHash != null &&
                                  r.txHash!.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    TextButton.icon(
                                      onPressed: () => _openTx(context, r.txHash!),
                                      icon: const Icon(Icons.open_in_new, size: 16),
                                      label: const Text('View on Amoyscan'),
                                    ),
                                    TextButton(
                                      onPressed: () => Clipboard.setData(
                                        ClipboardData(text: r.txHash!),
                                      ),
                                      child: const Text('Copy tx'),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
