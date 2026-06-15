/// 代理过滤器类型。
///
/// 对齐 Mesh Proxy Configuration 中的白名单 / 黑名单模式。
enum MeshProxyFilterType {
  /// 仅接受存在于过滤列表中的地址流量。
  whitelist,

  /// 拒绝存在于过滤列表中的地址流量。
  blacklist;

  /// 供原生桥接使用的稳定整数编码。
  int get code => switch (this) {
    MeshProxyFilterType.whitelist => 0,
    MeshProxyFilterType.blacklist => 1,
  };

  /// 从桥接层返回的整数编码恢复枚举值。
  static MeshProxyFilterType fromCode(int code) {
    return switch (code) {
      0 => MeshProxyFilterType.whitelist,
      1 => MeshProxyFilterType.blacklist,
      _ => throw ArgumentError.value(code, 'code', '不支持的代理过滤器类型'),
    };
  }
}
