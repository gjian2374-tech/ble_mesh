import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_mesh_platform_interface.dart';

/// 使用 MethodChannel 和 EventChannel 与原生平台通信的 [BleMeshPlatform] 实现。
class MethodChannelBleMesh extends BleMeshPlatform {
  @visibleForTesting
  static const methodChannel = MethodChannel('ble_mesh');

  @visibleForTesting
  static const eventChannel = EventChannel('ble_mesh/events');

  Stream<Map<dynamic, dynamic>>? _meshEventsStream;

  @override
  Stream<Map<dynamic, dynamic>> get meshEvents {
    _meshEventsStream ??= eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .cast<Map<dynamic, dynamic>>()
        .handleError((Object error) {
          developer.log(
            '接收 Mesh 事件时出错',
            name: 'ble_mesh.channel',
            level: 1000,
            error: error,
          );
        });
    return _meshEventsStream!;
  }

  @override
  Future<void> initialize() async {
    await methodChannel.invokeMethod<void>('initialize');
  }

  @override
  Future<bool> requestPermissions() async {
    final result = await methodChannel.invokeMethod<bool>('requestPermissions');
    return result ?? false;
  }

  @override
  Future<String> getBluetoothState() async {
    final state = await methodChannel.invokeMethod<String>('getBluetoothState');
    return state ?? 'unknown';
  }

  @override
  Future<void> startScan({int? timeoutMs}) async {
    await methodChannel.invokeMethod<void>('startScan', {
      ...?timeoutMs == null ? null : {'timeoutMs': timeoutMs},
    });
  }

  @override
  Future<void> stopScan() async {
    await methodChannel.invokeMethod<void>('stopScan');
  }

  @override
  Future<void> provisionDevice({
    required String uuid,
    required String address,
    String? nodeName,
  }) async {
    await methodChannel.invokeMethod<void>('provisionDevice', {
      'uuid': uuid,
      'address': address,
      ...?nodeName == null ? null : {'nodeName': nodeName},
    });
  }

  @override
  Future<void> cancelProvisioning() async {
    await methodChannel.invokeMethod<void>('cancelProvisioning');
  }

  @override
  Future<void> distributeAppKey(int unicastAddress) async {
    await methodChannel.invokeMethod<void>('distributeAppKey', {
      'unicastAddress': unicastAddress,
    });
  }

  @override
  Future<void> connectToProxy(String address) async {
    await methodChannel.invokeMethod<void>('connectToProxy', {
      'address': address,
    });
  }

  @override
  Future<void> disconnectFromProxy() async {
    await methodChannel.invokeMethod<void>('disconnectFromProxy');
  }

  @override
  Future<String> getConnectionState() async {
    final state = await methodChannel.invokeMethod<String>('getConnectionState');
    return state ?? 'disconnected';
  }

  @override
  Future<bool> isProxyReady(String address) async {
    final ready = await methodChannel.invokeMethod<bool>('isProxyReady', {
      'address': address,
    });
    return ready ?? false;
  }

  @override
  Future<Map<dynamic, dynamic>> getNetworkInfo() async {
    final result = await methodChannel.invokeMethod<Map>('getNetworkInfo');
    return result?.cast<dynamic, dynamic>() ?? <dynamic, dynamic>{};
  }

  @override
  Future<String> exportNetworkJson() async {
    final json = await methodChannel.invokeMethod<String>('exportNetworkJson');
    return json ?? '';
  }

  @override
  Future<void> importNetworkJson(String json) async {
    await methodChannel.invokeMethod<void>('importNetworkJson', {'json': json});
  }

  @override
  Future<void> sendGenericOnOff({
    required int address,
    required bool onOff,
    int appKeyIndex = 0,
    bool acknowledged = true,
  }) async {
    await methodChannel.invokeMethod<void>('sendGenericOnOff', {
      'address': address,
      'onOff': onOff,
      'appKeyIndex': appKeyIndex,
      'acknowledged': acknowledged,
    });
  }

  @override
  Future<void> sendGenericLevel({
    required int address,
    required int level,
    int appKeyIndex = 0,
    bool acknowledged = true,
  }) async {
    await methodChannel.invokeMethod<void>('sendGenericLevel', {
      'address': address,
      'level': level,
      'appKeyIndex': appKeyIndex,
      'acknowledged': acknowledged,
    });
  }

  @override
  Future<List<Map<dynamic, dynamic>>> getNodes() async {
    final result = await methodChannel.invokeListMethod<Map>('getNodes');
    return result?.cast<Map<dynamic, dynamic>>() ?? [];
  }

  @override
  Future<void> deleteNode(int unicastAddress) async {
    await methodChannel.invokeMethod<void>('deleteNode', {
      'unicastAddress': unicastAddress,
    });
  }

  @override
  Future<List<Map<dynamic, dynamic>>> getGroups() async {
    final result = await methodChannel.invokeListMethod<Map>('getGroups');
    return result?.cast<Map<dynamic, dynamic>>() ?? [];
  }

  @override
  Future<void> createGroup({required String name, required int address}) async {
    await methodChannel.invokeMethod<void>('createGroup', {
      'name': name,
      'address': address,
    });
  }

  @override
  Future<void> deleteGroup(int address) async {
    await methodChannel.invokeMethod<void>('deleteGroup', {'address': address});
  }

  @override
  Future<void> addSubscription({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int subscriptionAddress,
  }) async {
    await methodChannel.invokeMethod<void>('addSubscription', {
      'nodeAddress': nodeAddress,
      'elementAddress': elementAddress,
      'modelId': modelId,
      'subscriptionAddress': subscriptionAddress,
    });
  }

  @override
  Future<void> removeSubscription({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int subscriptionAddress,
  }) async {
    await methodChannel.invokeMethod<void>('removeSubscription', {
      'nodeAddress': nodeAddress,
      'elementAddress': elementAddress,
      'modelId': modelId,
      'subscriptionAddress': subscriptionAddress,
    });
  }

  @override
  Future<void> bindAppKey({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int appKeyIndex,
  }) async {
    await methodChannel.invokeMethod<void>('bindAppKey', {
      'nodeAddress': nodeAddress,
      'elementAddress': elementAddress,
      'modelId': modelId,
      'appKeyIndex': appKeyIndex,
    });
  }

  @override
  Future<void> sendVendorMessage({
    required int address,
    required int companyId,
    required int modelId,
    required int opCode,
    required List<int> payload,
    int appKeyIndex = 0,
    bool acknowledged = false,
  }) async {
    await methodChannel.invokeMethod<void>('sendVendorMessage', {
      'address': address,
      'companyId': companyId,
      'modelId': modelId,
      'opCode': opCode,
      'payload': payload,
      'appKeyIndex': appKeyIndex,
      'acknowledged': acknowledged,
    });
  }

  @override
  Future<void> setPublication({
    required int nodeAddress,
    required int elementAddress,
    required int modelId,
    required int publishAddress,
    int appKeyIndex = 0,
    int publishTtl = 5,
    int publishPeriod = 0,
  }) async {
    await methodChannel.invokeMethod<void>('setPublication', {
      'nodeAddress': nodeAddress,
      'elementAddress': elementAddress,
      'modelId': modelId,
      'publishAddress': publishAddress,
      'appKeyIndex': appKeyIndex,
      'publishTtl': publishTtl,
      'publishPeriod': publishPeriod,
    });
  }
}
