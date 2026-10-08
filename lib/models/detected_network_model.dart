enum NetworkSourceType { real, simulated, dummy }

class DetectedNetworkModel {
  final String id;
  final String ssid;
  final int signalStrength; // 0 - 100
  final double distanceMeters;
  final NetworkSourceType source;
  final String networkType;
  final String securityType;
  final String? frequencyBand;
  final bool isConnected;
  final double latitude;
  final double longitude;

  const DetectedNetworkModel({
    required this.id,
    required this.ssid,
    required this.signalStrength,
    required this.distanceMeters,
    required this.source,
    required this.networkType,
    required this.securityType,
    this.frequencyBand,
    this.isConnected = false,
    required this.latitude,
    required this.longitude,
  });
}
