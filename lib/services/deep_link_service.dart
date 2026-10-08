import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Parses `strata://onboard?...` captive-portal payloads ([`P0.3`]).
enum DeepLinkKind { onboarding }

class OnboardingDeepLink {
  final Uri uri;
  final String? portalIp;
  final int portalPort;
  final String? mac;
  /// Host wallet / router identity advertised by the captive page.
  final String? hostAddress;

  OnboardingDeepLink({
    required this.uri,
    this.portalIp,
    this.portalPort = 8080,
    this.mac,
    this.hostAddress,
  });

  String get baseUrl {
    final ip = portalIp ?? '';
    if (ip.isEmpty) return '';
    return Uri(scheme: 'http', host: ip, port: portalPort > 0 ? portalPort : 8080)
        .origin;
  }
}

class ParsedDeepLink {
  final DeepLinkKind kind;
  final OnboardingDeepLink onboarding;

  const ParsedDeepLink({required this.kind, required this.onboarding});
}

ParsedDeepLink? parseDeepLinkUri(Uri uri) {
  final schemeOk = uri.scheme == 'strata';
  final hostOk = uri.host.toLowerCase() == 'onboard';
  if (!schemeOk || !hostOk) return null;

  final q = uri.queryParameters;
  final portParsed =
      int.tryParse(q['portal_port'] ?? q['port'] ?? '') ?? 8080;
  return ParsedDeepLink(
    kind: DeepLinkKind.onboarding,
    onboarding: OnboardingDeepLink(
      uri: uri,
      portalIp: q['portal_ip'] ?? q['ip'],
      portalPort: portParsed,
      mac: q['mac'],
      hostAddress: q['host_address'],
    ),
  );
}

final class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final StreamController<ParsedDeepLink> _controller =
      StreamController<ParsedDeepLink>.broadcast();
  ParsedDeepLink? coldStartPending;
  AppLinks? _appLinks;

  Stream<ParsedDeepLink> get links => _controller.stream;

  ParsedDeepLink? consumePendingColdStart() {
    final r = coldStartPending;
    coldStartPending = null;
    return r;
  }

  /// Call after `WidgetsFlutterBinding.ensureInitialized()`.
  Future<void> initialize() async {
    _appLinks = AppLinks();

    try {
      final incoming = await _appLinks!.getInitialLink();
      if (incoming != null) {
        final parsed = parseDeepLinkUri(incoming);
        if (parsed != null) coldStartPending ??= parsed;
      }
    } on Object catch (e, st) {
      debugPrint('[STRATA] getInitialLink: $e $st');
    }

    _appLinks!.uriLinkStream.listen(
      (u) {
        final p = parseDeepLinkUri(u);
        if (p != null && !_controller.isClosed) _controller.add(p);
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[STRATA] uriLinkStream: $e $st');
      },
    );
  }
}
