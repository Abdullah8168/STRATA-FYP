import 'dart:convert';

import 'package:web/web.dart' as web;

import '../models/host_model.dart';
import '../models/session_model.dart';
import 'session_history_backend.dart';
import 'session_history_memory.dart';
import 'session_history_record.dart';

/// Browser ledger. `getApplicationDocumentsDirectory` and sqflite have no
/// web implementation, so rows live in origin `localStorage`.
class WebSessionHistoryBackend implements SessionHistoryBackend {
  WebSessionHistoryBackend() : _inner = _load();

  static const storageKey = 'strata.sessions.v1';

  final MemorySessionHistoryBackend _inner;

  static MemorySessionHistoryBackend _load() {
    final raw = web.window.localStorage.getItem(storageKey);
    final rows = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) rows.add(Map<String, dynamic>.from(item));
        }
      }
    }
    return MemorySessionHistoryBackend(
      rows: rows,
      onChange: (next) {
        web.window.localStorage.setItem(storageKey, jsonEncode(next));
      },
    );
  }

  @override
  Future<void> insertOnStart(SessionModel session, HostModel host) =>
      _inner.insertOnStart(session, host);

  @override
  Future<void> updateOnStop(
    String sessionId, {
    required int bytesUsed,
    required String reason,
    required DateTime endedAt,
    String? txHash,
    int? chainSessionId,
  }) =>
      _inner.updateOnStop(
        sessionId,
        bytesUsed: bytesUsed,
        reason: reason,
        endedAt: endedAt,
        txHash: txHash,
        chainSessionId: chainSessionId,
      );

  @override
  Future<void> updateMetering(String sessionId, int bytesUsed) =>
      _inner.updateMetering(sessionId, bytesUsed);

  @override
  Future<List<SessionHistoryRecord>> recentSessions({int limit = 50}) =>
      _inner.recentSessions(limit: limit);

  @override
  Future<List<SessionHistoryRecord>> sessionsForHost(String hostId) =>
      _inner.sessionsForHost(hostId);

  @override
  Future<void> close() => _inner.close();
}

SessionHistoryBackend createSessionHistoryBackend() => WebSessionHistoryBackend();
