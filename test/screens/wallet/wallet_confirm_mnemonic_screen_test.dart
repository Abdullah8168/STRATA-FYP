import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:strata/providers/app_provider.dart';
import 'package:strata/screens/wallet/wallet_confirm_mnemonic_screen.dart';
import 'package:strata/services/chain_client.dart';
import 'package:strata/services/host_api_service.dart';
import 'package:strata/services/secure_wallet_storage.dart';
import 'package:strata/services/wallet_service.dart';
import 'package:http/http.dart' as http;

class _NeverClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Future<http.StreamedResponse>.error(
      http.ClientException('offline (test)'),
    );
  }
}

class _OfflineDioAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline (test)',
    );
  }
}

Dio _offlineDio() {
  final dio = Dio();
  dio.httpClientAdapter = _OfflineDioAdapter();
  return dio;
}

// A real BIP-39 mnemonic with a valid checksum (the canonical Hardhat /
// Foundry test phrase). Required because commitWalletAfterConfirmation
// validates via bip39.validateMnemonic before persisting.
const _mnemonic =
    'test test test test test test test test test test test junk';

GoRouter _router(AppProvider provider) {
  return GoRouter(
    initialLocation: '/wallet/confirm-mnemonic',
    routes: [
      GoRoute(
        path: '/wallet/confirm-mnemonic',
        builder: (_, __) =>
            const WalletConfirmMnemonicScreen(mnemonic: _mnemonic),
      ),
      GoRoute(
        path: '/host/onboarding',
        builder: (_, __) => const Scaffold(body: Text('host-onboarding')),
      ),
      GoRoute(
        path: '/guest/location',
        builder: (_, __) => const Scaffold(body: Text('guest-location')),
      ),
    ],
  );
}

AppProvider _buildProvider(Map<String, String> backing) {
  return AppProvider(
    walletService:
        WalletService(storage: SecureWalletStorage.forTesting(backing)),
    chainClient: ChainClient(
        rpcUrl: 'http://offline.invalid/rpc', httpClient: _NeverClient()),
    hostApiService:
        HostApiService(baseUrl: 'http://offline.invalid', dio: _offlineDio()),
  );
}

Widget _wrap(AppProvider provider) {
  return ChangeNotifierProvider<AppProvider>.value(
    value: provider,
    child: MaterialApp.router(routerConfig: _router(provider)),
  );
}

void main() {
  testWidgets('wrong words show error snackbar', (tester) async {
    final provider = _buildProvider({});
    await tester.pumpWidget(_wrap(provider));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      await tester.enterText(fields.at(i), 'wrong');
    }
    await tester.tap(find.text('Confirm & continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Some words did not match. Try again.'), findsOneWidget);
  });

  testWidgets('all-correct words commit and navigate forward', (tester) async {
    final provider = _buildProvider({});
    await tester.pumpWidget(_wrap(provider));
    await tester.pump(const Duration(milliseconds: 200));

    final words = _mnemonic.split(' ');
    final fields = find.byType(TextField);
    final labelFinder = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').startsWith('Word #'),
    );
    // The InputDecorator renders the label twice (floating + body). Dedupe
    // by data while preserving first-seen order.
    final seen = <String>{};
    final indexes = <int>[];
    for (final t in tester.widgetList<Text>(labelFinder)) {
      final data = t.data ?? '';
      if (!data.startsWith('Word #')) continue;
      if (!seen.add(data)) continue;
      indexes.add(int.parse(data.substring('Word #'.length)));
    }
    expect(indexes.length, 3,
        reason: 'expected 3 unique Word #N labels but got ${indexes.length}');
    for (var i = 0; i < 3; i++) {
      await tester.enterText(fields.at(i), words[indexes[i] - 1]);
    }
    await tester.tap(find.text('Confirm & continue'));
    // Pump in small increments and short-circuit as soon as we see either
    // the snackbar or the new route. SnackBars auto-dismiss after 4 s, so we
    // can't pump for too long before checking.
    bool sawSuccess = false;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Wallet ready ✓').evaluate().isNotEmpty ||
          find.text('guest-location').evaluate().isNotEmpty ||
          find.text('host-onboarding').evaluate().isNotEmpty) {
        sawSuccess = true;
        break;
      }
    }

    final visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final mismatchedSnackbar =
        find.text('Some words did not match. Try again.').evaluate().isNotEmpty;
    expect(mismatchedSnackbar, isFalse,
        reason: 'words were typed in the wrong order — debug indexes=$indexes');
    expect(sawSuccess, isTrue,
        reason: 'Expected snackbar or new route within the pump window. '
            'Indexes=$indexes. Visible=$visible.');
  });
}
