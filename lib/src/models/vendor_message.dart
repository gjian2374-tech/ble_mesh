import 'package:flutter/foundation.dart';

import 'mesh_message_status.dart';

// ── Vendor Model 常量 ─────────────────────────────────────────────────────────

/// 设备的 Vendor 公司 ID（Company Identifier）。
///
/// Espressif 厂商 CID（与固件及原生层绑定一致）。
const int kVendorCompanyId = 0x02E5;

/// Vendor Model 32 位复合 ID（CID << 16 | ModelId），用于订阅/发布配置。
int vendorModelCompoundId(int modelId) =>
    (kVendorCompanyId << 16) | (modelId & 0xFFFF);

/// 同步模型复合 ID（0x02E5 + 0x0001）。
const int kSyncModelCompoundId = 0x02E50001;

/// Sync Group 发布/订阅所用的 Vendor 模型（**0x0001 同步模型**）。
const int kSyncGroupModelCompoundId = kSyncModelCompoundId;

/// 设备控制模型复合 ID（0x02E5 + 0x0002）。
const int kDeviceControlModelCompoundId = 0x02E50002;

/// 默认 Sync Group 组播地址。
const int kDefaultSyncGroupAddress = 0xC000;

/// 默认控制分组地址（Generic OnOff 组控测试用）。
const int kDefaultControlGroupAddress = 0xC001;

/// SIG Generic OnOff Server 模型 ID。
const int kGenericOnOffModelId = 0x1000;

/// Vendor Model 0x0001：同步模型，Sync Group 仅在此模型上 Publish / Subscribe。
const int kSyncModelId = 0x0001;

/// Vendor Model 0x0002：设备控制及 SD/算法同步 Pub/Sub。
const int kDeviceControlModelId = 0x0002;

/// Sync 相关 Vendor 模型复合 ID 列表（0x0001 + 0x0002）。
const List<int> kSyncVendorModelCompoundIds = [
  kSyncModelCompoundId,
  kDeviceControlModelCompoundId,
];

// ── 收到的 Vendor 消息状态 ────────────────────────────────────────────────────

/// 从节点收到的 Vendor 模型状态回包。
@immutable
class VendorMessageStatus {
  const VendorMessageStatus({
    required this.source,
    required this.companyId,
    required this.modelId,
    required this.opCode,
    required this.payload,
  });

  /// 消息来源节点地址。
  final int source;

  /// 公司 ID。
  final int companyId;

  /// Vendor 模型 ID。
  final int modelId;

  final int opCode;

  /// 负载数据。
  final Uint8List payload;

  /// 从原生层 Map 构造。
  factory VendorMessageStatus.fromMap(Map<dynamic, dynamic> map) {
    final data = map['data'] is Map
        ? Map<dynamic, dynamic>.from(map['data'] as Map)
        : map;
    final payloadList = (data['payload'] as List?)
            ?.map((e) => e as int)
            .toList() ??
        const <int>[];
    return VendorMessageStatus(
      source: (map['source'] ?? data['source']) as int? ?? 0,
      companyId: data['companyId'] as int? ?? 0,
      modelId: data['modelId'] as int? ?? 0,
      opCode: data['opCode'] as int? ?? 0,
      payload: Uint8List.fromList(payloadList),
    );
  }

  /// 从 [MeshMessageStatus] 构造 Vendor 状态对象。
  factory VendorMessageStatus.fromMeshMessageStatus(
    MeshMessageStatus status,
  ) {
    return VendorMessageStatus.fromMap({
      'source': status.source,
      'data': status.rawData,
    });
  }

  /// 格式化来源地址。
  String get hexSource =>
      '0x${source.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  @override
  String toString() =>
      'VendorMessageStatus(source: $hexSource, model: 0x${modelId.toRadixString(16)}, '
      'payload: ${payload.length} bytes)';
}
