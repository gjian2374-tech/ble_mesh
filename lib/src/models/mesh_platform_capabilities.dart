import 'package:flutter/foundation.dart';

/// 当前平台上的 Mesh 能力声明。
///
/// 用于告诉上层：当前是完整原生 Mesh 栈，还是仅有本地缓存 /
/// 占位增强实现，避免误把实验能力当成生产能力使用。
@immutable
class MeshPlatformCapabilities {
  const MeshPlatformCapabilities({
    required this.platformName,
    required this.isNativeMeshStackIntegrated,
    required this.supportsProvisioning,
    required this.supportsProxyConnection,
    required this.supportsConfigurationMessages,
    required this.supportsSceneManagement,
    required this.supportsVendorMessaging,
    required this.supportsTypedIncomingMessages,
    required this.hasLocalDataModel,
  });

  /// Android 平台能力。
  const MeshPlatformCapabilities.android()
    : this(
        platformName: 'android',
        isNativeMeshStackIntegrated: true,
        supportsProvisioning: true,
        supportsProxyConnection: true,
        supportsConfigurationMessages: true,
        supportsSceneManagement: true,
        supportsVendorMessaging: true,
        supportsTypedIncomingMessages: false,
        hasLocalDataModel: true,
      );

  /// iOS 平台能力（Nordic nRF Mesh Library 已集成）。
  const MeshPlatformCapabilities.ios()
    : this(
        platformName: 'ios',
        isNativeMeshStackIntegrated: true,
        supportsProvisioning: true,
        supportsProxyConnection: true,
        supportsConfigurationMessages: true,
        supportsSceneManagement: false,
        supportsVendorMessaging: true,
        supportsTypedIncomingMessages: false,
        hasLocalDataModel: true,
      );

  /// 非移动端或未知平台能力。
  const MeshPlatformCapabilities.unsupported()
    : this(
        platformName: 'unsupported',
        isNativeMeshStackIntegrated: false,
        supportsProvisioning: false,
        supportsProxyConnection: false,
        supportsConfigurationMessages: false,
        supportsSceneManagement: false,
        supportsVendorMessaging: false,
        supportsTypedIncomingMessages: false,
        hasLocalDataModel: false,
      );

  /// 当前平台名称。
  final String platformName;

  /// 是否已接入真实原生 Mesh 协议栈。
  final bool isNativeMeshStackIntegrated;

  /// 是否支持真实 Mesh 配网流程。
  final bool supportsProvisioning;

  /// 是否支持代理连接。
  final bool supportsProxyConnection;

  /// 是否支持配置消息能力，例如订阅/发布/模型绑定。
  final bool supportsConfigurationMessages;

  /// 是否支持场景相关消息和管理。
  final bool supportsSceneManagement;

  /// 是否支持 Vendor 消息发送。
  final bool supportsVendorMessaging;

  /// 是否支持原生层解析后的类型化入站消息。
  final bool supportsTypedIncomingMessages;

  /// 是否具备本地数据模型缓存能力。
  final bool hasLocalDataModel;

  /// 是否适合直接承载完整 Mesh 工作流。
  bool get supportsFullMeshWorkflow =>
      isNativeMeshStackIntegrated &&
      supportsProvisioning &&
      supportsProxyConnection &&
      supportsConfigurationMessages;
}
