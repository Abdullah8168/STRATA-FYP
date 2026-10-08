import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sidebar.dart';
import '../../widgets/host_card.dart';
import '../../widgets/real_network_map.dart';
import '../../providers/app_provider.dart';
import '../../models/detected_network_model.dart';
import '../../models/host_model.dart';

class NearbyHostsScreen extends StatefulWidget {
  const NearbyHostsScreen({super.key});

  @override
  State<NearbyHostsScreen> createState() => _NearbyHostsScreenState();
}

class _NearbyHostsScreenState extends State<NearbyHostsScreen> {
  bool _isMapView = false;
  String _activeFilter = 'Distance';
  final _filters = ['Distance', 'Price', 'Rating'];
  Map<String, double> _avgRatingByHostId = {};

  List<HostModel> _getSortedHosts(List<HostModel> hosts) {
    final sorted = List<HostModel>.from(hosts);
    switch (_activeFilter) {
      case 'Distance':
        sorted.sort((a, b) => a.distance.compareTo(b.distance));
        break;
      case 'Price':
        sorted.sort((a, b) => a.pricePerGB.compareTo(b.pricePerGB));
        break;
      case 'Rating':
        sorted.sort((a, b) => ((_avgRatingByHostId[b.id] ?? b.rating)
            .compareTo(_avgRatingByHostId[a.id] ?? a.rating)));
        break;
    }
    return sorted;
  }

