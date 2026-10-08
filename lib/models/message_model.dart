class MessageModel {
  final String id;
  final String sessionId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime sentAt;
  final bool isSystem;

  const MessageModel({
    required this.id,
    required this.sessionId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.sentAt,
    this.isSystem = false,
  });
}

