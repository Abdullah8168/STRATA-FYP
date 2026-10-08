import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/host_model.dart';
import '../models/session_model.dart';
import 'session_history_backend.dart';
import 'session_history_record.dart';

/// Mobile / desktop ledger: SQLite under the OS application documents directory.
class IoSessionHistoryBackend implements SessionHistoryBackend {
  IoSessionHistoryBackend({Database? testDb}) : _testDb = testDb;

  final Database? _testDb;
  Database? _db;

  Future<Database> _open() async {
    if (_testDb != null) return _testDb!;
    _db ??= await openDatabase(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'strata_sessions.db',
      ),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    host_id TEXT,
    host_name TEXT,
    host_address TEXT,
    quota_bytes INTEGER,
    bytes_used INTEGER,
    started_at INTEGER,
    ended_at INTEGER,
    end_reason TEXT,
    tx_hash TEXT,
    chain_session_id INTEGER,
    rate_rs_per_gb REAL
);
CREATE INDEX idx_sessions_started_at ON sessions(started_at DESC);
''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE sessions ADD COLUMN rate_rs_per_gb REAL');
        }
      },
    );
    return _db!;
  }

  @override
  Future<void> insertOnStart(SessionModel session, HostModel host) async {
    final db = await _open();
    final quotaBytes = session.quotaGb * (1024 * 1024 * 1024);
    await db.insert(
      'sessions',
      {
        'id': session.id,
        'host_id': host.id,
        'host_name': host.name,
        'host_address': host.walletAddress,
        'quota_bytes': quotaBytes,
        'bytes_used': (session.usedGb * (1024 * 1024 * 1024)).round(),
        'started_at': session.startedAt.millisecondsSinceEpoch,
        'ended_at': null,
        'end_reason': null,
        'tx_hash': null,
        'chain_session_id': null,
        'rate_rs_per_gb': host.pricePerGB,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    final db = await _open();
    await db.update(
      'sessions',
      {
        'bytes_used': bytesUsed,
        'end_reason': reason,
        'ended_at': endedAt.millisecondsSinceEpoch,
        if (txHash != null) 'tx_hash': txHash,
        if (chainSessionId != null) 'chain_session_id': chainSessionId,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  @override
  Future<void> updateMetering(String sessionId, int bytesUsed) async {
    final db = await _open();
    await db.update(
      'sessions',
      {'bytes_used': bytesUsed},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  @override
  Future<List<SessionHistoryRecord>> recentSessions({int limit = 50}) async {
    final db = await _open();
    final rows = await db.query(
      'sessions',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(SessionHistoryRecord.fromRow).toList();
  }

  @override
  Future<List<SessionHistoryRecord>> sessionsForHost(String hostId) async {
    final db = await _open();
    final rows = await db.query(
      'sessions',
      where: 'host_id = ?',
      whereArgs: [hostId],
      orderBy: 'started_at DESC',
    );
    return rows.map(SessionHistoryRecord.fromRow).toList();
  }

  @override
  Future<void> close() async {
    if (_testDb == null && _db != null) {
      await _db!.close();
      _db = null;
    }
  }
}

SessionHistoryBackend createSessionHistoryBackend() => IoSessionHistoryBackend();
