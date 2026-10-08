import '../models/host_model.dart';
import '../models/session_model.dart';
import 'session_history_backend.dart';
import 'session_history_record.dart';

/// In-memory session ledger. Web persists the same rows via `localStorage`;
/// tests use this class directly so they do not import browser libraries.
class MemorySessionHistoryBackend implements SessionHistoryBackend {
  MemorySessionHistoryBackend({List<Map<String, dynamic>>? rows, this.onChange})
      : _rows = rows ?? <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> _rows;
  final void Function(List<Map<String, dynamic>> rows)? onChange;

  void _touch() => onChange?.call(_rows);

  Map<String, dynamic> _rowFor(SessionModel session, HostModel host) {
    return {
      'id': session.id,
      'host_id': host.id,
      'host_name': host.name,
      'host_address': host.walletAddress,
      'quota_bytes': session.quotaGb * (1024 * 1024 * 1024),
      'bytes_used': (session.usedGb * (1024 * 1024 * 1024)).round(),
      'started_at': session.startedAt.millisecondsSinceEpoch,
      'ended_at': null,
      'end_reason': null,
      'tx_hash': null,
      'chain_session_id': null,
      'rate_rs_per_gb': host.pricePerGB,
    };
  }

  @override
  Future<void> insertOnStart(SessionModel session, HostModel host) async {
    _rows.removeWhere((r) => r['id'] == session.id);
    _rows.add(_rowFor(session, host));
    _touch();
  }

  @override
  Future<void> updateOnStop(
    String sessionId, {
    required int bytesUsed,
    required String reason,
    required DateTime endedAt,
    String? txHash,
    int? chainSessionId,
  }) async {
    for (final row in _rows) {
      if (row['id'] != sessionId) continue;
      row['bytes_used'] = bytesUsed;
      row['end_reason'] = reason;
      row['ended_at'] = endedAt.millisecondsSinceEpoch;
      if (txHash != null) row['tx_hash'] = txHash;
      if (chainSessionId != null) row['chain_session_id'] = chainSessionId;
    }
    _touch();
  }

  @override
  Future<void> updateMetering(String sessionId, int bytesUsed) async {
    for (final row in _rows) {
      if (row['id'] == sessionId) row['bytes_used'] = bytesUsed;
    }
    _touch();
  }

  List<SessionHistoryRecord> _sorted({int? limit, String? hostId}) {
    final rows = _rows.where((r) => hostId == null || r['host_id'] == hostId).toList()
      ..sort((a, b) => ((b['started_at'] as num?) ?? 0)
          .compareTo((a['started_at'] as num?) ?? 0));
    final sliced = limit == null ? rows : rows.take(limit);
    return sliced.map(SessionHistoryRecord.fromRow).toList();
  }

  @override
  Future<List<SessionHistoryRecord>> recentSessions({int limit = 50}) async =>
      _sorted(limit: limit);

  @override
  Future<List<SessionHistoryRecord>> sessionsForHost(String hostId) async =>
      _sorted(hostId: hostId);

  @override
  Future<void> close() async {}
}
