import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../core/constants/host_api_config.dart';
import 'host_discovery_service.dart';

enum ChatroomConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

class ChatroomConnection {
  final ChatroomConnectionState state;
  final String? hostName;
  final Duration? backoff;

  const ChatroomConnection({
    required this.state,
    this.hostName,
    this.backoff,
  });
}

class ChatMessage {
  final String id;
  final String type; // "msg" | "sos" | "system" | "location" | "history"
  final String from;
  final String? clientId;
  final String? text;
  final DateTime ts;
  final double? lat;
  final double? lon;

  const ChatMessage({
    required this.id,
    required this.type,
    required this.from,
    required this.ts,
    this.clientId,
    this.text,
    this.lat,
    this.lon,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'msg',
      from: json['from'] as String? ?? 'unknown',
      clientId: json['client_id'] as String?,
      text: json['text'] as String?,
      ts: DateTime.tryParse((json['ts'] as String?) ?? '') ?? DateTime.now(),
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
    );
  }
}

class ChatPresence {
  final String clientId;
  final String displayName;

  const ChatPresence({required this.clientId, required this.displayName});
}

/// Phase G — emergency chatroom client.
///
/// Auto-reconnects with exponential backoff, buffers up to 32 outgoing
/// messages while the socket is down, surfaces presence updates the
/// server emits every 30s, and falls back to the LAN gateway when the
/// captive portal hasn't published an mDNS service yet.
class ChatroomService {
  ChatroomService({
    HostDiscoveryService? discovery,
    NetworkInfo? networkInfo,
  })  : _discovery = discovery ?? HostDiscoveryService(),
        _networkInfo = networkInfo ?? NetworkInfo(),
        _clientId = const Uuid().v4();

