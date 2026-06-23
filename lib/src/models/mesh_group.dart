import 'package:flutter/foundation.dart';

/// Mesh 网络中的分组（Group）。
///
/// 分组使用多播地址（0xC000 - 0xFEFF），可以同时向多个节点发送消息。
/// 通过订阅（Subscribe）机制将节点加入分组。
@immutable
class MeshGroup {
  const MeshGroup({
    required this.address,
    required this.name,
    this.parentAddress,
    this.boundDeviceCount = 0,
  });

  /// 分组地址，有效范围为 0xC000 - 0xFEFF（固定组）或虚拟地址。
  final int address;

  /// 分组名称（用户可自定义）。
  final String name;

  /// 父分组地址（用于嵌套分组），没有父分组时为 null。
  final int? parentAddress;

  /// 已订阅该组地址的设备（节点）数量。
  final int boundDeviceCount;

  /// 从 Map 构造 [MeshGroup]（原生层返回的数据）。
  factory MeshGroup.fromMap(Map<dynamic, dynamic> map) {
    return MeshGroup(
      address: map['address'] as int? ?? 0,
      name: map['name'] as String? ?? '未知分组',
      parentAddress: map['parentAddress'] as int?,
      boundDeviceCount: map['boundDeviceCount'] as int? ?? 0,
    );
  }

  /// 将分组信息转换为 Map。
  Map<String, dynamic> toMap() => {
        'address': address,
        'name': name,
        'parentAddress': parentAddress,
        'boundDeviceCount': boundDeviceCount,
      };

  /// 格式化地址为十六进制字符串（例如 "0xC000"）。
  String get hexAddress =>
      '0x${address.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  /// 是否为固定组（Fixed Group，地址范围 0xFF00 - 0xFFFF）。
  bool get isFixedGroup => address >= 0xFF00;

  /// 是否为动态分组地址（0xC000 - 0xFEFF）。
  bool get isDynamicGroup => address >= 0xC000 && address <= 0xFEFF;

  /// 是否存在父分组。
  bool get hasParent => parentAddress != null;

  /// 名称是否匹配，忽略首尾空格和大小写。
  bool matchesName(String value) =>
      name.trim().toLowerCase() == value.trim().toLowerCase();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshGroup && address == other.address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'MeshGroup(address: $hexAddress, name: $name)';
}
