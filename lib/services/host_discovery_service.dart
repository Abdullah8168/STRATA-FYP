import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import '../core/constants/host_api_config.dart';

/// Phase G — mDNS discovery for STRATA host nodes on the LAN.
///
/// Queries the ``_strata._tcp.local.`` service the host node advertises
/// at startup (see ``host_node/src/strata_host/discovery.py``). Returns a
/// list of [DiscoveredHost] entries used by the real marketplace path
/// (`STRATA_DEMO_MARKETPLACE=false`).
///
/// Results are cached for [_cacheTTL] so a screen that rebuilds doesn't
/// flood the network with mDNS queries.
class DiscoveredHost {
  final String name;
  final String ipv4;
  final int port;
  final String hostWallet;
  final String? sessionEscrow;
  final String? strataToken;
  final String chainId;
  final String txtVersion;
  final bool demoMode;

  const DiscoveredHost({
    required this.name,
    required this.ipv4,
    required this.port,
    required this.hostWallet,
    required this.chainId,
    required this.txtVersion,
    this.sessionEscrow,
    this.strataToken,
    this.demoMode = false,
  });

  String get baseUrl => 'http://$ipv4:$port';

  @override
  String toString() => 'DiscoveredHost($name @ $ipv4:$port)';
}

class HostDiscoveryService {
  HostDiscoveryService();

  static const Duration _cacheTTL = Duration(seconds: 30);
  static const String _serviceType = '_strata._tcp.local.';

  List<DiscoveredHost> _cached = const [];
  DateTime? _cachedAt;

  /// Captive-portal deep link can pin a synthetic discoverable host so the
  /// guest UI matches the router they just joined ([`P0.3`]).
  DiscoveredHost? _captivePortalPin;

  void setCaptivePortalPin(DiscoveredHost? host) {
    _captivePortalPin = host;
  }

  /// Discover STRATA hosts on the local network.
  ///
  /// Returns the cached list if it was populated within the last 30
  /// seconds. Falls back to an empty list when discovery is impossible
  /// (web build, multicast blocked, no permission). Callers that need a
  /// concrete URL should fall through to [HostApiConfig.defaultBaseUrl]
  /// when the result is empty.
  Future<List<DiscoveredHost>> discover({
    Duration timeout = const Duration(seconds: 4),
    bool forceRefresh = false,
  }) async {
    final pin = _captivePortalPin;
    if (pin != null) {
      return <DiscoveredHost>[pin];
    }
    if (!forceRefresh &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTTL) {
      return _cached;
    }
    if (kIsWeb) {
      // multicast_dns needs raw UDP sockets, which browsers do not expose.
      // Fall through to the configured host node (HOST_API_URL) if it answers.
      final probed = await _probeConfiguredHost();
      _cached = probed == null ? const [] : [probed];
      _cachedAt = DateTime.now();
      return _cached;
    }

    final hosts = <DiscoveredHost>[];
    final mdns = MDnsClient(rawDatagramSocketFactory: (
      dynamic host,
      int port, {
      bool? reuseAddress,
      bool? reusePort,
      int? ttl,
    }) {
      return RawDatagramSocket.bind(
        host,
        port,
        reuseAddress: true,
        reusePort: false,
        ttl: ttl ?? 1,
      );
    });

    try {
      await mdns.start();
      final ptrs = mdns.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(_serviceType),
        timeout: timeout,
      );

      await for (final ptr in ptrs) {
        final srvs = mdns.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: timeout,
        );
        await for (final srv in srvs) {
          final aRecords = mdns.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
            timeout: timeout,
          );
          final txtRecords = mdns.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(ptr.domainName),
            timeout: timeout,
          );

          IPAddressResourceRecord? a;
          await for (final rec in aRecords) {
            a = rec;
            break;
          }
          if (a == null) continue;

          final txtMap = <String, String>{};
          await for (final txt in txtRecords) {
            for (final entry in txt.text.split('\n')) {
              final i = entry.indexOf('=');
              if (i <= 0) continue;
              txtMap[entry.substring(0, i)] = entry.substring(i + 1);
            }
            break;
          }

          hosts.add(DiscoveredHost(
            name: ptr.domainName.split('.').first,
            ipv4: a.address.address,
            port: srv.port,
            hostWallet: txtMap['host_wallet'] ?? '',
            sessionEscrow: txtMap['contracts_session_escrow'],
            strataToken: txtMap['contracts_strata_token'],
            chainId: txtMap['chain_id'] ?? '80002',
            txtVersion: txtMap['version'] ?? '0',
            demoMode: txtMap['demo_mode'] == 'true',
          ));
        }
      }
    } catch (e) {
      debugPrint('[STRATA] mDNS discover failed: ${e.runtimeType}');
    } finally {
      mdns.stop();
    }

    _cached = hosts;
    if (_cached.isEmpty) {
      final probed = await _probeConfiguredHost();
      if (probed != null) _cached = [probed];
    }
    // Don't cache "nothing found": the next call should search again.
    _cachedAt = _cached.isEmpty ? null : DateTime.now();
    return _cached;
  }

  /// Asks the configured host (`HOST_API_URL`) for `GET /host/info`.
  ///
  /// This is not a fake host: the card is created only when that process
  /// responds. Used when mDNS is unavailable (web) or returns nothing.
  Future<DiscoveredHost?> _probeConfiguredHost() async {
    final base = HostApiConfig.defaultBaseUrl;
    final root = Uri.tryParse(base);
    if (root == null || root.host.isEmpty) return null;
    final infoUri = root.replace(path: '/host/info', query: '');
    try {
      final resp = await http.get(infoUri).timeout(const Duration(seconds: 5));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map<String, dynamic>) return null;
      final wallet = (body['wallet_address'] ?? body['host_wallet_address'] ?? '')
          .toString();
      if (wallet.isEmpty) return null;
      final port = root.hasPort ? root.port : 8080;
      return DiscoveredHost(
        name: (body['display_name'] ?? body['name'] ?? 'STRATA Host').toString(),
        ipv4: root.host,
        port: port,
        hostWallet: wallet,
        chainId: (body['chain_id'] ?? '80002').toString(),
        txtVersion: (body['version'] ?? '0').toString(),
        demoMode: body['demo_mode'] == true,
      );
    } catch (e) {
      debugPrint('[STRATA] configured host probe failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Returns the first discovered host's baseUrl, or the configured
  /// fallback when discovery yields nothing. Used by HostApiService when
  /// constructing default endpoints.
  Future<String> resolveBaseUrl() async {
    final hosts = await discover();
    if (hosts.isEmpty) return HostApiConfig.defaultBaseUrl;
    return hosts.first.baseUrl;
  }

  void invalidateCache() {
    _cached = const [];
    _cachedAt = null;
  }
}
