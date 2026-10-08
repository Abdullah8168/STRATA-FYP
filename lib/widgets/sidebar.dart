import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../providers/app_provider.dart';
import '../services/session_history_service.dart';

class Sidebar extends StatelessWidget {
  final String role;
  final String currentRoute;

  const Sidebar({
    super.key,
    required this.role,
    this.currentRoute = '',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      color: AppColors.surface,
      child: Column(
        children: [
          _buildHeader(context),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 8),
                _buildNavSection(context, 'NAVIGATION'),
                _buildNavItem(
                  context,
                  icon: Icons.dashboard_outlined,
                  label: 'Dashboard',
                  route:
                      role == 'host' ? '/host/dashboard' : '/guest/dashboard',
                ),
                if (role == 'host') ...[
                  _buildNavItem(
                    context,
                    icon: Icons.router_outlined,
                    label: 'My Hosting',
                    route: '/host/my-hosting',
                  ),
                  _buildNavItem(
                    context,
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Earnings',
                    route: '/host/earnings',
                  ),
                  _buildNavItem(
                    context,
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Wallet',
                    route: '/wallet',
                  ),
                ] else ...[
                  _buildNavItem(
                    context,
                    icon: Icons.wifi_find_outlined,
                    label: 'Nearby Hosts',
                    route: '/guest/nearby',
                  ),
                  _buildNavItem(
                    context,
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Wallet',
                    route: '/wallet',
                  ),
                  _buildNavItem(
                    context,
                    icon: Icons.history_outlined,
                    label: 'Sessions',
                    route: '/guest/sessions',
                  ),
                ],
                _buildNavItem(
                  context,
                  icon: Icons.chat_bubble_outline,
                  label: 'Chat Room',
                  route: '/chatroom',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  route: role == 'host' ? '/profile' : '/guest/settings',
                ),
                const SizedBox(height: 16),
                _buildNavSection(context, 'RECENT SESSIONS'),
                if (role == 'guest')
                  _RecentSessionsList()
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16.0, vertical: 8),
                    child: Text(
                      'Session history appears in the desktop host console.',
                      style: TextStyle(
                        color: AppColors.textSecondary.withAlpha(140),
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          _buildUserProfile(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(30),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.primary, width: 1.5),
            ),
            child: const Icon(Icons.hub, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'STRATA',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              Text(
                'Bandwidth Network',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavSection(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String route,
  }) {
    final isSelected = currentRoute == route;
    return InkWell(
      onTap: () {
        if (Scaffold.of(context).isDrawerOpen) {
          Navigator.of(context).pop();
        }
        context.go(route);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.primary.withAlpha(25) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: AppColors.primary.withAlpha(80), width: 1)
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppColors.primary : AppColors.textPrimary,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserProfile(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final user = provider.currentUser;
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.primary.withAlpha(40),
            child: const Icon(Icons.person, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.name ?? 'Guest User',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  role.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout,
                color: AppColors.textSecondary, size: 18),
            onPressed: () {
              context.read<AppProvider>().resetSession();
              context.go('/role');
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _RecentSessionsList extends StatefulWidget {
  @override
  State<_RecentSessionsList> createState() => _RecentSessionsListState();
}

class _RecentSessionsListState extends State<_RecentSessionsList> {
  late Future<List<SessionHistoryRecord>> _future =
      Future<List<SessionHistoryRecord>>.value(const []);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  void _reload() {
    if (!mounted) return;
    final next = context
        .read<AppProvider>()
        .sessionHistoryService
        .recentSessions(limit: 3);
    setState(() {
      _future = next;
    });
  }

  static String _gbLine(SessionHistoryRecord r) {
    const g = 1024 * 1024 * 1024;
    final used = (r.bytesUsed / g).toStringAsFixed(1);
    final total = (r.quotaBytes / g).toStringAsFixed(0);
    return '$used GB / $total GB';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SessionHistoryRecord>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final rows = snapshot.data ?? const <SessionHistoryRecord>[];
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No sessions logged yet.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          );
        }
        return Column(
          children: rows
              .map((r) => InkWell(
                    onTap: () => context.go('/guest/sessions'),
                    child: _RecentRow(
                      name: r.hostName.isEmpty ? 'Host' : r.hostName,
                      subtitle: _gbLine(r),
                    ),
                  ))
              .toList(),
        );
      },
    );
  }
}

class _RecentRow extends StatelessWidget {
  final String name;
  final String subtitle;

  const _RecentRow({required this.name, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
