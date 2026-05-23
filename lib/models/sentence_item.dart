enum SentenceStatus { pending, sending, success, failed }

class SentenceItem {
  final int id;
  String text;
  SentenceStatus status;

  SentenceItem({
    required this.id,
    required this.text,
    this.status = SentenceStatus.pending,
  });

  bool get isPending => status == SentenceStatus.pending;
  bool get isSending => status == SentenceStatus.sending;
  bool get isSuccess => status == SentenceStatus.success;
  bool get isFailed => status == SentenceStatus.failed;
}
