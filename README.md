# ble_mesh

一个 Flutter BLE Mesh 插件，在 **Android** 与 **iOS** 上均基于 [Nordic nRF Mesh Library](https://www.nordicsemi.com/Products/Development-software/nRF-Mesh) 实现真实 PB-GATT 配网、Proxy 连接、配置消息与加密控制，目标为双端行为一致。

## 功能概览

| 功能 | Android | iOS | 说明 |
|------|---------|-----|------|
| 初始化与权限 | ✅ | ✅ | 加载/创建 Mesh 网络，请求蓝牙权限 |
| 扫描未配网设备 | ✅ | ✅ | 广播 Mesh Provisioning Service (0x1827) |
| PB-GATT 配网 | ✅ | ✅ | 完整 Provisioning + 自动 AppKey 分发与模型绑定 |
| Proxy 连接 | ✅ | ✅ | 连接 Mesh Proxy Service (0x1828) 收发加密 PDU |
| 单播控制 | ✅ | ✅ | Generic On/Off、Generic Level |
| 分组管理 | ✅ | ✅ | 创建/删除 Group，Subscription Add / Delete |
| 组播控制 | ✅ | ✅ | 向分组地址发送 Generic On/Off |
| 换组 | ✅ | ✅ | `changeNodeGroup`：取消旧组订阅并加入新组 |
| 同步组（Sync Group） | ✅ | ✅ | Vendor **0x0002** Publish/Subscribe，`configureSyncMaster/Slave` |
| 节点删除 | ✅ | ✅ | Config Node Reset + 本地网络同步 |
| 网络导入/导出 | ✅ | ✅ | nRF Mesh App 兼容 JSON |
| Vendor 消息 | ✅ | ✅ | Espressif CID 0x02E5 主从切换、播放模式等 |
| 场景管理 | ⚠️ 原生层 | ⚠️ 占位 | **尚未暴露 Dart 公开 API** |
| Light Lightness | ⚠️ 原生层 | ⚠️ 原生层 | **尚未暴露 Dart 公开 API** |

## 架构

```
Flutter (Dart)
    │ MethodChannel / EventChannel
    ├─ Android ── Nordic nRF Mesh Library 3.3.7 (Kotlin)
    └─ iOS     ── nRFMeshProvision ~4.2.0 (Swift)
```

| 阶段 | 流程 |
|------|------|
| **配网** | PB-GATT (0x1827) → 密钥交换 → 写入 Nordic Mesh DB |
| **自动配置** | Proxy 就绪后 → `ConfigCompositionDataGet` → `ConfigAppKeyAdd` → `ConfigModelAppBind` |
| **控制** | Proxy GATT (0x1828) → Nordic 加密栈 → 单播/组播 Mesh 消息 |
| **分组** | 创建 Group → `ConfigModelSubscriptionAdd` / `Delete` → 向组地址发控制消息 |

配网完成后，**原生层会自动连接 Proxy 并下发 AppKey / 模型绑定**（约 2.5s 延迟等待设备切换广播）。Dart 层监听 `configurationState` 等待 `complete` 即可，**不要在每次 Proxy 连接时重复调用 `distributeAppKey()`**。

## 安装

在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  ble_mesh:
    path: ../ble_mesh   # 或发布后的版本号
```

运行 `flutter pub get` 后，iOS 会通过 `ble_mesh.podspec` 自动引入 `nRFMeshProvision`，Android 通过 `build.gradle.kts` 引入 Nordic Mesh 库，**无需手动改 Podfile**。

## 快速开始

### 1. 初始化

推荐使用 `initializeAndWaitForNetwork`，确保本地 Mesh DB 加载完成后再扫描/配网：

```dart
final mesh = BleMesh();

await mesh.initializeAndWaitForNetwork(
  timeout: const Duration(seconds: 10),
);

// Android 必须请求蓝牙权限
final granted = await mesh.requestPermissions();
if (!granted) {
  // 处理权限拒绝
}
```

### 2. 监听事件

```dart
// 蓝牙开关
mesh.bluetoothState.listen((state) { /* ... */ });

// 扫描结果
mesh.scanResults.listen((device) {
  print('${device.name} uuid=${device.uuid} rssi=${device.rssi}');
});

// 配网进度
mesh.provisioningState.listen((state) { /* connecting / provisioning / complete / failed */ });

// 新节点加入
mesh.nodeAdded.listen((node) {
  print('节点 ${node.name} 地址 ${node.hexAddress}');
});

// 配网后配置进度（AppKey + 模型绑定）—— 控制前必须等到 complete
mesh.configurationState.listen((status) {
  switch (status.state) {
    case MeshConfigurationState.pendingProxy:
      print('等待 Proxy 连接…');
    case MeshConfigurationState.proxyConnected:
      print('开始下发 AppKey / Bind…');
    case MeshConfigurationState.complete:
      print('节点 ${status.unicastAddress} 配置完成，可以控制');
    case MeshConfigurationState.failed:
      print('配置失败: ${status.message}');
    default:
      break;
  }
});

// Proxy 连接状态
mesh.connectionState.listen((state) { /* connected / disconnected */ });

// 节点删除完成
mesh.nodeDeleted.listen((unicastAddress) {
  print('节点已删除: 0x${unicastAddress.toRadixString(16)}');
});
```

### 3. 扫描与配网

```dart
await mesh.startScan(timeout: const Duration(seconds: 15));

try {
  await mesh.provisionDevice(
    uuid: device.uuid,
    address: device.address,   // Android: MAC；iOS: CBPeripheral UUID
    nodeName: '客厅灯',
  );
} on ProvisioningException catch (e) {
  print('配网失败: ${e.message}');
}
```

> **说明**：`provisionDevice` 的 `address` 是扫描结果中的 **蓝牙标识**（`BleMeshDevice.address`），不是 Mesh 单播地址。单播地址由 Nordic 库根据 Provisioner 范围自动分配（跳过 exclusion list 中已删除地址）。

### 4. 配网后自动配置（AppKey + 模型绑定）

配网成功后原生层会：

1. 将节点加入待配置队列
2. 约 2.5s 后自动连接 Proxy
3. Proxy 就绪后发送 Composition → AppKey Add → Model Bind

Dart 层只需监听 `configurationState`：

```dart
// ✅ 推荐：等待原生自动配置完成
await mesh.configurationState
    .firstWhere(
      (s) =>
          s.unicastAddress == nodeAddress &&
          s.state == MeshConfigurationState.complete,
    )
    .timeout(const Duration(seconds: 30));

// ⚠️ 仅手动重试时使用（例如配置失败后点「重新分发」）
await mesh.distributeAppKey(nodeAddress);
```

**注意**

- Proxy 重连（分组、换组等）**不会**对已配置节点重复下发 AppKey（双端均只对队列中节点或 `applicationKeys` 为空的节点配置）。
- 不要在 `connectionState == connected` 回调里无条件调用 `distributeAppKey()`，否则可能与原生自动配置冲突。

### 5. 连接 Proxy

控制消息需先连接节点的 **Mesh Proxy Service**。`connectToProxy` 参数是 **蓝牙地址**，通常使用 `node.macAddress`：

```dart
if (node.macAddress != null) {
  await mesh.connectToProxy(node.macAddress!);
}
```

> **注意**：`macAddress` 仅在本次 App 运行期间缓存。冷启动后若为空，需重新扫描获取蓝牙标识。

### 6. 单播控制

```dart
// 需：Proxy 已连接 + configurationState.complete
await mesh.sendGenericOnOff(address: 0x0002, onOff: true);
await mesh.sendGenericLevel(address: 0x0002, level: 16384);
```

### 7. 分组控制

默认控制分组地址 `kDefaultControlGroupAddress`（`0xC001`）：

```dart
import 'package:ble_mesh/ble_mesh.dart';

// 1. 确保分组存在
final group = await mesh.ensureGroup(
  name: '控制组',
  address: kDefaultControlGroupAddress,
);

// 2. 连接 Proxy
await mesh.connectToProxy(node.macAddress!);

// 3. 订阅分组（配网后已 Bind AppKey，此处只发 Subscription Add）
for (final addr in [0x0002, 0x0003]) {
  await mesh.addModelSubscription(
    nodeAddress: addr,
    modelId: kGenericOnOffModelId,
    subscriptionAddress: group.address,
  );
}

// 4. 组播控制
await mesh.sendGenericOnOff(
  address: kDefaultControlGroupAddress,
  onOff: false,
);
```

#### 换组 / 取消订阅

```dart
// 将设备从 0xC001 换到 0xC002（Delete → Add，目标组不存在时自动创建）
await mesh.changeNodeGroup(
  nodeAddress: 0x0002,
  fromGroupAddress: kDefaultControlGroupAddress,
  toGroupAddress: 0xC002,
  targetGroupName: '备用组',
);

// 批量换组
await mesh.changeNodesGroup(
  nodeAddresses: [0x0002, 0x0003],
  fromGroupAddress: 0xC001,
  toGroupAddress: 0xC002,
);

// 仅从当前组移除
await mesh.removeModelSubscription(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  subscriptionAddress: kDefaultControlGroupAddress,
);
```

#### 模型订阅 / 发布（可单选或组合）

使用 [MeshModelMessagingMode] 明确选择能力，或分别调用底层 API：

```dart
// 组合配置（推荐）：Bind + 订阅/发布
await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  groupAddress: kDefaultControlGroupAddress,
  mode: MeshModelMessagingMode.subscribeOnly, // 仅订阅
);

