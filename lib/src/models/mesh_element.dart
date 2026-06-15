import 'package:flutter/foundation.dart';

/// Mesh 节点的元素（Element）。
///
/// 每个节点至少有一个主元素（Primary Element），
/// 每个元素拥有一个独立的单播地址，并包含多个模型（Model）。
@immutable
class MeshElement {
  const MeshElement({
    required this.elementAddress,
    this.name = '',
    this.modelIds = const [],
    this.location = 0,
  });

  /// 此元素的单播地址。
  final int elementAddress;

  /// 元素名称。
  final String name;

  /// 此元素包含的 SIG 和 Vendor 模型 ID 列表。
  final List<int> modelIds;

  /// 元素位置描述符（来自 Bluetooth SIG 定义的位置枚举）。
  final int location;

  /// 从 Map 构造 [MeshElement]。
  factory MeshElement.fromMap(Map<dynamic, dynamic> map) {
    return MeshElement(
      elementAddress: map['elementAddress'] as int? ?? 0,
      name: map['name'] as String? ?? '',
      modelIds: (map['modelIds'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      location: map['location'] as int? ?? 0,
    );
  }

  /// 将元素信息转换为 Map。
  Map<String, dynamic> toMap() => {
        'elementAddress': elementAddress,
        'name': name,
        'modelIds': modelIds,
        'location': location,
      };

  /// 格式化地址为十六进制字符串。
  String get hexAddress =>
      '0x${elementAddress.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  /// 是否包含指定模型。
  bool supportsModel(int modelId) => modelIds.contains(modelId);

  /// 是否包含任一指定模型。
  bool supportsAnyModel(Iterable<int> candidates) {
    for (final modelId in candidates) {
      if (modelIds.contains(modelId)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshElement && elementAddress == other.elementAddress;

  @override
  int get hashCode => elementAddress.hashCode;

  @override
  String toString() =>
      'MeshElement(address: $hexAddress, models: ${modelIds.length})';
}
