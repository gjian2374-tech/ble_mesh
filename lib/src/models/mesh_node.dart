import 'package:flutter/foundation.dart';

import 'mesh_element.dart';

/// 已配网的 Mesh 节点（Provisioned Node）。
///
/// 每个节点代表网络中一个物理设备，拥有唯一的单播地址
/// 和一个或多个元素（[MeshElement]）。
@immutable
class MeshNode {
  const MeshNode({
    required this.unicastAddress,
    required this.name,
    required this.uuid,
    this.macAddress,
    this.deviceKey,
    this.isOnline = false,
    this.elements = const [],
    this.appKeyIndexes = const [],
    this.ttl = 5,
    this.companyIdentifier,
    this.productIdentifier,
  });

  /// 节点主元素的单播地址（0x0001 - 0x7FFF）。
  final int unicastAddress;

  /// 节点名称（用户可自定义）。
  final String name;

  /// 节点唯一标识 UUID。
  final String uuid;

  /// 设备的蓝牙 MAC 地址（配网时记录），用于后续连接 Proxy Service。
  ///
  /// 仅在本次应用运行期间有效（不持久化）。重启后需通过扫描重新获取。
  final String? macAddress;

  /// 设备密钥（十六进制字符串），用于配置消息加密。此为敏感数据。
  final String? deviceKey;

  /// 节点当前是否在线（能够收到消息响应）。
  final bool isOnline;

  /// 节点包含的元素列表。
  final List<MeshElement> elements;

  /// 已绑定到此节点的应用密钥索引列表。
  final List<int> appKeyIndexes;

  /// 从此节点发出消息的默认 TTL 值（生存跳数）。
  final int ttl;

  /// 公司标识符（CID），来自 Bluetooth SIG 注册。
  final int? companyIdentifier;

  /// 产品标识符（PID）。
  final int? productIdentifier;

  /// 从 Map 构造 [MeshNode]（原生层返回的数据）。
  factory MeshNode.fromMap(Map<dynamic, dynamic> map) {
    return MeshNode(
      unicastAddress: map['unicastAddress'] as int? ?? 0,
      name: map['name'] as String? ?? '未知节点',
      uuid: map['uuid'] as String? ?? '',
      macAddress: map['macAddress'] as String?,
      deviceKey: map['deviceKey'] as String?,
      isOnline: map['isOnline'] as bool? ?? false,
      elements:
          (map['elements'] as List?)
              ?.map((e) => MeshElement.fromMap(e as Map))
              .toList() ??
          const [],
      appKeyIndexes:
          (map['appKeyIndexes'] as List?)?.map((e) => e as int).toList() ??
          const [],
      ttl: map['ttl'] as int? ?? 5,
      companyIdentifier: map['companyIdentifier'] as int?,
      productIdentifier: map['productIdentifier'] as int?,
    );
  }

  /// 将节点信息转换为 Map。
  Map<String, dynamic> toMap() => {
    'unicastAddress': unicastAddress,
    'name': name,
    'uuid': uuid,
    'macAddress': macAddress,
    'deviceKey': deviceKey,
    'isOnline': isOnline,
    'elements': elements.map((e) => e.toMap()).toList(),
    'appKeyIndexes': appKeyIndexes,
    'ttl': ttl,
    'companyIdentifier': companyIdentifier,
    'productIdentifier': productIdentifier,
  };

  /// 格式化单播地址为十六进制字符串（例如 "0x0001"）。
  String get hexAddress =>
      '0x${unicastAddress.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  /// 节点的元素数量。
  int get elementCount => elements.length;

  /// 规范化后的 UUID，便于比较。
  String get normalizedUuid => uuid.trim().toLowerCase();

  /// 是否记录了可用于后续连接的 MAC 地址。
  bool get hasMacAddress => macAddress != null && macAddress!.trim().isNotEmpty;

  /// 是否包含指定 AppKey 索引。
  bool hasAppKeyIndex(int appKeyIndex) => appKeyIndexes.contains(appKeyIndex);

  /// 是否包含指定元素地址。
  bool containsElementAddress(int elementAddress) {
    return elements.any((element) => element.elementAddress == elementAddress);
  }

  /// 按元素地址查找元素，不存在时返回 `null`。
  MeshElement? getElementByAddress(int elementAddress) {
    for (final element in elements) {
      if (element.elementAddress == elementAddress) {
        return element;
      }
    }
    return null;
  }

  /// 节点是否支持指定模型。
  bool supportsModel(int modelId) {
    return elements.any((element) => element.supportsModel(modelId));
  }

  /// 节点是否支持任一指定模型。
  bool supportsAnyModel(Iterable<int> candidates) {
    return elements.any((element) => element.supportsAnyModel(candidates));
  }

  /// 返回主元素，不存在时返回 `null`。
  MeshElement? get primaryElement => elements.isEmpty ? null : elements.first;

  /// 查找首个支持指定模型的元素，不存在时返回 `null`。
  MeshElement? getElementForModel(int modelId) {
    for (final element in elements) {
      if (element.supportsModel(modelId)) {
        return element;
      }
    }
    return null;
  }

  /// 查找首个支持指定模型的元素地址，不存在时返回 `null`。
  int? getElementAddressForModel(int modelId) {
    return getElementForModel(modelId)?.elementAddress;
  }

  /// 名称是否匹配，忽略首尾空格和大小写。
  bool matchesName(String value) =>
      name.trim().toLowerCase() == value.trim().toLowerCase();

  /// UUID 是否匹配，忽略首尾空格和大小写。
  bool matchesUuid(String value) =>
      normalizedUuid == value.trim().toLowerCase();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshNode && unicastAddress == other.unicastAddress;

  @override
  int get hashCode => unicastAddress.hashCode;

  @override
  String toString() =>
      'MeshNode(address: $hexAddress, name: $name, '
      'online: $isOnline, elements: $elementCount)';
}
