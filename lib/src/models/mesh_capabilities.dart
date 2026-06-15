/// 当前桥接层暴露的高层 Mesh 能力快照。
class MeshCapabilities {
  const MeshCapabilities({
    required this.rxSourceAddress,
    required this.rxAppKeyIndex,
    required this.proxyFilter,
  });

  /// 入站消息是否可靠携带源地址。
  final bool rxSourceAddress;

  /// 入站元数据是否可能携带 AppKey 索引。
  final bool rxAppKeyIndex;

  /// 当前桥接层对 Proxy Filter 的支持等级。
  final MeshProxyFilterCapability proxyFilter;

  /// 根据桥接支持标志构造能力快照。
  factory MeshCapabilities.fromSupportFlags({
    required bool rxSourceAddress,
    required bool rxAppKeyIndex,
    required bool supportsProxyFilter,
    bool supportsAutomaticProxyFilter = false,
  }) {
    return MeshCapabilities(
      rxSourceAddress: rxSourceAddress,
      rxAppKeyIndex: rxAppKeyIndex,
      proxyFilter: supportsProxyFilter
          ? MeshProxyFilterCapability.explicitControl
          : supportsAutomaticProxyFilter
          ? MeshProxyFilterCapability.automaticOnly
          : MeshProxyFilterCapability.unsupported,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshCapabilities &&
          rxSourceAddress == other.rxSourceAddress &&
          rxAppKeyIndex == other.rxAppKeyIndex &&
          proxyFilter == other.proxyFilter;

  @override
  int get hashCode => Object.hash(rxSourceAddress, rxAppKeyIndex, proxyFilter);

  @override
  String toString() {
    return 'MeshCapabilities('
        'rxSourceAddress: $rxSourceAddress, '
        'rxAppKeyIndex: $rxAppKeyIndex, '
        'proxyFilter: $proxyFilter'
        ')';
  }
}

/// Proxy Filter 支持等级。
enum MeshProxyFilterCapability {
  /// Flutter 层完全无法管理 Proxy Filter。
  unsupported,

  /// 原生层会自动管理，但 Flutter 不能显式改动。
  automaticOnly,

  /// Flutter 可显式配置 Proxy Filter。
  explicitControl,
}
