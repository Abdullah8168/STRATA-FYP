import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/session_model.dart';

/// Persists enough state to reconnect to a live metering session after a
/// process kill ([`P0.1`]).
class SessionStateStore {
  SessionStateStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String storageKey = 'strata.active_session.v1';

  final FlutterSecureStorage _storage;

  Future<void> saveActiveSession(SessionModel s) async {
    await _storage.write(key: storageKey, value: jsonEncode(s.toJson()));
  }

  Future<SessionModel?> loadActiveSession() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return SessionModel.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearActiveSession() async {
    await _storage.delete(key: storageKey);
  }
}
