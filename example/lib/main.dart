/// BLE Mesh 设备控制示例。
///
/// 流程：初始化 → 扫描 → 配网 → Proxy 连接 → 配置完成 → 设备控制 / 分组控制
///
/// 支持的模型：
/// - Generic OnOff Server (0x1000) 通用开关
/// - Generic Level Server (0x1002) 通用亮度
/// - Vendor Model 0x0002 Sync 发布/订阅（0xC000）+ 设备控制（0x10 主从，0x11 播放模式）
/// - Vendor Model 0x0001 固件存在但 Sync Pub/Sub 不使用
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ble_mesh/ble_mesh.dart';

void main() => runApp(const BleMeshApp());

// ─── 调试日志 ─────────────────────────────────────────────────────────────────

/// 单条调试日志。
class _DebugLogEntry {
  const _DebugLogEntry({
    required this.time,
    required this.message,
    this.isError = false,
  });

  final DateTime time;
  final String message;
  final bool isError;

  String get timeLabel {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// 页面底部调试信息面板，替代 SnackBar 弹窗展示错误。
class _DebugInfoSection extends StatelessWidget {
  const _DebugInfoSection({
    required this.logs,
    this.onClear,
  });

  final List<_DebugLogEntry> logs;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '调试信息',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (logs.isNotEmpty && onClear != null)
                  TextButton(
                    onPressed: onClear,
                    child: const Text('清空'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.outline),
                      ),
                    )
                  : ListView.separated(
                      itemCount: logs.length,
                      separatorBuilder: (_, __) => const Divider(height: 8),
                      itemBuilder: (_, i) {
                        final entry = logs[i];
                        return Text(
                          '[${entry.timeLabel}] ${entry.message}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: entry.isError ? cs.error : cs.onSurface,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── App ─────────────────────────────────────────────────────────────────────

class BleMeshApp extends StatelessWidget {
  const BleMeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Mesh',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const _InitPage(),
    );
  }

  static ThemeData _buildTheme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF00629B),
      brightness: brightness,
    ),
    useMaterial3: true,
    cardTheme: const CardThemeData(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
  );
}

// ─── Init Page ────────────────────────────────────────────────────────────────

/// 启动页：初始化协议栈、申请权限后跳转至主页。
class _InitPage extends StatefulWidget {
  const _InitPage();

  @override
  State<_InitPage> createState() => _InitPageState();
}

class _InitPageState extends State<_InitPage> {
  String _status = '正在启动…';
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _status = '正在初始化 Mesh 协议栈…';
      _hasError = false;
    });
    try {
      await BleMesh().initializeAndWaitForNetwork(
        timeout: const Duration(seconds: 10),
      );
      setState(() => _status = '正在申请蓝牙权限…');
      await BleMesh().requestPermissions();
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const _NetworkPage()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '初始化失败：$e';
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hub_outlined, size: 72, color: cs.primary),
                const SizedBox(height: 20),
                Text(
                  'BLE Mesh',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Nordic nRF Mesh 流程示例',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.outline,
                  ),
                ),
                const SizedBox(height: 40),
                if (!_hasError)
                  const CircularProgressIndicator()
                else
                  Icon(Icons.warning_amber_rounded, size: 40, color: cs.error),
                const SizedBox(height: 16),
                Text(_status, textAlign: TextAlign.center),
                if (_hasError) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _initialize,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Network Page ─────────────────────────────────────────────────────────────

/// 主页：显示已配网节点列表，提供添加设备入口。
///
/// 对应 nRF Mesh 官方 App 的 "Network" 标签页。
class _NetworkPage extends StatefulWidget {
  const _NetworkPage({super.key});

  @override
  State<_NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<_NetworkPage> {
  final _mesh = BleMesh();
  final List<MeshNode> _nodes = [];
  final List<_DebugLogEntry> _debugLogs = [];
  MeshConnectionState _connState = MeshConnectionState.disconnected;
  MeshNetworkInfo? _networkInfo;
  bool _loadingNetworkInfo = true;

  late final StreamSubscription<MeshNode> _nodeAddedSub;
  late final StreamSubscription<int> _nodeDeletedSub;
  late final StreamSubscription<MeshConnectionState> _connSub;
  late final StreamSubscription<BleMeshException> _errSub;
  late final StreamSubscription<void> _networkUpdatedSub;

  @override
  void initState() {
    super.initState();
    _loadInitialState();
    _nodeAddedSub = _mesh.nodeAdded.listen(_onNodeAdded);
    _nodeDeletedSub = _mesh.nodeDeleted.listen(_onNodeDeleted);
    _connSub = _mesh.connectionState.listen(_onConnState);
    _networkUpdatedSub = _mesh.networkUpdated.listen((_) => _loadNetworkInfo());
    _errSub = _mesh.errors.listen(
      (e) => _logDebug('[${e.code}] ${e.message}', isError: true),
    );
  }

  @override
  void dispose() {
    _nodeAddedSub.cancel();
    _nodeDeletedSub.cancel();
    _connSub.cancel();
    _networkUpdatedSub.cancel();
    _errSub.cancel();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    try {
      final state = await _mesh.getConnectionState();
      if (mounted) setState(() => _connState = state);
    } catch (_) {}
    await Future.wait([_loadNodes(), _loadNetworkInfo()]);
  }

  Future<void> _loadNetworkInfo() async {
    setState(() => _loadingNetworkInfo = true);
    try {
      final info = await _mesh.getNetworkInfo();
      if (mounted) {
        setState(() {
          _networkInfo = info;
          _loadingNetworkInfo = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingNetworkInfo = false);
        _logDebug('读取网络信息失败：$e', isError: true);
      }
    }
  }

  void _logDebug(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _debugLogs.insert(
        0,
        _DebugLogEntry(time: DateTime.now(), message: message, isError: isError),
      );
      if (_debugLogs.length > 50) {
        _debugLogs.removeRange(50, _debugLogs.length);
      }
    });
  }

  Future<void> _loadNodes() async {
    try {
      final nodes = await _mesh.getNodes();
      if (mounted) {
        setState(() {
          _nodes
            ..clear()
            ..addAll(nodes);
        });
      }
    } catch (_) {}
  }

  void _onNodeAdded(MeshNode node) => setState(() {
    _nodes.removeWhere((n) => n.unicastAddress == node.unicastAddress);
    _nodes.add(node);
  });

  void _onNodeDeleted(int address) =>
      setState(() => _nodes.removeWhere((n) => n.unicastAddress == address));

  void _onConnState(MeshConnectionState state) =>
      setState(() => _connState = state);

  Future<void> _deleteNode(MeshNode node) async {
    final confirmed = await _showDeleteConfirm(node);
    if (!confirmed || !mounted) return;
    _logDebug('开始删除节点 ${node.hexAddress} uuid=${node.uuid}');
    try {
      await _mesh.deleteNode(node.unicastAddress);
      final remaining = await _mesh.getNodes();
      _logDebug(
        '删除完成，本地剩余节点=${remaining.length} '
        '${remaining.isEmpty ? "（已清空，可重新扫描配网）" : remaining.map((n) => n.hexAddress).join(", ")}',
      );
    } catch (e) {
      _logDebug('删除失败：$e', isError: true);
    }
  }

