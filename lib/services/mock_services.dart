import '../models/host_model.dart';
import '../models/session_model.dart';

/// Central place for optional mock OTP / legacy demo helpers.
///
/// Iteration 2 marketplace discovery no longer uses [fetchNearbyHosts].
/// Real hosts come from mDNS + [HostApiService.getHostInfo]. Demo cards
/// only appear when ``STRATA_DEMO_MARKETPLACE=true``.
class MockStrataService {
  const MockStrataService();

  /// Legacy stub — always empty. Prefer mDNS discovery in [AppProvider.loadHosts].
  Future<List<HostModel>> fetchNearbyHosts() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return const [];
  }

  // NOTE (Phase D): the legacy mock `fetchWallet` was removed. The wallet is
  // now real and lives in `WalletService` + `ChainClient`.

  /// Mock starting a guest session (UI-only demo path; not used by paid flow).
  Future<SessionModel> startSession({
    required String hostId,
    required String guestId,
    required int quotaGb,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return SessionModel(
      id: 'sess-${DateTime.now().millisecondsSinceEpoch}',
      hostId: hostId,
      guestId: guestId,
      quotaGb: quotaGb,
      usedGb: 0,
      startedAt: DateTime.now(),
    );
  }

  /// Simulate sending OTP to email + phone (fallback when EmailJS/Firebase fail).
  Future<void> sendOtp({
    required String email,
    required String phone,
    required String code,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

