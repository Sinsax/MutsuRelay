class QrCodeStatus {
  final String status;
  final String? cookie;
  final String message;

  QrCodeStatus({
    required this.status,
    this.cookie,
    required this.message,
  });

  bool get isWaiting => status == 'waiting';
  bool get isConfirming => status == 'confirming';
  bool get isExpired => status == 'expired';
  bool get isSuccess => status == 'success';
}
