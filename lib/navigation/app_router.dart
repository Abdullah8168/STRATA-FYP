import 'package:go_router/go_router.dart';

import '../core/constants/app_routes.dart';
import '../screens/splash_screen.dart';
import '../screens/role_selection_screen.dart';
import '../screens/auth/login_signup_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/host/host_onboarding_screen.dart';
import '../screens/host/host_setup_screen.dart';
import '../screens/host/host_dashboard_screen.dart';
import '../screens/host/my_hosting_screen.dart';
import '../screens/host/earnings_screen.dart';
import '../screens/host/guest_booking_notification_screen.dart';
import '../screens/host/temp_access_key_screen.dart';
import '../screens/guest/location_permission_screen.dart';
import '../screens/guest/nearby_hosts_screen.dart';
import '../screens/guest/select_host_screen.dart';
import '../screens/guest/choose_quota_screen.dart';
import '../screens/guest/payment_screen.dart';
import '../screens/guest/guest_dashboard_screen.dart';
import '../screens/guest/access_revoked_screen.dart';
import '../screens/guest/session_history_screen.dart';
import '../screens/chatroom/chatroom_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/wallet_screen.dart';
import '../screens/wallet/wallet_create_intro_screen.dart';
import '../screens/wallet/wallet_show_mnemonic_screen.dart';
import '../screens/wallet/wallet_confirm_mnemonic_screen.dart';
import '../screens/wallet/wallet_import_screen.dart';
import '../screens/wallet/wallet_backup_screen.dart';
import '../screens/guest/settings_screen.dart';

String _mnemonicFromExtra(Object? extra) {
  if (extra is String && extra.isNotEmpty) return extra;
  if (extra is Map && extra['mnemonic'] is String) {
    return extra['mnemonic'] as String;
  }
  return '';
}

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.splash,
  routes: [
    GoRoute(
      path: AppRoutes.splash,
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: AppRoutes.roleSelection,
      builder: (context, state) => const RoleSelectionScreen(),
    ),
    GoRoute(
      path: AppRoutes.roleSelectionAlias,
      builder: (context, state) => const RoleSelectionScreen(),
    ),
    GoRoute(
      path: '/login/:role',
      builder: (context, state) {
        final role = state.pathParameters['role'] ?? 'guest';
        return LoginSignupScreen(role: role);
      },
    ),
    GoRoute(
      path: '/otp/:role',
      builder: (context, state) {
        final role = state.pathParameters['role'] ?? 'guest';
        var contact = state.uri.queryParameters['contact'] ?? '';
        if (contact.isEmpty) {
          final extra = state.extra;
          if (extra is Map) {
            final maybeContact = extra['contact'];
            if (maybeContact is String) {
              contact = maybeContact;
            }
          }
        }
        return OtpScreen(role: role, contact: contact);
      },
    ),
    GoRoute(
      path: AppRoutes.hostOnboarding,
      builder: (context, state) => const HostOnboardingScreen(),
    ),
    GoRoute(
      path: AppRoutes.hostSetup,
      builder: (context, state) => const HostSetupScreen(),
    ),
    GoRoute(
      path: AppRoutes.hostDashboard,
      builder: (context, state) => const HostDashboardScreen(),
    ),
    GoRoute(
      path: AppRoutes.hostMyHosting,
      builder: (context, state) => const MyHostingScreen(),
    ),
    GoRoute(
      path: AppRoutes.hostEarnings,
      builder: (context, state) => const EarningsScreen(),
    ),
    GoRoute(
      path: AppRoutes.hostBookingNotification,
      builder: (context, state) => const GuestBookingNotificationScreen(),
    ),
    GoRoute(
      path: AppRoutes.hostAccessKey,
      builder: (context, state) => const TempAccessKeyScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestLocationPermission,
      builder: (context, state) => const LocationPermissionScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestNearbyHosts,
      builder: (context, state) => const NearbyHostsScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestSelectHost,
      builder: (context, state) => const SelectHostScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestChooseQuota,
      builder: (context, state) => const ChooseQuotaScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestPayment,
      builder: (context, state) => const PaymentScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestDashboard,
      builder: (context, state) => const GuestDashboardScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestAccessRevoked,
      builder: (context, state) {
        final reason = state.uri.queryParameters['reason'] ?? 'revoked';
        return AccessRevokedScreen(reason: reason);
      },
    ),
    GoRoute(
      path: AppRoutes.guestSettings,
      builder: (context, state) => const GuestSettingsScreen(),
    ),
    GoRoute(
      path: AppRoutes.guestSessions,
      builder: (context, state) => const SessionHistoryScreen(),
    ),
    GoRoute(
      path: AppRoutes.chatroom,
      builder: (context, state) => const ChatroomScreen(),
    ),
    GoRoute(
      path: AppRoutes.profile,
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(
      path: AppRoutes.wallet,
      builder: (context, state) => const WalletScreen(),
    ),
    GoRoute(
      path: AppRoutes.walletCreateIntro,
      builder: (context, state) => const WalletCreateIntroScreen(),
    ),
    GoRoute(
      path: AppRoutes.walletShowMnemonic,
      builder: (context, state) {
        final mnemonic = _mnemonicFromExtra(state.extra);
        return WalletShowMnemonicScreen(mnemonic: mnemonic);
      },
    ),
    GoRoute(
      path: AppRoutes.walletConfirmMnemonic,
      builder: (context, state) {
        final mnemonic = _mnemonicFromExtra(state.extra);
        return WalletConfirmMnemonicScreen(mnemonic: mnemonic);
      },
    ),
    GoRoute(
      path: AppRoutes.walletImport,
      builder: (context, state) => const WalletImportScreen(),
    ),
    GoRoute(
      path: AppRoutes.walletBackup,
      builder: (context, state) => const WalletBackupScreen(),
    ),
  ],
);
