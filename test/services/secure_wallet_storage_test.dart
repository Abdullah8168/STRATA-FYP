import 'package:flutter_test/flutter_test.dart';
import 'package:strata/services/secure_wallet_storage.dart';

void main() {
  group('SecureWalletStorage (in-memory)', () {
    test('write / read / delete roundtrip', () async {
      final backing = <String, String>{};
      final storage = SecureWalletStorage.forTesting(backing);
      expect(await storage.exists(), isFalse);
      expect(await storage.readMnemonic(), isNull);

      await storage.writeMnemonic('twelve word mnemonic placeholder one');
      expect(await storage.exists(), isTrue);
      expect(await storage.readMnemonic(),
          'twelve word mnemonic placeholder one');

      await storage.deleteMnemonic();
      expect(await storage.exists(), isFalse);
      expect(await storage.readMnemonic(), isNull);
    });

    test('two instances sharing the same backing see the same value', () async {
      final backing = <String, String>{};
      final a = SecureWalletStorage.forTesting(backing);
      final b = SecureWalletStorage.forTesting(backing);

      await a.writeMnemonic('shared phrase');
      expect(await b.readMnemonic(), 'shared phrase');
    });
  });
}
