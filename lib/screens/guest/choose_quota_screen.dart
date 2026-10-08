import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../providers/app_provider.dart';
import '../../widgets/custom_text_field.dart';

class ChooseQuotaScreen extends StatefulWidget {
  const ChooseQuotaScreen({super.key});

  @override
  State<ChooseQuotaScreen> createState() => _ChooseQuotaScreenState();
}

class _ChooseQuotaScreenState extends State<ChooseQuotaScreen> {
  int? _selectedPackage;
  final _customController = TextEditingController();
  bool _isCustom = false;

  static const _packages = [
    {'gb': 1, 'label': '1 GB', 'badge': null, 'desc': 'Light browsing'},
    {'gb': 5, 'label': '5 GB', 'badge': 'POPULAR', 'desc': 'Everyday use'},
    {'gb': 10, 'label': '10 GB', 'badge': 'BEST VALUE', 'desc': 'Power user'},
  ];

  double _totalPrice(double pricePerGB) {
    if (_isCustom) {
      final custom = double.tryParse(_customController.text) ?? 0;
      return custom * pricePerGB;
    }
    if (_selectedPackage == null) return 0;
    return (_packages[_selectedPackage!]['gb'] as int).toDouble() * pricePerGB;
  }

  int _selectedGB(int fallback) {
    if (_isCustom) {
      return int.tryParse(_customController.text) ?? fallback;
    }
    if (_selectedPackage == null) return 0;
    return _packages[_selectedPackage!]['gb'] as int;
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final host = provider.selectedHost;
    if (host == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
            onPressed: () => context.go('/guest/nearby'),
          ),
          title: const Text('Choose Data Package'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.data_usage_outlined, color: AppColors.textSecondary, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Select a host first',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Packages and pricing depend on the host you choose.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => context.go('/guest/nearby'),
                    child: const Text('Go to Nearby Hosts'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final price = host.pricePerGB;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => context.go('/guest/select-host'),
        ),
        title: const Text('Choose Data Package'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Host info
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.router, color: AppColors.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  host.name,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Rs ${price.toStringAsFixed(2)} per GB',
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Select a Package',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._packages.asMap().entries.map((entry) {
                      final i = entry.key;
                      final pkg = entry.value;
                      final isSelected = _selectedPackage == i && !_isCustom;
                      final gb = pkg['gb'] as int;
                      final total = (gb * price).toStringAsFixed(2);

                      return GestureDetector(
                        onTap: () => setState(() {
                          _selectedPackage = i;
                          _isCustom = false;
                        }),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primary.withAlpha(15)
                                : AppColors.card,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.divider,
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? AppColors.primary
                                        : AppColors.textSecondary,
                                    width: 2,
                                  ),
                                  color: isSelected
                                      ? AppColors.primary
                                      : Colors.transparent,
                                ),
                                child: isSelected
                                    ? const Icon(Icons.check,
                                        color: Colors.black, size: 14)
                                    : null,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          pkg['label'] as String,
                                          style: TextStyle(
                                            color: isSelected
                                                ? AppColors.primary
                                                : AppColors.textPrimary,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        if (pkg['badge'] != null) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppColors.primary,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              pkg['badge'] as String,
                                              style: const TextStyle(
                                                color: Colors.black,
                                                fontSize: 9,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    Text(
                                      pkg['desc'] as String,
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                'Rs $total',
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    // Custom package
                    GestureDetector(
                      onTap: () => setState(() {
                        _isCustom = true;
                        _selectedPackage = null;
                      }),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _isCustom
                              ? AppColors.primary.withAlpha(15)
                              : AppColors.card,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _isCustom ? AppColors.primary : AppColors.divider,
                            width: _isCustom ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _isCustom
                                          ? AppColors.primary
                                          : AppColors.textSecondary,
                                      width: 2,
                                    ),
                                    color: _isCustom
                                        ? AppColors.primary
                                        : Colors.transparent,
                                  ),
                                  child: _isCustom
                                      ? const Icon(Icons.check,
                                          color: Colors.black, size: 14)
                                      : null,
                                ),
                                const SizedBox(width: 14),
                                const Text(
                                  'Custom Amount',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            if (_isCustom) ...[
                              const SizedBox(height: 12),
                              CustomTextField(
                                label: 'Enter GB amount',
                                controller: _customController,
                                keyboardType: TextInputType.number,
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Bottom bar
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: const Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          'Rs ${_totalPrice(price).toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: (_selectedPackage != null || _isCustom)
                        ? () {
                            provider.setQuota(_selectedGB(5));
                            context.go('/guest/payment');
                          }
                        : null,
                    child: const Text('Proceed to Payment'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
