import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/detected_network_model.dart';
import '../theme/app_theme.dart';

class RealNetworkMap extends StatelessWidget {
  final double userLatitude;
  final double userLongitude;
  final List<DetectedNetworkModel> networks;
  final double height;

  const RealNetworkMap({
    super.key,
    required this.userLatitude,
    required this.userLongitude,
    required this.networks,
    this.height = 260,
  });

  @override
  Widget build(BuildContext context) {
    final center = LatLng(userLatitude, userLongitude);
    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: FlutterMap(
        options: MapOptions(
          initialCenter: center,
          initialZoom: 15,
          minZoom: 3,
          maxZoom: 19,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.strata.app',
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: center,
                width: 40,
                height: 40,
                child: const Icon(
                  Icons.my_location,
                  color: AppColors.accent,
                  size: 30,
                ),
              ),
              ...networks.map(
                (n) => Marker(
                  point: LatLng(n.latitude, n.longitude),
                  width: 34,
                  height: 34,
                  child: Icon(
                    Icons.wifi,
                    size: 22,
                    color: _colorForSource(n.source),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _colorForSource(NetworkSourceType source) {
    switch (source) {
      case NetworkSourceType.real:
        return const Color(0xFF4CAF50);
      case NetworkSourceType.simulated:
        return AppColors.primary;
      case NetworkSourceType.dummy:
        return AppColors.textSecondary;
    }
  }
}
