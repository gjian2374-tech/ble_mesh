/// BLE Mesh Flutter 插件。
///
/// 提供蓝牙 Mesh 网络核心能力：
/// - 初始化与权限申请
/// - 扫描与配网
/// - 代理连接
/// - 节点与分组管理
/// - Generic OnOff / Level 控制
/// - Vendor 设备控制
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import 'ble_mesh_platform_interface.dart';

export 'src/enums/ble_mesh_enums.dart';
export 'src/exceptions/ble_mesh_exception.dart';
export 'src/models/ble_mesh_device.dart';
export 'src/models/mesh_element.dart';
export 'src/models/mesh_group.dart';
export 'src/models/mesh_configuration_status.dart';
export 'src/models/mesh_message_status.dart';
export 'src/models/mesh_network_info.dart';
export 'src/models/mesh_node.dart';
export 'src/models/vendor_message.dart';

import 'src/enums/ble_mesh_enums.dart';
import 'src/exceptions/ble_mesh_exception.dart';
import 'src/models/ble_mesh_device.dart';
import 'src/models/mesh_group.dart';
import 'src/models/mesh_configuration_status.dart';
import 'src/models/mesh_message_status.dart';
import 'src/models/mesh_network_info.dart';
import 'src/models/mesh_node.dart';
import 'src/models/vendor_message.dart';

/// BLE Mesh 插件主类（单例）。
///
/// 典型连接流程：
/// 1. [initialize] → [requestPermissions]
/// 2. [startScan] → 监听 [scanResults]
/// 3. [provisionDevice] → 监听 [provisioningState] / [nodeAdded]
/// 4. 监听 [configurationState] 等待 AppKey 与模型绑定完成
/// 5. [connectToProxy] → 监听 [connectionState]
/// 6. [ensureGroup] → [configureModel] 或 [addModelSubscription]
/// 7. [sendGenericOnOff] / [sendVendorMessage] 控制设备
class BleMesh {
  static final BleMesh _instance = BleMesh._internal();

  /// 全局单例。
  static BleMesh get instance => _instance;

  factory BleMesh() => _instance;

  BleMesh._internal();

  bool _isInitialized = false;

  /// 插件是否已完成 [initialize]。
  bool get isInitialized => _isInitialized;

  BleMeshPlatform get _platform => BleMeshPlatform.instance;

  // ═══════════════════════════════════════════════════════════════════════════
  // 事件流（按典型使用顺序排列，可在各阶段订阅）
  // ═══════════════════════════════════════════════════════════════════════════

  /// 全局错误事件。
  Stream<BleMeshException> get errors {
    return _platform.meshEvents
        .where((e) => e['type'] == 'error')
        .map(
          (e) => BleMeshException(
            e['message'] as String? ?? '未知错误',
            code: e['code'] as String? ?? 'UNKNOWN',
            details: e['details'],
          ),
        );
  }

