import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists interrupted payment payloads so Retry resumes at the FAILED step
/// instead of restarting at step one ([`P1.1`]).
class PendingPaymentStore {
  PendingPaymentStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String storageKey = 'strata.pending_payment.v1';

  final FlutterSecureStorage _storage;

  Future<void> save(PendingPaymentSnapshot s) =>
      _storage.write(key: storageKey, value: jsonEncode(s.toJson()));

  Future<PendingPaymentSnapshot?> load() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return PendingPaymentSnapshot.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: storageKey);
}

enum PaymentPipelineStep {
  idle,
  signAndReserve,
  approve,
  openSession,
  waitHost,
}

class PendingPaymentSnapshot {
  /// Where work should resume.
  final PaymentPipelineStep failedAt;
  final String? sessionId;
  final String? sessionRefHex;
  final String? nonce;
  final String? hostWallet;
  final int quotaBytes;
  final String pricePerGbWei;

  final bool approveUnlimited;
  final BigInt? amountWei;
  final String? approveTxHash;
  final String? openTxHash;

  const PendingPaymentSnapshot({
    required this.failedAt,
    required this.sessionId,
    required this.sessionRefHex,
    required this.nonce,
    required this.hostWallet,
    required this.quotaBytes,
    required this.pricePerGbWei,
    required this.approveUnlimited,
    this.amountWei,
    this.approveTxHash,
    this.openTxHash,
  });

  Map<String, dynamic> toJson() => {
        'failed_at': failedAt.name,
        'session_id': sessionId,
        'session_ref': sessionRefHex,
        'nonce': nonce,
        'host_wallet': hostWallet,
        'quota_bytes': quotaBytes,
        'price_per_gb_wei': pricePerGbWei,
        'approve_unlimited': approveUnlimited,
        if (amountWei != null) 'amount_wei': amountWei!.toString(),
        'approve_tx_hash': approveTxHash,
        'open_tx_hash': openTxHash,
      };

  factory PendingPaymentSnapshot.fromJson(Map<String, dynamic> json) {
    return PendingPaymentSnapshot(
      failedAt: PaymentPipelineStep.values.byName(json['failed_at'] as String),
      sessionId: json['session_id'] as String?,
      sessionRefHex: json['session_ref'] as String?,
      nonce: json['nonce'] as String?,
      hostWallet: json['host_wallet'] as String?,
      quotaBytes: (json['quota_bytes'] as num?)?.toInt() ?? 0,
      pricePerGbWei:
          json['price_per_gb_wei'] as String? ?? '1000000000000000',
      approveUnlimited: json['approve_unlimited'] as bool? ?? true,
      amountWei: json['amount_wei'] != null
          ? BigInt.tryParse(json['amount_wei'] as String)
          : null,
      approveTxHash: json['approve_tx_hash'] as String?,
      openTxHash: json['open_tx_hash'] as String?,
    );
  }
}
