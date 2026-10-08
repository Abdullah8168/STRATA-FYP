// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'STRATA';

  @override
  String get guestFlowTitle => 'Join as Guest';

  @override
  String get hostFlowTitle => 'Host Bandwidth';

  @override
  String get walletHeading => 'STRATA Wallet';

  @override
  String get confirmPaymentTitle => 'Confirm Payment';

  @override
  String get paymentStepPrepare => 'Preparing payment…';

  @override
  String get dashboardTitle => 'Active Session';

  @override
  String get nearbyHostsTitle => 'Nearby Hosts';

  @override
  String get sessionHistoryTitle => 'Session History';

  @override
  String get offlineBanner => 'You\'re offline. Some features are unavailable.';

  @override
  String get backOnlineBanner => 'Back online';

  @override
  String get wrongNetworkBanner =>
      'STRATA only operates on Polygon Amoy testnet. Payments are blocked until reconnected.';

  @override
  String get helpAccessibilityLabel => 'Open help';

  @override
  String get errorGeneric => 'Something went wrong.';

  @override
  String get roleGuestDescription =>
      'Connect to decentralized Wi‑Fi hotspots and pay only for what you use.';

  @override
  String get roleHostDescription =>
      'Share bandwidth from your uplink safely with metered payouts.';

  @override
  String get walletLegalNotice =>
      'I understand the Terms & Privacy Policy and agree to proceed.';

  @override
  String get paymentProgressLabel => 'Payment progress';

  @override
  String get chatOfflineLabel => 'Offline';

  @override
  String get sosSemanticsLabel => 'Send emergency SOS to the chatroom';

  @override
  String get mnemonicRevealSemanticsLabel => 'Reveal mnemonic word tiles';
}
