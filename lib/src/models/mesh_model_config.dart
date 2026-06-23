import 'package:flutter/foundation.dart';

/// 节点元素上某个模型的发布/订阅配置（来自本地 Mesh 网络数据库）。
@immutable
class MeshModelConfig {
  const MeshModelConfig({
    required this.modelId,
    this.publishAddress = 0,
    this.subscriptionAddresses = const [],
  });

  /// SIG 或 Vendor 模型 ID（Vendor 为 `(companyId << 16) | modelId`）。
  final int modelId;

  /// 发布地址，`0` 表示未配置。
  final int publishAddress;

  /// 已订阅的组播地址列表。
  final List<int> subscriptionAddresses;

  factory MeshModelConfig.fromMap(Map<dynamic, dynamic> map) {
    return MeshModelConfig(
      modelId: map['modelId'] as int? ?? 0,
      publishAddress: map['publishAddress'] as int? ?? 0,
      subscriptionAddresses: (map['subscriptionAddresses'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'modelId': modelId,
        'publishAddress': publishAddress,
        'subscriptionAddresses': subscriptionAddresses,
      };
}