  /// 系统蓝牙开关状态变化。
  Stream<BluetoothState> get bluetoothState {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.bluetoothStateChanged.name)
        .map(
          (e) => BluetoothState.fromString(e['state'] as String? ?? 'unknown'),
        );
  }

  /// Mesh 网络从本地存储加载完成（[initialize] 后触发）。
  Stream<void> get networkLoaded {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.networkLoaded.name)
        .map((_) {});
  }

  /// Mesh 网络数据变更（配网、删节点、导入等后触发）。
  Stream<void> get networkUpdated {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.networkUpdated.name)
        .map((_) {});
  }

  /// 扫描到的未配网设备。
  Stream<BleMeshDevice> get scanResults {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.scanResult.name)
        .map((e) => BleMeshDevice.fromMap(e['device'] as Map? ?? {}));
  }

  /// 扫描结束。
  Stream<void> get scanStopped {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.scanStopped.name)
        .map((_) {});
  }

  /// 配网进度（idle / linking / provisioning / success / failed）。
  Stream<ProvisioningState> get provisioningState {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.provisioningStateChanged.name)
        .map(
          (e) => ProvisioningState.fromString(e['state'] as String? ?? 'idle'),
        );
  }

  /// 新节点加入网络（配网成功后触发，含单播地址与 UUID）。
  Stream<MeshNode> get nodeAdded {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.nodeAdded.name)
        .map((e) => MeshNode.fromMap(e['node'] as Map? ?? {}));
  }

  /// 配网后配置进度（AppKey 下发、模型绑定等）。
  ///
  /// 控制设备前建议等待 `state == complete`。
  Stream<MeshConfigurationStatus> get configurationState {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.configurationStateChanged.name)
        .map(MeshConfigurationStatus.fromMap);
  }

  /// Proxy GATT 连接状态变化。
  Stream<MeshConnectionState> get connectionState {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.connectionStateChanged.name)
        .map(
          (e) => MeshConnectionState.fromString(
            e['state'] as String? ?? 'disconnected',
          ),
        );
  }

  /// 节点从网络中删除完成。
  Stream<int> get nodeDeleted {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.nodeDeleted.name)
        .map((e) => e['unicastAddress'] as int? ?? 0);
  }

  /// 收到的 SIG / Vendor 模型状态消息。
  Stream<MeshMessageStatus> get meshMessages {
    return _platform.meshEvents
        .where((e) => e['type'] == MeshEventType.meshMessageReceived.name)
        .map((e) => MeshMessageStatus.fromMap(e));
  }

  /// 收到的 Vendor 模型状态消息（[meshMessages] 的子集）。
  Stream<VendorMessageStatus> get vendorMessages {
    return meshMessages
        .where(
          (event) => event.modelType == MeshMessageModelType.vendorModelStatus,
        )
        .map(VendorMessageStatus.fromMeshMessageStatus);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. 初始化与权限
  // ═══════════════════════════════════════════════════════════════════════════

  /// 初始化插件并加载本地 Mesh 网络。
  ///
  /// 成功后触发 [networkLoaded]；若网络已存在可直接进入扫描/连接流程。
  Future<void> initialize() async {
    try {
      await _platform.initialize();
      _isInitialized = true;
      developer.log('BleMesh 初始化成功', name: 'ble_mesh');
    } on PlatformException catch (e) {
      developer.log('BleMesh 初始化失败', name: 'ble_mesh', level: 1000, error: e);
      throw BleMeshException(
        e.message ?? '初始化失败',
        code: e.code,
        details: e.details,
      );
    }
  }

  /// 初始化并阻塞等待 [networkLoaded]。
  ///
  /// [timeout] 超时抛出 [MeshTimeoutException]。
  Future<void> initializeAndWaitForNetwork({Duration? timeout}) async {
    final loadFuture = networkLoaded.first;
    await initialize();
    if (timeout == null) {
      await loadFuture;
      return;
    }
    await loadFuture.timeout(
      timeout,
      onTimeout: () => throw const MeshTimeoutException('等待 Mesh 网络加载'),
    );
  }

  /// 申请蓝牙相关运行时权限（Android 12+ 需 BLUETOOTH_SCAN / CONNECT）。
  Future<bool> requestPermissions() async {
    _ensureInitialized();
    try {
      return await _platform.requestPermissions();
    } on PlatformException catch (e) {
      throw PermissionDeniedException(detail: e.message);
    }
  }

  /// 查询当前系统蓝牙状态。
  Future<BluetoothState> getBluetoothState() async {
    final stateStr = await _platform.getBluetoothState();
    return BluetoothState.fromString(stateStr);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. 扫描未配网设备
  // ═══════════════════════════════════════════════════════════════════════════

  /// 开始扫描 PB-GATT 未配网设备，结果通过 [scanResults] 推送。
  ///
  /// [timeout] 可选自动停止时间；手动停止请调用 [stopScan]。
  Future<void> startScan({Duration? timeout}) async {
    _ensureInitialized();
    try {
      await _platform.startScan(timeoutMs: timeout?.inMilliseconds);
      developer.log('开始扫描...', name: 'ble_mesh');
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 停止扫描。
  Future<void> stopScan() async {
    _ensureInitialized();
    try {
      await _platform.stopScan();
      developer.log('扫描已停止', name: 'ble_mesh');
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. 配网
  // ═══════════════════════════════════════════════════════════════════════════

  /// 对指定未配网设备执行 PB-GATT 配网。
  ///
  /// [uuid] 设备 UUID；[address] 手机蓝牙 MAC（来自 [BleMeshDevice.address]）。
  /// 进度见 [provisioningState]，成功后见 [nodeAdded] 与 [configurationState]。
  Future<void> provisionDevice({
    required String uuid,
    required String address,
    String? nodeName,
  }) async {
    _ensureInitialized();
    try {
      await _platform.provisionDevice(
        uuid: uuid,
        address: address,
        nodeName: nodeName,
      );
    } on PlatformException catch (e) {
      throw ProvisioningException(
        e.message ?? '配网失败',
        code: e.code,
        details: e.details,
      );
    }
  }

  /// 取消进行中的配网。
  Future<void> cancelProvisioning() async {
    await _platform.cancelProvisioning();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. Proxy 连接（配网后控制与配置消息均经 Proxy 下发）
  // ═══════════════════════════════════════════════════════════════════════════

  /// 通过 GATT Proxy 连接到已配网节点。
  ///
  /// [address] 为节点蓝牙 MAC 字符串；连接状态见 [connectionState]。
  Future<void> connectToProxy(String address) async {
    _ensureInitialized();
    try {
      await _platform.connectToProxy(address);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 断开当前 Proxy 连接。
  Future<void> disconnectFromProxy() async {
    _ensureInitialized();
    try {
      await _platform.disconnectFromProxy();
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 查询当前 Proxy 连接状态（无需等待事件流，适合 App 启动时恢复 UI）。
  Future<MeshConnectionState> getConnectionState() async {
    _ensureInitialized();
    try {
      final state = await _platform.getConnectionState();
      return MeshConnectionState.fromString(state);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 指定蓝牙地址的 Proxy 是否已就绪（通知已开启、可收发 Mesh PDU）。
  Future<bool> isProxyReady(String address) async {
    _ensureInitialized();
    try {
      return await _platform.isProxyReady(address);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. 节点管理
  // ═══════════════════════════════════════════════════════════════════════════

  /// 获取网络中所有已配网节点。
  Future<List<MeshNode>> getNodes() async {
    _ensureInitialized();
    final maps = await _platform.getNodes();
    return maps.map(MeshNode.fromMap).toList();
  }

  /// 按单播地址查找节点。
  Future<MeshNode?> getNodeByAddress(int unicastAddress) async {
    final nodes = await getNodes();
    for (final node in nodes) {
      if (node.unicastAddress == unicastAddress) {
        return node;
      }
    }
    return null;
  }

  /// 按 UUID 查找节点。
  Future<MeshNode?> getNodeByUuid(String uuid) async {
    final normalized = uuid.trim().toLowerCase();
    final nodes = await getNodes();
    for (final node in nodes) {
      if (node.uuid.trim().toLowerCase() == normalized) {
        return node;
      }
    }
    return null;
  }

  /// 从网络中删除节点。
  Future<void> deleteNode(int unicastAddress) async {
    _ensureInitialized();
    try {
      await _platform.deleteNode(unicastAddress);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 手动触发 AppKey 下发与模型绑定（Config AppKey Add + Model App Bind）。
  ///
  /// 配网后通常自动执行；失败重试或 Proxy 重连后可再次调用。
  Future<void> distributeAppKey(int unicastAddress) async {
    _ensureInitialized();
    _validateAddress(unicastAddress);
    try {
      await _platform.distributeAppKey(unicastAddress);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 6. 分组管理（Provisioner 本地 Group 地址表）
  // ═══════════════════════════════════════════════════════════════════════════

  /// 获取所有分组。
  Future<List<MeshGroup>> getGroups() async {
    _ensureInitialized();
    final maps = await _platform.getGroups();
    return maps.map(MeshGroup.fromMap).toList();
  }

  /// 按组播地址查找分组。
  Future<MeshGroup?> getGroupByAddress(int address) async {
    final groups = await getGroups();
    for (final group in groups) {
      if (group.address == address) {
        return group;
      }
    }
    return null;
  }

  /// 在 Provisioner 中创建分组（地址范围 `0xC000`–`0xFEFF`）。
  Future<void> createGroup({required String name, required int address}) async {
    _ensureInitialized();
    if (address < 0xC000 || address > 0xFEFF) {
      throw InvalidAddressException(address);
    }
    try {
      await _platform.createGroup(name: name, address: address);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 删除分组。
  Future<void> deleteGroup(int address) async {
    _ensureInitialized();
    try {
      await _platform.deleteGroup(address);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 确保分组存在，不存在则自动 [createGroup]。
  Future<MeshGroup> ensureGroup({
    required String name,
    required int address,
  }) async {
    final existing = await getGroupByAddress(address);
    if (existing != null) {
      return existing;
    }
    await createGroup(name: name, address: address);
    return MeshGroup(address: address, name: name);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 7. 模型配置（订阅 / 发布，需已连接 Proxy）
  // ═══════════════════════════════════════════════════════════════════════════

  /// 为模型添加组订阅（Config Model Subscription Add）。
  ///
  /// 配网后若已自动 Bind AppKey，可直接调用；否则先用 [configureModel]。
  Future<void> addModelSubscription({
    required int nodeAddress,
    required int modelId,
    required int subscriptionAddress,
    int? elementAddress,
  }) async {
    _validateGroupAddress(subscriptionAddress);
    final resolvedElementAddress = await _resolveElementAddressForModel(
      nodeAddress: nodeAddress,
      modelId: modelId,
      elementAddress: elementAddress,
    );
    await _addSubscription(
      nodeAddress: nodeAddress,
      elementAddress: resolvedElementAddress,
      modelId: modelId,
      subscriptionAddress: subscriptionAddress,
    );
  }

  /// 取消模型的组订阅（Config Model Subscription Delete）。
  Future<void> removeModelSubscription({
    required int nodeAddress,
    required int modelId,
    required int subscriptionAddress,
    int? elementAddress,
  }) async {
    _validateGroupAddress(subscriptionAddress);
    final resolvedElementAddress = await _resolveElementAddressForModel(
      nodeAddress: nodeAddress,
      modelId: modelId,
      elementAddress: elementAddress,
    );
    await _removeSubscription(
      nodeAddress: nodeAddress,
      elementAddress: resolvedElementAddress,
      modelId: modelId,
      subscriptionAddress: subscriptionAddress,
    );
  }

  /// 配置模型发布地址（Config Model Publication Set）。
  ///
  /// [publishAddress] 为 `0` 时清除发布配置。
  Future<void> setModelPublication({
    required int nodeAddress,
    required int modelId,
    required int publishAddress,
    int? elementAddress,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
  }) async {
    if (publishAddress != 0) {
      _validateGroupAddress(publishAddress);
    }
    final resolvedElementAddress = await _resolveElementAddressForModel(
      nodeAddress: nodeAddress,
      modelId: modelId,
      elementAddress: elementAddress,
    );
    await _setPublication(
      nodeAddress: nodeAddress,
      elementAddress: resolvedElementAddress,
      modelId: modelId,
      publishAddress: publishAddress,
      appKeyIndex: appKeyIndex,
      publishTtl: publishTtl,
      publishPeriod: publishPeriod,
    );
  }

  /// 一步配置模型的 AppKey 绑定及可选的组订阅/发布。
  ///
  /// 使用 [MeshModelMessagingMode] 选择能力：
  /// - [MeshModelMessagingMode.appKeyOnly] 仅 Bind AppKey
  /// - [MeshModelMessagingMode.subscribeOnly] 仅订阅
  /// - [MeshModelMessagingMode.publishOnly] 仅发布
  /// - [MeshModelMessagingMode.subscribeAndPublish] 订阅 + 发布
  ///
  /// [groupAddress] 在 `appKeyOnly` 时可省略；其余模式必填。
  /// 默认会 [ensureGroup] 并 [bindAppKey]；已配置过可设 `bindAppKey: false`。
  Future<void> configureModel({
    required int nodeAddress,
    required int modelId,
    int? groupAddress,
    required MeshModelMessagingMode mode,
    int? elementAddress,
    bool bindAppKey = true,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
    bool ensureGroupExists = true,
    String? groupName,
  }) async {
    if (mode.requiresGroupAddress) {
      if (groupAddress == null) {
        throw const BleMeshException(
          '非 appKeyOnly 模式必须提供 groupAddress',
          code: 'INVALID_ARGUMENT',
        );
      }
      _validateGroupAddress(groupAddress);
      if (ensureGroupExists) {
        await ensureGroup(
          name: groupName ??
              'Group 0x${groupAddress.toRadixString(16).toUpperCase()}',
          address: groupAddress,
        );
      }
    }

    final resolvedElementAddress = await _resolveElementAddressForModel(
      nodeAddress: nodeAddress,
      modelId: modelId,
      elementAddress: elementAddress,
    );

    if (bindAppKey) {
      await _bindAppKey(
        nodeAddress: nodeAddress,
        elementAddress: resolvedElementAddress,
        modelId: modelId,
        appKeyIndex: appKeyIndex,
      );
    }

    if (mode.subscribe) {
      await _addSubscription(
        nodeAddress: nodeAddress,
        elementAddress: resolvedElementAddress,
        modelId: modelId,
        subscriptionAddress: groupAddress!,
      );
    }

    if (mode.publish) {
      await _setPublication(
        nodeAddress: nodeAddress,
        elementAddress: resolvedElementAddress,
        modelId: modelId,
        publishAddress: groupAddress!,
        appKeyIndex: appKeyIndex,
        publishTtl: publishTtl,
        publishPeriod: publishPeriod,
      );
    }
  }

  /// 将节点从旧分组换到新分组（Subscription Delete → Add，仅订阅）。
  ///
  /// [fromGroupAddress] 与 [toGroupAddress] 相同时仅确保目标组订阅存在。
  Future<void> changeNodeGroup({
    required int nodeAddress,
    required int fromGroupAddress,
    required int toGroupAddress,
    int modelId = kGenericOnOffModelId,
    String? targetGroupName,
    Duration interval = const Duration(milliseconds: 600),
    bool ensureTargetGroup = true,
  }) async {
    _validateGroupAddress(fromGroupAddress);
    _validateGroupAddress(toGroupAddress);

    if (fromGroupAddress != toGroupAddress) {
      await removeModelSubscription(
        nodeAddress: nodeAddress,
        modelId: modelId,
        subscriptionAddress: fromGroupAddress,
      );
      await Future<void>.delayed(interval);
    }

    if (ensureTargetGroup) {
      await ensureGroup(
        name: targetGroupName ??
            'Group 0x${toGroupAddress.toRadixString(16).toUpperCase()}',
        address: toGroupAddress,
      );
    }

    await addModelSubscription(
      nodeAddress: nodeAddress,
      modelId: modelId,
      subscriptionAddress: toGroupAddress,
    );
  }

  /// 批量将多个节点换到新分组。
  Future<void> changeNodesGroup({
    required List<int> nodeAddresses,
    required int fromGroupAddress,
    required int toGroupAddress,
    int modelId = kGenericOnOffModelId,
    String? targetGroupName,
    Duration interval = const Duration(milliseconds: 600),
    bool ensureTargetGroup = true,
  }) async {
    if (ensureTargetGroup) {
      await ensureGroup(
        name: targetGroupName ??
            'Group 0x${toGroupAddress.toRadixString(16).toUpperCase()}',
        address: toGroupAddress,
      );
    }

    for (final nodeAddress in nodeAddresses) {
      await changeNodeGroup(
        nodeAddress: nodeAddress,
        fromGroupAddress: fromGroupAddress,
        toGroupAddress: toGroupAddress,
        modelId: modelId,
        ensureTargetGroup: false,
        interval: interval,
      );
      if (nodeAddress != nodeAddresses.last) {
        await Future<void>.delayed(interval);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 8. 同步组 Sync Group（Vendor 0x0001 / 0x0002，默认组地址 0xC000）
  // ═══════════════════════════════════════════════════════════════════════════

  /// 配置 Vendor 同步模型（0x0001 / 0x0002）的 AppKey 及可选订阅/发布。
  ///
  /// [mode] 控制消息能力：
  /// - [MeshModelMessagingMode.appKeyOnly] 仅 Bind AppKey
  /// - [MeshModelMessagingMode.subscribeOnly] / [MeshModelMessagingMode.publishOnly]
  /// - [MeshModelMessagingMode.subscribeAndPublish] 订阅 + 发布
  ///
  /// [modelIds] 可只选 0x0001、只选 0x0002，或两者（默认 [kSyncVendorModelCompoundIds]）。
  Future<void> configureSyncModels({
    required int nodeAddress,
    required MeshModelMessagingMode mode,
    List<int> modelIds = kSyncVendorModelCompoundIds,
    int syncGroupAddress = kDefaultSyncGroupAddress,
    int? elementAddress,
    bool bindAppKey = true,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
    bool ensureGroupExists = true,
  }) async {
    final resolvedModelIds = _resolveSyncModelIds(modelIds);
    if (mode.requiresGroupAddress && ensureGroupExists) {
      await ensureGroup(name: 'Sync Group', address: syncGroupAddress);
    }

    for (final modelId in resolvedModelIds) {
      await configureModel(
        nodeAddress: nodeAddress,
        modelId: modelId,
        groupAddress:
            mode.requiresGroupAddress ? syncGroupAddress : null,
        mode: mode,
        elementAddress: elementAddress,
        bindAppKey: bindAppKey,
        appKeyIndex: appKeyIndex,
        publishTtl: publishTtl,
        publishPeriod: publishPeriod,
        ensureGroupExists: false,
      );
    }
  }

  /// 配置节点为 Sync 主机：Vendor 0x0001 / 0x0002 均 Publish 到同步组。
  ///
  /// 等价于 [configureSyncModels]（`mode: publishOnly`）。
  Future<void> configureSyncMaster({
    required int nodeAddress,
    int syncGroupAddress = kDefaultSyncGroupAddress,
    List<int> modelIds = kSyncVendorModelCompoundIds,
    int? elementAddress,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
  }) async {
    await configureSyncModels(
      nodeAddress: nodeAddress,
      mode: MeshModelMessagingMode.publishOnly,
      modelIds: modelIds,
      syncGroupAddress: syncGroupAddress,
      elementAddress: elementAddress,
      appKeyIndex: appKeyIndex,
      publishTtl: publishTtl,
      publishPeriod: publishPeriod,
    );
  }

  /// 配置节点为 Sync 从机：Vendor 0x0001 / 0x0002 均 Subscribe 同步组。
  ///
  /// 等价于 [configureSyncModels]（`mode: subscribeOnly`）。
  Future<void> configureSyncSlave({
    required int nodeAddress,
    int syncGroupAddress = kDefaultSyncGroupAddress,
    List<int> modelIds = kSyncVendorModelCompoundIds,
    int? elementAddress,
    int appKeyIndex = 0,
  }) async {
    await configureSyncModels(
      nodeAddress: nodeAddress,
      mode: MeshModelMessagingMode.subscribeOnly,
      modelIds: modelIds,
      syncGroupAddress: syncGroupAddress,
      elementAddress: elementAddress,
      appKeyIndex: appKeyIndex,
    );
  }

  /// 配网后默认从机：仅订阅同步组（不重复 Bind AppKey）。
  Future<void> configureDefaultSyncSlave({
    required int nodeAddress,
    int syncGroupAddress = kDefaultSyncGroupAddress,
    List<int> modelIds = kSyncVendorModelCompoundIds,
  }) async {
    await configureSyncModels(
      nodeAddress: nodeAddress,
      mode: MeshModelMessagingMode.subscribeOnly,
      modelIds: modelIds,
      syncGroupAddress: syncGroupAddress,
      bindAppKey: false,
    );
  }

  /// 从机切主机：删除 Subscribe，配置 Publish。
  Future<void> promoteSyncModelToMaster({
    required int nodeAddress,
    required int syncGroupAddress,
    List<int> modelIds = kSyncVendorModelCompoundIds,
    int? elementAddress,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
  }) async {
    final resolvedModelIds = _resolveSyncModelIds(modelIds);
    await ensureGroup(name: 'Sync Group', address: syncGroupAddress);
    for (final modelId in resolvedModelIds) {
      await removeModelSubscription(
        nodeAddress: nodeAddress,
        modelId: modelId,
        subscriptionAddress: syncGroupAddress,
      );
    }
    await configureSyncMaster(
      nodeAddress: nodeAddress,
      syncGroupAddress: syncGroupAddress,
      modelIds: resolvedModelIds,
      elementAddress: elementAddress,
      appKeyIndex: appKeyIndex,
      publishTtl: publishTtl,
      publishPeriod: publishPeriod,
    );
  }

  /// 主机切从机：清除 Publish，添加 Subscribe。
  Future<void> demoteSyncModelToSlave({
    required int nodeAddress,
    required int syncGroupAddress,
    List<int> modelIds = kSyncVendorModelCompoundIds,
    int? elementAddress,
  }) async {
    final resolvedModelIds = _resolveSyncModelIds(modelIds);
    await ensureGroup(name: 'Sync Group', address: syncGroupAddress);
    for (final modelId in resolvedModelIds) {
      await setModelPublication(
        nodeAddress: nodeAddress,
        modelId: modelId,
        publishAddress: 0,
        elementAddress: elementAddress,
      );
      await addModelSubscription(
        nodeAddress: nodeAddress,
        modelId: modelId,
        subscriptionAddress: syncGroupAddress,
        elementAddress: elementAddress,
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 9. 控制消息（需已连接 Proxy，目标为单播或组播地址）
  // ═══════════════════════════════════════════════════════════════════════════

  /// 发送 Generic OnOff Set（SIG 模型 `0x1000` / `0x1001`）。
  ///
  /// [address] 可为节点单播地址或组播地址（需已订阅）。
  Future<void> sendGenericOnOff({
    required int address,
    required bool onOff,
    int appKeyIndex = 0,
    bool acknowledged = true,
  }) async {
    _ensureInitialized();
    _validateAddress(address);
    try {
      await _platform.sendGenericOnOff(
        address: address,
        onOff: onOff,
        appKeyIndex: appKeyIndex,
        acknowledged: acknowledged,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 发送 Generic Level Set（SIG 模型 `0x1002` / `0x1003`）。
  ///
  /// [level] 范围 -32768 ~ 32767。
  Future<void> sendGenericLevel({
    required int address,
    required int level,
    int appKeyIndex = 0,
    bool acknowledged = true,
  }) async {
    _ensureInitialized();
    _validateAddress(address);
    if (level < -32768 || level > 32767) {
      throw BleMeshException(
        'Generic Level 值超出范围: $level，有效范围为 -32768 到 32767',
        code: 'INVALID_LEVEL',
      );
    }
    try {
      await _platform.sendGenericLevel(
        address: address,
        level: level,
        appKeyIndex: appKeyIndex,
        acknowledged: acknowledged,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 发送自定义 Vendor 消息。
  Future<void> sendVendorMessage({
    required int address,
    required int companyId,
    required int modelId,
    required int opCode,
    required List<int> payload,
    int appKeyIndex = 0,
    bool acknowledged = false,
  }) async {
    _ensureInitialized();
    _validateAddress(address);
    try {
      await _platform.sendVendorMessage(
        address: address,
        companyId: companyId,
        modelId: modelId,
        opCode: opCode,
        payload: payload,
        appKeyIndex: appKeyIndex,
        acknowledged: acknowledged,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 设置节点主从角色（Vendor OpCode `0x11`）。
  Future<void> setMasterSlaveRole({
    required int address,
    required MeshNodeRole role,
    int companyId = kVendorCompanyId,
    int appKeyIndex = 0,
  }) async {
    final message = MasterSlaveMessage(role: role, companyId: companyId);
    developer.log(
      '发送主从机切换: ${role.name} -> 0x${address.toRadixString(16)}',
      name: 'ble_mesh',
    );
    await sendVendorMessage(
      address: address,
      companyId: message.companyId,
      modelId: message.modelId,
      opCode: message.opCode,
      payload: message.payload.toList(),
      appKeyIndex: appKeyIndex,
    );
  }

  /// 设置播放模式（Vendor OpCode `0x11`，含亮度、速度、源类型等）。
  Future<void> setPlayMode({
    required int address,
    required PlayModeConfig config,
    int companyId = kVendorCompanyId,
    int appKeyIndex = 0,
  }) async {
    final message = PlayModeMessage(config: config, companyId: companyId);
    developer.log(
      '发送播放模式: $config -> 0x${address.toRadixString(16)}',
      name: 'ble_mesh',
    );
    await sendVendorMessage(
      address: address,
      companyId: message.companyId,
      modelId: message.modelId,
      opCode: message.opCode,
      payload: message.payload.toList(),
      appKeyIndex: appKeyIndex,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 10. 网络备份与恢复
  // ═══════════════════════════════════════════════════════════════════════════

  /// 获取当前 Mesh 网络摘要（NetKey、AppKey、IV Index 等）。
  Future<MeshNetworkInfo> getNetworkInfo() async {
    _ensureInitialized();
    try {
      final result = await _platform.getNetworkInfo();
      return MeshNetworkInfo.fromMap(result);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 导出网络为 Mesh Configuration Database JSON（兼容 nRF Mesh App）。
  Future<String> exportNetworkJson() async {
    _ensureInitialized();
    try {
      final json = await _platform.exportNetworkJson();
      if (json.isEmpty) {
        throw const BleMeshException('导出网络失败', code: 'EXPORT_FAILED');
      }
      return json;
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  /// 从 JSON 导入网络，成功后触发 [networkLoaded] 与 [networkUpdated]。
  Future<void> importNetworkJson(String json) async {
    _ensureInitialized();
    if (json.trim().isEmpty) {
      throw const BleMeshException('导入内容为空', code: 'INVALID_ARGUMENT');
    }
    try {
      await _platform.importNetworkJson(json);
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 私有辅助
  // ═══════════════════════════════════════════════════════════════════════════

  void _ensureInitialized() {
    if (!_isInitialized) throw const NotInitializedException();
  }

  void _validateAddress(int address) {
    if (address <= 0 || address > 0xFFFF) {
      throw InvalidAddressException(address);
    }
  }

  void _validateGroupAddress(int address) {
    if (address < 0xC000 || address > 0xFEFF) {
      throw InvalidAddressException(address);
    }
  }

  List<int> _resolveSyncModelIds(List<int> modelIds) {
    if (modelIds.isEmpty) {
      throw const BleMeshException(
        'modelIds 不能为空，请至少选择 0x0001 或 0x0002',
        code: 'INVALID_ARGUMENT',
      );
    }
    final allowed = kSyncVendorModelCompoundIds.toSet();
    final resolved = <int>[];
    for (final modelId in modelIds) {
      if (!allowed.contains(modelId)) {
        throw BleMeshException(
          '不支持的 Sync 模型 ID: 0x${modelId.toRadixString(16)}，'
          '仅允许 0x0001 / 0x0002',
          code: 'INVALID_ARGUMENT',
        );
      }
      if (!resolved.contains(modelId)) {
        resolved.add(modelId);
      }
    }
    return resolved;
  }

  Future<int> _resolveElementAddressForModel({
    required int nodeAddress,
    required int modelId,
    int? elementAddress,
  }) async {
    if (elementAddress != null) {
      return elementAddress;
    }

    final node = await getNodeByAddress(nodeAddress);
    if (node == null) {
      throw BleMeshException(
        '未找到节点: 0x${nodeAddress.toRadixString(16)}',
        code: 'NODE_NOT_FOUND',
      );
    }

    final resolved = node.getElementAddressForModel(modelId);
    if (resolved == null) {
      throw BleMeshException(
        '节点 0x${nodeAddress.toRadixString(16)} 不支持模型 '
        '0x${modelId.toRadixString(16)}',
        code: 'MODEL_NOT_FOUND',
      );
    }
    return resolved;
  }

  Future<void> _bindAppKey({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int appKeyIndex,
  }) async {
    _ensureInitialized();
    try {
      await _platform.bindAppKey(
        nodeAddress: nodeAddress,
        elementAddress: elementAddress,
        modelId: modelId,
        appKeyIndex: appKeyIndex,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  Future<void> _addSubscription({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int subscriptionAddress,
  }) async {
    _ensureInitialized();
    try {
      await _platform.addSubscription(
        nodeAddress: nodeAddress,
        elementAddress: elementAddress,
        modelId: modelId,
        subscriptionAddress: subscriptionAddress,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  Future<void> _removeSubscription({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int subscriptionAddress,
  }) async {
    _ensureInitialized();
    try {
      await _platform.removeSubscription(
        nodeAddress: nodeAddress,
        elementAddress: elementAddress,
        modelId: modelId,
        subscriptionAddress: subscriptionAddress,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  Future<void> _setPublication({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int publishAddress,
    required int appKeyIndex,
    required int publishTtl,
    required int publishPeriod,
  }) async {
    _ensureInitialized();
    try {
      await _platform.setPublication(
        nodeAddress: nodeAddress,
        elementAddress: elementAddress,
        modelId: modelId,
        publishAddress: publishAddress,
        appKeyIndex: appKeyIndex,
        publishTtl: publishTtl,
        publishPeriod: publishPeriod,
      );
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  BleMeshException _mapPlatformException(PlatformException e) {
    return switch (e.code) {
      'BLUETOOTH_UNAVAILABLE' => const BluetoothUnavailableException(),
      'BLUETOOTH_DISABLED' => const BluetoothDisabledException(),
      'PERMISSION_DENIED' => PermissionDeniedException(detail: e.message),
      'NOT_CONNECTED' => const NotConnectedException(),
      'PROVISIONING_FAILED' => ProvisioningException(
        e.message ?? '配网失败',
        code: e.code,
        details: e.details,
      ),
      _ => BleMeshException(
        e.message ?? '未知错误',
        code: e.code,
        details: e.details,
      ),
    };
  }
}
