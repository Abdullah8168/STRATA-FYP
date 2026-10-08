class ReviewModel {
  final String hostId;
  final String userName;
  final int rating; // 1–5
  final String comment;
  final DateTime createdAt;

  const ReviewModel({
    required this.hostId,
    required this.userName,
    required this.rating,
    required this.comment,
    required this.createdAt,
  });
}

