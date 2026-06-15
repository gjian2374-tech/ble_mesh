import 'package:flutter/foundation.dart';

/// Mesh 网络摘要信息，对应 nRF Mesh App 首页展示项。
@immutable
class MeshNetworkInfo {
  const MeshNetworkInfo({
    required this.networkId,
    required this.name,
    required this.ivIndex,
    required this.ivUpdateActive,
    required this.sequenceNumber,
    required this.provisionerAddress,
    required this.networkKeys,
    required this.appKeys,
    required this.nodeCount,
  });

  /// 网络 UUID。
  final String networkId;

  /// 网络名称。
  final String name;

  /// 当前 IV Index。
  final int ivIndex;

  /// IV Update 是否进行中。
  final bool ivUpdateActive;

  /// 当前 Provisioner 的 Sequence Number。
  final int sequenceNumber;

  /// 当前 Provisioner 单播地址。
  final int provisionerAddress;

  /// NetKey 列表。
  final List<MeshKeyInfo> networkKeys;

  /// AppKey 列表。
  final List<MeshKeyInfo> appKeys;

  /// 已配网节点总数（含 Provisioner）。
  final int nodeCount;

  factory MeshNetworkInfo.fromMap(Map<dynamic, dynamic> map) {
    return MeshNetworkInfo(
      networkId: map['networkId'] as String? ?? '',
      name: map['name'] as String? ?? '',
      ivIndex: map['ivIndex'] as int? ?? 0,
      ivUpdateActive: map['ivUpdateActive'] as bool? ?? false,
      sequenceNumber: map['sequenceNumber'] as int? ?? 0,
      provisionerAddress: map['provisionerAddress'] as int? ?? 0,
      networkKeys:
          (map['networkKeys'] as List?)
              ?.map((e) => MeshKeyInfo.fromMap(e as Map))
              .toList() ??
          const [],
      appKeys:
          (map['appKeys'] as List?)
              ?.map((e) => MeshKeyInfo.fromMap(e as Map))
              .toList() ??
          const [],
      nodeCount: map['nodeCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'networkId': networkId,
    'name': name,
    'ivIndex': ivIndex,
    'ivUpdateActive': ivUpdateActive,
    'sequenceNumber': sequenceNumber,
    'provisionerAddress': provisionerAddress,
    'networkKeys': networkKeys.map((e) => e.toMap()).toList(),
    'appKeys': appKeys.map((e) => e.toMap()).toList(),
    'nodeCount': nodeCount,
  };
}

/// NetKey / AppKey 条目。
@immutable
class MeshKeyInfo {
  const MeshKeyInfo({
    required this.index,
    required this.name,
    required this.keyHex,
    this.phase = 0,
  });

  /// 密钥索引。
  final int index;

  /// 密钥名称。
  final String name;

  /// 密钥十六进制字符串（大写，无分隔符）。
  final String keyHex;

  /// NetKey 相位，AppKey 恒为 0。
  final int phase;

  factory MeshKeyInfo.fromMap(Map<dynamic, dynamic> map) {
    return MeshKeyInfo(
      index: map['index'] as int? ?? 0,
      name: map['name'] as String? ?? '',
      keyHex: map['keyHex'] as String? ?? '',
      phase: map['phase'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'index': index,
    'name': name,
    'keyHex': keyHex,
    'phase': phase,
  };
}
