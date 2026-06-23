import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'ble_mesh_method_channel.dart';

/// BLE Mesh 插件的平台接口抽象类。
abstract class BleMeshPlatform extends PlatformInterface {
  BleMeshPlatform() : super(token: _token);

  static final Object _token = Object();

  static BleMeshPlatform _instance = MethodChannelBleMesh();

  static BleMeshPlatform get instance => _instance;

  static set instance(BleMeshPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Stream<Map<dynamic, dynamic>> get meshEvents;

  Future<void> initialize();

  Future<bool> requestPermissions();

  Future<String> getBluetoothState();

  Future<void> startScan({int? timeoutMs});

  Future<void> stopScan();

  Future<void> provisionDevice({
    required String uuid,
    required String address,
    String? nodeName,
  });

  Future<void> cancelProvisioning();

  Future<void> distributeAppKey(int unicastAddress);

  Future<void> connectToProxy(String address);

  Future<void> disconnectFromProxy();

  Future<String> getConnectionState();

  Future<bool> isProxyReady(String address);

  Future<Map<dynamic, dynamic>> getNetworkInfo();

  Future<String> exportNetworkJson();

  Future<void> importNetworkJson(String json);

  Future<void> sendGenericOnOff({
    required int address,
    required bool onOff,
    int appKeyIndex = 0,
    bool acknowledged = true,
  });

  Future<void> sendGenericLevel({
    required int address,
    required int level,
    int appKeyIndex = 0,
    bool acknowledged = true,
  });

  Future<List<Map<dynamic, dynamic>>> getNodes();

  Future<Map<dynamic, dynamic>> fetchReportedModels(int unicastAddress);

  Future<void> deleteNode(int unicastAddress);

  Future<List<Map<dynamic, dynamic>>> getGroups();

  Future<void> createGroup({required String name, required int address});

  Future<void> deleteGroup(int address);

  Future<void> addSubscription({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int subscriptionAddress,
  });

  Future<void> removeSubscription({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int subscriptionAddress,
  });

  Future<void> bindAppKey({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int appKeyIndex,
  });

  Future<void> sendVendorMessage({
    required int address,
    required int companyId,
    required int modelId,
    required int opCode,
    required List<int> payload,
    int appKeyIndex = 0,
    bool acknowledged = false,
  });

  Future<void> setPublication({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int publishAddress,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
  });

  /// 配置自定义 BLE GATT 通道（与 Proxy 共用同一连接）。
  Future<void> configureCustomBleChannel({
    required String serviceUuid,
    required String writeCharacteristicUuid,
    String? notifyCharacteristicUuid,
  });

  /// 自定义 BLE 写特征是否已就绪。
  Future<bool> isCustomBleReady();

  /// 向自定义写特征写入单包数据（不超过当前 MTU）。
  Future<void> writeCustomBleData(List<int> data);

  /// 按 MTU 分包写入自定义特征（带响应写入，适合 bin 下发）。
  Future<void> transferCustomBleData(List<int> data);
}