await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  mode: MeshModelMessagingMode.appKeyOnly, // 仅 Bind AppKey，无需 groupAddress
);

await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  groupAddress: kDefaultSyncGroupAddress,
  mode: MeshModelMessagingMode.publishOnly, // 仅发布
);

await mesh.configureModel(
  nodeAddress: 0x0002,
  modelId: kSyncModelCompoundId,
  groupAddress: kDefaultSyncGroupAddress,
  mode: MeshModelMessagingMode.subscribeAndPublish, // 订阅 + 发布
);

// 原子操作（配网后已 Bind AppKey 时无需再 bind）
await mesh.addModelSubscription(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  subscriptionAddress: kDefaultControlGroupAddress,
);

await mesh.setModelPublication(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  publishAddress: kDefaultSyncGroupAddress,
);

await mesh.removeModelSubscription(
  nodeAddress: 0x0002,
  modelId: kGenericOnOffModelId,
  subscriptionAddress: kDefaultControlGroupAddress,
);

await mesh.setModelPublication(
  nodeAddress: 0x0002,
  modelId: kDeviceControlModelCompoundId,
  publishAddress: 0, // 清除发布
);
```

**Example 应用** 主页 AppBar「分组控制测试」页包含：创建分组 → 订阅 → 换组 → 组播；节点控制页含 Sync Group 主从配置 UI。

### 8. 同步组（Sync Group）

同步组（默认 `0xC000`）用于固件 `send_ble_mesh_sync_mode`。通过 [configureSyncModels] 对 Vendor **0x0001** / **0x0002** 灵活配置：

| 选项 | 说明 |
|------|------|
| **模型** | 可只选 0x0001、只选 0x0002，或两者（`modelIds`） |
| **能力** | `appKeyOnly` / `subscribeOnly` / `publishOnly` / `subscribeAndPublish` |

```dart
await mesh.connectToProxy(node.macAddress!);

