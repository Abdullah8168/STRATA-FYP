import 'dart:math';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:web3dart/credentials.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/constants/chain_config.dart';
import '../core/constants/demo_config.dart';
import '../models/detected_network_model.dart';
import '../models/host_model.dart';
import '../models/user_model.dart';
import '../models/session_model.dart';
import '../models/wallet_model.dart';
import '../models/wallet_credentials_model.dart';
import '../models/session_request_model.dart';
import '../models/on_chain_activity.dart';
import '../services/mock_services.dart';
import '../services/email_otp_service.dart';
import '../services/network_detection_service.dart';
import '../services/wallet_service.dart';
import '../services/chain_client.dart';
import '../services/host_api_service.dart';
import '../services/host_discovery_service.dart';
import '../services/session_history_service.dart';
import '../services/session_state_store.dart';
import '../services/pending_payment_store.dart';
import '../services/rating_service.dart';
import '../services/log_service.dart';
import '../core/constants/app_routes.dart';
import '../services/deep_link_service.dart';

import '../models/review_model.dart';
import '../models/host_chain_session_status.dart';

/// Phase I — distinguishes healthy Amoy RPC from accidental mainnet ([`P1.4`]).
enum ChainHealth { unknown, ok, wrongNetwork }

class AppProvider extends ChangeNotifier {
  AppProvider({
    MockStrataService? mockService,
    WalletService? walletService,
    ChainClient? chainClient,
    HostApiService? hostApiService,
    HostDiscoveryService? discoveryService,
    SessionHistoryService? sessionHistoryService,
    RatingService? ratingService,
    SessionStateStore? sessionStateStore,
    PendingPaymentStore? pendingPaymentStore,
    Connectivity? connectivity,
  })  : _mockService = mockService ?? const MockStrataService(),
        _walletService = walletService ?? WalletService(),
        _chainClient = chainClient ?? ChainClient(),
        _hostApiService = hostApiService ?? HostApiService(),
        _discoveryService = discoveryService ?? HostDiscoveryService(),
        _sessionHistoryService =
            sessionHistoryService ?? SessionHistoryService(),
        _ratingService = ratingService ?? RatingService(),
        _sessionStore = sessionStateStore ?? SessionStateStore(),
        _pendingPaymentStore =
            pendingPaymentStore ?? PendingPaymentStore(),
        _connectivity = connectivity ?? Connectivity() {
    _listenConnectivity();
  }

  final MockStrataService _mockService;

  // Phase D: FirebaseAuth is resolved lazily so unit tests that don't
  // exercise OTP can construct AppProvider without Firebase.initializeApp.
  FirebaseAuth? _authCache;
  FirebaseAuth get _auth => _authCache ??= FirebaseAuth.instance;

  final NetworkDetectionService _networkDetectionService =
  const NetworkDetectionService();
  final WalletService _walletService;
  final ChainClient _chainClient;
  final HostApiService _hostApiService;
  final HostDiscoveryService _discoveryService;
  final SessionHistoryService _sessionHistoryService;
  final RatingService _ratingService;
  final SessionStateStore _sessionStore;
  final PendingPaymentStore _pendingPaymentStore;
  final Connectivity _connectivity;
  StreamSubscription<ConnectivityResult>? _connectivitySub;

  ChainHealth chainHealth = ChainHealth.unknown;
  bool offlineBanner = false;
  bool transientOnlineBanner = false;
  bool _deepLinkConsumedThisColdBoot = false;
  String? _pendingBootRoute;
  Future<void>? _walletInitFuture;

  PendingPaymentStore get pendingPaymentStore => _pendingPaymentStore;

  Future<void> clearPersistedGuestSession() => _sessionStore.clearActiveSession();

  // Phase G — live session-status subscription.
  StreamSubscription<SessionStatus>? _sessionStatusSubscription;
  String? _sessionStopReason;
  List<DiscoveredHost> _discoveredHosts = const [];

  String? _connectedHostBaseUrl;

  UserModel? _currentUser;
  String _selectedRole = '';
  HostModel? _selectedHost;
  int _selectedQuota = 5;
  bool _isHostActive = false;
  double _remainingData = 5.0;
  String _sessionKey = '';
  List<HostModel> _hosts = const [];
  WalletCredentials? _walletCredentials;
  WalletModel? _walletInfo;
  bool _walletBalancesLoading = false;
  SessionModel? _currentSession;
  String _lastOtpContact = '';
  String _lastOtpCode = '123456';
  final Map<String, List<ReviewModel>> _reviewsByHost = {};
  double? _currentLatitude;
  double? _currentLongitude;
  double? _locationAccuracyMeters;
  bool _locationPermissionDenied = false;
  List<DetectedNetworkModel> _realNetworks = const [];
  List<DetectedNetworkModel> _simulatedNetworks = const [];
  List<DetectedNetworkModel> _dummyNetworks = const [];

  // ── CHANGE 1: new field to store the scan status message ──────────────────
  String? _wifiScanStatusMessage;

  static const double _fallbackLat = 33.6844;
  static const double _fallbackLon = 73.0479;

  String? _phoneVerificationId;
  int? _resendToken;
  int _webRecaptchaAttempt = 0;
  bool _useFirebasePhoneAuth = false;
  bool _useEmailOtp = false;
  String? _firebaseAuthError;
  DateTime? _lastNetworkScanAt;
  bool _isNetworkScanInProgress = false;
  Timer? _networkScanTimer;

  UserModel? get currentUser => _currentUser;
  String get selectedRole => _selectedRole;
  HostModel? get selectedHost => _selectedHost;
  int get selectedQuota => _selectedQuota;
  bool get isHostActive => _isHostActive;
  double get remainingData => _remainingData;
  String get sessionKey => _sessionKey;
  List<HostModel> get hosts {
    if (_hosts.isNotEmpty) return _hosts;
    if (DemoConfig.demoMarketplace) return dummyHosts;
    return const [];
  }

