import '../models/host_model.dart';
import '../models/session_model.dart';
import 'session_history_record.dart';

/// Platform store for the guest session ledger.
abstract class SessionHistoryBackend {
  Future<void> insertOnStart(SessionModel session, HostModel host);
  Future<void> updateOnStop(
    String sessionId, {
    required int bytesUsed,
    required String reason,
    required DateTime endedAt,
    String? txHash,
    int? chainSessionId,
  });
  Future<void> updateMetering(String sessionId, int bytesUsed);
  Future<List<SessionHistoryRecord>> recentSessions({int limit = 50});
  Future<List<SessionHistoryRecord>> sessionsForHost(String hostId);
  Future<void> close();
}