// 灵活配置：两个模型 + 订阅+发布
await mesh.configureSyncModels(
  nodeAddress: 0x0002,
  mode: MeshModelMessagingMode.subscribeAndPublish,
);

// 仅 0x0002 发布
await mesh.configureSyncModels(
  nodeAddress: 0x0002,
  mode: MeshModelMessagingMode.publishOnly,
  modelIds: [kDeviceControlModelCompoundId],
);

// 仅 Bind AppKey，不配置订阅/发布
await mesh.configureSyncModels(
  nodeAddress: 0x0002,
  mode: MeshModelMessagingMode.appKeyOnly,
  modelIds: kSyncVendorModelCompoundIds,
);

// 快捷：主机 / 从机（仍支持 modelIds 参数）
await mesh.configureSyncMaster(nodeAddress: 0x0002);
await mesh.configureSyncSlave(nodeAddress: 0x0003);
```

### 9. 删除节点与重配网

```dart
await mesh.deleteNode(0x0002);
// 等待 nodeDeleted 后再重配网
```

| 注意项 | 说明 |
|--------|------|
| 等待删除完成 | 删除会发 `Config Node Reset` 并断开 GATT，应监听 `nodeDeleted` |
| 地址自动分配 | 重配网不要手动指定单播地址；Nordic 使用 `nextAvailableUnicastAddress` |
| iOS GATT 清理 | 删除/重配网前会关闭 PB-GATT Bearer，避免「设备已被使用」 |
| 设备端 Reset | 设备已 Reset 但 App 仍有旧节点时，先 `deleteNode` 或导入干净网络 |

### 10. 网络备份与迁移

```dart
final json = await mesh.exportNetworkJson();
await mesh.importNetworkJson(json);
// 触发 networkLoaded / networkUpdated
```

格式与 nRF Mesh App 的 Mesh Configuration Database 兼容。

### 11. Vendor 设备控制（Espressif）

```dart
await mesh.setMasterSlaveRole(address: 0x0002, role: MeshNodeRole.master);

await mesh.setPlayMode(
  address: 0x0002,
  config: PlayModeConfig(
    sourceType: SourceType.sdCard,
    modeIndex: 1,
    speed: 5,
    brightness: 32768,
  ),
);

