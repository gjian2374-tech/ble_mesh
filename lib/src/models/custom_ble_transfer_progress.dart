/// 自定义 BLE 通道数据传输进度。
class CustomBleTransferProgress {
  const CustomBleTransferProgress({
    required this.bytesSent,
    required this.totalBytes,
  });

  /// 已发送字节数。
  final int bytesSent;

  /// 总字节数。
  final int totalBytes;

  /// 进度比例 0.0–1.0。
  double get fraction =>
      totalBytes <= 0 ? 0 : bytesSent.clamp(0, totalBytes) / totalBytes;
}
