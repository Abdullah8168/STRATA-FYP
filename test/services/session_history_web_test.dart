import 'package:flutter_test/flutter_test.dart';
import 'package:strata/models/host_model.dart';
import 'package:strata/models/session_model.dart';
import 'package:strata/services/session_history_memory.dart';

void main() {
  test('web session ledger persists rows without path_provider', () async {
    final backend = MemorySessionHistoryBackend();
    final host = const HostModel(
      id: 'lan:127.0.0.1:8080',
      name: 'STRATA Host',
      ssid: 'STRATA-Local',
      pricePerGB: 0.5,
      rating: 0,
      distance: 0,
      availableGB: 0,
      isActive: true,
      walletAddress: '0x1111111111111111111111111111111111111111',
      pricePerGbWei: '1000000000000000',
    );
    final session = SessionModel(
      id: 'sess-1',
      hostId: host.id,
      guestId: 'guest',
      quotaGb: 1,
      usedGb: 0,
      startedAt: DateTime.utc(2026, 9, 25),
    );

    await backend.insertOnStart(session, host);
    await backend.updateMetering('sess-1', 1000);
    final rows = await backend.recentSessions();
    expect(rows, hasLength(1));
    expect(rows.first.bytesUsed, 1000);
    expect(rows.first.hostName, 'STRATA Host');

    await backend.updateOnStop(
      'sess-1',
      bytesUsed: 2000,
      reason: 'client_disconnect',
      endedAt: DateTime.utc(2026, 9, 25, 1),
    );
    final done = await backend.recentSessions();
    expect(done.first.endReason, 'client_disconnect');
    expect(done.first.bytesUsed, 2000);
  });
}
