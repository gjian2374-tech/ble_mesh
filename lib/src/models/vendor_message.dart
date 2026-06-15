import 'package:flutter/foundation.dart';

import '../enums/ble_mesh_enums.dart';
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

/// 设备控制模型复合 ID（0x02E5 + 0x0002，主从切换 0x10 / 播放模式 0x11）。
const int kDeviceControlModelCompoundId = 0x02E50002;

/// 默认 Sync Group 组播地址。
const int kDefaultSyncGroupAddress = 0xC000;

/// 默认控制分组地址（Generic OnOff 组控测试用）。
const int kDefaultControlGroupAddress = 0xC001;

/// SIG Generic OnOff Server 模型 ID。
const int kGenericOnOffModelId = 0x1000;

/// Vendor Model 0x0001：同步模型，Sync Group 仅在此模型上 Publish / Subscribe。
const int kSyncModelId = 0x0001;

/// Vendor Model 0x0002：主从切换（0x10）、播放模式（0x11）及 SD/算法同步 Pub/Sub。
const int kDeviceControlModelId = 0x0002;

/// Sync 相关 Vendor 模型复合 ID 列表（0x0001 + 0x0002）。
const List<int> kSyncVendorModelCompoundIds = [
  kSyncModelCompoundId,
  kDeviceControlModelCompoundId,
];

/// 设备控制模型：主从机切换操作码。
const int kOpCodeMasterSlave = 0x10;

/// 设备控制模型：播放模式切换操作码。
const int kOpCodePlayMode = 0x11;

// ── 播放模式配置 ──────────────────────────────────────────────────────────────

/// 播放模式配置（对应操作码 0x11 的 5 字节负载）。
///
/// 字节布局：
/// - byte0：资源类型（[SourceType.byteValue]）
/// - byte1：模式索引（mode index）
/// - byte2：速度值（1-10）
/// - byte3-4：亮度值（0-65535，大端序）
@immutable
class PlayModeConfig {
  const PlayModeConfig({
    required this.sourceType,
    required this.modeIndex,
    required this.speed,
    required this.brightness,
  }) : assert(speed >= 1 && speed <= 10, 'speed 必须在 1-10 范围内'),
       assert(brightness >= 0 && brightness <= 65535, 'brightness 必须在 0-65535 范围内');

  /// 资源类型（SD 卡或算法资源）。
  final SourceType sourceType;

  /// 模式索引编号（由固件定义，不同设备含义不同）。
  final int modeIndex;

  /// 播放速度，范围 1（最慢）到 10（最快）。
  final int speed;

  /// 亮度值，范围 0（熄灭）到 65535（最亮）。
  final int brightness;

  /// 将配置序列化为 5 字节的协议负载。
  ///
  /// 布局：[sourceType(1)] [modeIndex(1)] [speed(1)] [brightness_hi(1)] [brightness_lo(1)]
  Uint8List toBytes() {
    return Uint8List.fromList([
      sourceType.byteValue,             // byte0: 资源类型
      modeIndex & 0xFF,                 // byte1: 模式索引
      speed.clamp(1, 10),              // byte2: 速度
      (brightness >> 8) & 0xFF,        // byte3: 亮度高字节
      brightness & 0xFF,               // byte4: 亮度低字节
    ]);
  }

  /// 从 5 字节协议负载构造 [PlayModeConfig]。
  factory PlayModeConfig.fromBytes(Uint8List bytes) {
    if (bytes.length < 5) {
      throw ArgumentError('PlayModeConfig 需要至少 5 字节，实际: ${bytes.length}');
    }
    return PlayModeConfig(
      sourceType: SourceType.fromByte(bytes[0]),
      modeIndex: bytes[1],
      speed: bytes[2].clamp(1, 10),
      brightness: (bytes[3] << 8) | bytes[4],
    );
  }

  /// 亮度值转换为 0.0-1.0 的浮点比例。
  double get brightnessPercent => brightness / 65535.0;

