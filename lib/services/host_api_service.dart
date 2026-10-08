import 'dart:async';

import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/host_api_config.dart';
import '../models/session_request_model.dart';

/// Parsed `GET /host/info` payload.
class HostNodeInfo {
  final String displayName;
  final String ssid;
  final String walletAddress;
  final String pricePerGbWei;
  final double? pricePerGB;
  final bool demoMode;
  final bool chainEnabled;
  final String version;
  final String? guestIface;
  final String? wanIface;

  HostNodeInfo({
    required this.displayName,
    required this.ssid,
    required this.walletAddress,
    required this.pricePerGbWei,
    this.pricePerGB,
    this.demoMode = false,
    this.chainEnabled = false,
    this.version = '0.1.0',
    this.guestIface,
    this.wanIface,
  });

  factory HostNodeInfo.fromJson(Map<String, dynamic> json) {
    return HostNodeInfo(
      displayName: (json['name'] ?? json['display_name'] ?? 'STRATA Host')
          as String,
      ssid: (json['ssid'] ?? '') as String,
      walletAddress: (json['wallet_address'] ??
              json['host_wallet_address'] ??
              '') as String,
      pricePerGbWei:
          (json['price_per_gb_wei'] ?? json['pricePerGbWei'] ?? '1000000000000000')
              as String,
      pricePerGB: (json['price_per_gb'] as num?)?.toDouble(),
      demoMode: json['demo_mode'] as bool? ?? false,
      chainEnabled: json['chain_enabled'] as bool? ?? false,
      version: (json['version'] ?? '0.1.0').toString(),
      guestIface: json['guest_iface'] as String?,
      wanIface: json['wan_iface'] as String?,
    );
  }
}

/// Parsed `GET /portal/client` — MAC the guest must sign over.
class ClientIdentity {
  final String? clientIp;
  final String? macAddress;
  final String macSource;
  final String message;

  const ClientIdentity({
    required this.clientIp,
    required this.macAddress,
    required this.macSource,
    required this.message,
  });

  factory ClientIdentity.fromJson(Map<String, dynamic> json) {
    return ClientIdentity(
      clientIp: json['client_ip'] as String?,
      macAddress: json['mac_address'] as String?,
      macSource: (json['mac_source'] as String?) ?? 'unknown',
      message: (json['message'] as String?) ?? '',
    );
  }
}

/// Phase G — Dio-backed client for the STRATA host node.
///
/// Adds typed exceptions, a request-id header on every call (so a user
/// support ticket can quote a request id from the toast), retry-once on
/// connection-refused / timeout for idempotent GETs, and a
/// [watchStatus] broadcast stream that polls /session/status until the
/// session is `stopped` or the consumer cancels.
class HostApiException implements Exception {
  final int? statusCode;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  final String? requestId;

  const HostApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
    this.requestId,
  });

  @override
  String toString() {
    final ridSuffix = requestId == null ? '' : ' [$requestId]';
    return 'HostApiException($statusCode $code)$ridSuffix: $message';
  }
}

class SessionStatus {
  final String sessionId;
  final String status;
  final int bytesUsed;
  final int quotaBytes;
  final String? txHash;
  final int? chainSessionId;
  final String? stopReason;
  final DateTime? stoppedAt;
  final DateTime? startedAt;

  /// Host EIP-191 signature over `[receipt]` when `[closeSession]` is ready.
  final String? hostSettlementSigHex;
  final int? settlementBytesConsumed;
  final int? settlementQuotaBytes;
  /// `keccak256` receipt hash echoed for transparency ([`P1.7`]).
  final String? receiptHashHex;

  /// Router-side settlement: null until settled, then `settled` (the router
  /// sent closeSession itself), `closed_by_guest` or `failed`.
  final String? settlementStatus;

  /// Download / upload split of [bytesUsed] (router `bytes_in` / `bytes_out`).
  /// Null on older routers that only report the total.
  final int? bytesIn;
  final int? bytesOut;

