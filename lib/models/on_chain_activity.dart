/// Models for on-chain wallet activity (STRATA token + SessionEscrow).
library;

enum OnChainActivityKind {
  tokenTransfer,
  paymentSettled,
}

enum OnChainDirection {
  incoming,
  outgoing,
  settlement,
}

enum OnChainTxStatus {
  confirmed,
  pending,
  failed,
  unknown,
}

class OnChainActivity {
  final OnChainActivityKind kind;
  final OnChainDirection direction;
  final OnChainTxStatus status;
  final String txHash;
  final BigInt amountWei;
  final String tokenSymbol;
  final int? blockNumber;
  final DateTime? timestamp;
  final String? counterparty;
  final BigInt? sessionId;
  final BigInt? refundWei;

  const OnChainActivity({
    required this.kind,
    required this.direction,
    required this.status,
    required this.txHash,
    required this.amountWei,
    required this.tokenSymbol,
    this.blockNumber,
    this.timestamp,
    this.counterparty,
    this.sessionId,
    this.refundWei,
  });
}