  /// True when the UI may show explicitly labeled demo host cards.
  bool get isDemoMarketplaceEnabled => DemoConfig.demoMarketplace;
  WalletCredentials? get walletCredentials => _walletCredentials;
  WalletModel? get walletInfo => _walletInfo;
  bool get walletBalancesLoading => _walletBalancesLoading;
  SessionModel? get currentSession => _currentSession;
  String get lastOtpContact => _lastOtpContact;
  String get lastOtpCode => _lastOtpCode;
  double? get currentLatitude => _currentLatitude;
  double? get currentLongitude => _currentLongitude;
  double? get locationAccuracyMeters => _locationAccuracyMeters;
  bool get locationPermissionDenied => _locationPermissionDenied;
  List<DetectedNetworkModel> get realNetworks => _realNetworks;
  List<DetectedNetworkModel> get simulatedNetworks => _simulatedNetworks;
  List<DetectedNetworkModel> get dummyNetworks => _dummyNetworks;
  List<DetectedNetworkModel> get detectedNetworks {
    // Simulated / dummy map pins only when STRATA_DEMO_MARKETPLACE=true.
    final combined = <DetectedNetworkModel>[
      ..._realNetworks,
      if (DemoConfig.demoMarketplace) ..._simulatedNetworks,
      if (DemoConfig.demoMarketplace) ..._dummyNetworks,
    ];
    combined.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return combined;
  }

  DateTime? get lastNetworkScanAt => _lastNetworkScanAt;
  bool get isNetworkScanInProgress => _isNetworkScanInProgress;
  List<DiscoveredHost> get discoveredHosts => _discoveredHosts;
  String? get sessionStopReason => _sessionStopReason;
  HostApiService get hostApiService => _hostApiService;
  HostDiscoveryService get discoveryService => _discoveryService;
  SessionHistoryService get sessionHistoryService => _sessionHistoryService;
  RatingService get ratingService => _ratingService;
  WalletService get walletService => _walletService;
  String? get connectedHostBaseUrl => _connectedHostBaseUrl;

  // ── CHANGE 2: new getter exposing the scan status message to the UI ───────
  String? get wifiScanStatusMessage => _wifiScanStatusMessage;

  void setConnectedHostBaseUrl(String baseUrl) {
    _connectedHostBaseUrl = baseUrl;
    notifyListeners();
  }

  bool get useFirebasePhoneAuth => _useFirebasePhoneAuth;
  bool get useEmailOtp => _useEmailOtp;
  bool get usedRealOtp => _useFirebasePhoneAuth || _useEmailOtp;
  String? get firebaseAuthError => _firebaseAuthError;
  String? get phoneVerificationId => _phoneVerificationId;
  List<ReviewModel> reviewsForHost(String hostId) =>
      _reviewsByHost[hostId] ?? const [];

  // Phase D: dummy hosts now carry placeholder wallet addresses + per-GB
  // wei prices. Phase E will populate these from on-chain registration data.
  // Address values are valid-format checksummed addresses for demo purposes.
  final List<HostModel> dummyHosts = const [
    HostModel(
      id: '1',
      name: "Ahmad's Node",
      ssid: 'STRATA-Ahmad-01',
      pricePerGB: 0.50,
      rating: 4.8,
      distance: 150,
      availableGB: 45,
      isActive: true,
      walletAddress: '0x1111111111111111111111111111111111111111',
      pricePerGbWei: '1000000000000000',
    ),
    HostModel(
      id: '2',
      name: "Sara's Hub",
      ssid: 'STRATA-Sara-02',
      pricePerGB: 0.35,
      rating: 4.5,
      distance: 280,
      availableGB: 20,
      isActive: true,
      walletAddress: '0x2222222222222222222222222222222222222222',
      pricePerGbWei: '1000000000000000',
    ),
    HostModel(
      id: '3',
      name: 'Campus Node 3',
      ssid: 'STRATA-Campus-03',
      pricePerGB: 0.25,
      rating: 4.9,
      distance: 95,
      availableGB: 100,
      isActive: true,
      walletAddress: '0x3333333333333333333333333333333333333333',
      pricePerGbWei: '1000000000000000',
    ),
    HostModel(
      id: '4',
      name: "Khan's Relay",
      ssid: 'STRATA-Khan-04',
      pricePerGB: 0.75,
      rating: 4.2,
      distance: 420,
      availableGB: 15,
      isActive: true,
      walletAddress: '0x4444444444444444444444444444444444444444',
      pricePerGbWei: '1000000000000000',
    ),
    HostModel(
      id: '5',
      name: "Ali's Network",
      ssid: 'STRATA-Ali-05',
      pricePerGB: 0.45,
      rating: 4.6,
      distance: 200,
      availableGB: 60,
      isActive: true,
      walletAddress: '0x5555555555555555555555555555555555555555',
      pricePerGbWei: '1000000000000000',
    ),
  ];

  void setRole(String role) {
    _selectedRole = role;
    notifyListeners();
  }

  void setUser(UserModel user) {
    _currentUser = user;
    notifyListeners();
  }

  void selectHost(HostModel host) {
    _selectedHost = host;
    notifyListeners();
  }

  void setQuota(int gb) {
    _selectedQuota = gb;
    _remainingData = gb.toDouble();
    notifyListeners();
  }

  void activateHostSharing() {
    _isHostActive = true;
    notifyListeners();
  }

  void deactivateHostSharing() {
    _isHostActive = false;
    notifyListeners();
  }