  const SessionStatus({
    required this.sessionId,
    required this.status,
    required this.bytesUsed,
    required this.quotaBytes,
    this.txHash,
    this.chainSessionId,
    this.stopReason,
    this.stoppedAt,
    this.startedAt,
    this.hostSettlementSigHex,
    this.settlementBytesConsumed,
    this.settlementQuotaBytes,
    this.receiptHashHex,
    this.settlementStatus,
    this.bytesIn,
    this.bytesOut,
  });

  factory SessionStatus.fromJson(Map<String, dynamic> json) {
    return SessionStatus(
      sessionId: json['session_id'] as String,
      status: json['status'] as String,
      bytesUsed: (json['bytes_used'] as num?)?.toInt() ?? 0,
      quotaBytes: (json['quota_bytes'] as num?)?.toInt() ?? 0,
      txHash: json['tx_hash'] as String?,
      chainSessionId: (json['chain_session_id'] as num?)?.toInt(),
      stopReason: json['stop_reason'] as String?,
      stoppedAt: json['stopped_at'] == null
          ? null
          : DateTime.tryParse(json['stopped_at'] as String),
      startedAt: json['started_at'] == null
          ? null
          : DateTime.tryParse(json['started_at'] as String),
      hostSettlementSigHex: json['host_settlement_sig'] as String? ??
          json['host_sig'] as String?,
      settlementBytesConsumed:
          (json['settlement_bytes_consumed'] as num?)?.toInt() ??
              (json['bytes_consumed'] as num?)?.toInt(),
      settlementQuotaBytes:
          (json['settlement_quota_bytes'] as num?)?.toInt() ??
              (json['quota_bytes'] as num?)?.toInt(),
      receiptHashHex: json['receipt_hash'] as String?,
      settlementStatus: json['settlement_status'] as String?,
      bytesIn: (json['bytes_in'] as num?)?.toInt(),
      bytesOut: (json['bytes_out'] as num?)?.toInt(),
    );
  }
}

enum StopReason { guestStopped, hostRevoked }

extension StopReasonString on StopReason {
  String get wireValue {
    switch (this) {
      case StopReason.guestStopped:
        return 'client_disconnect';
      case StopReason.hostRevoked:
        return 'host_stop';
    }
  }
}

class _RequestIdInterceptor extends Interceptor {
  static const _uuid = Uuid();
  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    // Stamp a request id so error toasts can quote it.
    options.headers['X-Request-Id'] = _uuid.v4();
    handler.next(options);
  }
}

class HostApiService {
  HostApiService({String? baseUrl, Dio? dio})
      : _baseUrl = baseUrl ?? HostApiConfig.defaultBaseUrl,
        _dio = dio ?? _buildDio(baseUrl ?? HostApiConfig.defaultBaseUrl) {
    // When a custom Dio is provided (typical in unit tests with a fake
    // adapter), make sure our request-id interceptor is still attached.
    // This keeps the contract — every outgoing request carries an
    // X-Request-Id — true regardless of how the service was constructed.
    if (dio != null && !_dio.interceptors.any((i) => i is _RequestIdInterceptor)) {
      _dio.interceptors.add(_RequestIdInterceptor());
    }
  }

  String _baseUrl;
  final Dio _dio;

  String get baseUrl => _baseUrl;

  /// Alias used by My Hosting diagnostics.
  String get baseUrlHint => _baseUrl;

  /// Update the base URL after mDNS discovery resolves a real host.
  /// Subsequent calls hit the new URL without recreating Dio.
  void setBaseUrl(String url) {
    _baseUrl = url;
    _dio.options.baseUrl = url;
  }

