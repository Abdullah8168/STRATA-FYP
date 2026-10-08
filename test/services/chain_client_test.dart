import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:strata/services/chain_client.dart';
import 'package:web3dart/web3dart.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) _handler;
  int callCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    callCount++;
    return _handler(request);
  }
}

http.StreamedResponse _streamed(int status, String body) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    headers: {'content-type': 'application/json'},
  );
}

Future<String?> _rpcMethod(http.BaseRequest req) async {
  if (req is! http.Request) return null;
  if (req.body.isEmpty) return null;
  try {
    final m = jsonDecode(req.body);
    return m['method'] as String?;
  } catch (_) {
    return null;
  }
}

void main() {
  group('ChainClient', () {
    test('getNativeBalance parses an eth_getBalance JSON-RPC response',
        () async {
      final fake = _FakeClient((req) async {
        final method = await _rpcMethod(req);
        if (method == 'eth_chainId') {
          return _streamed(
            200,
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': '0x13882'}),
          );
        }
        return _streamed(
          200,
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': '0x4563918244F40000',
          }),
        );
      });
      final client = ChainClient(
        rpcUrl: 'http://test.example/rpc',
        httpClient: fake,
      );

      final balance = await client.getNativeBalance(
        EthereumAddress.fromHex('0x1111111111111111111111111111111111111111'),
      );
      expect(balance, BigInt.parse('5000000000000000000'));
      client.dispose();
    });

    test('getTokenBalance returns null when contract is null', () async {
      final fake = _FakeClient((_) async => _streamed(200, '{}'));
      final client = ChainClient(
        rpcUrl: 'http://test.example/rpc',
        httpClient: fake,
      );
      final result = await client.getTokenBalance(
        EthereumAddress.fromHex('0x1111111111111111111111111111111111111111'),
        null,
      );
      expect(result, isNull);
      expect(fake.callCount, 0);
      client.dispose();
    });

    test('persistent network error throws ChainClientException', () async {
      final fake = _FakeClient((_) async {
        throw http.ClientException('boom');
      });
      final client = ChainClient(
        rpcUrl: 'http://test.example/rpc',
        httpClient: fake,
      );
      try {
        await client.getNativeBalance(
          EthereumAddress.fromHex('0x1111111111111111111111111111111111111111'),
        );
        fail('should have thrown');
      } catch (e) {
        expect(e, isA<ChainClientException>());
      }
      expect(fake.callCount, 2);
      client.dispose();
    });
  });
}
