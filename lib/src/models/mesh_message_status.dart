import 'package:flutter/foundation.dart';

import '../enums/ble_mesh_enums.dart';

/// 从 Mesh 网络收到的状态消息。
///
/// 当发送已确认消息（Acknowledged Message）后，
/// 目标节点会回复此类型的状态消息。
@immutable
class MeshMessageStatus {
  const MeshMessageStatus({
    required this.source,
    required this.modelType,
    required this.rawData,
  });

  /// 消息来源节点的单播地址。
  final int source;

  /// 消息对应的模型类型。
  final MeshMessageModelType modelType;

  /// 原始消息数据（不同模型类型有不同的字段）。
  final Map<String, dynamic> rawData;

  /// 从 Map 构造 [MeshMessageStatus]。
  factory MeshMessageStatus.fromMap(Map<dynamic, dynamic> map) {
    return MeshMessageStatus(
      source: map['source'] as int? ?? 0,
      modelType: MeshMessageModelType.fromString(
        map['modelType'] as String? ?? 'unknown',
      ),
      rawData: map['data'] != null
          ? Map<String, dynamic>.from(map['data'] as Map)
          : const {},
    );
  }

  // ── 便捷访问器（针对常用模型） ──────────────────────────────────────────────

  /// 获取 Generic On/Off 状态（仅当 [modelType] 为
  /// [MeshMessageModelType.genericOnOffStatus] 时有效）。
  bool? get genericOnOff => rawData['onOff'] as bool?;

  /// 获取 Generic Level 值 -32768 到 32767（仅当 [modelType] 为
  /// [MeshMessageModelType.genericLevelStatus] 时有效）。
  int? get genericLevel => rawData['level'] as int?;

  /// 获取 Light Lightness 值 0 到 65535（仅当 [modelType] 为
  /// [MeshMessageModelType.lightLightnessStatus] 时有效）。
  int? get lightLightness => rawData['lightness'] as int?;

  /// 是否为 Generic On/Off 状态消息。
  bool get isGenericOnOffStatus =>
      modelType == MeshMessageModelType.genericOnOffStatus;

  /// 是否为 Generic Level 状态消息。
  bool get isGenericLevelStatus =>
      modelType == MeshMessageModelType.genericLevelStatus;

  /// 是否为 Light Lightness 状态消息。
  bool get isLightLightnessStatus =>
      modelType == MeshMessageModelType.lightLightnessStatus;

  /// 是否为 Scene 状态消息。
  bool get isSceneStatus => modelType == MeshMessageModelType.sceneStatus;

  /// 是否为 Vendor 模型状态消息。
  bool get isVendorModelStatus =>
      modelType == MeshMessageModelType.vendorModelStatus;

  /// 格式化来源地址为十六进制字符串。
  String get hexSource =>
      '0x${source.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  @override
  String toString() =>
      'MeshMessageStatus(source: $hexSource, type: $modelType, data: $rawData)';
}
