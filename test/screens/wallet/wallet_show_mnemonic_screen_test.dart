import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:strata/screens/wallet/wallet_show_mnemonic_screen.dart';

// Show-mnemonic does NOT validate the phrase — it only renders. Use 12
// distinct dummy words so we can assert each cell uniquely.
const _mnemonic =
    'abandon ability able about above absent absorb abstract absurd abuse access accident';

GoRouter _router(String mnemonic) {
  return GoRouter(
    initialLocation: '/wallet/show-mnemonic',
    routes: [
      GoRoute(
        path: '/wallet/show-mnemonic',
        builder: (_, __) => WalletShowMnemonicScreen(mnemonic: mnemonic),
      ),
      GoRoute(
        path: '/wallet/confirm-mnemonic',
        builder: (_, __) => const Scaffold(body: Text('confirm')),
      ),
    ],
  );
}

void main() {
  testWidgets('renders 12 numbered cells', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(_mnemonic)));
    await tester.pump();
    final words = _mnemonic.split(' ');
    for (final w in words) {
      expect(find.text(w), findsOneWidget);
    }
    // The position numbers 1..12 should each appear at least once.
    for (var i = 1; i <= 12; i++) {
      expect(find.text('$i'), findsWidgets);
    }
  });

  testWidgets('"I\'ve written it down" is disabled for the first 5 seconds',
      (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router(_mnemonic)));
    await tester.pump();

    final disabledFinder = find.text('Read carefully…');
    expect(disabledFinder, findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(find.text("I've written it down"), findsOneWidget);
  });
}
