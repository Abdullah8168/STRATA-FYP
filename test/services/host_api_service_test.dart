import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata/models/session_request_model.dart';
import 'package:strata/services/host_api_service.dart';

/// Phase G — HostApiService is now Dio-backed. We swap in a custom
/// `HttpClientAdapter` so the tests can craft canned responses without
/// touching the network.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);
  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options);
  }
}

ResponseBody _jsonResponse(int status, String body) {
  return ResponseBody.fromString(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

SessionStartRequest _validRequest() => const SessionStartRequest(
      guestWalletAddress: '0x1111111111111111111111111111111111111111',
      hostWalletAddress: '0x2222222222222222222222222222222222222222',
      macAddress: 'aa:bb:cc:dd:ee:ff',
      quotaBytes: 5368709120,
      pricePerGbWei: '1000000000000000',
      nonce: '11111111-2222-4333-8444-555555555555',
      guestSignature: '0xabc',
    );

HostApiService _buildService(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return HostApiService(baseUrl: 'http://localhost:8080', dio: dio);
}

void main() {
  group('HostApiService', () {
    test('parses a Phase A 201 envelope', () async {
      final adapter = _FakeAdapter((options) async {
        expect(options.path, '/session/start');
        return _jsonResponse(
          201,
          '{"session_id":"00000000-0000-4000-8000-000000000001",'
          '"status":"active",'
          '"started_at":"2026-05-03T00:00:00Z",'
          '"expires_at":"2026-05-03T01:00:00Z",'
          '"metering_ws_url":"/ws/metering/abc",'
          '"bytes_used":0,'
          '"quota_bytes":5368709120}',
        );
      });
      final svc = _buildService(adapter);
      final response = await svc.startSession(_validRequest());
      expect(response.sessionId, '00000000-0000-4000-8000-000000000001');
      expect(response.status, 'active');
      expect(response.quotaBytes, 5368709120);
    });

    test('parses a 409 NONCE_REPLAY into HostApiException', () async {
      final adapter = _FakeAdapter((options) async {
        return _jsonResponse(
          409,
          '{"error":{"code":"NONCE_REPLAY",'
          '"message":"nonce already used",'
          '"details":{"nonce":"11111111"}}}',
        );
      });
      final svc = _buildService(adapter);
      try {
        await svc.startSession(_validRequest());
        fail('should have thrown');
      } on HostApiException catch (e) {
        expect(e.statusCode, 409);
        expect(e.code, 'NONCE_REPLAY');
        expect(e.message, 'nonce already used');
        expect(e.requestId, isNotNull,
            reason: 'Phase G adds an X-Request-Id header on every call');
      }
    });
  });
}
