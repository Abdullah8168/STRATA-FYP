/// Represents the on-chain status of a session as returned by the host node
/// or derived from chain events. Used by [AppProvider.lastHostChainSessionStatus]
/// and read by guest_dashboard_screen.dart to decide whether to show the
/// close / dispute settlement UI.
class HostChainSessionStatus {
  /// One of: 'active', 'stopped', 'closed', 'disputed'
  final String status;

  /// The on-chain session ID as returned by the host node (chain_session_id).
  /// Null until the host node confirms the on-chain open event.
  final int? chainSessionId;

  /// Hex-encoded host settlement signature. Non-null and non-empty once the
  /// host has signed the close parameters and the guest can submit closeSession.
  final String? hostSettlementSigHex;

  /// When the host marked the session as stopped (off-chain). Used to detect
  /// the 24-hour dispute window expiry.
  final DateTime? stoppedAt;

  /// Bytes the host signed into the EIP-191 receipt (authoritative for closeSession).
  final int? settlementBytesConsumed;
  final int? settlementQuotaBytes;

  /// Router-side settlement (`settled`, `closed_by_guest`, `failed`), null
  /// while still open. Once set, the guest must not call closeSession.
  final String? settlementStatus;

  /// True once the escrow session is closed on-chain (by router or guest).
  bool get isSettled =>
      settlementStatus == 'settled' || settlementStatus == 'closed_by_guest';

  const HostChainSessionStatus({
    required this.status,
    this.chainSessionId,
    this.hostSettlementSigHex,
    this.stoppedAt,
    this.settlementBytesConsumed,
    this.settlementQuotaBytes,
    this.settlementStatus,
  });

  /// Named constructor to build directly from a [SessionStatus] snapshot.
  factory HostChainSessionStatus.fromSessionStatus(dynamic s) {
    return HostChainSessionStatus(
      status: s.status as String,
      chainSessionId: s.chainSessionId as int?,
      hostSettlementSigHex: s.hostSettlementSigHex as String?,
      stoppedAt: s.stoppedAt as DateTime? ??
          (s.status == 'stopped' ? DateTime.now() : null),
      settlementBytesConsumed: s.settlementBytesConsumed as int?,
      settlementQuotaBytes: s.settlementQuotaBytes as int?,
      settlementStatus: s.settlementStatus as String?,
    );
  }

  /// Convenience: true when the session is stopped AND the host has provided
  /// a settlement signature the guest can use to call closeSession on-chain.
  bool get canClose =>
      status == 'stopped' &&
      !isSettled &&
      chainSessionId != null &&
      hostSettlementSigHex != null &&
      hostSettlementSigHex!.isNotEmpty;

  /// Convenience: true when the session is stopped, no host signature is
  /// available, and the 24-hour dispute window has not yet expired.
  bool get canDispute =>
      status == 'stopped' &&
      chainSessionId != null &&
      (hostSettlementSigHex == null || hostSettlementSigHex!.isEmpty) &&
      stoppedAt != null &&
      DateTime.now().difference(stoppedAt!).inHours < 24;
}
