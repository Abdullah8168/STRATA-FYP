/// Iteration 2 — marketplace / discovery behaviour toggles.
///
/// Real demo path (default): only mDNS / captive-portal pinned hosts.
/// Explicit demo marketplace: `--dart-define=STRATA_DEMO_MARKETPLACE=true`
/// shows the labeled `dummyHosts` list for UI walkthroughs without a Pi.
class DemoConfig {
  static const bool demoMarketplace = bool.fromEnvironment(
    'STRATA_DEMO_MARKETPLACE',
    defaultValue: false,
  );
}
