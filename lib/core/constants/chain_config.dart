/// Chain configuration for wallet + Iteration 3 SessionEscrow settlement.
///
/// Addresses and RPC are injected at build/run time — never hardcode Amoy
/// deployment addresses in source:
///
/// ```bash
/// flutter run \
///   --dart-define=STRATA_TOKEN=0x... \
///   --dart-define=SESSION_ESCROW=0x... \
///   --dart-define=CHAIN_ID=80002 \
///   --dart-define=RPC_URL=https://rpc-amoy.polygon.technology
/// ```
///
/// Local Hardhat also accepts `--dart-define=CHAIN_RPC_URL=http://127.0.0.1:8545`
/// as an alias for [RPC_URL].
///
/// When [strataTokenContract] or [sessionEscrowContract] is empty, the app
/// stays on the Iteration 2 off-chain admit path.
class ChainConfig {
  static const String _rpcUrlPrimary = String.fromEnvironment(
    'RPC_URL',
    defaultValue: '',
  );

  /// Alias used by some runbooks / earlier Iteration 3 docs.
  static const String _rpcUrlAlias = String.fromEnvironment(
    'CHAIN_RPC_URL',
    defaultValue: '',
  );

  static const String _rpcUrlDefault =
      'https://rpc-amoy.polygon.technology';

  static String get rpcUrl {
    if (_rpcUrlPrimary.isNotEmpty) return _rpcUrlPrimary;
    if (_rpcUrlAlias.isNotEmpty) return _rpcUrlAlias;
    return _rpcUrlDefault;
  }

  static const int chainId = int.fromEnvironment(
    'CHAIN_ID',
    defaultValue: 80002,
  );

  /// Display / Crashlytics labels (same RPC + chain as [rpcUrl] / [chainId]).
  static String get polygonAmoyRpcUrl => rpcUrl;
  static int get polygonAmoyChainId => chainId;

  /// Set via `--dart-define=STRATA_TOKEN=0x...`
  static const String strataTokenContract =
      String.fromEnvironment('STRATA_TOKEN', defaultValue: '');

  /// Set via `--dart-define=SESSION_ESCROW=0x...`
  static const String sessionEscrowContract =
      String.fromEnvironment('SESSION_ESCROW', defaultValue: '');

  static bool get isConfigured =>
      strataTokenContract.isNotEmpty && sessionEscrowContract.isNotEmpty;

  /// Alias used by payment screens (same semantics as [isConfigured]).
  static bool get isOnChainEnabled => isConfigured;
}