  Future<bool> _showDeleteConfirm(MeshNode node) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('移除节点'),
            content: Text(
              '确认从网络中移除节点 "${node.name}"（${node.hexAddress}）？\n\n'
              '此操作将向设备发送 Reset 消息，设备将返回未配网状态。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('移除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _exportNetwork() async {
    try {
      final json = await _mesh.exportNetworkJson();
      await Clipboard.setData(ClipboardData(text: json));
      _logDebug('网络 JSON 已复制到剪贴板（${json.length} 字符）');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('网络 JSON 已复制到剪贴板')),
      );
    } catch (e) {
      _logDebug('导出失败：$e', isError: true);
    }
  }

  Future<void> _importNetwork() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入网络'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '粘贴 Mesh Configuration Database JSON',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _mesh.importNetworkJson(controller.text);
      await _loadInitialState();
      _logDebug('网络导入成功');
    } catch (e) {
      _logDebug('导入失败：$e', isError: true);
    } finally {
      controller.dispose();
    }
  }

  void _openScan() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const _ScanPage()),
  );

  void _openNodeControl(MeshNode node) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _NodeControlPage(
        node: node,
        initialConnState: _connState,
      ),
    ),
  );

  void _openGroupTest() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _GroupTestPage(initialConnState: _connState),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Mesh 网络'),
        actions: [
          IconButton(
            tooltip: '分组控制测试',
            onPressed: _nodes.isEmpty ? null : _openGroupTest,
            icon: const Icon(Icons.groups_outlined),
          ),
          IconButton(
            tooltip: '导出网络',
            onPressed: _exportNetwork,
            icon: const Icon(Icons.upload_outlined),
          ),
          IconButton(
            tooltip: '导入网络',
            onPressed: _importNetwork,
            icon: const Icon(Icons.download_outlined),
          ),
          _ConnectionChip(state: _connState),
        ],
      ),
      body: Column(
        children: [
          _NetworkInfoCard(
            info: _networkInfo,
            loading: _loadingNetworkInfo,
            onRefresh: _loadNetworkInfo,
          ),
          Expanded(
            child: _nodes.isEmpty
                ? const _EmptyNetworkView()
                : _NodeList(
                    nodes: _nodes,
                    onTap: _openNodeControl,
                    onDelete: _deleteNode,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _DebugInfoSection(
              logs: _debugLogs,
              onClear: () => setState(_debugLogs.clear),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScan,
        icon: const Icon(Icons.add),
        label: const Text('添加设备'),
      ),
    );
  }
}

// ── Network Page 子组件 ────────────────────────────────────────────────────────

class _NetworkInfoCard extends StatelessWidget {
  const _NetworkInfoCard({
    required this.info,
    required this.loading,
    required this.onRefresh,
  });

  final MeshNetworkInfo? info;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: loading
            ? const Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('正在读取网络信息…'),
                ],
              )
            : info == null
            ? const Text('暂无网络信息')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        info!.name.isEmpty ? 'Mesh Network' : info!.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: 'IV Index',
                    value:
                        '0x${info!.ivIndex.toRadixString(16).toUpperCase()}'
                        '${info!.ivUpdateActive ? ' (IV Update)' : ''}',
                  ),
                  _InfoRow(
                    label: 'Sequence',
                    value: info!.sequenceNumber.toString(),
                  ),
                  _InfoRow(
                    label: 'Provisioner',
                    value:
                        '0x${info!.provisionerAddress.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                  ),
                  if (info!.networkKeys.isNotEmpty)
                    _InfoRow(
                      label: 'NetKey',
                      value: info!.networkKeys
                          .map((k) => '#${k.index} ${k.name}')
                          .join(', '),
                    ),
                  if (info!.appKeys.isNotEmpty)
                    _InfoRow(
                      label: 'AppKey',
                      value: info!.appKeys
                          .map((k) => '#${k.index} ${k.name}')
                          .join(', '),
                    ),
                  _InfoRow(label: '节点数', value: '${info!.nodeCount}'),
                ],
              ),
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.state});

  final MeshConnectionState state;

  @override
  Widget build(BuildContext context) {
    if (state == MeshConnectionState.disconnected) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        avatar: state == MeshConnectionState.connected
            ? const Icon(Icons.bluetooth_connected, size: 16)
            : const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
        label: Text(
          state == MeshConnectionState.connected ? '代理已连接' : '连接中…',
        ),
        backgroundColor: state == MeshConnectionState.connected
            ? Colors.green.shade100
            : null,
      ),
    );
  }
}

class _EmptyNetworkView extends StatelessWidget {
  const _EmptyNetworkView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.device_hub, size: 80, color: cs.outlineVariant),
          const SizedBox(height: 16),
          Text(
            '网络中暂无设备',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 8),
          Text(
            '点击"添加设备"扫描并配网 BLE Mesh 设备',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.outlineVariant),
          ),
        ],
      ),
    );
  }
}

class _NodeList extends StatelessWidget {
  const _NodeList({
    required this.nodes,
    required this.onTap,
    required this.onDelete,
  });

