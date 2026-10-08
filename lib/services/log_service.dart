import 'dart:collection';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Buffers the last lines for "Copy diagnostics" while mirroring into
/// Crashlytics when Firebase is initialized ([`P0.4`]).
final class LogService {
  LogService({this.maxLines = 200});

  static final LogService instance = LogService();

  final int maxLines;
  final Queue<String> _lines = Queue<String>();

  Iterable<String> get recentLines => _lines;

  String getRecentDiagnosticsTail(int max) {
    if (_lines.isEmpty) return '';
    final list = _lines.toList();
    final skip = max >= list.length ? 0 : list.length - max;
    return list.skip(skip).join('\n');
  }

  void log(String line) {
    final full =
        '${DateTime.now().toUtc().toIso8601String()} $line';
    while (_lines.length >= maxLines) {
      _lines.removeFirst();
    }
    _lines.addLast(full);
    if (!kIsWeb) {
      try {
        if (Firebase.apps.isNotEmpty) {
          FirebaseCrashlytics.instance.log(full);
        }
      } catch (_) {/* tests / no Crashlytics */}
    }
  }
}
