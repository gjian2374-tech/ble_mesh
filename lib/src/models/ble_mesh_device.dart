import 'package:flutter/foundation.dart';

/// 扫描到的未配网 BLE Mesh 设备。
///
/// 当调用 [BleMesh.startScan] 后，可通过 [BleMesh.scanResults] 流
/// 接收到此类型的设备信息。
@immutable
class BleMeshDevice {
  const BleMeshDevice({
    required this.uuid,
    this.name,
    required this.rssi,
    required this.address,
    this.capabilities,
  });

  /// 设备广播数据中的 UUID（用于配网标识）。
  final String uuid;

  /// 设备名称（如果广播数据中携带）。
  final String? name;

  /// 接收信号强度（dBm），数值越大信号越强，通常为负数。
  final int rssi;

  /// 蓝牙地址（Android 上为 MAC 地址，iOS 上为系统分配的 UUID）。
  final String address;

  /// 设备配网能力（元素数量、算法、OOB 类型等）。
  final Map<String, dynamic>? capabilities;

  /// 从原生层返回的 Map 构造 [BleMeshDevice]。
  factory BleMeshDevice.fromMap(Map<dynamic, dynamic> map) {
    return BleMeshDevice(
      uuid: map['uuid'] as String? ?? '',
      name: map['name'] as String?,
      rssi: map['rssi'] as int? ?? -100,
      address: map['address'] as String? ?? '',
      capabilities: map['capabilities'] != null
          ? Map<String, dynamic>.from(map['capabilities'] as Map)
          : null,
    );
  }

  /// 将设备信息转换为 Map，用于传递给原生层。
  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'name': name,
        'rssi': rssi,
        'address': address,
        'capabilities': capabilities,
      };

  /// 信号强度描述（根据 RSSI 值划分强弱）。
  String get signalStrength {
    if (rssi >= -50) return '极强';
    if (rssi >= -70) return '强';
    if (rssi >= -85) return '中等';
    return '弱';
  }

  /// 规范化后的 UUID，便于比较。
  String get normalizedUuid => uuid.trim().toLowerCase();

  /// 规范化后的地址，便于比较。
  String get normalizedAddress => address.trim().toLowerCase();

  /// 是否携带可展示名称。
  bool get hasName => name != null && name!.trim().isNotEmpty;

  /// 是否包含配网能力信息。
  bool get hasCapabilities => capabilities != null && capabilities!.isNotEmpty;

  /// 信号是否至少达到中等强度。
  bool get hasAcceptableSignal => rssi >= -85;

  /// UUID 是否匹配，忽略首尾空格和大小写。
  bool matchesUuid(String value) => normalizedUuid == value.trim().toLowerCase();

  /// 地址是否匹配，忽略首尾空格和大小写。
  bool matchesAddress(String value) =>
      normalizedAddress == value.trim().toLowerCase();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BleMeshDevice &&
          runtimeType == other.runtimeType &&
          uuid == other.uuid;

  @override
  int get hashCode => uuid.hashCode;

  @override
  String toString() =>
      'BleMeshDevice(uuid: $uuid, name: $name, rssi: $rssi dBm, address: $address)';
}
