/// BLE Mesh 插件自定义异常类定义。
library;

// ── 基础异常 ──────────────────────────────────────────────────────────────────

/// BLE Mesh 插件所有异常的基类。
///
/// 可通过 [code] 在代码中识别异常类型，通过 [message] 展示给用户。
class BleMeshException implements Exception {
  const BleMeshException(
    this.message, {
    this.code,
    this.details,
  });

  /// 人类可读的错误描述。
  final String message;

  /// 机器可读的错误码，用于在代码中区分异常类型。
  final String? code;

  /// 附加的调试信息或原始错误对象。
  final dynamic details;

  @override
  String toString() {
    final codeStr = code != null ? '[$code] ' : '';
    final detailStr = details != null ? '\n  Details: $details' : '';
    return 'BleMeshException: $codeStr$message$detailStr';
  }
}

// ── 具体异常类型 ──────────────────────────────────────────────────────────────

/// 当前设备不支持蓝牙时抛出。
class BluetoothUnavailableException extends BleMeshException {
  const BluetoothUnavailableException()
      : super(
          '当前设备不支持蓝牙',
          code: 'BLUETOOTH_UNAVAILABLE',
        );
}

/// 蓝牙适配器已关闭时抛出。
class BluetoothDisabledException extends BleMeshException {
  const BluetoothDisabledException()
      : super(
          '蓝牙已关闭，请开启蓝牙后重试',
          code: 'BLUETOOTH_DISABLED',
        );
}

/// 用户拒绝了必要的蓝牙权限时抛出。
class PermissionDeniedException extends BleMeshException {
  const PermissionDeniedException({String? detail})
      : super(
          '蓝牙或位置权限被拒绝，功能无法使用',
          code: 'PERMISSION_DENIED',
          details: detail,
        );
}

/// 调用 API 前未调用 [BleMesh.initialize] 时抛出。
class NotInitializedException extends BleMeshException {
  const NotInitializedException()
      : super(
          '插件未初始化，请先调用 BleMesh.initialize()',
          code: 'NOT_INITIALIZED',
        );
}

/// 需要连接代理节点但当前未连接时抛出。
class NotConnectedException extends BleMeshException {
  const NotConnectedException()
      : super(
          '未连接到任何 Mesh 代理节点',
          code: 'NOT_CONNECTED',
        );
}

/// 配网流程失败时抛出。
class ProvisioningException extends BleMeshException {
  const ProvisioningException(
    String message, {
    String? code,
    dynamic details,
  }) : super(message, code: code ?? 'PROVISIONING_FAILED', details: details);
}

/// 传入了超出范围的 Mesh 地址时抛出。
class InvalidAddressException extends BleMeshException {
  InvalidAddressException(int address)
      : super(
          '无效的 Mesh 地址: 0x${address.toRadixString(16).padLeft(4, '0').toUpperCase()}',
          code: 'INVALID_ADDRESS',
          details: address,
        );
}

/// 场景编号超出 1-65535 范围时抛出。
class InvalidSceneNumberException extends BleMeshException {
  InvalidSceneNumberException(int number)
      : super(
          '无效的场景编号: $number，有效范围为 1-65535',
          code: 'INVALID_SCENE_NUMBER',
          details: number,
        );
}

/// 操作超时时抛出。
class MeshTimeoutException extends BleMeshException {
  const MeshTimeoutException(String operation)
      : super(
          '操作超时: $operation',
          code: 'TIMEOUT',
          details: operation,
        );
}
