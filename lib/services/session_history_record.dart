/// One persisted guest session row.
class SessionHistoryRecord {
  final String id;
  final String hostId;
  final String hostName;
  final String hostAddress;
  final int quotaBytes;
  final int bytesUsed;
  final int startedAtMs;
  final int? endedAtMs;
  final String? endReason;
  final String? txHash;
  final int? chainSessionId;
  final double? rateRsPerGb;

  const SessionHistoryRecord({
    required this.id,
    required this.hostId,
    required this.hostName,
    required this.hostAddress,
    required this.quotaBytes,
    required this.bytesUsed,
    required this.startedAtMs,
    this.endedAtMs,
    this.endReason,
    this.txHash,
    this.chainSessionId,
    this.rateRsPerGb,
  });

  factory SessionHistoryRecord.fromRow(Map<String, Object?> m) =>
      SessionHistoryRecord(
        id: m['id']! as String,
        hostId: m['host_id'] as String? ?? '',
        hostName: m['host_name'] as String? ?? '',
        hostAddress: m['host_address'] as String? ?? '',
        quotaBytes: (m['quota_bytes'] as num?)?.toInt() ?? 0,
        bytesUsed: (m['bytes_used'] as num?)?.toInt() ?? 0,
        startedAtMs: (m['started_at'] as num?)?.toInt() ?? 0,
        endedAtMs: (m['ended_at'] as num?)?.toInt(),
        endReason: m['end_reason'] as String?,
        txHash: m['tx_hash'] as String?,
        chainSessionId: (m['chain_session_id'] as num?)?.toInt(),
        rateRsPerGb: (m['rate_rs_per_gb'] as num?)?.toDouble(),
      );
}
