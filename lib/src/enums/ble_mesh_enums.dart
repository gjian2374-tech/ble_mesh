/// BLE Mesh 插件所有枚举类型定义。
library;

// ── 蓝牙状态 ──────────────────────────────────────────────────────────────────

/// 蓝牙适配器当前状态。
enum BluetoothState {
  /// 状态未知，通常是初始化之前。
  unknown,

  /// 当前设备不支持蓝牙。
  unsupported,

  /// 应用没有蓝牙使用权限。
  unauthorized,

  /// 蓝牙已关闭。
  poweredOff,

  /// 蓝牙已开启，可以使用。
  poweredOn,

  /// 蓝牙正在重置中。
  resetting;

  /// 将原生层返回的字符串转换为 [BluetoothState]。
  static BluetoothState fromString(String value) {
    return BluetoothState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => BluetoothState.unknown,
    );
  }
}

// ── 配网状态 ──────────────────────────────────────────────────────────────────

/// BLE Mesh 设备配网流程状态。
enum ProvisioningState {
  /// 无配网进行中。
  idle,

  /// 正在连接待配网设备。
  connecting,

  /// 设备已连接，正在获取能力信息。
  identifying,

  /// 正在交换公钥。
  exchangingKeys,

  /// 需要用户确认（OOB 验证）。
  authenticationRequired,

  /// 正在发送配网数据。
  provisioning,

  /// 配网成功完成。
  complete,

  /// 配网失败。
  failed;

  /// 将原生层返回的字符串转换为 [ProvisioningState]。
  static ProvisioningState fromString(String value) {
    return ProvisioningState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ProvisioningState.idle,
    );
  }
}

// ── 连接状态 ──────────────────────────────────────────────────────────────────

/// 与 Mesh 代理节点的 GATT 连接状态。
enum MeshConnectionState {
  /// 未连接。
  disconnected,

  /// 正在建立连接。
  connecting,

  /// 已连接，可以收发 Mesh 消息。
  connected,

  /// 正在断开连接。
  disconnecting;

  /// 将原生层返回的字符串转换为 [MeshConnectionState]。
  static MeshConnectionState fromString(String value) {
    return MeshConnectionState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MeshConnectionState.disconnected,
    );
  }
}

/// BLE Mesh 节点配置阶段状态。
enum MeshConfigurationState {
  /// 暂无配置流程进行中。
  idle,

  /// 配网完成，等待重新通过 Proxy 连接。
  pendingProxy,

  /// Proxy 已连接，准备发送配置消息。
  proxyConnected,

  /// 正在获取 Composition Data。
  compositionGetting,

  /// 已收到 Composition Data。
  compositionReceived,

  /// 正在发送 Config AppKey Add。
  appKeyAdding,

  /// 正在发送 Config Model App Bind。
  modelBinding,

  /// 配置序列已完成。
  complete,

  /// 配置失败。
  failed;

  /// 将原生层返回的字符串转换为 [MeshConfigurationState]。
  static MeshConfigurationState fromString(String value) {
    return MeshConfigurationState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MeshConfigurationState.idle,
    );
  }
}

// ── Mesh 事件类型 ─────────────────────────────────────────────────────────────

/// 从原生层接收的 Mesh 事件类型。
enum MeshEventType {
  /// 蓝牙状态变化。
  bluetoothStateChanged,

  /// 扫描到一个未配网设备。
  scanResult,

  /// 扫描已停止。
  scanStopped,

  /// 代理连接状态变化。
  connectionStateChanged,

  /// 配网状态变化。
  provisioningStateChanged,

  /// Configuration 状态变化。
  configurationStateChanged,

  /// 配网成功，节点已加入网络。
  nodeAdded,

  /// 节点已从网络中删除。
  nodeDeleted,

  /// 网络数据已加载完成。
  networkLoaded,

  /// 网络数据已更新。
  networkUpdated,

  /// 收到 Mesh 消息响应。
  meshMessageReceived,

  /// 自定义 BLE 通道已就绪（可与 Proxy 共存）。
  customBleChannelReady,

  /// 自定义 BLE 数据传输进度。
  customBleTransferProgress,

  /// 自定义 BLE 通道收到通知数据。
  customBleDataReceived,

  /// 发生错误。
  error;

  /// 将字符串转换为 [MeshEventType]。
  static MeshEventType? fromString(String value) {
    return MeshEventType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MeshEventType.error,
    );
  }
}

// ── 模型组播配置 ───────────────────────────────────────────────────────────────

/// 模型在组地址上的消息能力：可仅 Bind AppKey、仅订阅、仅发布或组合。
enum MeshModelMessagingMode {
  /// 仅下发 Config Model App Bind（不配置订阅与发布）。
  appKeyOnly,

  /// 仅下发 Config Model Subscription Add。
  subscribeOnly,

  /// 仅下发 Config Model Publication Set。
  publishOnly,

  /// 同时下发 Subscription Add 与 Publication Set。
  subscribeAndPublish;

  /// 是否需要配置组订阅。
  bool get subscribe =>
      this == MeshModelMessagingMode.subscribeOnly ||
      this == MeshModelMessagingMode.subscribeAndPublish;

  /// 是否需要配置组发布。
  bool get publish =>
      this == MeshModelMessagingMode.publishOnly ||
      this == MeshModelMessagingMode.subscribeAndPublish;

  /// 是否需要组播地址（订阅或发布时为 true）。
  bool get requiresGroupAddress =>
      this != MeshModelMessagingMode.appKeyOnly;
}

// ── 收到的 Mesh 消息的模型类型 ─────────────────────────────────────────────────

/// 收到的 Mesh 消息的模型类型。
enum MeshMessageModelType {
  /// Generic On/Off 模型状态回包。
  genericOnOffStatus,

  /// Generic Level 模型状态回包。
  genericLevelStatus,

  /// Light Lightness 模型状态回包。
  lightLightnessStatus,

  /// Light HSL 模型状态回包。
  lightHslStatus,

  /// Scene 模型状态回包。
  sceneStatus,

  /// Vendor 模型消息。
  vendorModelStatus,

  /// 未知模型消息。
  unknown;

  /// 将字符串转换为 [MeshMessageModelType]。
  static MeshMessageModelType fromString(String value) {
    return MeshMessageModelType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MeshMessageModelType.unknown,
    );
  }
}
