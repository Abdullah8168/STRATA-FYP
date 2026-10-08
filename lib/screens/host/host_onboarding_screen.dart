import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/custom_text_field.dart';
import '../../widgets/real_network_map.dart';
import '../../providers/app_provider.dart';
import '../../services/location_service.dart';

class HostOnboardingScreen extends StatefulWidget {
  const HostOnboardingScreen({super.key});

  @override
  State<HostOnboardingScreen> createState() => _HostOnboardingScreenState();
}

class _HostOnboardingScreenState extends State<HostOnboardingScreen> {
  final _ispController = TextEditingController(text: 'Comcast Business');
  final _ssidController = TextEditingController(text: 'STRATA-MyNode-01');
  final _locationController =
      TextEditingController(text: '37.7749° N, 122.4194° W');
  String _selectedPlan = '100 Mbps';
  bool _detectingLocation = false;
  final _locationService = const LocationService();

  final _plans = ['10 Mbps', '50 Mbps', '100 Mbps', '1 Gbps'];

  @override
  void dispose() {
    _ispController.dispose();
    _ssidController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final hasLocation =
        provider.currentLatitude != null && provider.currentLongitude != null;
    final coords = hasLocation
        ? '${provider.currentLatitude!.toStringAsFixed(5)}, '
            '${provider.currentLongitude!.toStringAsFixed(5)}'
        : _locationController.text;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => context.go('/role'),
        ),
        title: const Text('Set Up Your Node'),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16, top: 8, bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Center(
              child: Text(
                'Step 1 of 2',
                style: TextStyle(color: AppColors.primary, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Configure\nYour Node',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tell us about your network setup so guests can connect.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 32),
              CustomTextField(
                label: 'ISP / Provider Name',
                controller: _ispController,
                prefixIcon: const Icon(Icons.business_outlined),
              ),
              const SizedBox(height: 16),
              CustomTextField(
                label: 'SSID (WiFi Network Name)',
                controller: _ssidController,
                prefixIcon: const Icon(Icons.wifi),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedPlan,
                dropdownColor: AppColors.surface,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Internet Plan Speed',
                  filled: true,
                  fillColor: AppColors.surface,
                  prefixIcon: const Icon(Icons.speed_outlined,
                      color: AppColors.textSecondary),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.divider),
                  ),
                ),
                items: _plans.map((plan) {
                  return DropdownMenuItem(
                    value: plan,
                    child: Text(plan),
                  );
                }).toList(),
                onChanged: (v) => setState(() => _selectedPlan = v!),
              ),
              const SizedBox(height: 16),
              CustomTextField(
                label: 'GPS Location',
                controller: _locationController,
                readOnly: true,
                prefixIcon: const Icon(Icons.location_on_outlined),
                suffixIcon: IconButton(
                  icon: _detectingLocation
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location, color: AppColors.primary),
                  onPressed: _detectingLocation
                      ? null
                      : () async {
                          final provider = context.read<AppProvider>();
                          final messenger = ScaffoldMessenger.of(context);
                          setState(() => _detectingLocation = true);
                          try {
                            final position =
                                await _locationService.getCurrentLocation();
                            if (!mounted) return;
                            final formatted =
                                '${position.latitude.toStringAsFixed(5)}, '
                                '${position.longitude.toStringAsFixed(5)}';
                            _locationController.text = formatted;
                            await provider.updateLocationAndNetworks(
                              latitude: position.latitude,
                              longitude: position.longitude,
                              accuracyMeters: position.accuracy,
                            );
                          } catch (e) {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                  content: Text(e
                                      .toString()
                                      .replaceFirst('Exception: ', ''))),
                            );
                          } finally {
                            if (mounted) {
                              setState(() => _detectingLocation = false);
                            }
                          }
                        },
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Node Location',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              RealNetworkMap(
                height: 220,
                userLatitude: provider.currentLatitude ?? 33.6844,
                userLongitude: provider.currentLongitude ?? 73.0479,
                networks: provider.detectedNetworks,
              ),
              const SizedBox(height: 8),
              Text(
                'Detected coordinates: $coords',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 32),
              CustomButton(
                label: 'Next: Configure Sharing',
                onPressed: () => context.go('/host/setup'),
                icon: Icons.arrow_forward,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
