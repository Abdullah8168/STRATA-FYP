// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Urdu (`ur`).
class AppLocalizationsUr extends AppLocalizations {
  AppLocalizationsUr([String locale = 'ur']) : super(locale);

  @override
  String get appTitle => 'STRATA';

  @override
  String get guestFlowTitle => 'مهمان کے طور پر شامل ہوں';

  @override
  String get hostFlowTitle => 'بینڈوتھ شیئر کریں';

  @override
  String get walletHeading => 'STRATA Wallet';

  @override
  String get confirmPaymentTitle => 'ادائیگی کی تصدیق';

  @override
  String get paymentStepPrepare => 'ادائیگی تیار…';

  @override
  String get dashboardTitle => 'فعال سیشن';

  @override
  String get nearbyHostsTitle => 'قریب کے Host';

  @override
  String get sessionHistoryTitle => 'سابق سیشنز';

  @override
  String get offlineBanner => 'آپ آف لائن ہیں۔ کچھ فیچرز دستیاب نہیں۔';

  @override
  String get backOnlineBanner => 'واپس آن لائن';

  @override
  String get wrongNetworkBanner =>
      'STRATA صرف Polygon Amoy testnet پر ہے۔ ادائیگی بند ہے۔';

  @override
  String get helpAccessibilityLabel => 'مدد کھولیں';

  @override
  String get errorGeneric => 'کچھ غلط ہو گیا۔';

  @override
  String get roleGuestDescription =>
      'غیر مرکزی Wi‑Fi سے جڑیں اور استعمال کے مطابق ادائیگی کریں۔';

  @override
  String get roleHostDescription => 'اپنا بینڈوتھ محفوظ طریقے سے شیئر کریں۔';

  @override
  String get walletLegalNotice =>
      'میں Terms & Privacy Policy سمجھتا/سمجھتی ہوں اور آگے بڑھنا قبول ہے۔';

  @override
  String get paymentProgressLabel => 'ادائیگی کی پیش رفت';

  @override
  String get chatOfflineLabel => 'آف لائن';

  @override
  String get sosSemanticsLabel => 'چیٹ روم میں SOS بھیجیں';

  @override
  String get mnemonicRevealSemanticsLabel => 'mnemonic الفاظ دکھائیں';
}
