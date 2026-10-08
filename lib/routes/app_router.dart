import 'package:go_router/go_router.dart';
import '../screens/splash_screen.dart';
import '../screens/role_selection_screen.dart';
import '../screens/auth/login_signup_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/host/host_onboarding_screen.dart';
import '../screens/host/host_setup_screen.dart';
import '../screens/host/host_dashboard_screen.dart';
import '../screens/host/guest_booking_notification_screen.dart';
import '../screens/host/temp_access_key_screen.dart';
import '../screens/guest/location_permission_screen.dart';
import '../screens/guest/nearby_hosts_screen.dart';
import '../screens/guest/select_host_screen.dart';
import '../screens/guest/choose_quota_screen.dart';
import '../screens/guest/payment_screen.dart';
import '../screens/guest/guest_dashboard_screen.dart';
import '../screens/guest/access_revoked_screen.dart';
import '../screens/chatroom/chatroom_screen.dart';
import '../screens/guest/settings_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/role',
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
      path: '/host/onboarding',
      builder: (context, state) => const HostOnboardingScreen(),
    ),
    GoRoute(
      path: '/host/setup',
      builder: (context, state) => const HostSetupScreen(),
    ),
    GoRoute(
      path: '/host/dashboard',
      builder: (context, state) => const HostDashboardScreen(),
    ),
    GoRoute(
      path: '/host/booking',
      builder: (context, state) => const GuestBookingNotificationScreen(),
    ),
    GoRoute(
      path: '/host/access-key',
      builder: (context, state) => const TempAccessKeyScreen(),
    ),
    GoRoute(
      path: '/guest/location',
      builder: (context, state) => const LocationPermissionScreen(),
    ),
    GoRoute(
      path: '/guest/nearby',
      builder: (context, state) => const NearbyHostsScreen(),
    ),
    GoRoute(
      path: '/guest/select-host',
      builder: (context, state) => const SelectHostScreen(),
    ),
    GoRoute(
      path: '/guest/quota',
      builder: (context, state) => const ChooseQuotaScreen(),
    ),
    GoRoute(
      path: '/guest/payment',
      builder: (context, state) => const PaymentScreen(),
    ),
    GoRoute(
      path: '/guest/dashboard',
      builder: (context, state) => const GuestDashboardScreen(),
    ),
    GoRoute(
      path: '/guest/settings',
      builder: (context, state) => const GuestSettingsScreen(),
    ),
    GoRoute(
      path: '/guest/revoked',
      builder: (context, state) {
        final reason = state.uri.queryParameters['reason'] ?? 'revoked';
        return AccessRevokedScreen(reason: reason);
      },
    ),
    GoRoute(
      path: '/chatroom',
      builder: (context, state) => const ChatroomScreen(),
    ),
  ],
);
