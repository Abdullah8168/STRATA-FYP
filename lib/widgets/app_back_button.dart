import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/constants/app_routes.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';

/// AppBar back arrow for screens reached with `context.go`, which replaces
/// the page instead of stacking it, so Flutter shows no automatic back
/// button. Same look as the existing hand-written back buttons.
///
/// [to] is where "back" goes (with optional [extra], e.g. the recovery
/// phrase between wallet steps). Without [to], it goes to the role's home:
/// Nearby Hosts for guests, the Dashboard for hosts.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, this.to, this.extra});

  final String? to;
  final Object? extra;

  static String homeFor(String role) =>
      role == 'host' ? AppRoutes.hostDashboard : AppRoutes.guestNearbyHosts;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
      tooltip: 'Back',
      onPressed: () {
        final target = to ?? homeFor(context.read<AppProvider>().selectedRole);
        context.go(target, extra: extra);
      },
    );
  }
}
