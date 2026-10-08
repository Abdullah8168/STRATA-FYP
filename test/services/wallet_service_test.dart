import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:strata/services/secure_wallet_storage.dart';
import 'package:strata/services/wallet_service.dart';

// Standard Hardhat / Anvil / Foundry default test mnemonic. Anyone reproducing
// the BIP44 m/44'/60'/0'/0/0 derivation will get the same address.
//
// Golden-value note: this is the canonical Hardhat account #0 for path
// m/44'/60'/0'/0/0. It was captured once on the dev machine to pin our
// BIP-39 + BIP-32 + secp256k1 stack. If this changes, our derivation
// pipeline regressed — investigate before updating.
const _hardhatMnemonic =
    'test test test test test test test test test test test junk';
const _hardhatAccount0 = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';

void main() {
  group('WalletService.createWallet', () {
    test('returns a valid 12-word BIP-39 mnemonic', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      final result = await svc.createWallet();
      expect(result.mnemonic.split(RegExp(r'\s+')).length, 12);
      expect(bip39.validateMnemonic(result.mnemonic), isTrue);
    });

    test('does NOT persist on creation (must commit explicitly)', () async {
      final backing = <String, String>{};
      final svc =
          WalletService(storage: SecureWalletStorage.forTesting(backing));
      await svc.createWallet();
      expect(backing, isEmpty);
      expect(await svc.hasWallet(), isFalse);
    });
  });

  group('WalletService.importWallet', () {
    test('derives the canonical Hardhat account 0 address', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      final creds = await svc.importWallet(_hardhatMnemonic);
      expect(creds.hexAddress, _hardhatAccount0);
    });

    test('rejects 11-word phrase', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      const eleven = 'test test test test test test test test test test test';
      expect(() => svc.importWallet(eleven),
          throwsA(isA<WalletImportException>()));
    });

    test('rejects 13-word phrase', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      const thirteen =
          'test test test test test test test test test test test junk junk';
      expect(() => svc.importWallet(thirteen),
          throwsA(isA<WalletImportException>()));
    });

    test('rejects gibberish', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      expect(() => svc.importWallet('asdf qwerty zxcv'),
          throwsA(isA<WalletImportException>()));
    });
  });

  group('WalletService.loadWallet', () {
    test('throws WalletNotFoundException when storage empty', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      expect(() => svc.loadWallet(),
          throwsA(isA<WalletNotFoundException>()));
    });

    test('round-trips through importWallet', () async {
      final backing = <String, String>{};
      final svc =
          WalletService(storage: SecureWalletStorage.forTesting(backing));
      await svc.importWallet(_hardhatMnemonic);
      final reloaded = await svc.loadWallet();
      expect(reloaded.hexAddress, _hardhatAccount0);
    });
  });

  group('WalletService.signMessage', () {
    test('produces a 65-byte 0x-prefixed signature deterministically',
        () async {
      final backing = <String, String>{};
      final svc =
          WalletService(storage: SecureWalletStorage.forTesting(backing));
      await svc.importWallet(_hardhatMnemonic);
      final a = await svc.signMessage('hello strata');
      final b = await svc.signMessage('hello strata');
      expect(a, b,
          reason:
              'EIP-191 personal_sign should be deterministic for the same key + message');
      expect(a.startsWith('0x'), isTrue);
      // 65 bytes = 130 hex chars + '0x' prefix.
      expect(a.length, 132);
      // v byte must be 27 or 28 per EIP-191.
      final v = int.parse(a.substring(130), radix: 16);
      expect(v == 27 || v == 28, isTrue, reason: 'got v=$v');
    });
  });

  group('WalletService.signSessionStart', () {
    test('uses the canonical message format and signs it', () async {
      final svc = WalletService(
          storage: SecureWalletStorage.forTesting(<String, String>{}));
      await svc.importWallet(_hardhatMnemonic);

      final result = await svc.signSessionStart(
        guestAddress: _hardhatAccount0,
        hostAddress: '0x1111111111111111111111111111111111111111',
        macAddress: 'aa:bb:cc:dd:ee:ff',
        quotaBytes: BigInt.from(5368709120),
        nonce: '11111111-2222-4333-8444-555555555555',
      );

      expect(
        result.canonicalMessage,
        'STRATA-SESSION-START\n'
        'guest:$_hardhatAccount0\n'
        'host:0x1111111111111111111111111111111111111111\n'
        'mac:aa:bb:cc:dd:ee:ff\n'
        'quota:5368709120\n'
        'nonce:11111111-2222-4333-8444-555555555555',
      );
      expect(result.signature.startsWith('0x'), isTrue);
      expect(result.signature.length, 132);
    });
  });
}
