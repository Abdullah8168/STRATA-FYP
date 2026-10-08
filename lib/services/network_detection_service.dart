import 'dart:math';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../models/detected_network_model.dart';
import '../models/host_model.dart';

/// Result from a real WiFi scan, carrying both the networks and a
/// human-readable status message so the UI can show exactly why scanning
/// is in a particular state.
class WifiScanResult {
  final List<DetectedNetworkModel> networks;
  final WifiScanStatus status;
  final String? statusMessage;

  const WifiScanResult({
    required this.networks,
    required this.status,
    this.statusMessage,
  });
}

enum WifiScanStatus {
  /// Full scan succeeded — real networks returned.
  success,

  /// Scan ran but returned 0 results (device might still be scanning).
  successEmpty,

  /// Location permission not granted at runtime.
  noLocationPermission,

  /// Location service (GPS) is switched off on the device.
  locationServiceDisabled,

  /// Platform doesn't support scanning (iOS, web).
  notSupported,

  /// Only the currently connected network could be determined.
  connectedOnly,

  /// Scan failed for an unclassified reason.
  failed,
}

class NetworkDetectionService {
  const NetworkDetectionService();

  static const _earthRadiusM = 6371000.0;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Attempts a real WiFi scan. Always returns a [WifiScanResult] — never
  /// throws. The [status] field tells you exactly what happened so the UI
  /// can display an informative message rather than silently showing nothing.
  Future<WifiScanResult> scanRealNetworks({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final info = NetworkInfo();
      final connectedSsidRaw = await info.getWifiName();
      final connectedSsid = connectedSsidRaw?.replaceAll('"', '').trim();

      // ── 1. Check if we CAN start a scan ────────────────────────────────────
      final canStart = await WiFiScan.instance.canStartScan();

      if (canStart != CanStartScan.yes) {
        // Try to explain the failure specifically.
        final (status, msg) = _startScanFailureReason(canStart);

        // Still try to show the connected network even if scanning is blocked.
        final connected = _connectedNetworkOrEmpty(
          connectedSsid,
          latitude,
          longitude,
        );

        if (connected.isNotEmpty) {
          return WifiScanResult(
            networks: connected,
            status: WifiScanStatus.connectedOnly,
            statusMessage:
            '$msg — showing your connected network only.',
          );
        }

        return WifiScanResult(
          networks: const [],
          status: status,
          statusMessage: msg,
        );
      }

      // ── 2. Check if we can READ results ─────────────────────────────────────
      final canGetResults = await WiFiScan.instance.canGetScannedResults();

      if (canGetResults != CanGetScannedResults.yes) {
        final (status, msg) = _getResultsFailureReason(canGetResults);
        return WifiScanResult(
          networks: const [],
          status: status,
          statusMessage: msg,
        );
      }

      // ── 3. Trigger scan and wait briefly for results ─────────────────────────
      await WiFiScan.instance.startScan();
      // Give the OS a moment to populate results; 1.2 s is a good balance.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final results = await WiFiScan.instance.getScannedResults();

      if (results.isEmpty) {
        // Scan worked but device returned nothing yet — could still be scanning.
        return WifiScanResult(
          networks: const [],
          status: WifiScanStatus.successEmpty,
          statusMessage:
          'Scan completed but no networks found. Try refreshing in a moment.',
        );
      }

      // ── 4. Map raw results to our model ──────────────────────────────────────
      final mapped = results.map((r) {
        final ssid = r.ssid.isEmpty ? '<Hidden SSID>' : r.ssid;
        final signal = _signalFromRssi(r.level);
        final distance = _estimateDistanceFromRssi(r.level);
        final band = _frequencyBand(r.frequency);
        final sec = _securityFromCapabilities(r.capabilities);
        final point = _offsetCoordinate(
            latitude, longitude, distance, _bearingFromString(ssid));
        return DetectedNetworkModel(
          id: 'real-$ssid-${r.bssid}',
          ssid: ssid,
          signalStrength: signal,
          distanceMeters: distance,
          source: NetworkSourceType.real,
          networkType: 'wifi',
          securityType: sec,
          frequencyBand: band,
          isConnected: connectedSsid != null && ssid == connectedSsid,
          latitude: point.$1,
          longitude: point.$2,
        );
      }).toList();

      mapped.sort((a, b) => b.signalStrength.compareTo(a.signalStrength));

      return WifiScanResult(
        networks: mapped,
        status: WifiScanStatus.success,
        statusMessage: 'Real WiFi scan active — ${mapped.length} network'
            '${mapped.length == 1 ? '' : 's'} found.',
      );
    } catch (e) {
      return WifiScanResult(
        networks: const [],
        status: WifiScanStatus.failed,
        statusMessage: 'Scan error: $e',
      );
    }
  }

