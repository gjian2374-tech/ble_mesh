import '../enums/ble_mesh_enums.dart';

/// 表示节点在 Configuration 阶段的当前进度。
class MeshConfigurationStatus {
  const MeshConfigurationStatus({
    required this.state,
    this.uuid,
    this.unicastAddress,
    this.modelId,
    this.companyId,
    this.message,
  });

  factory MeshConfigurationStatus.fromMap(Map<dynamic, dynamic> map) {
    return MeshConfigurationStatus(
      state: MeshConfigurationState.fromString(
        map['state'] as String? ?? 'idle',
      ),
      uuid: map['uuid'] as String?,
      unicastAddress: map['unicastAddress'] as int?,
      modelId: map['modelId'] as int?,
      companyId: map['companyId'] as int?,
      message: map['message'] as String?,
    );
  }

  final MeshConfigurationState state;
  final String? uuid;
  final int? unicastAddress;
  final int? modelId;
  final int? companyId;
  final String? message;

  /// 当前是否为完成或失败等终态。
  bool get isTerminal =>
      state == MeshConfigurationState.complete ||
      state == MeshConfigurationState.failed;
}
