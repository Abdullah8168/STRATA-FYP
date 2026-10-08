import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/custom_button.dart';
import '../../providers/app_provider.dart';

class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({super.key});

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  double _dataForSale = 50;
  double _pricePerGB = 150;
  double _maxUsers = 5;

  double get _estimatedEarnings => _dataForSale * _pricePerGB * 0.7;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => context.go('/host/onboarding'),
        ),
        title: const Text('Configure Sharing'),
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
                'Step 2 of 2',
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
                'Set Your\nSharing Terms',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Configure how much bandwidth you want to share and at what price.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 32),
              _buildSliderCard(
                title: 'Data for Sale',
                value: '${_dataForSale.toInt()} GB',
                child: Slider(
                  value: _dataForSale,
                  min: 1,
                  max: 100,
                  divisions: 99,
                  label: '${_dataForSale.toInt()} GB',
                  onChanged: (v) => setState(() => _dataForSale = v),
                ),
              ),
              const SizedBox(height: 16),
              _buildSliderCard(
                title: 'Price per GB',
                value: 'Rs ${_pricePerGB.toStringAsFixed(2)}',
                child: Slider(
                  value: _pricePerGB,
                  min: 10,
                  max: 500,
                  divisions: 49,
                  label: 'Rs ${_pricePerGB.toStringAsFixed(0)}',
                  onChanged: (v) => setState(() => _pricePerGB = v),
                ),
              ),
              const SizedBox(height: 16),
              _buildSliderCard(
                title: 'Max Concurrent Users',
                value: '${_maxUsers.toInt()} users',
                child: Slider(
                  value: _maxUsers,
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: '${_maxUsers.toInt()}',
                  onChanged: (v) => setState(() => _maxUsers = v),
                ),
              ),
              const SizedBox(height: 24),
              _buildEarningsSummary(),
              const SizedBox(height: 32),
              CustomButton(
                label: 'Activate Node',
                onPressed: () {
                  context.read<AppProvider>().activateHostSharing();
                  context.go('/host/dashboard');
                },
                icon: Icons.power_settings_new,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSliderCard({
    required String title,
    required String value,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  value,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          child,
        ],
      ),
    );
  }

  Widget _buildEarningsSummary() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withAlpha(30),
            AppColors.primaryDark.withAlpha(20),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.insights, color: AppColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Estimated Earnings',
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "You'll earn up to",
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          Text(
            '${_estimatedEarnings.toStringAsFixed(2)} STRATA tokens/day',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildSummaryItem('${_dataForSale.toInt()} GB', 'For Sale'),
              const SizedBox(width: 16),
              _buildSummaryItem('Rs ${_pricePerGB.toStringAsFixed(0)}', 'Per GB'),
              const SizedBox(width: 16),
              _buildSummaryItem('${_maxUsers.toInt()}', 'Max Users'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
      ],
    );
  }
}
