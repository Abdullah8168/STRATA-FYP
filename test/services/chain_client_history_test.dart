import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:strata/services/chain_client.dart';
import 'package:web3dart/crypto.dart' show bytesToHex, keccakUtf8;
import 'package:web3dart/web3dart.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

http.StreamedResponse _streamed(Object body) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Future<Map<String, dynamic>> _rpcBody(http.BaseRequest req) async {
  final r = req as http.Request;
  return jsonDecode(r.body) as Map<String, dynamic>;
}

String _padAddress(String addr) {
  final h = addr.toLowerCase().replaceFirst('0x', '');
  return '0x${h.padLeft(64, '0')}';
}

String _transferTopic0() {
  // keccak256("Transfer(address,address,uint256)")
  final hash = keccakUtf8('Transfer(address,address,uint256)');
  return bytesToHex(hash, include0x: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fetchWalletHistory parses Transfer logs for the wallet', () async {
    final wallet = '0x1111111111111111111111111111111111111111';
    final other = '0x2222222222222222222222222222222222222222';
    final token = '0x3333333333333333333333333333333333333333';
    final topic0 = _transferTopic0();
    final valueHex =
        '0x${BigInt.from(10).pow(18).toRadixString(16).padLeft(64, '0')}';

    final fake = _FakeClient((req) async {
      final body = await _rpcBody(req);
      final method = body['method'] as String;
      if (method == 'eth_chainId') {
        return _streamed({'jsonrpc': '2.0', 'id': 1, 'result': '0x7a69'});
      }
      if (method == 'eth_blockNumber') {
        return _streamed({'jsonrpc': '2.0', 'id': 1, 'result': '0xa'});
      }
      if (method == 'eth_getLogs') {
        final params = (body['params'] as List).first as Map<String, dynamic>;
        final topics = params['topics'] as List;
        // Incoming: topic2 == wallet
        final isIncoming = topics.length >= 3 &&
            topics[2] is List &&
            (topics[2] as List).isNotEmpty &&
            (topics[2] as List).first == _padAddress(wallet);
        if (isIncoming) {
          return _streamed({
            'jsonrpc': '2.0',
            'id': 1,
            'result': [
              {
                'removed': false,
                'logIndex': '0x0',
                'transactionIndex': '0x0',
                'transactionHash':
                    '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'blockHash':
                    '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                'blockNumber': '0x5',
                'address': token,
                'data': valueHex,
                'topics': [
                  topic0,
                  _padAddress(other),
                  _padAddress(wallet),
                ],
              }
            ],
          });
        }
        return _streamed({'jsonrpc': '2.0', 'id': 1, 'result': []});
      }
      if (method == 'eth_getBlockByNumber') {
        return _streamed({
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'number': '0x5',
            'timestamp': '0x66f00000',
            'hash':
                '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          },
        });
      }
      return _streamed({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'message': 'unexpected ${body['method']}'},
      });
    });

    final client = ChainClient(
      rpcUrl: 'http://test.example/rpc',
      httpClient: fake,
      chainId: 31337,
    );

    final history = await client.fetchWalletHistory(
      wallet: EthereumAddress.fromHex(wallet),
      tokenAddress: EthereumAddress.fromHex(token),
      escrowAddress: null,
      lookbackBlocks: 20,
      chunkSize: 50,
    );

    expect(history, hasLength(1));
    expect(history.first.amountWei, BigInt.from(10).pow(18));
    expect(history.first.txHash.startsWith('0xaaaa'), isTrue);
    expect(history.first.direction.name, 'incoming');
    client.dispose();
  });
}
