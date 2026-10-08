import '../models/host_model.dart';
import '../models/session_model.dart';
import 'session_history_backend.dart';
import 'session_history_backend_selector.dart';
import 'session_history_record.dart';

export 'session_history_record.dart';

/// Local guest session ledger.
///
/// IO uses SQLite in the application documents directory.
/// Web uses `localStorage` because `path_provider` /
/// `getApplicationDocumentsDirectory` has no browser implementation.
class SessionHistoryService {
  SessionHistoryService({SessionHistoryBackend? backend})
      : _backend = backend ?? createSessionHistoryBackend();

  final SessionHistoryBackend _backend;

  Future<void> insertOnStart(SessionModel session, HostModel host) =>
      _backend.insertOnStart(session, host);

  Future<void> updateOnStop(
    String sessionId, {
    required int bytesUsed,
    required String reason,
    required DateTime endedAt,
    String? txHash,
    int? chainSessionId,
  }) =>
      _backend.updateOnStop(
        sessionId,
        bytesUsed: bytesUsed,
        reason: reason,
        endedAt: endedAt,
        txHash: txHash,
        chainSessionId: chainSessionId,
      );

  Future<void> updateMetering(String sessionId, int bytesUsed) =>
      _backend.updateMetering(sessionId, bytesUsed);

  Future<List<SessionHistoryRecord>> recentSessions({int limit = 50}) =>
      _backend.recentSessions(limit: limit);

  Future<List<SessionHistoryRecord>> sessionsForHost(String hostId) =>
      _backend.sessionsForHost(hostId);

  Future<void> close() => _backend.close();
}