  final List<MeshNode> nodes;
  final ValueChanged<MeshNode> onTap;
  final ValueChanged<MeshNode> onDelete;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {},
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: nodes.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _NodeCard(
          node: nodes[i],
          onTap: () => onTap(nodes[i]),
          onDelete: () => onDelete(nodes[i]),
        ),
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.node,
    required this.onTap,
    required this.onDelete,
  });

  final MeshNode node;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.memory, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      node.hexAddress,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.primary,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (node.macAddress != null)
                      Text(
                        node.macAddress!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.outline,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                color: cs.error,
                tooltip: '移除节点',
                onPressed: onDelete,
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Scan Page ────────────────────────────────────────────────────────────────

/// 扫描页：扫描周围的未配网 BLE Mesh 设备。
///
/// 对应 nRF Mesh 官方 App 的扫描步骤。
class _ScanPage extends StatefulWidget {
  const _ScanPage({super.key});

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _mesh = BleMesh();
  final Map<String, BleMeshDevice> _devices = {};
  final List<_DebugLogEntry> _debugLogs = [];
  bool _isScanning = false;

  StreamSubscription<BleMeshDevice>? _scanSub;
  StreamSubscription<void>? _stopSub;
  StreamSubscription<BleMeshException>? _errSub;

  @override
  void initState() {
    super.initState();
    _errSub = _mesh.errors.listen(
      (e) => _logDebug('[${e.code}] ${e.message}', isError: true),
    );
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _stopSub?.cancel();
    _errSub?.cancel();
    _mesh.stopScan().ignore();
    super.dispose();
  }

  void _logDebug(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _debugLogs.insert(
        0,
        _DebugLogEntry(time: DateTime.now(), message: message, isError: isError),
      );
      if (_debugLogs.length > 50) {
        _debugLogs.removeRange(50, _debugLogs.length);
      }
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _devices.clear();
      _isScanning = true;
    });

    _scanSub?.cancel();
    _stopSub?.cancel();

    _scanSub = _mesh.scanResults.listen(_onDevice);
    _stopSub = _mesh.scanStopped.listen((_) {
      if (mounted) setState(() => _isScanning = false);
    });

    try {
      await _mesh.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        _logDebug('扫描失败：$e', isError: true);
      }
    }
  }

  void _onDevice(BleMeshDevice device) {
    if (!mounted) return;
    setState(() => _devices[device.address] = device);
  }

  Future<void> _onDeviceSelected(BleMeshDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开始配网'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(
              label: '设备名称',
              value: device.name ?? '未命名',
            ),
            _InfoRow(label: 'MAC 地址', value: device.address, mono: true),
            _InfoRow(
              label: '信号强度',
              value: '${device.rssi} dBm（${device.signalStrength}）',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('配网'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _mesh.stopScan().ignore();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ProvisioningPage(device: device),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描未配网设备'),
        actions: [
          if (_isScanning)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新扫描',
              onPressed: _startScan,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: devices.isEmpty
                ? _ScanEmptyView(isScanning: _isScanning)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: devices.length,
                    itemBuilder: (_, i) => _DeviceTile(
                      device: devices[i],
                      onTap: () => _onDeviceSelected(devices[i]),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _DebugInfoSection(
              logs: _debugLogs,
              onClear: () => setState(_debugLogs.clear),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanEmptyView extends StatelessWidget {
  const _ScanEmptyView({required this.isScanning});

  final bool isScanning;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isScanning ? Icons.radar : Icons.bluetooth_searching,
            size: 80,
            color: isScanning ? cs.primary : cs.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            isScanning ? '正在扫描周围设备…' : '未发现未配网设备',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: isScanning ? cs.primary : cs.outline),
          ),
          if (!isScanning) ...[
            const SizedBox(height: 8),
            Text(
              '请确认设备处于未配网状态并已开启蓝牙',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outlineVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onTap});

  final BleMeshDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rssi = device.rssi;
    final rssiColor = rssi >= -60
        ? Colors.green
        : rssi >= -80
            ? Colors.orange
            : Colors.red;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: cs.secondaryContainer,
        child: Icon(Icons.bluetooth, color: cs.onSecondaryContainer),
      ),
      title: Text(device.name ?? '未命名设备'),
      subtitle: Text(
        device.address,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.signal_cellular_alt, color: rssiColor, size: 18),
          Text(
            '$rssi dBm',
            style: TextStyle(fontSize: 10, color: rssiColor),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

// ─── Provisioning Page ────────────────────────────────────────────────────────

/// 配网页：执行 PB-GATT 配网流程，显示各步骤进度。
///
/// 对应 nRF Mesh 官方 App 的配网对话框流程。
class _ProvisioningPage extends StatefulWidget {
  const _ProvisioningPage({super.key, required this.device});

  final BleMeshDevice device;

  @override
  State<_ProvisioningPage> createState() => _ProvisioningPageState();
}

class _ProvisioningPageState extends State<_ProvisioningPage> {
  final _mesh = BleMesh();
  ProvisioningState _state = ProvisioningState.idle;
  MeshNode? _provisionedNode;
  String? _errorMessage;

  StreamSubscription<ProvisioningState>? _stateSub;
  StreamSubscription<MeshNode>? _nodeAddedSub;

  @override
  void initState() {
    super.initState();
    _stateSub = _mesh.provisioningState.listen(_onStateChanged);
    _nodeAddedSub = _mesh.nodeAdded.listen(_onNodeAdded);
    _startProvisioning();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _nodeAddedSub?.cancel();
    super.dispose();
  }

  Future<void> _startProvisioning() async {
    try {
      await _mesh.provisionDevice(
        uuid: widget.device.uuid,
        address: widget.device.address,
        nodeName: widget.device.name,
      );
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    }
  }

  void _onStateChanged(ProvisioningState state) {
    if (!mounted) return;
    setState(() => _state = state);
    if (state == ProvisioningState.failed) {
      setState(() => _errorMessage = '配网失败，请检查设备状态后重试');
    }
  }

  void _onNodeAdded(MeshNode node) {
    if (mounted) setState(() => _provisionedNode = node);
  }

  /// 配网完成后跳转到节点控制页，并从扫描页弹出（保留主页）。
  void _goToNodeControl() {
    final node = _provisionedNode;
    if (node == null) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => _NodeControlPage(
          node: node,
          // 原生层已在配网完成后自动连接 Proxy 并下发配置，避免重复连接
          autoConnectProxy: false,
        ),
      ),
      (route) => route.isFirst,
    );
  }

  bool get _isComplete =>
      _state == ProvisioningState.complete && _provisionedNode != null;
  bool get _isFailed => _errorMessage != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('正在配网'),
        automaticallyImplyLeading: _isFailed,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DeviceInfoCard(device: widget.device),
            const SizedBox(height: 28),
            _ProvisioningSteps(state: _state),
            const SizedBox(height: 36),
            if (_isComplete) _ProvisioningSuccessView(
              node: _provisionedNode!,
              onContinue: _goToNodeControl,
            ),
            if (_isFailed) _ProvisioningFailedView(
              error: _errorMessage!,
              onBack: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard({required this.device});

  final BleMeshDevice device;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.bluetooth, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name ?? '未命名设备',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    device.address,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProvisioningSteps extends StatelessWidget {
  const _ProvisioningSteps({required this.state});

  final ProvisioningState state;

  static const _steps = [
    (ProvisioningState.connecting, '建立 PB-GATT 连接'),
    (ProvisioningState.identifying, '获取设备能力（Capabilities）'),
    (ProvisioningState.exchangingKeys, '密钥交换（ECDH）'),
    (ProvisioningState.provisioning, '下发网络数据（NetKey + 地址）'),
    (ProvisioningState.complete, '配网完成'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: _steps.asMap().entries.map((entry) {
        final stepState = entry.value.$1;
        final stepLabel = entry.value.$2;
        final stepIndex = entry.key;
        final currentIndex = _steps.indexWhere((s) => s.$1 == state);

        final isDone = state == ProvisioningState.complete ||
            (currentIndex > stepIndex && currentIndex >= 0);
        final isActive = state == stepState;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              _StepIcon(isDone: isDone, isActive: isActive),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  stepLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: isActive ? FontWeight.w600 : null,
                    color: isDone
                        ? Colors.green
                        : isActive
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon({required this.isDone, required this.isActive});

  final bool isDone;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    if (isDone) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 24);
    }
    if (isActive) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }
    return Icon(
      Icons.radio_button_unchecked,
      size: 24,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

class _ProvisioningSuccessView extends StatelessWidget {
  const _ProvisioningSuccessView({
    required this.node,
    required this.onContinue,
  });

  final MeshNode node;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.check_circle_outline, color: Colors.green, size: 56),
        const SizedBox(height: 12),
        Text(
          '配网成功！',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(color: Colors.green),
        ),
        const SizedBox(height: 6),
        Text('节点已加入网络，单播地址：${node.hexAddress}'),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onContinue,
          icon: const Icon(Icons.settings_remote),
          label: const Text('连接代理并配置节点'),
        ),
      ],
    );
  }
}

class _ProvisioningFailedView extends StatelessWidget {
  const _ProvisioningFailedView({required this.error, required this.onBack});

  final String error;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Icon(Icons.error_outline, color: cs.error, size: 56),
        const SizedBox(height: 12),
        Text(
          error,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.error),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
          label: const Text('返回重试'),
        ),
      ],
    );
  }
}

// ─── Node Control Page ────────────────────────────────────────────────────────

/// 节点控制页：管理代理连接、AppKey 分发，并发送控制消息。
///
/// 对应 nRF Mesh 官方 App 的节点详情页。流程：
/// 1. 进入页面 → （可选）自动连接 Proxy
/// 2. Proxy 连接成功 → 自动触发 AppKey 分发
/// 3. 分发完成 → 显示控制区域
class _NodeControlPage extends StatefulWidget {
  const _NodeControlPage({
    super.key,
    required this.node,
    this.initialConnState = MeshConnectionState.disconnected,
    this.autoConnectProxy = false,
  });

  final MeshNode node;
  final MeshConnectionState initialConnState;

