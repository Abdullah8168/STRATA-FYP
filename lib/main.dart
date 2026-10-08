import 'dart:async';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'navigation/app_router.dart';
import 'providers/app_provider.dart';
import 'services/deep_link_service.dart';
import 'services/log_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Crashlytics is mobile-only; wiring it on web asserts and kills debug runs.
  if (!kIsWeb) {
    FlutterError.onError = (FlutterErrorDetails details) {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } else {
    FlutterError.onError = FlutterError.presentError;
  }

  LogService.instance.log('[boot] firebase init OK');

  if (kIsWeb && !kDebugMode) {
    runApp(const _WebUnsupportedApp());
    return;
  }
  if (!kIsWeb) {
    try {
      await DeepLinkService.instance.initialize();
      LogService.instance.log('[boot] deeplink hub ready');
    } catch (e, st) {
      LogService.instance.log('[boot] deeplink init skipped: $e');
      debugPrint('$st');
    }
  }

  if (!kIsWeb) {
    try {
      final info = await PackageInfo.fromPlatform();
      await FirebaseCrashlytics.instance
          .setCustomKey('app_version', '${info.version}+${info.buildNumber}');
      await FirebaseCrashlytics.instance.setCustomKey('chain_id', 80002);
    } catch (_) {/* tests / simulator */}
  }

  runApp(const StrataApp());
}

/// Registered under [MultiProvider]; observes lifecycle for session +
/// metering reconnect ([`P1.10`]).
class _LifecycleShell extends StatefulWidget {
  const _LifecycleShell({required this.child});
  final Widget child;

  @override
  State<_LifecycleShell> createState() => _LifecycleShellState();
}

class _LifecycleShellState extends State<_LifecycleShell>
    with WidgetsBindingObserver {
  StreamSubscription<ParsedDeepLink>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _linkSub = DeepLinkService.instance.links.listen((link) {
      if (!mounted) return;
      final p = context.read<AppProvider>();
      p.applyOnboardingDeepLink(link);
      final r = p.takePendingBootRoute();
      if (r != null) {
        appRouter.go(r);
      }
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final provider = context.read<AppProvider>();
    switch (state) {
      case AppLifecycleState.resumed:
        // ignore: discarded_futures
        provider.onAppResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        provider.onAppPaused();
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class StrataApp extends StatelessWidget {
  const StrataApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()),
      ],
      child: _LifecycleShell(
        child: MaterialApp.router(
          title: 'STRATA',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          routerConfig: appRouter,
        ),
      ),
    );
  }
}

class _WebUnsupportedApp extends StatelessWidget {
  const _WebUnsupportedApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'STRATA',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Wallet not supported on web build yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Please use the Android or iOS build for the STRATA wallet '
                  'demo. Browser localStorage is not a secure place to keep a '
                  'recovery phrase.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