  void generateAccessKey() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final part1 = (timestamp % 10000).toString().padLeft(4, '0');
    const part2 = 'A7F3';
    const part3 = 'B2D9';
    _sessionKey = 'STRATA-$part1-$part2-$part3';
    notifyListeners();
  }

  /// Phase G — kept for the demo dashboard "simulate usage" button. In
  /// real sessions the host node is the source of truth and this is a
  /// no-op (the streamed status overrides the local mutation on the next
  /// tick). Tagged @visibleForTesting so reviewers don't think it's load-
  /// bearing in production paths.
  @visibleForTesting
  void consumeData(double gb) {
    _remainingData =
        (_remainingData - gb).clamp(0.0, _selectedQuota.toDouble());
    notifyListeners();
  }

  void resetSession() {
    _selectedHost = null;
    _selectedQuota = 5;
    _remainingData = 5.0;
    _sessionKey = '';
    _currentSession = null;
    _sessionStopReason = null;
    _connectedHostBaseUrl = null;
    _discoveryService.setCaptivePortalPin(null);
    stopSessionMonitor();
    notifyListeners();
  }

  void setCurrentLocation({
    required double latitude,
    required double longitude,
    double? accuracyMeters,
  }) {
    _currentLatitude = latitude;
    _currentLongitude = longitude;
    _locationAccuracyMeters = accuracyMeters;
    _locationPermissionDenied = false;
    notifyListeners();
  }

  Future<void> updateLocationAndNetworks({
    required double latitude,
    required double longitude,
    double? accuracyMeters,
  }) async {
    _currentLatitude = latitude;
    _currentLongitude = longitude;
    _locationAccuracyMeters = accuracyMeters;
    _locationPermissionDenied = false;
    await _refreshDetectedNetworks();
  }

  Future<void> useFallbackLocation() async {
    _currentLatitude ??= _fallbackLat;
    _currentLongitude ??= _fallbackLon;
    _locationAccuracyMeters = null;
    _locationPermissionDenied = true;
    await _refreshDetectedNetworks();
  }

  // ── CHANGE 3: updated _refreshDetectedNetworks to use scanRealNetworks() ──
  Future<void> _refreshDetectedNetworks() async {
    if (_isNetworkScanInProgress) return;
    _isNetworkScanInProgress = true;
    notifyListeners();
    try {
      final lat = _currentLatitude ?? _fallbackLat;
      final lon = _currentLongitude ?? _fallbackLon;

      // Use scanRealNetworks() instead of detectRealNetworks() so we get
      // a status message explaining exactly what happened (permission denied,
      // GPS off, not supported, etc.) that the UI banner can display.
      final scanResult = await _networkDetectionService.scanRealNetworks(
        latitude: lat,
        longitude: lon,
      );
      _realNetworks = scanResult.networks;
      _wifiScanStatusMessage = scanResult.statusMessage;

      if (DemoConfig.demoMarketplace) {
        _simulatedNetworks = _networkDetectionService.simulateNearbyNetworks(
          latitude: lat,
          longitude: lon,
          count: 6,
        );
        _dummyNetworks = _networkDetectionService.fromDummyHosts(
          hosts: hosts,
          latitude: lat,
          longitude: lon,
        );
      } else {
        _simulatedNetworks = const [];
        _dummyNetworks = const [];
      }
      _lastNetworkScanAt = DateTime.now();
    } finally {
      _isNetworkScanInProgress = false;
      notifyListeners();
    }
  }

  Future<void> refreshNetworksNow() async {
    await _refreshDetectedNetworks();
  }

  void startNetworkAutoRefresh({Duration every = const Duration(seconds: 10)}) {
    _networkScanTimer?.cancel();
    _networkScanTimer = Timer.periodic(every, (_) {
      _refreshDetectedNetworks();
      // The first discovery right after joining the host's Wi-Fi often times
      // out (Android still settling on the new network). Keep retrying while
      // no live host has been found, instead of only on screen open.
      final hasLanHost = _hosts.any((h) => h.id.startsWith('lan:'));
      if (!hasLanHost && !_isLoadingHosts) loadHosts();
    });
  }

  void stopNetworkAutoRefresh() {
    _networkScanTimer?.cancel();
    _networkScanTimer = null;
  }

  bool _isLoadingHosts = false;

  Future<void> loadHosts() async {
    if (_isLoadingHosts) return;
    _isLoadingHosts = true;
    try {
      await _loadHosts();
    } finally {
      _isLoadingHosts = false;
    }
  }

  Future<void> _loadHosts() async {
    // Iteration 2 — real path uses mDNS / captive-portal pins only.
    // Dummy hosts appear only when STRATA_DEMO_MARKETPLACE=true.
    try {
      _discoveredHosts = await _discoveryService.discover(forceRefresh: true);
    } catch (e) {
      debugPrint('[STRATA] mDNS discover failed: ${e.runtimeType}');
      _discoveredHosts = const [];
    }

    final fromLan = <HostModel>[];
    for (final h in _discoveredHosts) {
      final id = 'lan:${h.ipv4}:${h.port}';
      var name = h.name;
      var wallet = h.hostWallet;
      var priceWei = '0';
      var priceGb = 0.0;
      var ssid = '';
      HostNodeInfo? info;
      try {
        _hostApiService.setBaseUrl(h.baseUrl);
        info = await _hostApiService.getHostInfo();
        if (info != null) {
          name = info.displayName;
          if (info.walletAddress.trim().isNotEmpty) {
            wallet = info.walletAddress.trim();
          }
          priceWei = info.pricePerGbWei;
          priceGb = info.pricePerGB ?? 0;
          ssid = info.ssid;
        }
      } catch (e) {
        debugPrint('[STRATA] getHostInfo ${h.baseUrl}: $e');
      }
      if (wallet.isEmpty || info == null) {
        debugPrint('[STRATA] skip discovered host without live /host/info: $h');
        continue;
      }
      fromLan.add(
        HostModel(
          id: id,
          name: name,
          ssid: ssid,
          pricePerGB: priceGb,
          rating: 0,
          distance: 0,
          availableGB: 0,
          isActive: true,
          walletAddress: wallet,
          pricePerGbWei: priceWei,
        ),
      );
    }

    if (DemoConfig.demoMarketplace) {
      _hosts = [...fromLan, ...dummyHosts];
    } else {
      _hosts = fromLan;
    }

    if (_currentLatitude != null && _currentLongitude != null) {
      await _refreshDetectedNetworks();
    }
    notifyListeners();
  }

  /// Phase G — subscribe to the host node's /session/status stream so
  /// the dashboard's quota gauge mirrors the server's authoritative
  /// metering instead of the client-side decrement. Idempotent: calling
  /// while already subscribed is a no-op.
  Future<void> startSessionMonitor({String? sessionId}) async {
    final id = sessionId ?? _currentSession?.id;
    if (id == null) return;
    if (_sessionStatusSubscription != null) return;
    _sessionStatusSubscription = _hostApiService
        .watchStatus(id)
        .listen(
      _onSessionStatus,
      onError: (Object e) {
        debugPrint('[STRATA] session status stream error: ${e.runtimeType}');
      },
      cancelOnError: false,
    );
  }

  void stopSessionMonitor() {
    _sessionStatusSubscription?.cancel();
    _sessionStatusSubscription = null;
  }

  void _onSessionStatus(SessionStatus status) {
    final quotaBytes = status.quotaBytes <= 0 ? 1 : status.quotaBytes;
    final usedRatio = status.bytesUsed / quotaBytes;
    final remaining = (_selectedQuota * (1 - usedRatio))
        .clamp(0.0, _selectedQuota.toDouble());
    _remainingData = remaining;

    // Keep lastHostChainSessionStatus in sync with the live stream so the
    // dashboard's settle/dispute card always reflects the latest state.
    _lastHostChainSessionStatus =
        HostChainSessionStatus.fromSessionStatus(status);

    if (status.status == 'stopped') {
      _sessionStopReason = status.stopReason;
      stopSessionMonitor();
      // ignore: discarded_futures
      _sessionStore.clearActiveSession();
      LogService.instance.log(
        '[session] stopped reason=${status.stopReason ?? 'n/a'}',
      );
    }
    notifyListeners();
  }

  /// Phase G — guest-initiated session stop.
  Future<void> stopGuestSession() async {
    final session = _currentSession;
    if (session == null) return;
    try {
      await _hostApiService.stopSession(
        sessionId: session.id,
        reason: StopReason.guestStopped,
      );
    } on HostApiException catch (e) {
      debugPrint('[STRATA] stopSession failed: $e');
    }
    stopSessionMonitor();
    _sessionStopReason = 'guest_stopped';
    notifyListeners();
  }

  /// Phase I — captive-portal deep links ([`P0.3`]).
  void applyOnboardingDeepLink(ParsedDeepLink link) {
    final o = link.onboarding;
    _deepLinkConsumedThisColdBoot = true;
    final ip = o.portalIp ?? '';
    if (ip.isNotEmpty) {
      _discoveryService.setCaptivePortalPin(
        DiscoveredHost(
          name: 'Captive portal',
          ipv4: ip,
          port: o.portalPort,
          hostWallet: o.hostAddress ?? '',
          chainId: '80002',
          txtVersion: 'phase-i',
        ),
      );
      final base = o.baseUrl;
      if (base.isNotEmpty) {
        _hostApiService.setBaseUrl(base);
        setConnectedHostBaseUrl(base);
      }
    }
    final addr = o.hostAddress;
    if (addr != null && addr.isNotEmpty) {
      selectHost(
        HostModel(
          id: 'captive-pinned',
          name: 'STRATA Host',
          ssid: 'STRATA',
          pricePerGB: 0.5,
          rating: 5,
          distance: 0,
          availableGB: 100,
          isActive: true,
          walletAddress: addr,
        ),
      );
    }
    _pendingBootRoute = _currentUser != null
        ? AppRoutes.guestNearbyHosts
        : AppRoutes.roleSelection;
    notifyListeners();
  }

  String? takePendingBootRoute() {
    final r = _pendingBootRoute;
    _pendingBootRoute = null;
    return r;
  }

  Future<void> persistActiveGuestSession() async {
    final cs = _currentSession;
    if (cs == null) return;
    final hs = _selectedHost;
    final merged = cs.copyWith(
      hostBaseUrl: _connectedHostBaseUrl ?? _hostApiService.baseUrl,
      persistedHostName: hs?.name ?? cs.persistedHostName,
      persistedHostWallet: hs?.walletAddress ?? cs.persistedHostWallet,
      persistedHostSsid: hs?.ssid ?? cs.persistedHostSsid,
    );
    _currentSession = merged;
    await _sessionStore.saveActiveSession(merged);
    notifyListeners();
  }

  void _hydrateHostFromSession(SessionModel s) {
    final w = s.persistedHostWallet;
    if (w == null || w.isEmpty) return;
    selectHost(
      HostModel(
        id: s.hostId.isEmpty ? 'restored' : s.hostId,
        name: s.persistedHostName ?? 'STRATA Host',
        ssid: s.persistedHostSsid ?? 'STRATA',
        pricePerGB: 0.5,
        rating: 5,
        distance: 0,
        availableGB: 100,
        isActive: true,
        walletAddress: w,
      ),
    );
    if (s.quotaGb > 0) {
      setQuota(s.quotaGb);
    }
  }

  Future<void> _restorePersistedGuestSession() async {
    if (_deepLinkConsumedThisColdBoot) return;

    SessionModel? saved;
    try {
      saved = await _sessionStore.loadActiveSession();
    } catch (e, st) {
      debugPrint('[STRATA] loadActiveSession fail: $e $st');
      return;
    }
    if (saved == null) return;

    final base = saved.hostBaseUrl ?? _hostApiService.baseUrl;
    if (base.isNotEmpty) {
      _hostApiService.setBaseUrl(base);
      setConnectedHostBaseUrl(base);
    }
    _hydrateHostFromSession(saved);

    try {
      final st = await _hostApiService.getSessionStatus(saved.id);
      if (st.status != 'active') {
        await _sessionStore.clearActiveSession();
        return;
      }
      _currentSession = saved;
      _selectedQuota = saved.quotaGb > 0 ? saved.quotaGb : _selectedQuota;
      final qb =
      saved.quotaGb <= 0 ? 1 : saved.quotaGb * 1024 * 1024 * 1024;
      final ratio = qb <= 0 ? 0.0 : st.bytesUsed / qb;
      _remainingData = (_selectedQuota * (1 - ratio))
          .clamp(0.0, _selectedQuota.toDouble());

      LogService.instance.log('[session] restored active id=${saved.id}');
      _pendingBootRoute = AppRoutes.guestDashboard;
      notifyListeners();
    } on HostApiException catch (e) {
      LogService.instance.log('[session] restore status fail ${e.code}');
      if (e.statusCode == 404) {
        await _sessionStore.clearActiveSession();
      }
    }
  }

  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub =
        _connectivity.onConnectivityChanged.listen((ConnectivityResult r) {
          final offline = r == ConnectivityResult.none;
          if (offline != offlineBanner) {
            offlineBanner = offline;
            if (!offline) {
              transientOnlineBanner = true;
              // ignore: discarded_futures
              refreshWalletBalances();
            }
            notifyListeners();
            if (!offline) {
              Future.delayed(const Duration(seconds: 3), () {
                transientOnlineBanner = false;
                notifyListeners();
              });
            }
          }
        });
  }

  Future<void> _primeConnectivityOnce() =>
      _connectivity.checkConnectivity().then((ConnectivityResult r) {
        offlineBanner = r == ConnectivityResult.none;
        notifyListeners();
      });

  Future<void> onAppResumed() async {
    await _primeConnectivityOnce();
    final sid = _currentSession?.id;
    if (sid != null) {
      try {
        await _hostApiService.getSessionStatus(sid);
      } catch (_) {/* best-effort */}
      await startSessionMonitor(sessionId: sid);
      await persistActiveGuestSession();
    }
    await refreshWalletBalances();
  }

  void onAppPaused() {
    stopSessionMonitor();
  }

  // -------------------- Phase D: wallet --------------------

  Future<bool> hasWallet() => _walletService.hasWallet();

  Future<void> initWallet() {
    _walletInitFuture ??= _initWalletInner();
    return _walletInitFuture!;
  }

  Future<void> _initWalletInner() async {
    try {
      if (await _walletService.hasWallet()) {
        _walletCredentials = await _walletService.loadWallet();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[STRATA] initWallet failed: ${e.runtimeType}');
    }
    await _restorePersistedGuestSession();
  }

  Future<({String mnemonic, WalletCredentials credentials})>
  createNewWallet() async {
    final result = await _walletService.createWallet();
    _walletCredentials = result.credentials;
    notifyListeners();
    return result;
  }

  Future<void> commitWalletAfterConfirmation(String mnemonic) async {
    await _walletService.persistMnemonic(mnemonic);
    _walletCredentials = await _walletService.loadWallet();
    notifyListeners();
  }

  Future<WalletCredentials> importExistingWallet(String mnemonic) async {
    final credentials = await _walletService.importWallet(mnemonic);
    _walletCredentials = credentials;
    notifyListeners();
    return credentials;
  }

  Future<String> revealMnemonicForBackup() => _walletService.revealMnemonic();

  Future<String> revealWalletMnemonic() => revealMnemonicForBackup();

  Future<void> refreshWalletBalances() async {
    final credentials = _walletCredentials;
    if (credentials == null) return;
    if (_walletBalancesLoading) return;
    _walletBalancesLoading = true;
    notifyListeners();
    try {
      final native = await _chainClient.getNativeBalance(credentials.address);
      BigInt? token;
      final tokenAddr = ChainConfig.strataTokenContract;
      if (tokenAddr.isNotEmpty) {
        token = await _chainClient.getTokenBalance(
          credentials.address,
          EthereumAddress.fromHex(tokenAddr),
        );
      }
      _walletInfo = WalletModel(
        address: credentials.hexAddress,
        nativeBalanceWei: native,
        tokenBalanceWei: token,
        fetchedAt: DateTime.now(),
      );
      chainHealth = ChainHealth.ok;
      if (!kIsWeb) {
        try {
          final addr = credentials.hexAddress;
          final tail = addr.length >= 6
              ? addr.substring(addr.length - 6).toLowerCase()
              : addr.toLowerCase();
          await FirebaseCrashlytics.instance
              .setCustomKey('wallet_address', tail);
          await FirebaseCrashlytics.instance.setCustomKey(
            'host_base_url',
            _hostApiService.baseUrl,
          );
        } catch (_) {/* tests */}
      }
    } on WrongNetworkException {
      chainHealth = ChainHealth.wrongNetwork;
    } catch (e) {
      debugPrint(
          '[STRATA] refreshWalletBalances error: ${e.runtimeType}');
      chainHealth = ChainHealth.unknown;
    } finally {
      _walletBalancesLoading = false;
      notifyListeners();
    }
  }

  /// Demo-only Amoy/testnet STRT faucet. Never a production payment path.
  Future<String> claimTestnetFaucet() async {
    final credentials = _walletCredentials;
    if (credentials == null) throw const WalletNotFoundException();
    if (!ChainConfig.isConfigured) {
      throw const _OnChainNotConfiguredException();
    }
    final tokenAddr = ChainConfig.strataTokenContract;
    final hash = await _chainClient.claimFaucet(
      credentials: credentials.privateKey,
      tokenAddress: EthereumAddress.fromHex(tokenAddr),
    );
    await refreshWalletBalances();
    return hash;
  }

  /// STRATA `Transfer` + SessionEscrow `PaymentSettled` logs for the local wallet.
  Future<List<OnChainActivity>> fetchOnChainHistory({
    int lookbackBlocks = 50000,
  }) async {
    final credentials = _walletCredentials;
    if (credentials == null) return const [];
    if (!ChainConfig.isConfigured) return const [];
    return _chainClient.fetchWalletHistory(
      wallet: credentials.address,
      lookbackBlocks: lookbackBlocks,
    );
  }

  Future<SessionStartResponse> startPaidSession({
    required String hostWalletAddress,
    required int quotaBytes,
    required String pricePerGbWei,
    String macAddress = '',
    String? txHash,
  }) async {
    final credentials = _walletCredentials;
    if (credentials == null) {
      throw const WalletNotFoundException();
    }

    final selected = _selectedHost;
    if (selected != null &&
        !DemoConfig.demoMarketplace &&
        !selected.id.startsWith('lan:') &&
        !selected.id.startsWith('captive')) {
      throw const HostApiException(
        statusCode: 400,
        code: 'DEMO_HOST_BLOCKED',
        message:
            'Selected host is not a live LAN discovery result. '
            'Join the STRATA Wi-Fi or enable STRATA_DEMO_MARKETPLACE only for UI demos.',
      );
    }
    // Reject well-known placeholder demo wallets outside explicit demo mode.
    final wa = hostWalletAddress.toLowerCase();
    if (!DemoConfig.demoMarketplace &&
        (wa.startsWith('0x11111111') ||
            wa.startsWith('0x22222222') ||
            wa.startsWith('0x33333333') ||
            wa.startsWith('0x44444444') ||
            wa.startsWith('0x55555555'))) {
      throw const HostApiException(
        statusCode: 400,
        code: 'DEMO_WALLET_BLOCKED',
        message: 'Refusing to start a paid session against a demo host wallet.',
      );
    }

    // Iteration 2 — resolve MAC from the host (ARP) before signing so the
    // EIP-191 message matches what the Pi will verify.
    var mac = macAddress.trim().toLowerCase();
    if (mac.isEmpty) {
      try {
        final identity = await _hostApiService.fetchClientIdentity();
        mac = (identity.macAddress ?? '').trim().toLowerCase();
      } catch (e) {
        debugPrint('[STRATA] fetchClientIdentity: $e');
      }
    }
    if (mac.isEmpty) {
      throw const HostApiException(
        statusCode: 422,
        code: 'MAC_UNRESOLVED',
        message:
            'Could not resolve device MAC from the host. Stay on the STRATA '
            'Wi-Fi, open the captive portal once, then retry payment.',
      );
    }

    final nonce = _newUuidV4();
    final signed = await _walletService.signSessionStart(
      guestAddress: credentials.hexAddress,
      hostAddress: hostWalletAddress,
      macAddress: mac,
      quotaBytes: BigInt.from(quotaBytes),
      nonce: nonce,
    );
    final req = SessionStartRequest(
      guestWalletAddress: credentials.hexAddress,
      hostWalletAddress: hostWalletAddress,
      macAddress: mac,
      quotaBytes: quotaBytes,
      pricePerGbWei: pricePerGbWei,
      nonce: nonce,
      guestSignature: signed.signature,
      txHash: txHash,
    );
    final response = await _hostApiService.startSession(req);
    final hs = _selectedHost;
    _currentSession = SessionModel(
      id: response.sessionId,
      hostId: hs?.id ?? '',
      guestId: _currentUser?.id ?? '',
      quotaGb: (quotaBytes / (1024 * 1024 * 1024)).round(),
      usedGb: 0,
      startedAt: response.startedAt,
      hostBaseUrl: _connectedHostBaseUrl ?? _hostApiService.baseUrl,
      persistedHostName: hs?.name,
      persistedHostWallet: hs?.walletAddress ?? hostWalletAddress,
      persistedHostSsid: hs?.ssid,
    );
    try {
      final hs = _selectedHost;
      final cs = _currentSession;
      if (hs != null && cs != null) {
        await _sessionHistoryService.insertOnStart(cs, hs);
      }
    } catch (e) {
      debugPrint('[STRATA] session history insertOnStart: $e');
    }
    notifyListeners();
    return response;
  }

  Future<String> executeOnChainOpenSession({
    required String sessionId,
    required String sessionRefHex,
    required String hostWalletAddress,
    required BigInt amountWei,
    String? approveTxHash,
    String? openTxHash,
  }) async {
    final credentials = _walletCredentials;
    if (credentials == null) {
      throw const WalletNotFoundException();
    }
    if (!ChainConfig.isConfigured) {
      throw const _OnChainNotConfiguredException();
    }
    final tokenAddr = ChainConfig.strataTokenContract;
    final escrowAddr = ChainConfig.sessionEscrowContract;
    final priceWei = _selectedHost?.pricePerGbWei ?? '1000000000000000';

    Future<void> persist(PaymentPipelineStep step, {String? approve, String? open}) {
      return _pendingPaymentStore.save(
        PendingPaymentSnapshot(
          failedAt: step,
          sessionId: sessionId,
          sessionRefHex: sessionRefHex,
          nonce: null,
          hostWallet: hostWalletAddress,
          quotaBytes: (_selectedQuota * 1024 * 1024 * 1024),
          pricePerGbWei: priceWei,
          approveUnlimited: true,
          amountWei: amountWei,
          approveTxHash: approve ?? approveTxHash,
          openTxHash: open ?? openTxHash,
        ),
      );
    }

    await persist(PaymentPipelineStep.approve);
    String? approveHash = approveTxHash;
    if (approveHash == null || approveHash.isEmpty) {
      approveHash = await _chainClient.approveToken(
        credentials: credentials.privateKey,
        tokenAddress: EthereumAddress.fromHex(tokenAddr),
        spender: EthereumAddress.fromHex(escrowAddr),
        amount: amountWei,
      );
    }

    await persist(PaymentPipelineStep.openSession, approve: approveHash);
    String txHash = openTxHash ?? '';
    if (txHash.isEmpty) {
      final result = await _chainClient.openSession(
        credentials: credentials.privateKey,
        escrowAddress: EthereumAddress.fromHex(escrowAddr),
        hostAddress: EthereumAddress.fromHex(hostWalletAddress),
        amount: amountWei,
        sessionRefHex: sessionRefHex,
      );
      txHash = result.txHash;
    }

    await persist(PaymentPipelineStep.waitHost, approve: approveHash, open: txHash);

    try {
      await _hostApiService.notifyPayment(
        sessionId: sessionId,
        txHash: txHash,
      );
    } catch (e) {
      debugPrint('[STRATA] notifyPayment failed (non-fatal): ${e.runtimeType}');
    }
    return txHash;
  }

  Future<PendingPaymentSnapshot?> loadPendingPayment() =>
      _pendingPaymentStore.load();

  Future<void> clearPendingPayment() => _pendingPaymentStore.clear();

  // ── Missing members referenced by guest_dashboard_screen.dart ───────────

  /// Last known on-chain session status. Null until the first on-chain
  /// status check completes. The dashboard reads .status, .chainSessionId,
  /// .hostSettlementSigHex and .stoppedAt from this object.
  HostChainSessionStatus? _lastHostChainSessionStatus;
  HostChainSessionStatus? get lastHostChainSessionStatus =>
      _lastHostChainSessionStatus;

  /// Push a host [SessionStatus] into [lastHostChainSessionStatus] so the
  /// settle UI works even when the dashboard owns the status stream.
  void updateHostChainSessionStatus(SessionStatus status) {
    _lastHostChainSessionStatus =
        HostChainSessionStatus.fromSessionStatus(status);
    if (status.status == 'stopped') {
      _sessionStopReason = status.stopReason;
    }
    notifyListeners();
  }

  /// Executes the on-chain `closeSession` call for the current session.
  /// Uses the chainSessionId and **host-signed settlement bytes** from the
  /// last known host status (must match the EIP-191 receipt).
  Future<String> executeOnChainCloseSession() async {
    final credentials = _walletCredentials;
    if (credentials == null) throw const WalletNotFoundException();
    if (!ChainConfig.isConfigured) throw const _OnChainNotConfiguredException();

    final session = _currentSession;
    if (session == null) throw Exception('No active session to close.');

    final st = _lastHostChainSessionStatus;
    final chainId = st?.chainSessionId;
    if (chainId == null) throw Exception('No on-chain session ID available.');

    final sigHex = st?.hostSettlementSigHex ?? '';
    if (sigHex.isEmpty) {
      throw Exception(
        'Host has not provided a settlement signature yet. '
        'Stop the session and wait for the host receipt.',
      );
    }

    final escrowAddr = ChainConfig.sessionEscrowContract;
    // Prefer host-signed settlement fields — they must match the EIP-191 sig.
    final quotaBytes = BigInt.from(
      st?.settlementQuotaBytes ??
          (session.quotaGb * 1024 * 1024 * 1024),
    );
    final usedBytes = BigInt.from(
      st?.settlementBytesConsumed ?? 0,
    );

    Uint8List hostSigBytes;
    try {
      final hex = sigHex.startsWith('0x') ? sigHex.substring(2) : sigHex;
      if (hex.isEmpty || hex.length.isOdd) {
        throw FormatException('empty or odd-length signature');
      }
      hostSigBytes = Uint8List.fromList(
        List.generate(
          hex.length ~/ 2,
          (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
    } catch (e) {
      throw Exception('Invalid host settlement signature: $e');
    }

    final hash = await _chainClient.closeSession(
      credentials: credentials.privateKey,
      escrowAddress: EthereumAddress.fromHex(escrowAddr),
      onChainSessionId: BigInt.from(chainId),
      bytesConsumed: usedBytes,
      quotaBytes: quotaBytes,
      hostSig: hostSigBytes,
    );
    _lastHostChainSessionStatus = HostChainSessionStatus(
      status: 'closed',
      chainSessionId: chainId,
      stoppedAt: st?.stoppedAt,
      settlementBytesConsumed: st?.settlementBytesConsumed,
      settlementQuotaBytes: st?.settlementQuotaBytes,
    );
    notifyListeners();
    return hash;
  }

  /// Executes the on-chain `disputeSession` call for the current session.
  Future<String> executeOnChainDisputeSession() async {
    final credentials = _walletCredentials;
    if (credentials == null) throw const WalletNotFoundException();
    if (!ChainConfig.isConfigured) throw const _OnChainNotConfiguredException();

    final session = _currentSession;
    if (session == null) throw Exception('No active session to dispute.');

    final st = _lastHostChainSessionStatus;
    final chainId = st?.chainSessionId;
    if (chainId == null) throw Exception('No on-chain session ID available.');

    final escrowAddr = ChainConfig.sessionEscrowContract;
    final hash = await _chainClient.disputeSession(
      credentials: credentials.privateKey,
      escrowAddress: EthereumAddress.fromHex(escrowAddr),
      onChainSessionId: BigInt.from(chainId),
    );
    _lastHostChainSessionStatus = HostChainSessionStatus(
      status: 'disputed',
      chainSessionId: chainId,
      stoppedAt: st?.stoppedAt,
    );
    notifyListeners();
    return hash;
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<String> waitForSessionActive({
    required String sessionId,
    Duration timeout = const Duration(seconds: 60),
    Duration interval = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    String last = 'pending_payment';
    while (DateTime.now().isBefore(deadline)) {
      try {
        final status = await _hostApiService.getSessionStatus(sessionId);
        last = status.status;
        if (status.status == 'active') return 'active';
        if (status.status == 'stopped') return 'stopped';
      } catch (e) {
        debugPrint('[STRATA] status poll error: ${e.runtimeType}');
      }
      await Future<void>.delayed(interval);
    }
    return last;
  }

  String _newUuidV4() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-'
        '${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-'
        '${h.substring(20)}';
  }

  Future<void> startGuestSession() async {
    final user = _currentUser;
    final host = _selectedHost;
    if (user == null || host == null) return;
    final started = await _mockService.startSession(
      hostId: host.id,
      guestId: user.id,
      quotaGb: _selectedQuota,
    );
    _currentSession = started.copyWith(
      hostBaseUrl: _connectedHostBaseUrl ?? _hostApiService.baseUrl,
      persistedHostName: host.name,
      persistedHostWallet: host.walletAddress,
      persistedHostSsid: host.ssid,
    );
    _remainingData = _selectedQuota.toDouble();
    notifyListeners();
    await persistActiveGuestSession();
    try {
      final hs = _selectedHost;
      final cs = _currentSession;
      if (hs != null && cs != null) {
        await _sessionHistoryService.insertOnStart(cs, hs);
      }
    } catch (e) {
      debugPrint('[STRATA] session history demo insert: $e');
    }
    // ignore: discarded_futures
    startSessionMonitor();
  }

  Future<void> sendOtp({required String email, required String phone}) async {
    _firebaseAuthError = null;
    _useFirebasePhoneAuth = false;
    _useEmailOtp = false;
    _phoneVerificationId = null;

    final rnd = Random();
    _lastOtpCode = (100000 + rnd.nextInt(900000)).toString();

    if (email.isNotEmpty) {
      _lastOtpContact = email;
      debugPrint('[STRATA] Attempting EmailJS for: $email');
      try {
        final userName = _currentUser?.name ?? 'STRATA User';
        await EmailOtpService.sendOtp(
          toEmail: email,
          otpCode: _lastOtpCode,
          toName: userName,
        );
        _useFirebasePhoneAuth = false;
        _useEmailOtp = true;
        debugPrint('[STRATA] Email OTP sent successfully to $email');
        notifyListeners();
        return;
      } catch (e) {
        debugPrint('[STRATA] EmailJS FAILED: $e');
        _firebaseAuthError = e.toString();
        _useEmailOtp = false;
      }
    }

    if (phone.isNotEmpty) {
      final normalizedPhone = _normalizePhone(phone);
      debugPrint(
          '[STRATA] Attempting Firebase Phone Auth for: $normalizedPhone');
      _useFirebasePhoneAuth = true;
      _useEmailOtp = false;
      _lastOtpContact = phone;
      try {
        await sendPhoneOtp(normalizedPhone);
        debugPrint('[STRATA] Firebase OTP sent successfully');
        return;
      } catch (e) {
        debugPrint('[STRATA] Firebase Phone Auth FAILED: $e');
        _firebaseAuthError = e.toString();
        _useFirebasePhoneAuth = false;
      }
    }

    _lastOtpContact = email.isNotEmpty ? email : phone;
    _useFirebasePhoneAuth = false;
    _useEmailOtp = false;
    debugPrint('[STRATA] Using mock OTP: $_lastOtpCode');
    await _mockService.sendOtp(email: email, phone: phone, code: _lastOtpCode);
    notifyListeners();
  }

  Future<bool> verifyOtp(String code) async {
    if (_useFirebasePhoneAuth && _phoneVerificationId != null) {
      debugPrint('[STRATA] Verifying via Firebase Phone Auth');
      return verifyPhoneOtp(code);
    }
    if (_useEmailOtp) {
      debugPrint('[STRATA] Verifying via Email OTP');
    } else {
      debugPrint('[STRATA] Verifying via mock OTP');
    }
    return code == _lastOtpCode;
  }

  String _normalizePhone(String phone) {
    String cleaned = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (cleaned.startsWith('03') && cleaned.length == 11) {
      cleaned = '+92${cleaned.substring(1)}';
    } else if (!cleaned.startsWith('+')) {
      cleaned = '+$cleaned';
    }
    debugPrint('[STRATA] Normalized phone: $phone -> $cleaned');
    return cleaned;
  }

  Future<void> sendPhoneOtp(String phone) async {
    _firebaseAuthError = null;
    debugPrint('[STRATA] sendPhoneOtp called for: $phone (isWeb: $kIsWeb)');

    if (kIsWeb) {
      try {
        _webRecaptchaAttempt++;
        final verifier = RecaptchaVerifier(
          auth: FirebaseAuthPlatform.instance,
          container: 'recaptcha-container',
          size: RecaptchaVerifierSize.compact,
          theme: RecaptchaVerifierTheme.dark,
          onSuccess: () => debugPrint('[STRATA] reCAPTCHA success'),
          onError: (FirebaseAuthException e) {
            debugPrint('[STRATA] reCAPTCHA error: ${e.code} ${e.message}');
          },
          onExpired: () => debugPrint('[STRATA] reCAPTCHA expired'),
        );

        debugPrint(
          '[STRATA] Calling signInWithPhoneNumber... attempt=$_webRecaptchaAttempt',
        );
        final confirmation = await _auth.signInWithPhoneNumber(phone, verifier);
        _phoneVerificationId = confirmation.verificationId;
        _useFirebasePhoneAuth = true;
        debugPrint(
            '[STRATA] signInWithPhoneNumber succeeded, verificationId: $_phoneVerificationId');
        notifyListeners();
      } catch (e) {
        debugPrint('[STRATA] signInWithPhoneNumber FAILED: $e');
        _firebaseAuthError = e.toString();
        rethrow;
      }
    } else {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint('[STRATA] Auto-verification completed');
          await _auth.signInWithCredential(credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('[STRATA] verificationFailed: ${e.message}');
          _firebaseAuthError = e.message ?? e.code;
          notifyListeners();
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint('[STRATA] codeSent, verificationId: $verificationId');
          _phoneVerificationId = verificationId;
          _resendToken = resendToken;
          _useFirebasePhoneAuth = true;
          notifyListeners();
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _phoneVerificationId = verificationId;
        },
      );
    }
  }

  Future<bool> verifyPhoneOtp(String smsCode) async {
    if (_phoneVerificationId == null) {
      debugPrint('[STRATA] verifyPhoneOtp: no verificationId');
      return false;
    }
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _phoneVerificationId!,
        smsCode: smsCode,
      );
      await _auth.signInWithCredential(credential);
      debugPrint('[STRATA] Phone OTP verified successfully');
      return true;
    } catch (e) {
      debugPrint('[STRATA] Phone OTP verification failed: $e');
      return false;
    }
  }

  void addReview({
    required String hostId,
    required String userName,
    required int rating,
    required String comment,
  }) {
    final list = _reviewsByHost.putIfAbsent(hostId, () => []);
    list.add(
      ReviewModel(
        hostId: hostId,
        userName: userName,
        rating: rating,
        comment: comment,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _networkScanTimer?.cancel();
    _sessionStatusSubscription?.cancel();
    _connectivitySub?.cancel();
    _chainClient.dispose();
    super.dispose();
  }
}

class _OnChainNotConfiguredException implements Exception {
  const _OnChainNotConfiguredException();
  @override
  String toString() =>
      'On-chain settlement is not configured. Set --dart-define=STRATA_TOKEN '
          'and --dart-define=SESSION_ESCROW after running scripts/deploy.ts.';
}