  Future<void> _refreshRatingLookup() async {
    final provider = context.read<AppProvider>();
    final next = <String, double>{};
    for (final h in provider.hosts) {
      try {
        final s = await provider.ratingService.hostStats(h.id);
        next[h.id] = s?.avgRating ?? h.rating;
      } catch (_) {
        next[h.id] = h.rating;
      }
    }
    if (!mounted) return;
    setState(() => _avgRatingByHostId = next);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<AppProvider>();
      provider.loadHosts().whenComplete(_refreshRatingLookup);
      if (provider.currentLatitude == null ||
          provider.currentLongitude == null) {
        provider.useFallbackLocation();
      } else {
        provider.updateLocationAndNetworks(
          latitude: provider.currentLatitude!,
          longitude: provider.currentLongitude!,
          accuracyMeters: provider.locationAccuracyMeters,
        );
      }
      provider.startNetworkAutoRefresh(every: const Duration(seconds: 8));
    });
  }

  // Kept so dispose() needn't look up the widget tree: `context.read` in
  // dispose throws "Null check operator used on a null value" on unmount.
  AppProvider? _provider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = context.read<AppProvider>();
  }

  @override
  void dispose() {
    _provider?.stopNetworkAutoRefresh();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final hosts = _getSortedHosts(provider.hosts);

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 800;

      return Scaffold(
        backgroundColor: AppColors.background,
        drawer: isWide
            ? null
            : const Sidebar(role: 'guest', currentRoute: '/guest/nearby'),
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          leading: isWide
              ? null
              : Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu, color: AppColors.textPrimary),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          title: const Text('Nearby Hosts'),
          actions: [
            IconButton(
              icon: provider.isNetworkScanInProgress
                  ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(Icons.refresh, color: AppColors.textPrimary),
              onPressed: provider.isNetworkScanInProgress
                  ? null
                  : () => provider.refreshNetworksNow(),
            ),
            IconButton(
              icon: Icon(
                _isMapView ? Icons.list : Icons.map_outlined,
                color: AppColors.primary,
              ),
              onPressed: () => setState(() => _isMapView = !_isMapView),
            ),
          ],
        ),
        body: Row(
          children: [
            if (isWide)
              const Sidebar(role: 'guest', currentRoute: '/guest/nearby'),
            Expanded(
              child: Column(
                children: [
                  _buildScanModeBanner(provider),
                  // Filter chips
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    color: AppColors.surface,
                    child: Row(
                      children: [
                        const Text(
                          'Sort by: ',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        ..._filters.map((f) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(f),
                            selected: _activeFilter == f,
                            onSelected: (_) =>
                                setState(() => _activeFilter = f),
                            selectedColor: AppColors.primary.withAlpha(40),
                            checkmarkColor: AppColors.primary,
                            labelStyle: TextStyle(
                              color: _activeFilter == f
                                  ? AppColors.primary
                                  : AppColors.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                        )),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _isMapView
                        ? _buildMapView(hosts, provider)
                        : _buildListView(hosts, provider),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildMapView(List<HostModel> hosts, AppProvider provider) {
    final coordinates = (provider.currentLatitude != null &&
        provider.currentLongitude != null)
        ? '${provider.currentLatitude!.toStringAsFixed(5)}, ${provider.currentLongitude!.toStringAsFixed(5)}'
        : 'Location unavailable';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: RealNetworkMap(
              height: double.infinity,
              userLatitude: provider.currentLatitude ?? 33.6844,
              userLongitude: provider.currentLongitude ?? 73.0479,
              networks: provider.detectedNetworks,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Your location: $coordinates',
              style:
              const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: hosts.length,
              itemBuilder: (context, index) {
                final host = hosts[index];
                return GestureDetector(
                  onTap: () {
                    provider.selectHost(host);
                    context.go('/guest/select-host');
                  },
                  child: Container(
                    width: 180,
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          host.name,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${host.distance.toInt()}m away',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Rs ${host.pricePerGB}/GB',
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '⭐ ${host.rating}',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _buildDetectedNetworksList(provider.detectedNetworks),
        ],
      ),
    );
  }

  Widget _buildListView(List<HostModel> hosts, AppProvider provider) {
    final demoOn = provider.isDemoMarketplaceEnabled;
    final lanHosts = hosts.where((h) => h.id.startsWith('lan:')).toList();
    final demoHosts = hosts.where((h) => !h.id.startsWith('lan:')).toList();

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      children: [
        _buildDiscoveredHostsSection(provider),
        if (hosts.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              demoOn
                  ? 'No hosts yet. Start host_node on this machine or enable a Pi on the LAN.'
                  : 'No STRATA host responded.\n\n'
                      'Start the host node, then refresh. On this browser, discovery '
                      'uses HOST_API_URL (mDNS is not available in web). '
                      'On a phone joined to the STRATA Wi-Fi, the Pi is found via mDNS.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        if (lanHosts.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Live hosts',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...lanHosts.map(
            (host) => HostCard(
              host: host,
              onConnect: () {
                provider.selectHost(host);
                final matches = provider.discoveredHosts
                    .where((d) => host.id.contains(d.ipv4))
                    .toList();
                if (matches.isNotEmpty) {
                  provider.hostApiService.setBaseUrl(matches.first.baseUrl);
                  provider.setConnectedHostBaseUrl(matches.first.baseUrl);
                }
                context.go('/guest/select-host');
              },
            ),
          ),
        ],
        if (demoOn && demoHosts.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Demo hosts (not a real Pi)',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ...demoHosts.map(
            (host) => HostCard(
              host: host,
              onConnect: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Demo host — payment will not reach a real node. '
                      'Use a LAN host for the real path.',
                    ),
                  ),
                );
                provider.selectHost(host);
                context.go('/guest/select-host');
              },
            ),
          ),
        ],
        _buildDetectedNetworksList(provider.detectedNetworks),
      ],
    );
  }

  /// Phase G — discovered STRATA hosts on the LAN. Pinned above the demo
  /// hosts list. When mDNS finds nothing the section collapses entirely
  /// so the screen looks identical to the Phase D layout for users who
  /// don't have a real Pi on their network.
  Widget _buildDiscoveredHostsSection(AppProvider provider) {
    final discovered = provider.discoveredHosts;
    if (discovered.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(120)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cell_tower,
                    size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                const Text(
                  'Hosts on this network',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${discovered.length}',
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...discovered.map(
                  (h) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: GestureDetector(
                  onTap: () async {
                    final prov = context.read<AppProvider>();
                    final messenger = ScaffoldMessenger.of(context);
                    final nav = GoRouter.of(context);
                    prov.hostApiService.setBaseUrl(h.baseUrl);
                    prov.setConnectedHostBaseUrl(h.baseUrl);
                    final info = await prov.hostApiService.getHostInfo();
                    if (!context.mounted) return;
                    final id = 'lan:${h.ipv4}:${h.port}';
                    final hs = await prov.ratingService.hostStats(id);
                    if (!context.mounted) return;
                    final wa = info?.walletAddress.trim();
                    final hostModel = HostModel(
                      id: id,
                      name: info?.displayName ?? h.name,
                      ssid: 'STRATA-LAN',
                      pricePerGB: info?.pricePerGB ?? 0.5,
                      rating: hs?.avgRating ?? 4.5,
                      distance: 0,
                      availableGB: 100,
                      isActive: true,
                      walletAddress: (wa != null && wa.isNotEmpty)
                          ? wa
                          : (h.hostWallet.isNotEmpty
                          ? h.hostWallet
                          : '0x0000000000000000000000000000000000000000'),
                      pricePerGbWei: info?.pricePerGbWei ?? '1000000000000000',
                    );
                    prov.selectHost(hostModel);
                    messenger.showSnackBar(
                      SnackBar(content: Text('Using ${hostModel.name}')),
                    );
                    nav.go('/guest/select-host');
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.router_outlined,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(h.name,
                                style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600)),
                            Text(
                              '${h.ipv4}:${h.port} · ${_shortAddr(h.hostWallet)}',
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF166534),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'LAN',
                          style: TextStyle(
                              color: Color(0xFFB8FACC),
                              fontSize: 10,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _shortAddr(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 6)}…${addr.substring(addr.length - 4)}';
  }

  Widget _buildDetectedNetworksList(List<DetectedNetworkModel> networks) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Detected Networks',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (context.watch<AppProvider>().lastNetworkScanAt != null)
                Text(
                  'Updated: ${_formatTime(context.watch<AppProvider>().lastNetworkScanAt!)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (networks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No networks detected yet.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          else
            ...networks.take(10).map((n) {
              final isReal = n.source == NetworkSourceType.real;
              final sourceLabel = switch (n.source) {
                NetworkSourceType.real => 'Real',
                NetworkSourceType.simulated => 'Simulated',
                NetworkSourceType.dummy => 'Demo',
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: n.isConnected
                        ? AppColors.primary.withAlpha(20)
                        : isReal
                        ? const Color(0xFF1A2A1A)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: isReal
                        ? Border.all(
                        color: AppColors.primary.withAlpha(60), width: 1)
                        : null,
                  ),
                  child: Row(
                    children: [
                      // Signal strength icon
                      Icon(
                        n.signalStrength > 66
                            ? Icons.wifi
                            : n.signalStrength > 33
                            ? Icons.wifi_2_bar
                            : Icons.wifi_1_bar,
                        color: n.isConnected
                            ? const Color(0xFF4CAF50)
                            : isReal
                            ? AppColors.primary
                            : AppColors.textSecondary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    n.ssid,
                                    style: TextStyle(
                                      color: isReal
                                          ? AppColors.textPrimary
                                          : AppColors.textSecondary,
                                      fontWeight: isReal
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (n.isConnected) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF166534),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Connected',
                                      style: TextStyle(
                                          color: Color(0xFFB8FACC),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            Text(
                              '${n.securityType} · ${n.frequencyBand ?? 'Unknown'}',
                              style: const TextStyle(
                                  color: AppColors.textSecondary, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${n.signalStrength}%',
                            style: TextStyle(
                              color: isReal
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: isReal
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          Text(
                            '${n.distanceMeters.toStringAsFixed(0)}m',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: isReal
                              ? AppColors.primary.withAlpha(30)
                              : AppColors.divider.withAlpha(60),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          sourceLabel,
                          style: TextStyle(
                            color: isReal
                                ? AppColors.primary
                                : AppColors.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  // ── Updated banner: reads wifiScanStatusMessage for specific guidance ──────
  Widget _buildScanModeBanner(AppProvider provider) {
    final hasReal = provider.realNetworks.isNotEmpty;

    // Web: browser always blocks real WiFi scanning
    if (kIsWeb) {
      return _banner(
        color: const Color(0xFFFFB300),
        icon: Icons.info_outline,
        message: provider.isDemoMarketplaceEnabled
            ? 'Web mode: real WiFi scan is blocked by the browser. '
                'Showing simulated + demo networks.'
            : 'Web mode: real WiFi scan is blocked by the browser. '
                'Use mDNS / captive-portal discovery for live hosts.',
      );
    }

    // Real networks found — green success banner
    if (hasReal) {
      final count = provider.realNetworks.length;
      return _banner(
        color: const Color(0xFF4CAF50),
        icon: Icons.wifi_tethering,
        message: 'Real WiFi scan active — $count nearby network'
            '${count == 1 ? '' : 's'} detected.',
      );
    }

    // No real networks — read the specific reason from the scan engine
    final reason = provider.wifiScanStatusMessage ?? '';

    if (reason.toLowerCase().contains('location permission')) {
      return _banner(
        color: const Color(0xFFEF5350),
        icon: Icons.location_off_outlined,
        message:
        'Location permission is required to scan for WiFi networks. '
            'Tap "Open Settings" to grant it, then refresh.',
        actionLabel: 'Open Settings',
        onAction: _openAppSettings,
      );
    }

    if (reason.toLowerCase().contains('location service')) {
      return _banner(
        color: const Color(0xFFEF5350),
        icon: Icons.gps_off,
        message:
        'Location services (GPS) are off. Enable them in device '
            'settings, then refresh.',
        actionLabel: 'Open Settings',
        onAction: _openLocationSettings,
      );
    }

    if (reason.toLowerCase().contains('not supported')) {
      return _banner(
        color: const Color(0xFF78909C),
        icon: Icons.wifi_off,
        message: provider.isDemoMarketplaceEnabled
            ? 'WiFi scanning is not supported on this device. '
                'Showing simulated and demo networks.'
            : 'WiFi scanning is not supported on this device. '
                'Live hosts still appear via mDNS / captive portal.',
      );
    }

    if (reason.toLowerCase().contains('completed but no networks')) {
      return _banner(
        color: const Color(0xFFFFB300),
        icon: Icons.wifi_find,
        message: 'Scan completed but no networks returned yet. '
            'Tap refresh to try again.',
      );
    }

    // Generic fallback
    return _banner(
      color: const Color(0xFFFFB300),
      icon: Icons.info_outline,
      message: reason.isNotEmpty
          ? reason
          : 'Real WiFi scan unavailable. Check location permission and refresh.',
    );
  }

  /// Shared banner widget used by all _buildScanModeBanner branches.
  Widget _banner({
    required Color color,
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        border: Border(
          bottom: BorderSide(color: color.withAlpha(120)),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onAction,
              child: Text(
                actionLabel,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                  decorationColor: color,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openAppSettings() {
    Geolocator.openAppSettings();
  }

  void _openLocationSettings() {
    Geolocator.openLocationSettings();
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}