mesh.vendorMessages.listen((status) {
  print('Vendor ${status.hexSource} op=0x${status.opCode.toRadixString(16)}');
});
```

| 常量 | 值 | 用途 |
|------|-----|------|
| `kVendorCompanyId` | `0x02E5` | Espressif CID |
| `kDefaultSyncGroupAddress` | `0xC000` | 同步组播地址 |
| `kDefaultControlGroupAddress` | `0xC001` | 默认控制分组 |
| `kGenericOnOffModelId` | `0x1000` | SIG Generic OnOff Server |

## 完整工作流

```
initializeAndWaitForNetwork
        ↓
   startScan → provisionDevice
        ↓
  原生自动连 Proxy（iOS ~4s 扫描重连，ESP 需 GATT 切换完成）
        ↓
 configurationState.complete（AppKey + Model Bind）
        ↓
 connectToProxy（若未保持连接）
        ↓
 单播控制 / ensureGroup → addModelSubscription → 组播
        ↓
 changeNodeGroup（可选：换到其他组）
```

## 错误处理

所有异常继承自 `BleMeshException`：

```dart
try {
  await mesh.sendGenericOnOff(address: 0x0002, onOff: true);
} on NotInitializedException {
  // 未调用 initialize()
} on NotConnectedException {
  // 未连接 Proxy
} on BluetoothDisabledException {
  // 蓝牙已关闭
} on PermissionDeniedException {
  // 权限被拒绝
} on ProvisioningException catch (e) {
  // 配网失败
} on BleMeshException catch (e) {
  print('[${e.code}] ${e.message}');
}
```

## 调试

### Xcode（iOS）

Console 过滤 `BleMesh` 或以下标签：

| 标签 | 含义 |
|------|------|
| `[PROVISION]` | 配网与地址分配 |
| `[DELETE]` | 节点删除与 Reset |
| `[GROUP]` | AppKey / Bind / Subscription Add·Delete |
| `[PROXY]` | Proxy 连接与 PDU |
| `[NET]` / `[CACHE]` | 网络 DB 与缓存 |

**AppKey 配置成功** 应看到：

```
─── 开始向节点 0x0002 分发 AppKey ───
Composition Data 获取成功，待绑定模型数=3
发送 ConfigAppKeyAdd → 0x0002
绑定 SIG Model 0x1000 @0x0002
─── AppKey 分发序列完成 ───
```

**分组订阅成功** 应看到：

```
[GROUP] 发送 ConfigModelSubscriptionAdd ... group=0xC001
[GROUP] ConfigModelSubscriptionAdd 成功
```

**换组成功** 应看到：

```
[GROUP] 发送 ConfigModelSubscriptionDelete ... group=0xC001
[GROUP] ConfigModelSubscriptionDelete 成功
[GROUP] 发送 ConfigModelSubscriptionAdd ... group=0xC002
```

设备串口（ESP 等）对应：`MODEL_OP_APPKEY_ADD`、`MODEL_OP_MODEL_APP_BIND`、`MODEL_OP_MODEL_SUB_ADD` / `MODEL_OP_MODEL_SUB_DELETE`，组控时 `dst 0xc001`。

#### ESP 配网后卡在 Proxy / 密钥分发

串口若出现 `PROV_COMPLETE` 后仅有 `Connected` + `MTU exchange`，但**没有**后续 Mesh Config 日志，常见原因：

1. **GATT 服务切换**：配网用 `0x1827`，配置用 `0x1828`。ESP 报错  
   `GATT_SendServiceChangeIndication can't send service change indication` 时，iOS 会缓存旧 GATT 表。  
   **固件侧**建议在 `menuconfig` 启用 `BT_GATTS_SEND_SERVICE_CHANGE_MANUALLY` 或正确配置 Service Change 特性。  
   **插件侧**（iOS）配网后会延迟 ~4s、扫描重连并 `discoverServices(nil)` 全量发现。

2. **验证**：Xcode 应看到 `didDiscoverServices: [1828]` → `Proxy Data Out 通知已开启` → `分发 AppKey`。

### Android

Logcat 过滤 `BleMesh` 或 `BleMeshNetworkManager`。

### Example 应用

```bash
cd example && flutter run
```

主页含设备列表、单播/Vendor 控制、调试日志面板；AppBar 分组图标进入分组/换组测试页。

## 平台配置

### Android

`AndroidManifest.xml` 需包含（插件通常已合并）：

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

依赖：`no.nordicsemi.android:mesh:3.3.7`（见 `android/build.gradle.kts`）。

### iOS

