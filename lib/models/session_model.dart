class SessionModel {
  /// Host node session id (`GET /session/status` key).
  final String id;
  final String hostId;
  final String guestId;
  final int quotaGb;
  final double usedGb;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// Base URL used for host API when this session began (restoration).
  final String? hostBaseUrl;

  /// Display + on-chain selection after app relaunch.
  final String? persistedHostName;
  final String? persistedHostWallet;
  final String? persistedHostSsid;

  /// Opening block time from chain (dispute countdown) when known.
  final DateTime? openedOnChainAt;

  const SessionModel({
    required this.id,
    required this.hostId,
    required this.guestId,
    required this.quotaGb,
    required this.usedGb,
    required this.startedAt,
    this.endedAt,
    this.hostBaseUrl,
    this.persistedHostName,
    this.persistedHostWallet,
    this.persistedHostSsid,
    this.openedOnChainAt,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'host_id': hostId,
      'guest_id': guestId,
      'quota_gb': quotaGb,
      'used_gb': usedGb,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt?.toIso8601String(),
      'host_base_url': hostBaseUrl,
      'persisted_host_name': persistedHostName,
      'persisted_host_wallet': persistedHostWallet,
      'persisted_host_ssid': persistedHostSsid,
      'opened_on_chain_at': openedOnChainAt?.toIso8601String(),
    };
  }

  factory SessionModel.fromJson(Map<String, dynamic> json) {
    return SessionModel(
      id: json['id'] as String,
      hostId: json['host_id'] as String,
      guestId: json['guest_id'] as String,
      quotaGb: (json['quota_gb'] as num?)?.toInt() ?? 0,
      usedGb: (json['used_gb'] as num?)?.toDouble() ?? 0,
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: json['ended_at'] != null
          ? DateTime.tryParse(json['ended_at'] as String)
          : null,
      hostBaseUrl: json['host_base_url'] as String?,
      persistedHostName: json['persisted_host_name'] as String?,
      persistedHostWallet: json['persisted_host_wallet'] as String?,
      persistedHostSsid: json['persisted_host_ssid'] as String?,
      openedOnChainAt: json['opened_on_chain_at'] != null
          ? DateTime.tryParse(json['opened_on_chain_at'] as String)
          : null,
    );
  }

  SessionModel copyWith({
    String? id,
    String? hostId,
    String? guestId,
    int? quotaGb,
    double? usedGb,
    DateTime? startedAt,
    DateTime? endedAt,
    String? hostBaseUrl,
    String? persistedHostName,
    String? persistedHostWallet,
    String? persistedHostSsid,
    DateTime? openedOnChainAt,
  }) {
    return SessionModel(
      id: id ?? this.id,
      hostId: hostId ?? this.hostId,
      guestId: guestId ?? this.guestId,
      quotaGb: quotaGb ?? this.quotaGb,
      usedGb: usedGb ?? this.usedGb,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      hostBaseUrl: hostBaseUrl ?? this.hostBaseUrl,
      persistedHostName: persistedHostName ?? this.persistedHostName,
      persistedHostWallet: persistedHostWallet ?? this.persistedHostWallet,
      persistedHostSsid: persistedHostSsid ?? this.persistedHostSsid,
      openedOnChainAt: openedOnChainAt ?? this.openedOnChainAt,
    );
  }
}