  /// Legacy method kept for backward-compat with existing provider code.
  /// Internally calls [scanRealNetworks] and returns just the list.
  Future<List<DetectedNetworkModel>> detectRealNetworks({
    required double latitude,
    required double longitude,
  }) async {
    final result = await scanRealNetworks(
      latitude: latitude,
      longitude: longitude,
    );
    return result.networks;
  }

  // ---------------------------------------------------------------------------
  // Simulated / dummy networks (unchanged)
  // ---------------------------------------------------------------------------

  List<DetectedNetworkModel> simulateNearbyNetworks({
    required double latitude,
    required double longitude,
    int count = 6,
  }) {
    final seed = (latitude * 10000).round() ^ (longitude * 10000).round();
    final rng = Random(seed);
    final list = <DetectedNetworkModel>[];

    for (var i = 0; i < count; i++) {
      final distance = 60 + rng.nextInt(540);
      final bearing = rng.nextDouble() * 2 * pi;
      final point =
      _offsetCoordinate(latitude, longitude, distance.toDouble(), bearing);
      list.add(DetectedNetworkModel(
        id: 'sim-$i',
        ssid: 'STRATA-SIM-${100 + i}',
        signalStrength: _signalFromDistance(distance.toDouble()),
        distanceMeters: distance.toDouble(),
        source: NetworkSourceType.simulated,
        networkType: 'wifi',
        securityType: i.isEven ? 'WPA2' : 'Open',
        frequencyBand: i.isEven ? '5 GHz' : '2.4 GHz',
        latitude: point.$1,
        longitude: point.$2,
      ));
    }
    return list;
  }

