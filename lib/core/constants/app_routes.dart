class AppRoutes {
  // Splash & role selection
  static const splash = '/splash';
  static const roleSelection = '/role';
  static const roleSelectionAlias = '/roll';

  // Auth
  static const login = '/login/:role';
  static const otp = '/otp/:role';

  // Host flow
  static const hostOnboarding = '/host/onboarding';
  static const hostSetup = '/host/setup';
  static const hostDashboard = '/host/dashboard';
  static const hostMyHosting = '/host/my-hosting';
  static const hostEarnings = '/host/earnings';
  static const hostBookingNotification = '/host/booking';
  static const hostAccessKey = '/host/access-key';
  static const profile = '/profile';
  static const wallet = '/wallet';

  // Guest flow
  static const guestLocationPermission = '/guest/location';
  static const guestNearbyHosts = '/guest/nearby';
  static const guestSelectHost = '/guest/select-host';
  static const guestChooseQuota = '/guest/quota';
  static const guestPayment = '/guest/payment';
  static const guestDashboard = '/guest/dashboard';
  static const guestAccessRevoked = '/guest/revoked';
  static const guestSettings = '/guest/settings';
  static const guestSessions = '/guest/sessions';

  // Chat
  static const chatroom = '/chatroom';

  // Phase D: wallet
  static const walletCreateIntro = '/wallet/create-intro';
  static const walletShowMnemonic = '/wallet/show-mnemonic';
  static const walletConfirmMnemonic = '/wallet/confirm-mnemonic';
  static const walletImport = '/wallet/import';
  static const walletBackup = '/wallet/backup';
}