  static Dio _buildDio(String base) {
    final dio = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: HostApiConfig.requestTimeout,
      receiveTimeout: HostApiConfig.requestTimeout,
      sendTimeout: HostApiConfig.requestTimeout,
      contentType: 'application/json',
      responseType: ResponseType.json,
    ));
    dio.interceptors.add(_RequestIdInterceptor());
    return dio;
  }

  Future<SessionStartResponse> startSession(SessionStartRequest req) async {
    return _dispatchJson<SessionStartResponse>(
      idempotent: false,
      doRequest: () => _dio.post('/session/start', data: req.toJson()),
      decode: (data) => SessionStartResponse.fromJson(data),
    );
  }

  Future<void> notifyPayment({
    required String sessionId,
    required String txHash,
  }) async {
    await _dispatchRaw(
      idempotent: false,
      doRequest: () => _dio.post(
        '/session/$sessionId/payment',
        data: {'tx_hash': txHash},
      ),
    );
  }

  /// Phase I stub — registers FCM tokens with Pi when the backend adds it.
  Future<void> registerNotificationsToken(String token) async {
    try {
      await _dispatchRaw(
        idempotent: false,
        doRequest: () => _dio
            .post('/user/notifications/register', data: {'fcm_token': token}),
      );
    } on HostApiException catch (e) {
      developer.log(
        'registerNotificationsToken skipped (${e.code})',
        name: 'HostApiService',
      );
    }
  }

  /// Round-trip time of the last successful `/session/status` call — a real
  /// ping to the host node, shown on the guest dashboard.
  Duration? lastStatusRtt;

  Future<SessionStatus> getStatus({String? sessionId, String? macAddress}) async {
    final params = <String, dynamic>{};
    if (sessionId != null) params['session_id'] = sessionId;
    if (macAddress != null) params['mac_address'] = macAddress;
    final sw = Stopwatch()..start();
    final status = await _dispatchJson<SessionStatus>(
      idempotent: true,
      doRequest: () => _dio.get('/session/status', queryParameters: params),
      decode: (data) => SessionStatus.fromJson(data),
    );
    lastStatusRtt = sw.elapsed;
    return status;
  }

  /// Phase D-era convenience wrapper kept around for the AppProvider
  /// poll loop and the existing tests.
  Future<SessionStatus> getSessionStatus(String sessionId) =>
      getStatus(sessionId: sessionId);

  /// Best-effort host metadata — returns null when endpoint is absent.
  Future<HostNodeInfo?> getHostInfo() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/host/info');
      final data = r.data;
      if (data != null && r.statusCode != null && r.statusCode! < 400) {
        return HostNodeInfo.fromJson(data);
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null || code == 404 || code == 501 || code == 503) {
        return null;
      }
      return null;
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Iteration 2 — guest IP/MAC as seen by the host (`GET /portal/client`).
  Future<ClientIdentity> fetchClientIdentity() async {
    final response = await _dispatchRaw(
      idempotent: true,
      doRequest: () => _dio.get('/portal/client'),
    );
    final body = response.data;
    if (body is! Map<String, dynamic>) {
      throw const HostApiException(
        statusCode: null,
        code: 'BAD_RESPONSE',
        message: 'Expected JSON object from /portal/client',
      );
    }
    return ClientIdentity.fromJson(body);
  }

  /// Live session list for host dashboards (`GET /host/sessions`).
  Future<List<Map<String, dynamic>>> fetchHostSessions() async {
    final response = await _dispatchRaw(
      idempotent: true,
      doRequest: () => _dio.get('/host/sessions'),
    );
    final body = response.data;
    if (body is! Map<String, dynamic>) return const [];
    final raw = body['sessions'];
    if (raw is! List<dynamic>) return const [];
    return raw
        .map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
        .toList(growable: false);
  }

  /// Optional live firewall MAC list (`GET /admin/firewall/state`).
  ///
  /// Requires ``--dart-define=STRATA_ADMIN_TOKEN=...`` matching the host's
  /// ``ADMIN_TOKEN``. Returns an empty list when the token is unset (My Hosting
  /// falls back to ``/host/sessions``). Throws [HostApiException] only when
  /// the token is set but the host rejects it or the call fails.
  Future<List<String>> fetchAdminAuthedMacs() async {
    const token = String.fromEnvironment('STRATA_ADMIN_TOKEN', defaultValue: '');
    if (token.isEmpty) {
      return const [];
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/admin/firewall/state',
        options: Options(
          headers: <String, dynamic>{'Authorization': 'Bearer $token'},
        ),
      );
      final data = response.data;
      if (data == null) return const [];
      final macs = data['authed_macs'];
      if (macs is! List<dynamic>) return const [];
      return macs.map((e) => e.toString()).toList(growable: false);
    } on DioException catch (e) {
      throw _toException(e);
    }
  }

  /// Whether Flutter was built with ``STRATA_ADMIN_TOKEN``.
  static bool get hasAdminTokenConfigured {
    const token = String.fromEnvironment('STRATA_ADMIN_TOKEN', defaultValue: '');
    return token.isNotEmpty;
  }

  Future<SessionStatus> stopSession({
    required String sessionId,
    required StopReason reason,
  }) {
    return _dispatchJson<SessionStatus>(
      idempotent: false,
      doRequest: () => _dio.post('/session/stop', data: {
        'session_id': sessionId,
        'reason': reason.wireValue,
      }),
      decode: (data) => SessionStatus.fromJson(data),
    );
  }

  /// Live broadcast of /session/status. Polls every [interval] until the
  /// stream is cancelled or the session reaches a terminal state.
  Stream<SessionStatus> watchStatus(
    String sessionId, {
    Duration interval = const Duration(seconds: 2),
  }) async* {
    while (true) {
      try {
        final status = await getStatus(sessionId: sessionId);
        yield status;
        if (status.status == 'stopped') return;
      } on HostApiException catch (e, st) {
        developer.log(
          'watchStatus poll skipped',
          name: 'HostApiService',
          error: e,
          stackTrace: st,
        );
      }
      await Future<void>.delayed(interval);
    }
  }

  // --- internals ---------------------------------------------------------

  Future<T> _dispatchJson<T>({
    required bool idempotent,
    required Future<Response<dynamic>> Function() doRequest,
    required T Function(Map<String, dynamic>) decode,
  }) async {
    final response = await _dispatchRaw(
      idempotent: idempotent,
      doRequest: doRequest,
    );
    final body = response.data;
    if (body is Map<String, dynamic>) return decode(body);
    throw HostApiException(
      statusCode: response.statusCode,
      code: 'BAD_RESPONSE',
      message: 'Host returned a non-JSON body for ${response.requestOptions.path}',
      requestId: response.requestOptions.headers['X-Request-Id']?.toString(),
    );
  }

  Future<Response<dynamic>> _dispatchRaw({
    required bool idempotent,
    required Future<Response<dynamic>> Function() doRequest,
  }) async {
    try {
      return await doRequest();
    } on DioException catch (e) {
      if (idempotent && _isRetryable(e)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          return await doRequest();
        } on DioException catch (e2) {
          throw _toException(e2);
        }
      }
      throw _toException(e);
    }
  }

  bool _isRetryable(DioException e) {
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout;
  }

  HostApiException _toException(DioException e) {
    final response = e.response;
    final requestId = e.requestOptions.headers['X-Request-Id']?.toString();
    if (response == null) {
      return HostApiException(
        statusCode: null,
        code: 'HOST_UNREACHABLE',
        message: 'Could not reach the host node (${e.type.name}).',
        requestId: requestId,
      );
    }
    final body = response.data;
    Map<String, dynamic>? envelope;
    if (body is Map<String, dynamic>) {
      final err = body['error'];
      if (err is Map<String, dynamic>) envelope = err;
    }
    return HostApiException(
      statusCode: response.statusCode,
      code: (envelope?['code'] as String?) ?? 'HTTP_${response.statusCode}',
      message: (envelope?['message'] as String?) ??
          'Host node returned status ${response.statusCode}',
      details: envelope?['details'] as Map<String, dynamic>?,
      requestId: requestId,
    );
  }
}
