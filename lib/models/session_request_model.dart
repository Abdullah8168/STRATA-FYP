/// Request/response shapes for the host node's POST /session/start.
///
/// Field names mirror the host_node Pydantic model. Note that quotaBytes is
/// an int which must stay within JSON's safe-integer range (2^53 - 1). For
/// STRATA quotas (max 10 GB ≈ 10.7e9) this is comfortable; if we ever
/// exceed it, switch to a string field in the backend and here.
class SessionStartRequest {
  final String guestWalletAddress;
  final String hostWalletAddress;
  final String macAddress;
  final int quotaBytes;
  final String pricePerGbWei;
  final String nonce;
  final String guestSignature;
  final String? txHash;
  /// Display-only access key from TempAccessKeyScreen (host ignores it).
  final String? accessKey;

  const SessionStartRequest({
    required this.guestWalletAddress,
    required this.hostWalletAddress,
    required this.macAddress,
    required this.quotaBytes,
    required this.pricePerGbWei,
    required this.nonce,
    required this.guestSignature,
    this.txHash,
    this.accessKey,
  });

  Map<String, dynamic> toJson() {
    return {
      'guest_wallet_address': guestWalletAddress,
      'host_wallet_address': hostWalletAddress,
      'mac_address': macAddress,
      'quota_bytes': quotaBytes,
      'price_per_gb_wei': pricePerGbWei,
      'nonce': nonce,
      'guest_signature': guestSignature,
      'tx_hash': txHash,
      if (accessKey != null && accessKey!.isNotEmpty) 'access_key': accessKey,
    };
  }
}

class SessionStartResponse {
  final String sessionId;
  final String status; // "pending_payment" | "active" | "stopped"
  final DateTime startedAt;
  final DateTime expiresAt;
  final String? meteringWsUrl;
  final int bytesUsed;
  final int quotaBytes;
  /// Phase E — 32-byte ref the guest passes to SessionEscrow.openSession.
  final String? sessionRef;
  final String? txHash;
  final int? chainSessionId;

  const SessionStartResponse({
    required this.sessionId,
    required this.status,
    required this.startedAt,
    required this.expiresAt,
    required this.meteringWsUrl,
    required this.bytesUsed,
    required this.quotaBytes,
    this.sessionRef,
    this.txHash,
    this.chainSessionId,
  });

  factory SessionStartResponse.fromJson(Map<String, dynamic> json) {
    return SessionStartResponse(
      sessionId: json['session_id'] as String,
      status: json['status'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      expiresAt: DateTime.parse(json['expires_at'] as String),
      meteringWsUrl: json['metering_ws_url'] as String?,
      bytesUsed: (json['bytes_used'] as num?)?.toInt() ?? 0,
      quotaBytes: (json['quota_bytes'] as num).toInt(),
      sessionRef: json['session_ref'] as String?,
      txHash: json['tx_hash'] as String?,
      chainSessionId: (json['chain_session_id'] as num?)?.toInt(),
    );
  }
}
