import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class Rating {
  final String id;
  final String hostId;
  final String hostAddress;
  final String userId;
  final String userName;
  final int stars;
  final String comment;
  final String sessionId;
  final DateTime createdAt;

  const Rating({
    required this.id,
    required this.hostId,
    required this.hostAddress,
    required this.userId,
    required this.userName,
    required this.stars,
    required this.comment,
    required this.sessionId,
    required this.createdAt,
  });
}

class HostStats {
  final double avgRating;
  final int ratingCount;

  const HostStats({required this.avgRating, required this.ratingCount});
}

/// Firestore-backed ratings for FYP; falls back to in-memory when Firebase
/// is not initialised (unit tests / `flutter test` without options file).
class RatingService {
  RatingService({FirebaseFirestore? firestore})
      : _explicitFirestore = firestore;

  final FirebaseFirestore? _explicitFirestore;
  final List<Rating> _memory = [];

  FirebaseFirestore? get _fire {
    try {
      if (Firebase.apps.isEmpty) return null;
      return _explicitFirestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  Future<void> submitRating({
    required String hostId,
    required String hostAddress,
    required String sessionId,
    required int stars,
    required String comment,
    required String userId,
    required String userName,
  }) async {
    final fs = _fire;
    if (fs == null) {
      debugPrint('[STRATA] RatingService: Firebase inactive — storing in-memory');
      _memory.add(Rating(
        id: '${DateTime.now().millisecondsSinceEpoch}',
        hostId: hostId,
        hostAddress: hostAddress,
        userId: userId,
        userName: userName,
        stars: stars.clamp(1, 5),
        comment: comment,
        sessionId: sessionId,
        createdAt: DateTime.now(),
      ));
      return;
    }
    final ratingRef = fs.collection('ratings').doc();
    final hostRef = fs.collection('hosts').doc(hostId);
    await fs.runTransaction((tx) async {
      final snap = await tx.get(hostRef);
      final avg = (snap.data()?['avg_rating'] as num?)?.toDouble() ?? 0.0;
      final count = (snap.data()?['rating_count'] as num?)?.toInt() ?? 0;
      final newCount = count + 1;
      final newAvg = ((avg * count) + stars) / newCount;
      tx.set(ratingRef, {
        'host_id': hostId,
        'host_address': hostAddress,
        'user_id': userId,
        'user_name': userName,
        'stars': stars,
        'comment': comment,
        'session_id': sessionId,
        'created_at': FieldValue.serverTimestamp(),
      });
      tx.set(hostRef, {
        'avg_rating': newAvg,
        'rating_count': newCount,
      }, SetOptions(merge: true));
    });
  }

  Stream<List<Rating>> ratingsForHost(String hostId) {
    final fs = _fire;
    if (fs == null) {
      return Stream.value(
        _memory.where((r) => r.hostId == hostId).toList(),
      );
    }
    return fs
        .collection('ratings')
        .where('host_id', isEqualTo: hostId)
        .limit(50)
        .snapshots()
        .map((snap) {
      final ratings = snap.docs.map((d) {
        final data = d.data();
        final ts = data['created_at'];
        DateTime dt;
        if (ts is Timestamp) {
          dt = ts.toDate();
        } else {
          dt = DateTime.now();
        }
        return Rating(
          id: d.id,
          hostId: data['host_id'] as String? ?? '',
          hostAddress: data['host_address'] as String? ?? '',
          userId: data['user_id'] as String? ?? '',
          userName: data['user_name'] as String? ?? '',
          stars: (data['stars'] as num?)?.toInt().clamp(1, 5) ?? 1,
          comment: data['comment'] as String? ?? '',
          sessionId: data['session_id'] as String? ?? '',
          createdAt: dt,
        );
      }).toList();
      ratings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return ratings;
    });
  }

  Future<HostStats?> hostStats(String hostId) async {
    final fs = _fire;
    if (fs == null) {
      final list = _memory.where((r) => r.hostId == hostId).toList();
      if (list.isEmpty) return null;
      final avg = list.map((e) => e.stars).reduce((a, b) => a + b) / list.length;
      return HostStats(avgRating: avg, ratingCount: list.length);
    }
    final snap = await fs.collection('hosts').doc(hostId).get();
    if (!snap.exists) return null;
    final m = snap.data()!;
    return HostStats(
      avgRating: (m['avg_rating'] as num?)?.toDouble() ?? 0.0,
      ratingCount: (m['rating_count'] as num?)?.toInt() ?? 0,
    );
  }
}
