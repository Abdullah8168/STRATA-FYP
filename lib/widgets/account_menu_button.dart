import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../theme/app_theme.dart';

enum _AccountMenuItem { profile, wallet, settings, logout }

class AccountMenuButton extends StatelessWidget {
  const AccountMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_AccountMenuItem>(
      icon: const Icon(Icons.account_circle_outlined,
          color: AppColors.textPrimary),
      onSelected: (item) {
        switch (item) {
          case _AccountMenuItem.profile:
            context.go('/profile');
            break;
          case _AccountMenuItem.wallet:
            context.go('/wallet');
            break;
          case _AccountMenuItem.settings:
            final userRole =
                (context.read<AppProvider>().currentUser?.role ?? '')
                    .toLowerCase();
            if (userRole == 'host') {
              context.go('/profile');
            } else {
              context.go('/guest/settings');
            }
            break;
          case _AccountMenuItem.logout:
            context.read<AppProvider>().resetSession();
            context.go('/role');
            break;
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _AccountMenuItem.profile,
          child: Text('See Profile'),
        ),
        PopupMenuItem(
          value: _AccountMenuItem.wallet,
          child: Text('Wallet (token)'),
        ),
        PopupMenuItem(
          value: _AccountMenuItem.settings,
          child: Text('Settings'),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: _AccountMenuItem.logout,
          child: Text('Logout'),
        ),
      ],
    );
  }
}
