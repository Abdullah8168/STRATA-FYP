/// Map known exceptions into user-facing diagnostics (Phase H).
class ChatroomDisconnectedException implements Exception {
  ChatroomDisconnectedException([this.reason = 'WebSocket disconnected']);
  final String reason;
  @override
  String toString() => 'ChatroomDisconnectedException: $reason';
}
