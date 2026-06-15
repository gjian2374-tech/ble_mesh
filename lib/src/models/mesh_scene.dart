import 'package:flutter/foundation.dart';

/// Mesh 网络中的场景（Scene）。
///
/// 场景保存了多个节点的状态快照，通过 Recall Scene 消息
/// 可以一次性恢复所有节点到保存时的状态。
@immutable
class MeshScene {
  const MeshScene({
    required this.number,
    required this.name,
    this.addresses = const [],
  });

  /// 场景编号（有效范围 1 - 65535）。
  final int number;

  /// 场景名称（用户可自定义）。
  final String name;

  /// 参与此场景的节点单播地址列表。
  final List<int> addresses;

  /// 从 Map 构造 [MeshScene]（原生层返回的数据）。
  factory MeshScene.fromMap(Map<dynamic, dynamic> map) {
    return MeshScene(
      number: map['number'] as int? ?? 0,
      name: map['name'] as String? ?? '场景 ${map['number']}',
      addresses: (map['addresses'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
    );
  }

  /// 将场景信息转换为 Map。
  Map<String, dynamic> toMap() => {
        'number': number,
        'name': name,
        'addresses': addresses,
      };

  /// 此场景包含的节点数量。
  int get nodeCount => addresses.length;

  /// 十六进制格式的场景编号。
  String get hexNumber =>
      '0x${number.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  /// 是否包含指定节点地址。
  bool containsAddress(int address) => addresses.contains(address);

  /// 名称是否匹配，忽略首尾空格和大小写。
  bool matchesName(String value) =>
      name.trim().toLowerCase() == value.trim().toLowerCase();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshScene && number == other.number;

  @override
  int get hashCode => number.hashCode;

  @override
  String toString() =>
      'MeshScene(number: $number, name: $name, nodes: $nodeCount)';
}
