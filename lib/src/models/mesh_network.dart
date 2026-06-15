import 'mesh_group.dart';
import 'mesh_node.dart';

/// Mesh 网络快照。
class MeshNetwork {
  const MeshNetwork({
    required this.networkId,
    required this.name,
    required this.networkKeys,
    required this.appKeys,
    required this.nodes,
    required this.groups,
    required this.provisioner,
  });

  /// 网络稳定标识。
  final String networkId;

  /// 用户可见的网络名称。
  final String name;

  /// 当前网络中的 NetKey 列表。
  final List<NetworkKey> networkKeys;

  /// 当前网络中的 AppKey 列表。
  final List<AppKey> appKeys;

  /// 已配网节点快照。
  final List<MeshNode> nodes;

  /// 分组快照。
  final List<MeshGroup> groups;

  /// 当前本地 Provisioner 元信息。
  final Provisioner provisioner;

  factory MeshNetwork.fromMap(Map<dynamic, dynamic> map) {
    return MeshNetwork(
      networkId: map['networkId'] as String? ?? '',
      name: map['name'] as String? ?? '',
      networkKeys:
          (map['networkKeys'] as List?)
              ?.map((e) => NetworkKey.fromMap(e as Map))
              .toList() ??
          const [],
      appKeys:
          (map['appKeys'] as List?)
              ?.map((e) => AppKey.fromMap(e as Map))
              .toList() ??
          const [],
      nodes:
          (map['nodes'] as List?)
              ?.map((e) => MeshNode.fromMap(e as Map))
              .toList() ??
          const [],
      groups:
          (map['groups'] as List?)
              ?.map((e) => MeshGroup.fromMap(e as Map))
              .toList() ??
          const [],
      provisioner: Provisioner.fromMap(map['provisioner'] as Map? ?? const {}),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'networkId': networkId,
      'name': name,
      'networkKeys': networkKeys.map((e) => e.toMap()).toList(),
      'appKeys': appKeys.map((e) => e.toMap()).toList(),
      'nodes': nodes.map((e) => e.toMap()).toList(),
      'groups': groups.map((e) => e.toMap()).toList(),
      'provisioner': provisioner.toMap(),
    };
  }
}

/// NetKey 条目。
class NetworkKey {
  const NetworkKey({
    required this.keyId,
    required this.key,
    required this.index,
    required this.enabled,
  });

  final String keyId;
  final String key;
  final int index;
  final bool enabled;

  factory NetworkKey.fromMap(Map<dynamic, dynamic> map) {
    return NetworkKey(
      keyId: map['keyId'] as String? ?? '',
      key: map['key'] as String? ?? '',
      index: map['index'] as int? ?? 0,
      enabled: map['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() => {
    'keyId': keyId,
    'key': key,
    'index': index,
    'enabled': enabled,
  };
}

/// AppKey 条目。
class AppKey {
  const AppKey({
    required this.keyId,
    required this.key,
    required this.index,
    required this.enabled,
  });

  final String keyId;
  final String key;
  final int index;
  final bool enabled;

  factory AppKey.fromMap(Map<dynamic, dynamic> map) {
    return AppKey(
      keyId: map['keyId'] as String? ?? '',
      key: map['key'] as String? ?? '',
      index: map['index'] as int? ?? 0,
      enabled: map['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() => {
    'keyId': keyId,
    'key': key,
    'index': index,
    'enabled': enabled,
  };
}

/// 本地 Provisioner 元信息。
class Provisioner {
  const Provisioner({
    required this.name,
    required this.provisionerId,
    required this.addressRange,
  });

  final String name;
  final String provisionerId;
  final List<int> addressRange;

  factory Provisioner.fromMap(Map<dynamic, dynamic> map) {
    return Provisioner(
      name: map['name'] as String? ?? '',
      provisionerId: map['provisionerId'] as String? ?? '',
      addressRange:
          (map['addressRange'] as List?)?.map((e) => e as int).toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'provisionerId': provisionerId,
    'addressRange': addressRange,
  };
}