  static const _backoffSequence = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];
  static const _outboxLimit = 32;

  final HostDiscoveryService _discovery;
  final NetworkInfo _networkInfo;
  final String _clientId;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  final _messages = StreamController<ChatMessage>.broadcast();
  final _connection = StreamController<ChatroomConnection>.broadcast();
  final _presence = StreamController<List<ChatPresence>>.broadcast();
  final List<Map<String, dynamic>> _outbox = [];

  String _displayName = 'guest';
  String? _baseUrl;
  bool _disposed = false;
  bool _intentionalClose = false;
  int _backoffIndex = 0;
  Timer? _reconnectTimer;

  Stream<ChatMessage> get messages => _messages.stream;
  Stream<ChatroomConnection> get connection => _connection.stream;
  Stream<List<ChatPresence>> get presence => _presence.stream;

  bool get isConnected => _channel != null;

  /// Open a new connection to the chatroom WebSocket.
  ///
  /// [baseUrl] is the same `http(s)://...` host URL used for the REST
  /// API. We auto-rewrite to `ws(s)://.../ws/chatroom`. Falls back to
  /// the gateway IP when discovery is empty so SOS still works without
  /// DNS.
  Future<void> connect({
    String? baseUrl,
    required String displayName,
  }) async {
    _displayName = displayName;
    _intentionalClose = false;

    String? resolved = baseUrl;
    if (resolved == null || resolved.isEmpty) {
      try {
        final hosts = await _discovery.discover(
          timeout: const Duration(seconds: 2),
        );
        if (hosts.isNotEmpty) resolved = hosts.first.baseUrl;
      } catch (_) {/* swallow */}
    }
    if (resolved == null || resolved.isEmpty) {
      try {
        final gw = await _networkInfo.getWifiGatewayIP();
        if (gw != null && gw.isNotEmpty) {
          resolved = 'http://$gw:${HostApiConfig.defaultPort}';
        }
      } catch (_) {/* swallow */}
    }
    resolved ??= HostApiConfig.defaultBaseUrl;
    _baseUrl = resolved;

    await _open();
  }

  Future<void> _open() async {
    if (_baseUrl == null) return;
    final url = _httpToWs('$_baseUrl/ws/chatroom');

    _emit(ChatroomConnectionState.connecting);
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      // Send the join frame first.
      _send({
        'type': 'join',
        'display_name': _displayName,
        'client_id': _clientId,
      });
      _subscription = _channel!.stream.listen(
        _onFrame,
        onDone: _onDone,
        onError: _onError,
        cancelOnError: false,
      );
      _backoffIndex = 0;
      _emit(ChatroomConnectionState.connected, hostName: _baseUrl);
      // Drain any messages buffered while we were offline.
      final pending = List<Map<String, dynamic>>.from(_outbox);
      _outbox.clear();
      for (final frame in pending) {
        _send(frame);
      }
    } catch (e) {
      debugPrint('[STRATA] chatroom connect failed: ${e.runtimeType}');
      _scheduleReconnect();
    }
  }

  void _onFrame(dynamic raw) {
    Map<String, dynamic> frame;
    try {
      frame = (raw is String ? jsonDecode(raw) : raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = frame['type'];
    switch (type) {
      case 'history':
        final list = (frame['messages'] as List?) ?? const [];
        for (final m in list) {
          if (m is Map<String, dynamic>) {
            _messages.add(ChatMessage.fromJson(m));
          }
        }
        break;
      case 'msg':
      case 'sos':
      case 'system':
      case 'location':
        _messages.add(ChatMessage.fromJson(frame));
        break;
      case 'presence':
        final users = (frame['users'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((u) => ChatPresence(
                  clientId: u['client_id'] as String? ?? '',
                  displayName: u['display_name'] as String? ?? 'unknown',
                ))
            .toList();
        _presence.add(users);
        break;
      case 'error':
        debugPrint(
          '[STRATA] chatroom server error: ${frame['code']} ${frame['message']}',
        );
        break;
      case 'pong':
        break;
    }
  }

  void _onError(Object error) {
    debugPrint('[STRATA] chatroom WS error: ${error.runtimeType}');
  }

  void _onDone() {
    if (_intentionalClose || _disposed) {
      _emit(ChatroomConnectionState.disconnected);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _channel = null;
    _subscription?.cancel();
    _subscription = null;
    final backoff = _backoffSequence[
        _backoffIndex.clamp(0, _backoffSequence.length - 1)];
    _backoffIndex++;
    _emit(ChatroomConnectionState.reconnecting, backoff: backoff);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(backoff, () {
      if (_disposed) return;
      _open();
    });
  }

  // --- send helpers ----------------------------------------------------
  void sendText(String text) => _enqueue({'type': 'msg', 'text': text});

  void sendSos(String text, {double? lat, double? lon}) {
    _enqueue({
      'type': 'sos',
      'text': text,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
    });
  }

  void shareLocation({required double lat, required double lon}) {
    _enqueue({'type': 'location', 'lat': lat, 'lon': lon});
  }

  void _enqueue(Map<String, dynamic> frame) {
    if (_channel == null) {
      if (_outbox.length >= _outboxLimit) {
        _outbox.removeAt(0);
        debugPrint('[STRATA] chatroom outbox full; dropping oldest frame');
      }
      _outbox.add(frame);
      return;
    }
    _send(frame);
  }

  void _send(Map<String, dynamic> frame) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(frame));
    } catch (e) {
      debugPrint('[STRATA] chatroom send failed: ${e.runtimeType}');
      _enqueue(frame);
    }
  }

  Future<void> disconnect() async {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final ch = _channel;
    _channel = null;
    await _subscription?.cancel();
    _subscription = null;
    if (ch != null) {
      await ch.sink.close(ws_status.normalClosure);
    }
    _emit(ChatroomConnectionState.disconnected);
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _messages.close();
    await _connection.close();
    await _presence.close();
  }

  // --- helpers ---------------------------------------------------------
  String _httpToWs(String url) {
    if (url.startsWith('https://')) return 'wss://${url.substring(8)}';
    if (url.startsWith('http://')) return 'ws://${url.substring(7)}';
    return url;
  }

  void _emit(ChatroomConnectionState state,
      {String? hostName, Duration? backoff}) {
    _connection.add(ChatroomConnection(
      state: state,
      hostName: hostName,
      backoff: backoff,
    ));
  }
}