  List<DetectedNetworkModel> fromDummyHosts({
    required List<HostModel> hosts,
    required double latitude,
    required double longitude,
  }) {
    return hosts.asMap().entries.map((entry) {
      final index = entry.key;
      final host = entry.value;
      final bearing = (index + 1) * (pi / 5);
      final point =
      _offsetCoordinate(latitude, longitude, host.distance, bearing);
      return DetectedNetworkModel(
        id: 'dummy-${host.id}',
        ssid: host.ssid,
        signalStrength: _signalFromDistance(host.distance),
        distanceMeters: host.distance,
        source: NetworkSourceType.dummy,
        networkType: 'wifi',
        securityType: 'WPA2',
        frequencyBand: index.isEven ? '5 GHz' : '2.4 GHz',
        latitude: point.$1,
        longitude: point.$2,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  List<DetectedNetworkModel> _connectedNetworkOrEmpty(
      String? connectedSsid,
      double latitude,
      double longitude,
      ) {
    if (connectedSsid == null ||
        connectedSsid.isEmpty ||
        connectedSsid == '<unknown ssid>') {
      return const [];
    }
    return [
      DetectedNetworkModel(
        id: 'real-$connectedSsid',
        ssid: connectedSsid,
        signalStrength: 88,
        distanceMeters: 0,
        source: NetworkSourceType.real,
        networkType: 'wifi',
        securityType: 'Unknown',
        frequencyBand: null,
        isConnected: true,
        latitude: latitude,
        longitude: longitude,
      ),
    ];
  }

  (WifiScanStatus, String) _startScanFailureReason(CanStartScan reason) {
    return switch (reason) {
      CanStartScan.noLocationPermissionRequired ||
      CanStartScan.noLocationPermissionUpgradeAccuracy ||
      CanStartScan.noLocationPermissionDenied =>
      (
      WifiScanStatus.noLocationPermission,
      'Location permission is required to scan for nearby WiFi networks. '
          'Please grant it in Settings → App Permissions.',
      ),
      CanStartScan.noLocationServiceDisabled => (
      WifiScanStatus.locationServiceDisabled,
      'Location services are turned off. '
          'Enable GPS/Location in your device settings to scan for WiFi.',
      ),
      CanStartScan.notSupported => (
      WifiScanStatus.notSupported,
      'WiFi scanning is not supported on this platform.',
      ),
      _ => (
      WifiScanStatus.failed,
      'Cannot start WiFi scan: $reason',
      ),
    };
  }

  (WifiScanStatus, String) _getResultsFailureReason(
      CanGetScannedResults reason) {
    return switch (reason) {
      CanGetScannedResults.noLocationPermissionRequired ||
      CanGetScannedResults.noLocationPermissionUpgradeAccuracy ||
      CanGetScannedResults.noLocationPermissionDenied =>
      (
      WifiScanStatus.noLocationPermission,
      'Location permission denied — cannot read scan results.',
      ),
      CanGetScannedResults.noLocationServiceDisabled => (
      WifiScanStatus.locationServiceDisabled,
      'Location services disabled — cannot read WiFi scan results.',
      ),
      CanGetScannedResults.notSupported => (
      WifiScanStatus.notSupported,
      'Reading scan results is not supported on this platform.',
      ),
      _ => (
      WifiScanStatus.failed,
      'Cannot read scan results: $reason',
      ),
    };
  }

  int _signalFromDistance(double distanceMeters) {
    final raw = 100 - (distanceMeters / 8);
    return raw.clamp(20, 100).round();
  }

  int _signalFromRssi(int rssi) {
    final percent = ((rssi + 100) * 2).clamp(0, 100);
    return percent.round();
  }

  double _estimateDistanceFromRssi(int rssi) {
    const txPower = -55.0;
    const n = 2.6;
    final ratio = (txPower - rssi) / (10 * n);
    return pow(10, ratio).toDouble().clamp(1.0, 800.0);
  }

  String _securityFromCapabilities(String? caps) {
    final c = (caps ?? '').toUpperCase();
    if (c.contains('WPA3')) return 'WPA3';
    if (c.contains('WPA2')) return 'WPA2';
    if (c.contains('WPA')) return 'WPA';
    if (c.contains('WEP')) return 'WEP';
    return 'Open';
  }

  String _frequencyBand(int? frequency) {
    if (frequency == null) return 'Unknown';
    if (frequency >= 4900) return '5 GHz';
    return '2.4 GHz';
  }

  double _bearingFromString(String text) {
    final hash = text.codeUnits.fold<int>(0, (a, b) => a + b);
    return (hash % 360) * pi / 180;
  }

  (double, double) _offsetCoordinate(
      double latitude,
      double longitude,
      double distanceMeters,
      double bearingRadians,
      ) {
    final lat1 = latitude * pi / 180;
    final lon1 = longitude * pi / 180;
    final angDist = distanceMeters / _earthRadiusM;

    final lat2 = asin(
      sin(lat1) * cos(angDist) +
          cos(lat1) * sin(angDist) * cos(bearingRadians),
    );
    final lon2 = lon1 +
        atan2(
          sin(bearingRadians) * sin(angDist) * cos(lat1),
          cos(angDist) - sin(lat1) * sin(lat2),
        );

    return (lat2 * 180 / pi, lon2 * 180 / pi);
  }
}