  /// 配网后首次进入时设为 true，自动发起 Proxy 连接。
  final bool autoConnectProxy;

  @override
  State<_NodeControlPage> createState() => _NodeControlPageState();
}

class _NodeControlPageState extends State<_NodeControlPage> {
  final _mesh = BleMesh();
  final List<_DebugLogEntry> _debugLogs = [];
  late MeshConnectionState _connState;
  bool _isDistributing = false;
  bool _isReady = false;

  StreamSubscription<MeshConnectionState>? _connSub;
  StreamSubscription<BleMeshException>? _errSub;
  StreamSubscription<MeshConfigurationStatus>? _configSub;

  @override
  void initState() {
    super.initState();
    _connState = widget.initialConnState;
    _isReady = widget.initialConnState == MeshConnectionState.connected;
    _connSub = _mesh.connectionState.listen(_onConnState);
    _errSub = _mesh.errors.listen(_onError);
    _configSub = _mesh.configurationState.listen(_onConfigState);
    if (widget.node.appKeyIndexes.isNotEmpty) {
      _isReady = true;
    }
    if (widget.autoConnectProxy && widget.node.hasMacAddress) {
      // 配网完成后延迟少许，等待设备重新以 Proxy 模式广播
      Future<void>.delayed(const Duration(seconds: 2), _connectProxy);
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _errSub?.cancel();
    _configSub?.cancel();
    super.dispose();
  }

  void _logDebug(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _debugLogs.insert(
        0,
        _DebugLogEntry(time: DateTime.now(), message: message, isError: isError),
      );
      if (_debugLogs.length > 50) {
        _debugLogs.removeRange(50, _debugLogs.length);
      }
    });
  }

  void _onConfigState(MeshConfigurationStatus status) {
    if (!mounted) return;
    final addr = status.unicastAddress;
    final addrLabel = addr == null
        ? ''
        : ' → 0x${addr.toRadixString(16).padLeft(4, '0')}';
    _logDebug(
      '[${status.state.name}]${status.message ?? ''}$addrLabel',
      isError: status.state == MeshConfigurationState.failed,
    );
    if (status.unicastAddress != widget.node.unicastAddress) return;

    setState(() {
      if (status.state == MeshConfigurationState.complete) {
        _isReady = true;
        _isDistributing = false;
        return;
      }
      if (status.state == MeshConfigurationState.failed) {
        _isDistributing = false;
        _isReady = false;
        return;
      }
      if (status.state == MeshConfigurationState.proxyConnected ||
          status.state == MeshConfigurationState.compositionGetting ||
          status.state == MeshConfigurationState.compositionReceived ||
          status.state == MeshConfigurationState.appKeyAdding ||
          status.state == MeshConfigurationState.modelBinding) {
        _isDistributing = true;
        _isReady = false;
      }
    });
  }

  void _onConnState(MeshConnectionState state) {
    if (!mounted) return;
    setState(() => _connState = state);
    if (state == MeshConnectionState.connected &&
        widget.node.appKeyIndexes.isNotEmpty) {
      setState(() {
        _isReady = true;
        _isDistributing = false;
      });
    }
  }

  void _onError(BleMeshException error) {
    if (!mounted) return;
    _logDebug('[${error.code}] ${error.message}', isError: true);
  }

  Future<void> _connectProxy() async {
    final mac = widget.node.macAddress;
    if (mac == null) {
      _logDebug(
        '未缓存设备标识，请在本机重新扫描并配网该设备后再连接',
        isError: true,
      );
      return;
    }
    setState(() {
      _connState = MeshConnectionState.connecting;
      _isReady = false;
    });
    try {
      await _mesh.connectToProxy(mac);
    } catch (e) {
      if (mounted) {
        setState(() => _connState = MeshConnectionState.disconnected);
        _logDebug('Proxy 连接失败：$e', isError: true);
      }
    }
  }

  Future<void> _disconnectProxy() async {
    try {
      await _mesh.disconnectFromProxy();
      if (mounted) setState(() => _isReady = false);
    } catch (e) {
      _logDebug('断开失败：$e', isError: true);
    }
  }

  Future<void> _distributeAppKey() async {
    setState(() {
      _isDistributing = true;
      _isReady = false;
    });
    try {
      await _mesh.distributeAppKey(widget.node.unicastAddress);
      // 等待所有配置消息发完（包括模型绑定队列）
      await Future<void>.delayed(const Duration(seconds: 4));
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      if (mounted) _logDebug('AppKey 分发失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isDistributing = false);
    }
  }

  void _showError(String message) => _logDebug(message, isError: true);

  void _showInfo(String message) => _logDebug(message);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.node.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _ProxyStatusChip(
              state: _connState,
              isReady: _isReady,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NodeInfoSection(node: widget.node),
            const SizedBox(height: 12),
            _ProxySection(
              connState: _connState,
              isDistributing: _isDistributing,
              isReady: _isReady,
              hasMac: widget.node.hasMacAddress,
              onConnect: _connectProxy,
              onDisconnect: _disconnectProxy,
              onRedistribute: _distributeAppKey,
            ),
            if (_isReady) ...[
              const SizedBox(height: 12),
              _DeviceControlPanel(
                node: widget.node,
                mesh: _mesh,
                onInfo: _showInfo,
                onError: _showError,
              ),
            ],
            const SizedBox(height: 12),
            _DebugInfoSection(
              logs: _debugLogs,
              onClear: () => setState(_debugLogs.clear),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Node Control Page 子组件 ───────────────────────────────────────────────────

class _ProxyStatusChip extends StatelessWidget {
  const _ProxyStatusChip({required this.state, required this.isReady});

  final MeshConnectionState state;
  final bool isReady;

  @override
  Widget build(BuildContext context) {
    if (isReady) {
      return const Chip(
        avatar: Icon(Icons.check_circle, size: 16, color: Colors.green),
        label: Text('就绪'),
        backgroundColor: Color(0xFFE8F5E9),
      );
    }
    return switch (state) {
      MeshConnectionState.connected => const Chip(
        avatar: Icon(Icons.bluetooth_connected, size: 16),
        label: Text('分发密钥中…'),
      ),
      MeshConnectionState.connecting => const Chip(
        avatar: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text('连接中…'),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _NodeInfoSection extends StatelessWidget {
  const _NodeInfoSection({required this.node});

  final MeshNode node;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(icon: Icons.info_outline, title: '节点信息'),
            const SizedBox(height: 12),
            _InfoRow(label: '名称', value: node.name),
            _InfoRow(label: '单播地址', value: node.hexAddress, mono: true),
            if (node.macAddress != null)
              _InfoRow(label: 'MAC 地址', value: node.macAddress!, mono: true),
            _InfoRow(label: '元素数量', value: '${node.elementCount}'),
            _InfoRow(label: 'AppKey 数量', value: '${node.appKeyIndexes.length}'),
            if (node.elements.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              _SectionHeader(icon: Icons.layers_outlined, title: '元素'),
              const SizedBox(height: 8),
              ...node.elements.map(
                (e) => _InfoRow(
                  label: '元素 0x${e.elementAddress.toRadixString(16).toUpperCase().padLeft(4, '0')}',
                  value: '${e.modelIds.length} 个模型',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProxySection extends StatelessWidget {
  const _ProxySection({
    required this.connState,
    required this.isDistributing,
    required this.isReady,
    required this.hasMac,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRedistribute,
  });

  final MeshConnectionState connState;
  final bool isDistributing;
  final bool isReady;
  final bool hasMac;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onRedistribute;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(icon: Icons.settings_ethernet, title: 'Proxy 代理'),
            const SizedBox(height: 12),
            _ProxyStatusRow(
              connState: connState,
              isDistributing: isDistributing,
              isReady: isReady,
            ),
            const SizedBox(height: 12),
            if (connState != MeshConnectionState.connected)
              FilledButton.icon(
                onPressed: hasMac &&
                        connState != MeshConnectionState.connecting
                    ? onConnect
                    : null,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('连接代理节点'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onDisconnect,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: const Text('断开'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isDistributing ? null : onRedistribute,
                      icon: const Icon(Icons.vpn_key_outlined),
                      label: const Text('重发密钥'),
                    ),
                  ),
                ],
              ),
            if (!hasMac) ...[
              const SizedBox(height: 8),
              Text(
                '⚠️ 未缓存 MAC 地址（应用重启后丢失），请重新配网',
                style: TextStyle(fontSize: 12, color: cs.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProxyStatusRow extends StatelessWidget {
  const _ProxyStatusRow({
    required this.connState,
    required this.isDistributing,
    required this.isReady,
  });

  final MeshConnectionState connState;
  final bool isDistributing;
  final bool isReady;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, String text) = switch (true) {
      _ when isReady => (Icons.check_circle, Colors.green, '就绪，可发送控制消息'),
      _ when isDistributing => (
        Icons.sync,
        Colors.orange,
        '正在分发 AppKey 并绑定模型…',
      ),
      _ when connState == MeshConnectionState.connected => (
        Icons.bluetooth_connected,
        Colors.blue,
        '代理已连接，等待密钥分发',
      ),
      _ when connState == MeshConnectionState.connecting => (
        Icons.more_horiz,
        Colors.orange,
        '正在连接代理节点…',
      ),
      _ => (Icons.bluetooth_disabled, Colors.grey, '未连接代理'),
    };
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }
}

// ── 设备控制面板（按模型协议组织） ─────────────────────────────────────────────

/// 聚合所有 SIG / Vendor 模型控制区。
class _DeviceControlPanel extends StatelessWidget {
  const _DeviceControlPanel({
    required this.node,
    required this.mesh,
    required this.onInfo,
    required this.onError,
  });

  final MeshNode node;
  final BleMesh mesh;
  final ValueChanged<String> onInfo;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GenericOnOffSection(
          address: node.unicastAddress,
          mesh: mesh,
          onInfo: onInfo,
          onError: onError,
        ),
        const SizedBox(height: 12),
        _GenericLevelSection(
          address: node.unicastAddress,
          mesh: mesh,
          onInfo: onInfo,
          onError: onError,
        ),
        const SizedBox(height: 12),
        _SyncModelSection(
          node: node,
          mesh: mesh,
          onInfo: onInfo,
          onError: onError,
        ),
        const SizedBox(height: 12),
        _DeviceControlModelSection(
          address: node.unicastAddress,
          mesh: mesh,
          onInfo: onInfo,
          onError: onError,
        ),
      ],
    );
  }
}

// ── Generic OnOff Server（Model 0x1000）────────────────────────────────────────

class _GenericOnOffSection extends StatefulWidget {
  const _GenericOnOffSection({
    required this.address,
    required this.mesh,
    required this.onInfo,
    required this.onError,
  });

  final int address;
  final BleMesh mesh;
  final ValueChanged<String> onInfo;
  final ValueChanged<String> onError;

  @override
  State<_GenericOnOffSection> createState() => _GenericOnOffSectionState();
}

class _GenericOnOffSectionState extends State<_GenericOnOffSection> {
  bool _isOn = false;
  bool _isBusy = false;

  Future<void> _send(bool value) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      await widget.mesh.sendGenericOnOff(
        address: widget.address,
        onOff: value,
        acknowledged: false,
      );
      setState(() => _isOn = value);
      widget.onInfo(
        'Generic OnOff → ${value ? "ON" : "OFF"} '
        '(0x${widget.address.toRadixString(16)})',
      );
    } catch (e) {
      widget.onError('Generic OnOff 失败：$e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: Icons.toggle_on_outlined,
              title: 'Generic OnOff Server（0x1000）',
            ),
            const SizedBox(height: 4),
            Text(
              '通用开关模型',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开关状态'),
              subtitle: Text(_isOn ? '当前：开启' : '当前：关闭'),
              value: _isOn,
              onChanged: _isBusy ? null : _send,
            ),
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: '开启',
                    icon: Icons.lightbulb,
                    color: Colors.orange,
                    isActive: _isOn,
                    isBusy: _isBusy,
                    onPressed: () => _send(true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionButton(
                    label: '关闭',
                    icon: Icons.lightbulb_outline,
                    color: Colors.blueGrey,
                    isActive: !_isOn,
                    isBusy: _isBusy,
                    onPressed: () => _send(false),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Generic Level Server（Model 0x1002）────────────────────────────────────────

class _GenericLevelSection extends StatefulWidget {
  const _GenericLevelSection({
    required this.address,
    required this.mesh,
    required this.onInfo,
    required this.onError,
  });

  final int address;
  final BleMesh mesh;
  final ValueChanged<String> onInfo;
  final ValueChanged<String> onError;

  @override
  State<_GenericLevelSection> createState() => _GenericLevelSectionState();
}

class _GenericLevelSectionState extends State<_GenericLevelSection> {
  double _percent = 50;
  Timer? _levelDebounce;

  int _levelFromPercent(double percent) =>
      (percent / 100 * 32767).round().clamp(0, 32767);

  @override
  void dispose() {
    _levelDebounce?.cancel();
    super.dispose();
  }

  Future<void> _sendLevel(int level) async {
    try {
      await widget.mesh.sendGenericLevel(
        address: widget.address,
        level: level,
        acknowledged: false,
      );
      widget.onInfo('Generic Level → $level (${_percent.round()}%)');
    } catch (e) {
      widget.onError('Generic Level 失败：$e');
    }
  }

  void _onPercentChanged(double percent) {
    setState(() => _percent = percent);
    _levelDebounce?.cancel();
    _levelDebounce = Timer(const Duration(milliseconds: 120), () {
      _sendLevel(_levelFromPercent(percent));
    });
  }

  void _onPercentChangeEnd(double percent) {
    _levelDebounce?.cancel();
    _sendLevel(_levelFromPercent(percent));
  }

  @override
  Widget build(BuildContext context) {
    final level = _levelFromPercent(_percent);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: Icons.tune,
              title: 'Generic Level Server（0x1002）',
            ),
            const SizedBox(height: 4),
            Text(
              '拖动滑块实时发送亮度（Level 0 ~ 32767）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _percent,
                    min: 0,
                    max: 100,
                    label: '${_percent.round()}%',
                    onChanged: _onPercentChanged,
                    onChangeEnd: _onPercentChangeEnd,
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    '$level\n${_percent.round()}%',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sync Group（Vendor 0x0002 发布/订阅，与固件 send_ble_mesh_sync_mode 一致）──

class _SyncModelSection extends StatefulWidget {
  const _SyncModelSection({
    required this.node,
    required this.mesh,
    required this.onInfo,
    required this.onError,
  });

  final MeshNode node;
  final BleMesh mesh;
  final ValueChanged<String> onInfo;
  final ValueChanged<String> onError;

  @override
  State<_SyncModelSection> createState() => _SyncModelSectionState();
}

class _SyncModelSectionState extends State<_SyncModelSection> {
  int _syncGroupAddress = kDefaultSyncGroupAddress;
  bool _isBusy = false;
  bool _syncModel0001 = true;
  bool _syncModel0002 = true;
  bool _syncSubscribe = false;
  bool _syncPublish = false;

  int get _elementAddress =>
      widget.node.primaryElement?.elementAddress ?? widget.node.unicastAddress;

  List<int> get _selectedSyncModelIds {
    final ids = <int>[];
    if (_syncModel0001) ids.add(kSyncModelCompoundId);
    if (_syncModel0002) ids.add(kDeviceControlModelCompoundId);
    return ids;
  }

  MeshModelMessagingMode _resolveSyncMode() {
    if (!_syncSubscribe && !_syncPublish) {
      return MeshModelMessagingMode.appKeyOnly;
    }
    if (_syncSubscribe && _syncPublish) {
      return MeshModelMessagingMode.subscribeAndPublish;
    }
    if (_syncSubscribe) return MeshModelMessagingMode.subscribeOnly;
    return MeshModelMessagingMode.publishOnly;
  }

  Future<void> _ensureSyncGroup() async {
    try {
      await widget.mesh.createGroup(
        name: 'Sync Group',
        address: _syncGroupAddress,
      );
    } catch (_) {
      // 组已存在时忽略
    }
  }

  Future<void> _applySyncConfiguration({MeshModelMessagingMode? mode}) async {
    if (_isBusy) return;
    final modelIds = _selectedSyncModelIds;
    if (modelIds.isEmpty) {
      widget.onError('请至少选择一个 Vendor 模型（0x0001 或 0x0002）');
      return;
    }
    final resolvedMode = mode ?? _resolveSyncMode();
    setState(() => _isBusy = true);
    try {
      if (resolvedMode.requiresGroupAddress) {
        await _ensureSyncGroup();
      }
      await widget.mesh.configureSyncModels(
        nodeAddress: widget.node.unicastAddress,
        mode: resolvedMode,
        modelIds: modelIds,
        syncGroupAddress: _syncGroupAddress,
        elementAddress: _elementAddress,
      );
      final modelLabel = modelIds
          .map((id) => '0x${(id & 0xFFFF).toRadixString(16).padLeft(4, '0')}')
          .join('、');
      final modeLabel = switch (resolvedMode) {
        MeshModelMessagingMode.appKeyOnly => '仅 Bind AppKey',
        MeshModelMessagingMode.subscribeOnly => '订阅',
        MeshModelMessagingMode.publishOnly => '发布',
        MeshModelMessagingMode.subscribeAndPublish => '订阅+发布',
      };
      final groupLabel = resolvedMode.requiresGroupAddress
          ? ' → 0x${_syncGroupAddress.toRadixString(16).toUpperCase()}'
          : '';
      widget.onInfo('Sync 已配置：$modelLabel，$modeLabel$groupLabel');
    } catch (e) {
      widget.onError('Sync 配置失败：$e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _configureAsMaster() => _applySyncConfiguration(
        mode: MeshModelMessagingMode.publishOnly,
      );

  Future<void> _configureAsSlave() => _applySyncConfiguration(
        mode: MeshModelMessagingMode.subscribeOnly,
      );

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: Icons.sync,
              title: 'Sync Group（Vendor 0x0001 / 0x0002）',
            ),
            const SizedBox(height: 4),
            Text(
              '可选模型与订阅/发布；均不选时仅下发 AppKey Bind',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: const Text('0x0001'),
                  selected: _syncModel0001,
                  onSelected: _isBusy
                      ? null
                      : (v) => setState(() => _syncModel0001 = v),
                ),
                FilterChip(
                  label: const Text('0x0002'),
                  selected: _syncModel0002,
                  onSelected: _isBusy
                      ? null
                      : (v) => setState(() => _syncModel0002 = v),
                ),
                FilterChip(
                  label: const Text('订阅'),
                  selected: _syncSubscribe,
                  onSelected: _isBusy
                      ? null
                      : (v) => setState(() => _syncSubscribe = v),
                ),
                FilterChip(
                  label: const Text('发布'),
                  selected: _syncPublish,
                  onSelected: _isBusy
                      ? null
                      : (v) => setState(() => _syncPublish = v),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Sync Group：'),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: _syncGroupAddress,
                    items: const [
                      DropdownMenuItem(
                        value: 0xC000,
                        child: Text('0xC000（默认）'),
                      ),
                      DropdownMenuItem(
                        value: 0xC001,
                        child: Text('0xC001'),
                      ),
                      DropdownMenuItem(
                        value: 0xC002,
                        child: Text('0xC002'),
                      ),
                    ],
                    onChanged: _isBusy
                        ? null
                        : (v) {
                            if (v != null) setState(() => _syncGroupAddress = v);
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isBusy ? null : () => _applySyncConfiguration(),
                icon: const Icon(Icons.tune),
                label: const Text('应用 Sync 配置'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : _configureAsMaster,
                    icon: const Icon(Icons.upload),
                    label: const Text('快捷：主机（发布）'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : _configureAsSlave,
                    icon: const Icon(Icons.download),
                    label: const Text('快捷：从机（订阅）'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Vendor Model 0x0002 设备控制模型 ───────────────────────────────────────────

class _DeviceControlModelSection extends StatefulWidget {
  const _DeviceControlModelSection({
    required this.address,
    required this.mesh,
    required this.onInfo,
    required this.onError,
  });

  final int address;
  final BleMesh mesh;
  final ValueChanged<String> onInfo;
  final ValueChanged<String> onError;

  @override
  State<_DeviceControlModelSection> createState() =>
      _DeviceControlModelSectionState();
}

class _DeviceControlModelSectionState extends State<_DeviceControlModelSection> {
  MeshNodeRole _role = MeshNodeRole.slave;
  SourceType _sourceType = SourceType.sdCard;
  int _modeIndex = 1;
  double _speed = 5;
  double _brightness = 32768;
  bool _isBusy = false;

  Future<void> _setRole(MeshNodeRole role) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      await widget.mesh.setMasterSlaveRole(
        address: widget.address,
        role: role,
      );
      setState(() => _role = role);
      widget.onInfo(
        'OpCode 0x10 → ${role == MeshNodeRole.master ? "主机(0x01)" : "从机(0x02)"}',
      );
    } catch (e) {
      widget.onError('主从切换失败：$e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _sendPlayMode() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final config = PlayModeConfig(
        sourceType: _sourceType,
        modeIndex: _modeIndex,
        speed: _speed.round(),
        brightness: _brightness.round(),
      );
      await widget.mesh.setPlayMode(
        address: widget.address,
        config: config,
      );
      widget.onInfo(
        'OpCode 0x11 → ${config.toString()} '
        'payload=${config.toBytes().map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}',
      );
    } catch (e) {
      widget.onError('播放模式失败：$e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: Icons.extension_outlined,
              title: 'Vendor Model 0x0002（设备控制）',
            ),
            const SizedBox(height: 4),
            Text(
              'CID 0x02E5',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.outline,
              ),
            ),

            // OpCode 0x10
            const SizedBox(height: 16),
            const _SectionHeader(
              icon: Icons.swap_horiz,
              title: 'OpCode 0x10 — 主从机切换',
            ),
            const SizedBox(height: 8),
            SegmentedButton<MeshNodeRole>(
              segments: const [
                ButtonSegment(
                  value: MeshNodeRole.master,
                  label: Text('主机 0x01'),
                  icon: Icon(Icons.star),
                ),
                ButtonSegment(
                  value: MeshNodeRole.slave,
                  label: Text('从机 0x02'),
                  icon: Icon(Icons.star_border),
                ),
              ],
              selected: {_role},
              onSelectionChanged: _isBusy
                  ? null
                  : (roles) => _setRole(roles.first),
            ),

            // OpCode 0x11
            const SizedBox(height: 20),
            const _SectionHeader(
              icon: Icons.play_circle_outline,
              title: 'OpCode 0x11 — 播放模式切换',
            ),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '资源类型 (byte0)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<SourceType>(
                  isExpanded: true,
                  value: _sourceType,
                  items: const [
                DropdownMenuItem(
                  value: SourceType.sdCard,
                  child: Text('0x01 SD 卡资源'),
                ),
                DropdownMenuItem(
                  value: SourceType.algorithm,
                  child: Text('0x02 算法资源'),
                ),
              ],
              onChanged: _isBusy
                  ? null
                  : (v) {
                      if (v != null) setState(() => _sourceType = v);
                    },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('模式 index (byte1)'),
                const Spacer(),
                IconButton(
                  onPressed: _isBusy || _modeIndex <= 0
                      ? null
                      : () => setState(() => _modeIndex--),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text('$_modeIndex'),
                IconButton(
                  onPressed: _isBusy || _modeIndex >= 255
                      ? null
                      : () => setState(() => _modeIndex++),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('速度 (byte2)：${_speed.round()} / 10'),
            Slider(
              value: _speed,
              min: 1,
              max: 10,
              divisions: 9,
              label: '${_speed.round()}',
              onChanged: _isBusy ? null : (v) => setState(() => _speed = v),
            ),
            Text(
              '亮度 (byte3~4)：${_brightness.round()} / 65535',
            ),
            Slider(
              value: _brightness,
              min: 0,
              max: 65535,
              divisions: 100,
              label: '${_brightness.round()}',
              onChanged: _isBusy ? null : (v) => setState(() => _brightness = v),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isBusy ? null : _sendPlayMode,
                icon: _isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: const Text('发送播放模式'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 公共子组件 ────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ─── Group Test Page ────────────────────────────────────────────────────────────

/// 分组控制测试页：创建分组 → 节点订阅 → 组播控制。
class _GroupTestPage extends StatefulWidget {
  const _GroupTestPage({required this.initialConnState});

  final MeshConnectionState initialConnState;

  @override
  State<_GroupTestPage> createState() => _GroupTestPageState();
}

class _GroupTestPageState extends State<_GroupTestPage> {
  final _mesh = BleMesh();
  final List<_DebugLogEntry> _debugLogs = [];

  List<MeshNode> _nodes = [];
  final Set<int> _selectedNodes = {};
  MeshNode? _proxyNode;
  MeshConnectionState _connState = MeshConnectionState.disconnected;

  int _groupAddress = kDefaultControlGroupAddress;
  int _targetGroupAddress = 0xC002;
  final _groupNameController = TextEditingController(text: '控制组');
  final _targetGroupNameController = TextEditingController(text: '备用组');
  bool _groupReady = false;
  bool _subscribed = false;
  bool _isBusy = false;
  bool _groupOn = false;

  StreamSubscription<MeshConnectionState>? _connSub;
  StreamSubscription<BleMeshException>? _errSub;

  @override
  void initState() {
    super.initState();
    _connState = widget.initialConnState;
    _connSub = _mesh.connectionState.listen((s) {
      if (mounted) setState(() => _connState = s);
    });
    _errSub = _mesh.errors.listen(
      (e) => _log('[${e.code}] ${e.message}', isError: true),
    );
    _loadNodes();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _errSub?.cancel();
    _groupNameController.dispose();
    _targetGroupNameController.dispose();
    super.dispose();
  }

  Future<void> _loadNodes() async {
    try {
      final nodes = await _mesh.getNodes();
      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _selectedNodes
          ..clear()
          ..addAll(nodes.map((n) => n.unicastAddress));
        MeshNode? proxy;
        for (final n in nodes) {
          if (n.hasMacAddress) {
            proxy = n;
            break;
          }
        }
        _proxyNode = proxy ?? (nodes.isNotEmpty ? nodes.first : null);
      });
    } catch (e) {
      _log('加载节点失败：$e', isError: true);
    }
  }

  void _log(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _debugLogs.insert(
        0,
        _DebugLogEntry(time: DateTime.now(), message: message, isError: isError),
      );
      if (_debugLogs.length > 50) {
        _debugLogs.removeRange(50, _debugLogs.length);
      }
    });
  }

  Future<void> _ensureGroup() async {
    setState(() => _isBusy = true);
    try {
      final group = await _mesh.ensureGroup(
        name: _groupNameController.text.trim().isEmpty
            ? '控制组'
            : _groupNameController.text.trim(),
        address: _groupAddress,
      );
      setState(() => _groupReady = true);
      _log('分组已就绪：${group.name} ${group.hexAddress}');
    } catch (e) {
      _log('创建分组失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _connectProxy() async {
    final node = _proxyNode;
    if (node == null || !node.hasMacAddress) {
      _log('请选择有 MAC 缓存的 Proxy 节点', isError: true);
      return;
    }
    setState(() => _isBusy = true);
    try {
      await _mesh.connectToProxy(node.macAddress!);
      _log('Proxy 已连接 → ${node.name}');
    } catch (e) {
      _log('Proxy 连接失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _subscribeSelectedNodes() async {
    if (!_groupReady) {
      await _ensureGroup();
      if (!_groupReady) return;
    }
    if (_connState != MeshConnectionState.connected) {
      _log('请先连接 Proxy', isError: true);
      return;
    }
    if (_selectedNodes.isEmpty) {
      _log('请至少选择一个节点', isError: true);
      return;
    }

    setState(() {
      _isBusy = true;
      _subscribed = false;
    });
    try {
      _log(
        '开始订阅 ${_selectedNodes.length} 个节点 → '
        '0x${_groupAddress.toRadixString(16).toUpperCase()} '
        '(Generic OnOff 0x1000)',
      );
      for (final nodeAddress in _selectedNodes) {
        await _mesh.addModelSubscription(
          nodeAddress: nodeAddress,
          modelId: kGenericOnOffModelId,
          subscriptionAddress: _groupAddress,
        );
        if (nodeAddress != _selectedNodes.last) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
      setState(() => _subscribed = true);
      _log('全部节点已订阅分组，可发送组播控制');
    } catch (e) {
      _log('订阅失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _removeSelectedNodesFromGroup() async {
    if (_connState != MeshConnectionState.connected) {
      _log('请先连接 Proxy', isError: true);
      return;
    }
    if (_selectedNodes.isEmpty) {
      _log('请至少选择一个节点', isError: true);
      return;
    }

    setState(() => _isBusy = true);
    try {
      _log(
        '从 0x${_groupAddress.toRadixString(16).toUpperCase()} 移除 '
        '${_selectedNodes.length} 个节点订阅',
      );
      for (final nodeAddress in _selectedNodes) {
        await _mesh.removeModelSubscription(
          nodeAddress: nodeAddress,
          modelId: kGenericOnOffModelId,
          subscriptionAddress: _groupAddress,
        );
        if (nodeAddress != _selectedNodes.last) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
      setState(() => _subscribed = false);
      _log('已从当前组取消订阅');
    } catch (e) {
      _log('取消订阅失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _changeSelectedNodesGroup() async {
    if (_connState != MeshConnectionState.connected) {
      _log('请先连接 Proxy', isError: true);
      return;
    }
    if (_selectedNodes.isEmpty) {
      _log('请至少选择一个节点', isError: true);
      return;
    }
    if (_groupAddress == _targetGroupAddress) {
      _log('源组与目标组相同，无需换组', isError: true);
      return;
    }

    setState(() {
      _isBusy = true;
      _subscribed = false;
    });
    try {
      final fromHex =
          '0x${_groupAddress.toRadixString(16).toUpperCase()}';
      final toHex =
          '0x${_targetGroupAddress.toRadixString(16).toUpperCase()}';
      _log(
        '换组 ${_selectedNodes.length} 个节点：$fromHex → $toHex',
      );
      await _mesh.changeNodesGroup(
        nodeAddresses: _selectedNodes.toList(),
        fromGroupAddress: _groupAddress,
        toGroupAddress: _targetGroupAddress,
        modelId: kGenericOnOffModelId,
        targetGroupName: _targetGroupNameController.text.trim().isEmpty
            ? 'Group $toHex'
            : _targetGroupNameController.text.trim(),
      );
      setState(() {
        _groupAddress = _targetGroupAddress;
        _groupReady = true;
        _subscribed = true;
      });
      _log('换组完成，当前控制组为 $toHex');
    } catch (e) {
      _log('换组失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _sendGroupOnOff(bool on) async {
    if (_connState != MeshConnectionState.connected) {
      _log('请先连接 Proxy', isError: true);
      return;
    }
    if (!_subscribed) {
      _log('请先完成节点订阅', isError: true);
      return;
    }
    setState(() => _isBusy = true);
    try {
      await _mesh.sendGenericOnOff(
        address: _groupAddress,
        onOff: on,
        acknowledged: false,
      );
      setState(() => _groupOn = on);
      _log(
        '组播 Generic OnOff → ${on ? "ON" : "OFF"} '
        '0x${_groupAddress.toRadixString(16).toUpperCase()}',
      );
    } catch (e) {
      _log('组播控制失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groupHex =
        '0x${_groupAddress.toRadixString(16).padLeft(4, '0').toUpperCase()}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('分组控制测试'),
        actions: [
          _ConnectionChip(state: _connState),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '1. 创建分组',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _groupNameController,
                    decoration: const InputDecoration(
                      labelText: '分组名称',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _groupAddress,
                    decoration: const InputDecoration(
                      labelText: '组播地址',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: kDefaultControlGroupAddress,
                        child: Text('0xC001 控制组'),
                      ),
                      DropdownMenuItem(
                        value: kDefaultSyncGroupAddress,
                        child: Text('0xC000 Sync Group'),
                      ),
                      DropdownMenuItem(
                        value: 0xC002,
                        child: Text('0xC002'),
                      ),
                    ],
                    onChanged: _isBusy
                        ? null
                        : (v) {
                            if (v != null) {
                              setState(() {
                                _groupAddress = v;
                                _groupReady = false;
                                _subscribed = false;
                              });
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _isBusy ? null : _ensureGroup,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(_groupReady ? '分组已创建 $groupHex' : '创建分组'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '2. 连接 Proxy',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  if (_nodes.isEmpty)
                    const Text('暂无节点，请先配网设备')
                  else
                    DropdownButtonFormField<MeshNode>(
                      value: _proxyNode,
                      decoration: const InputDecoration(
                        labelText: 'Proxy 节点',
                        border: OutlineInputBorder(),
                      ),
                      items: _nodes
                          .map(
                            (n) => DropdownMenuItem(
                              value: n,
                              child: Text(
                                '${n.name} ${n.hexAddress}'
                                '${n.hasMacAddress ? '' : ' (无MAC)'}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _isBusy
                          ? null
                          : (n) => setState(() => _proxyNode = n),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isBusy ? null : _connectProxy,
                          icon: const Icon(Icons.bluetooth_connected),
                          label: const Text('连接 Proxy'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isBusy
                              ? null
                              : () async {
                                  await _mesh.disconnectFromProxy();
                                  _log('Proxy 已断开');
                                },
                          icon: const Icon(Icons.bluetooth_disabled),
                          label: const Text('断开'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '3. 将设备加入分组（订阅 Generic OnOff）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '勾选要加入 $groupHex 的节点，然后点击订阅',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._nodes.map(
                    (node) => CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(node.name),
                      subtitle: Text(node.hexAddress),
                      value: _selectedNodes.contains(node.unicastAddress),
                      onChanged: _isBusy
                          ? null
                          : (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedNodes.add(node.unicastAddress);
                                } else {
                                  _selectedNodes.remove(node.unicastAddress);
                                }
                                _subscribed = false;
                              });
                            },
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _isBusy ? null : _subscribeSelectedNodes,
                    icon: const Icon(Icons.group_add_outlined),
                    label: Text(
                      _subscribed ? '已订阅，可重新配置' : '订阅选中节点到分组',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '4. 换组 / 取消订阅',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '将设备从当前组 $groupHex 移到目标组，或仅从当前组移除',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _targetGroupNameController,
                    decoration: const InputDecoration(
                      labelText: '目标分组名称（换组时自动创建）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _targetGroupAddress,
                    decoration: const InputDecoration(
                      labelText: '目标组播地址',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: kDefaultControlGroupAddress,
                        child: Text('0xC001 控制组'),
                      ),
                      DropdownMenuItem(
                        value: kDefaultSyncGroupAddress,
                        child: Text('0xC000 Sync Group'),
                      ),
                      DropdownMenuItem(
                        value: 0xC002,
                        child: Text('0xC002'),
                      ),
                      DropdownMenuItem(
                        value: 0xC003,
                        child: Text('0xC003'),
                      ),
                    ],
                    onChanged: _isBusy
                        ? null
                        : (v) {
                            if (v != null) {
                              setState(() => _targetGroupAddress = v);
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _isBusy ? null : _removeSelectedNodesFromGroup,
                          icon: const Icon(Icons.group_remove_outlined),
                          label: const Text('从当前组移除'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isBusy ? null : _changeSelectedNodesGroup,
                          icon: const Icon(Icons.swap_horiz),
                          label: const Text('换到目标组'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '5. 组播控制（所有订阅设备应同时响应）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('组开关'),
                    subtitle: Text(_groupOn ? '组状态：开启' : '组状态：关闭'),
                    value: _groupOn,
                    onChanged: _isBusy ? null : _sendGroupOnOff,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: '组开启',
                          icon: Icons.power_settings_new,
                          color: cs.primary,
                          isActive: _groupOn,
                          isBusy: _isBusy,
                          onPressed: () => _sendGroupOnOff(true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ActionButton(
                          label: '组关闭',
                          icon: Icons.power_off,
                          color: cs.outline,
                          isActive: !_groupOn,
                          isBusy: _isBusy,
                          onPressed: () => _sendGroupOnOff(false),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _DebugInfoSection(
            logs: _debugLogs,
            onClear: () => setState(_debugLogs.clear),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outline),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: mono ? 'monospace' : null,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.isActive,
    required this.isBusy,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool isActive;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: isActive ? color : null,
        foregroundColor: isActive ? Colors.white : color,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      onPressed: isBusy ? null : onPressed,
      icon: isBusy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: isActive ? Colors.white : color,
              ),
            )
          : Icon(icon),
      label: Text(label),
    );
  }
}
