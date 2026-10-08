/// HTTP configuration for the STRATA host node API.
class HostApiConfig {
  static const String defaultBaseUrl = String.fromEnvironment(
    'HOST_API_URL',
    defaultValue: 'http://192.168.50.1:8080',
  );

  static int get defaultPort {
    try {
      final u = Uri.parse(defaultBaseUrl);
      if (u.hasPort) return u.port;
    } catch (_) {/* ignore */}
    return 8080;
  }

  static const Duration requestTimeout = Duration(seconds: 30);
}
