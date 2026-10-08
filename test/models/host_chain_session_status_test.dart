import 'package:flutter_test/flutter_test.dart';
import 'package:strata/models/host_chain_session_status.dart';
import 'package:strata/services/host_api_service.dart';

void main() {
  group('HostChainSessionStatus settlement fields', () {
    test('fromSessionStatus copies host receipt bytes', () {
      final s = SessionStatus(
        sessionId: 'abc',
        status: 'stopped',
        bytesUsed: 999,
        quotaBytes: 10000000,
        chainSessionId: 42,
        hostSettlementSigHex: '0xdead',
        settlementBytesConsumed: 1500000,
        settlementQuotaBytes: 10000000,
        stoppedAt: DateTime.utc(2026, 1, 1),
      );
      final st = HostChainSessionStatus.fromSessionStatus(s);
      expect(st.canClose, isTrue);
      expect(st.settlementBytesConsumed, 1500000);
      expect(st.settlementQuotaBytes, 10000000);
      expect(st.chainSessionId, 42);
    });

    test('canClose false without signature', () {
      final st = HostChainSessionStatus(
        status: 'stopped',
        chainSessionId: 1,
        hostSettlementSigHex: null,
      );
      expect(st.canClose, isFalse);
    });
  });
}