`Info.plist` 添加蓝牙用途说明：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>需要蓝牙权限以控制 Mesh 灯光设备</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>需要蓝牙权限以控制 Mesh 灯光设备</string>
```

依赖：`nRFMeshProvision ~> 4.2.0`（见 `ios/ble_mesh.podspec`）。

最低系统版本：**iOS 13.0**。

## Dart API 参考

### 主要方法

| 方法 | 说明 |
|------|------|
| `initialize()` / `initializeAndWaitForNetwork()` | 初始化并加载 Mesh 网络 |
| `startScan()` / `stopScan()` | 扫描未配网设备 |
| `provisionDevice()` / `cancelProvisioning()` | 配网 |
| `connectToProxy()` / `disconnectFromProxy()` | Proxy 连接（蓝牙地址字符串） |
| `distributeAppKey()` | 手动触发 AppKey 配置（失败重试用） |
| `sendGenericOnOff()` / `sendGenericLevel()` | SIG 模型控制 |
| `getNodes()` / `deleteNode()` | 节点管理 |
| `createGroup()` / `deleteGroup()` / `ensureGroup()` | 分组管理 |
| `addModelSubscription()` / `removeModelSubscription()` | Subscription Add / Delete |
| `setModelPublication()` | Publication Set（`publishAddress: 0` 清除发布） |
| `configureModel()` | Bind + 按 `MeshModelMessagingMode` 配置订阅/发布 |
| `changeNodeGroup()` / `changeNodesGroup()` | 换组（Delete + Add，仅订阅） |
| `configureSyncModels()` | Vendor 0x0001/0x0002 灵活配置（模型 + 订阅/发布/AppKey） |
| `configureSyncMaster()` / `configureSyncSlave()` | Sync 主从快捷配置 |
| `exportNetworkJson()` / `importNetworkJson()` | 网络备份 |
| `sendVendorMessage()` / `setMasterSlaveRole()` / `setPlayMode()` | Vendor 控制 |

### 主要事件流

| 流 | 说明 |
|----|------|
| `scanResults` | 扫描到的未配网设备 |
| `provisioningState` | 配网状态 |
| `nodeAdded` | 新节点加入 |
| `configurationState` | 配网后 AppKey / Bind 进度（**控制前必听**） |
| `connectionState` | Proxy 连接状态 |
| `nodeDeleted` | 节点删除完成 |
| `networkLoaded` / `networkUpdated` | 网络加载/变更 |
| `meshMessages` / `vendorMessages` | 收到的状态消息 |

### configurationState 状态

| 状态 | 含义 |
|------|------|
| `pendingProxy` | 配网完成，等待 Proxy |
| `proxyConnected` | Proxy 已连，正在下发配置消息 |
| `complete` | AppKey + 模型绑定完成 |
| `failed` | 配置失败（见 `message`） |

## 数据模型

| 类型 | 说明 |
|------|------|
| `BleMeshDevice` | 扫描到的未配网设备 |
| `MeshNode` | 已配网节点（含 `unicastAddress`、`macAddress`、元素列表） |
| `MeshElement` | 节点元素 |
| `MeshGroup` | 分组（组播地址） |
| `MeshNetworkInfo` | 网络摘要（NetKey、AppKey、IV Index 等） |
| `MeshConfigurationStatus` | 配置阶段状态 |
| `MeshMessageStatus` | SIG 模型状态回包 |
| `VendorMessageStatus` | Vendor 模型状态回包 |

## 常用 Mesh 模型 ID

| 模型 | ID |
|------|-----|
| Generic On/Off Server | `0x1000` |
| Generic On/Off Client | `0x1001` |
| Generic Level Server | `0x1002` |
| Generic Level Client | `0x1003` |
| Light Lightness Server | `0x1300` |
| Scene Server | `0x1203` |

## 常用 Mesh 地址范围

| 范围 | 用途 |
|------|------|
| `0x0001 – 0x7FFF` | 单播地址（Provisioner 通常占 `0x0001`） |
| `0xC000 – 0xFEFF` | 分组地址 |
| `0xFF00 – 0xFFFF` | 固定组地址（如 `0xFFFF` 全节点） |

## 已知限制

- **场景 API**：原生层有占位实现，Dart 层尚未公开 `getScenes` / `storeScene` 等方法。
- **Light Lightness**：原生已实现，Dart 层尚未公开 `sendLightLightness`。
- **`macAddress` 非持久化**：App 重启后需重新扫描获取蓝牙地址再连 Proxy。
- **Publication / Proxy Filter**：Publication Set 已支持 iOS/Android；Proxy Filter 尚未实现。
- **多 Proxy 节点**：同时只维护一条 Proxy GATT 连接，组播经当前 Proxy 转发。

## 许可证

MIT License
