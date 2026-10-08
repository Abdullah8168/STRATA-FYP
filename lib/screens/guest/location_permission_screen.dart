import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/real_network_map.dart';
import '../../providers/app_provider.dart';
import '../../services/location_service.dart';

class LocationPermissionScreen extends StatefulWidget {
  const LocationPermissionScreen({super.key});

  @override
  State<LocationPermissionScreen> createState() =>
      _LocationPermissionScreenState();
}

class _LocationPermissionScreenState extends State<LocationPermissionScreen> {
  final _locationService = const LocationService();
  bool _loading = false;
  String? _error;

  Future<void> _grantPermission() async {
    final provider = context.read<AppProvider>();
    final router = GoRouter.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final position = await _locationService.getCurrentLocation();
      if (!mounted) return;
      await provider.updateLocationAndNetworks(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
      );
      router.go('/guest/nearby');
    } catch (e) {
      if (!mounted) return;
      await provider.useFallbackLocation();
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final hasLocation =
        provider.currentLatitude != null && provider.currentLongitude != null;
    final coordinates = hasLocation
        ? '${provider.currentLatitude!.toStringAsFixed(5)}, '
            '${provider.currentLongitude!.toStringAsFixed(5)}'
        : 'No coordinates yet';

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxHeight - 48),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(20),
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.primary, width: 2),
                      ),
                      child: const Icon(
                        Icons.location_on,
                        color: AppColors.primary,
                        size: 64,
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'Enable Location\nAccess',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'STRATA needs your location to discover nearby bandwidth hosts in your area.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 15,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureRow(
                      Icons.wifi_find_outlined,
                      'Find hosts within 500m radius',
                    ),
                    _buildFeatureRow(
                      Icons.security_outlined,
                      'Your location stays private',
                    ),
                    _buildFeatureRow(
                      Icons.speed_outlined,
                      'Connect to the fastest nearby node',
                    ),
                    const SizedBox(height: 12),
                    RealNetworkMap(
                      height: 180,
                      userLatitude: provider.currentLatitude ?? 33.6844,
                      userLongitude: provider.currentLongitude ?? 73.0479,
                      networks: provider.detectedNetworks,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Detected: $coordinates',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (provider.locationAccuracyMeters != null)
                      Text(
                        'Accuracy: ±${provider.locationAccuracyMeters!.toStringAsFixed(0)} m',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(
                            color: AppColors.error, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 20),
                    CustomButton(
                      label: 'Grant Permission',
                      onPressed: _grantPermission,
                      loading: _loading,
                      icon: Icons.my_location,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () async {
                        final provider = context.read<AppProvider>();
                        final router = GoRouter.of(context);
                        router.go('/guest/nearby');
                        provider.useFallbackLocation();
                      },
                      child: const Text(
                        'Not now',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppColors.primary, size: 18),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