  PlayModeConfig copyWith({
    SourceType? sourceType,
    int? modeIndex,
    int? speed,
    int? brightness,
  }) {
    return PlayModeConfig(
      sourceType: sourceType ?? this.sourceType,
      modeIndex: modeIndex ?? this.modeIndex,
      speed: speed ?? this.speed,
      brightness: brightness ?? this.brightness,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayModeConfig &&
          sourceType == other.sourceType &&
          modeIndex == other.modeIndex &&
          speed == other.speed &&
          brightness == other.brightness;

  @override
  int get hashCode =>
      Object.hash(sourceType, modeIndex, speed, brightness);

  @override
  String toString() =>
      'PlayModeConfig(source: ${sourceType.displayName}, '
      'mode: $modeIndex, speed: $speed, brightness: $brightness)';
}

// ── Vendor 消息基类 ───────────────────────────────────────────────────────────

/// Vendor 模型消息的抽象基类。
@immutable
abstract class VendorMessage {
  const VendorMessage({
    required this.companyId,
    required this.modelId,
    required this.opCode,
  });

  /// 公司 ID（CID）。
  final int companyId;

  /// Vendor 模型 ID。
  final int modelId;

  /// 操作码（单字节，厂商自定义）。
  final int opCode;

  /// 消息负载数据。
  Uint8List get payload;

  /// 将消息转换为 Map，用于传递给原生层。
  Map<String, dynamic> toMap() => {
        'companyId': companyId,
        'modelId': modelId,
        'opCode': opCode,
        'payload': payload.toList(),
      };
}

// ── 具体 Vendor 消息类型 ───────────────────────────────────────────────────────

/// 主从机角色切换消息（操作码 0x10）。
///
/// 负载为 1 字节：0x01=主机，0x02=从机。
@immutable
class MasterSlaveMessage extends VendorMessage {
  const MasterSlaveMessage({
    required this.role,
    super.companyId = kVendorCompanyId,
  }) : super(
          modelId: kDeviceControlModelId,
          opCode: kOpCodeMasterSlave,
        );

  /// 目标角色。
  final MeshNodeRole role;

  @override
  Uint8List get payload => Uint8List.fromList([role.byteValue]);

  @override
  String toString() =>
      'MasterSlaveMessage(role: ${role.name}, opCode: 0x${opCode.toRadixString(16)})';
}

/// 播放模式切换消息（操作码 0x11）。
///
/// 负载为 5 字节，见 [PlayModeConfig.toBytes]。
@immutable
class PlayModeMessage extends VendorMessage {
  const PlayModeMessage({
    required this.config,
    super.companyId = kVendorCompanyId,
  }) : super(
          modelId: kDeviceControlModelId,
          opCode: kOpCodePlayMode,
        );

  /// 播放模式配置。
  final PlayModeConfig config;

  @override
  Uint8List get payload => config.toBytes();

  @override
  String toString() =>
      'PlayModeMessage(config: $config, opCode: 0x${opCode.toRadixString(16)})';
}

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

  /// 操作码。
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

  /// 尝试将此消息解析为 [MeshNodeRole]（操作码 0x10）。
  MeshNodeRole? get asMasterSlaveRole {
    if (opCode != kOpCodeMasterSlave || payload.isEmpty) return null;
    return MeshNodeRole.fromByte(payload[0]);
  }

  /// 尝试将此消息解析为 [PlayModeConfig]（操作码 0x11）。
  PlayModeConfig? get asPlayModeConfig {
    if (opCode != kOpCodePlayMode || payload.length < 5) return null;
    return PlayModeConfig.fromBytes(payload);
  }

  /// 格式化来源地址。
  String get hexSource =>
      '0x${source.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  @override
  String toString() =>
      'VendorMessageStatus(source: $hexSource, model: 0x${modelId.toRadixString(16)}, '
      'opCode: 0x${opCode.toRadixString(16)}, payload: ${payload.length} bytes)';
}
