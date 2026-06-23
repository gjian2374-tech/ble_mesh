part of 'main.dart';

// ─── Node Control Page ────────────────────────────────────────────────────────

/// 节点控制页：设备信息、元素模型列表、模型配置与底部连接管理。
class _NodeControlPage extends StatefulWidget {
  const _NodeControlPage({
    super.key,
    required this.node,
    this.initialConnState = MeshConnectionState.disconnected,
    this.autoConnectProxy = false,
  });

  final MeshNode node;
  final MeshConnectionState initialConnState;
  final bool autoConnectProxy;

  @override
  State<_NodeControlPage> createState() => _NodeControlPageState();
}

class _NodeControlPageState extends State<_NodeControlPage> {
  final _mesh = BleMesh();

  late MeshConnectionState _connState;
  MeshNode? _localNode;
  MeshNode? _reportedNode;
  MeshNetworkInfo? _networkInfo;
  List<MeshGroup> _groups = [];
  bool _loadingModels = false;
  String? _modelsError;
  bool _busyFooter = false;
  bool _busyProxy = false;

  StreamSubscription<MeshConnectionState>? _connSub;
  StreamSubscription<MeshConfigurationStatus>? _configSub;
  StreamSubscription<void>? _networkUpdatedSub;

  @override
  void initState() {
    super.initState();
    _connState = widget.initialConnState;
    _connSub = _mesh.connectionState.listen((s) {
      if (mounted) setState(() => _connState = s);
    });
    _configSub = _mesh.configurationState.listen((status) {
      if (status.unicastAddress == widget.node.unicastAddress &&
          status.state == MeshConfigurationState.complete) {
        _refreshModels();
      }
    });
    _networkUpdatedSub = _mesh.networkUpdated.listen((_) => _loadLocalNode());
    _loadMeta();
    _loadLocalNode();
    if (widget.autoConnectProxy && widget.node.hasMacAddress) {
      Future<void>.delayed(const Duration(seconds: 2), _connectProxySilently);
    }
  }

  MeshNode get _displayNode =>
      _reportedNode ?? _localNode ?? widget.node;

  Future<void> _loadLocalNode() async {
    try {
      final node = await _mesh.getNodeByAddress(widget.node.unicastAddress);
      if (mounted && node != null) {
        setState(() => _localNode = node);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _configSub?.cancel();
    _networkUpdatedSub?.cancel();
    super.dispose();
  }

  Future<void> _connectProxySilently() async {
    await _connectProxy(silent: true);
  }

  Future<void> _connectProxy({bool silent = false}) async {
    final mac = widget.node.macAddress;
    if (mac == null) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('无 MAC 地址，请返回主页重新扫描连接'),
          ),
        );
      }
      return;
    }
    if (_busyProxy || _connState == MeshConnectionState.connecting) return;

    setState(() => _busyProxy = true);
    try {
      await _mesh.connectToProxy(mac);
      if (!mounted) return;
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Proxy 已连接')),
        );
      }
      await _loadLocalNode();
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Proxy 连接失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyProxy = false);
    }
  }

  Future<void> _loadMeta() async {
    try {
      final info = await _mesh.getNetworkInfo();
      final groups = await _mesh.getGroups();
      if (mounted) {
        setState(() {
          _networkInfo = info;
          _groups = groups;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshModels() async {
    if (_connState != MeshConnectionState.connected) return;
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final mac = widget.node.macAddress;
      if (mac != null) {
        final ready = await _mesh.isProxyReady(mac);
        if (!ready) {
          throw const NotConnectedException();
        }
      }
      final reported = await _mesh.fetchReportedModels(
        widget.node.unicastAddress,
      );
      if (mounted) {
        setState(() => _reportedNode = reported);
        await _loadLocalNode();
      }
    } on BleMeshException catch (e) {
      if (mounted) setState(() => _modelsError = '[${e.code}] ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _modelsError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _openModelSettings(MeshElement element, int modelId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ModelSettingsPage(
          node: _localNode ?? widget.node,
          element: element,
          modelId: modelId,
          groups: _groups,
          appKeys: _networkInfo?.appKeys ?? const [],
          nodeAppKeyIndexes: widget.node.appKeyIndexes,
        ),
      ),
    );
  }

  Future<void> _disconnect() async {
    setState(() => _busyFooter = true);
    try {
      await _mesh.disconnectFromProxy();
      if (mounted) {
        setState(() {
          _connState = MeshConnectionState.disconnected;
          _reportedNode = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('断开失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyFooter = false);
    }
  }

  Future<void> _resetDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备重置'),
        content: Text(
          '将向 ${widget.node.name} 发送 Config Node Reset 并从网络中移除，'
          '此操作不可撤销。',
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
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busyFooter = true);
    try {
      await _mesh.deleteNode(widget.node.unicastAddress);
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备已重置并从网络移除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重置失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyFooter = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final appKeyLabel = widget.node.appKeyIndexes.isEmpty
        ? '（未绑定）'
        : widget.node.appKeyIndexes
            .map((i) => '#$i')
            .join(', ');

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.node.name),
        actions: [
          IconButton(
            tooltip: '刷新模型',
            onPressed: _loadingModels ? null : _refreshModels,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshModels,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── 上：设备信息 ──
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader(
                            icon: Icons.devices,
                            title: '设备信息',
                          ),
                          const SizedBox(height: 12),
                          _InfoRow(label: '设备名称', value: widget.node.name),
                          _InfoRow(
                            label: '设备地址',
                            value: widget.node.hexAddress,
                            mono: true,
                          ),
                          _InfoRow(
                            label: 'Device Key',
                            value: widget.node.deviceKey ?? '（不可见）',
                            mono: true,
                          ),
                          _InfoRow(label: 'AppKey', value: appKeyLabel),
                          if (_networkInfo != null &&
                              _networkInfo!.appKeys.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            const Divider(height: 1),
                            const SizedBox(height: 8),
                            Text(
                              '网络 AppKey',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const SizedBox(height: 4),
                            ..._networkInfo!.appKeys.map(
                              (k) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '#${k.index} ${k.name} · ${k.keyHex}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── 自定义效果（共用 Proxy GATT，无需二次连接）──
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _SectionHeader(
                            icon: Icons.palette_outlined,
                            title: '自定义效果',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '在已建立的 Proxy 连接上通过自定义 GATT 特征下发 bin，'
                            '无需断开 Mesh 再连普通蓝牙。',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => _CustomEffectPreviewPage(
                                    node: widget.node,
                                    connState: _connState,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('效果预览'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── 中：元素与模型 ──
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SectionHeader(
                            icon: Icons.layers_outlined,
                            title: '元素与模型',
                          ),
                          const SizedBox(height: 8),
                          if (_connState != MeshConnectionState.connected)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    _connState == MeshConnectionState.connecting
                                        ? 'Proxy 连接中…'
                                        : 'Proxy 未连接（isConnected=false），'
                                            '请连接后再配置模型',
                                    style: TextStyle(
                                      color: cs.error,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton.icon(
                                    onPressed: _busyProxy ||
                                            _connState ==
                                                MeshConnectionState.connecting ||
                                            !widget.node.hasMacAddress
                                        ? null
                                        : _connectProxy,
                                    icon: _busyProxy ||
                                            _connState ==
                                                MeshConnectionState.connecting
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.bluetooth_connected),
                                    label: Text(
                                      _connState ==
                                              MeshConnectionState.connecting
                                          ? '连接中…'
                                          : '连接 Proxy',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (_loadingModels)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: CircularProgressIndicator(),
                              ),
                            )
                          else if (_modelsError != null)
                            Text(
                              _modelsError!,
                              style: TextStyle(color: cs.error),
                            )
                          else if (_displayNode.elements.isEmpty)
                            Text(
                              '暂无模型数据，连接 Proxy 后点刷新',
                              style: TextStyle(color: cs.outline),
                            )
                          else
                            ..._displayNode.elements.map((element) {
                              return _ElementModelsBlock(
                                element: element,
                                onModelTap: (modelId) =>
                                    _openModelSettings(element, modelId),
                              );
                            }),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 下：断开 / 重置 ──
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_connState == MeshConnectionState.connected)
                    OutlinedButton.icon(
                      onPressed: _busyFooter ? null : _disconnect,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: const Text('断开连接'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busyFooter ||
                              _busyProxy ||
                              _connState == MeshConnectionState.connecting ||
                              !widget.node.hasMacAddress
                          ? null
                          : _connectProxy,
                      icon: _busyProxy ||
                              _connState == MeshConnectionState.connecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bluetooth_connected),
                      label: Text(
                        _connState == MeshConnectionState.connecting
                            ? '连接中…'
                            : '连接 Proxy',
                      ),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                    ),
                    onPressed: _busyFooter ? null : _resetDevice,
                    icon: _busyFooter
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.restart_alt),
                    label: const Text('设备重置'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ElementModelsBlock extends StatelessWidget {
  const _ElementModelsBlock({
    required this.element,
    required this.onModelTap,
  });

  final MeshElement element;
  final ValueChanged<int> onModelTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            '元素 ${element.hexAddress}',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ),
        if (element.modelIds.isEmpty)
          Text('（无模型）', style: TextStyle(color: cs.outline, fontSize: 13))
        else
          ...element.modelIds.map((modelId) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.memory_outlined, color: cs.primary),
              title: Text(_modelDisplayName(modelId)),
              subtitle: Text(
                '0x${modelId.toRadixString(16).toUpperCase()}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onModelTap(modelId),
            );
          }),
        const Divider(height: 16),
      ],
    );
  }
}

// ─── Model Settings Page ──────────────────────────────────────────────────────

class _ModelSettingsPage extends StatefulWidget {
  const _ModelSettingsPage({
    required this.node,
    required this.element,
    required this.modelId,
    required this.groups,
    required this.appKeys,
    required this.nodeAppKeyIndexes,
  });

  final MeshNode node;
  final MeshElement element;
  final int modelId;
  final List<MeshGroup> groups;
  final List<MeshKeyInfo> appKeys;
  final List<int> nodeAppKeyIndexes;

  @override
  State<_ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class _ModelSettingsPageState extends State<_ModelSettingsPage> {
  final _mesh = BleMesh();

  late int _appKeyIndex;
  int? _selectedPublishAddress;
  int? _selectedSubscribeAddress;
  bool _busy = false;

  List<MeshKeyInfo> get _appKeyOptions =>
      _uniqueAppKeyOptions(widget.appKeys, widget.nodeAppKeyIndexes);

  List<MeshGroup> get _uniqueGroups => _uniqueGroupsByAddress(widget.groups);

  @override
  void initState() {
    super.initState();
    _appKeyIndex = _initialAppKeyIndex(_appKeyOptions, widget.nodeAppKeyIndexes);
    _loadPersistedModelState();
  }

  Future<void> _loadPersistedModelState() async {
    try {
      final node = await _mesh.getNodeByAddress(widget.node.unicastAddress);
      if (!mounted || node == null) return;

      final groups = _uniqueGroups.isNotEmpty
          ? _uniqueGroups
          : _uniqueGroupsByAddress(await _mesh.getGroups());

      final element = node.elements.firstWhere(
        (e) => e.elementAddress == widget.element.elementAddress,
        orElse: () => widget.element,
      );
      final config = element.configForModel(widget.modelId);
      if (config == null) return;

      int? publish;
      if (config.publishAddress >= 0xC000 &&
          config.publishAddress <= 0xFEFF &&
          groups.any((g) => g.address == config.publishAddress)) {
        publish = config.publishAddress;
      }

      int? subscribe;
      for (final addr in config.subscriptionAddresses) {
        if (addr >= 0xC000 &&
            addr <= 0xFEFF &&
            groups.any((g) => g.address == addr)) {
          subscribe = addr;
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        _selectedPublishAddress = publish;
        _selectedSubscribeAddress = subscribe;
      });
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _ModelSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final options = _appKeyOptions;
    if (!options.any((k) => k.index == _appKeyIndex)) {
      _appKeyIndex = _initialAppKeyIndex(options, widget.nodeAppKeyIndexes);
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label 成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label 失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyPublish({required bool clear}) async {
    if (clear) {
      await _run('清除发布', () async {
        await _mesh.setModelPublication(
          nodeAddress: widget.node.unicastAddress,
          modelId: widget.modelId,
          publishAddress: 0,
          appKeyIndex: _appKeyIndex,
        );
      });
      if (mounted) setState(() => _selectedPublishAddress = null);
      return;
    }
    final addr = _selectedPublishAddress;
    if (addr == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择发布分组')),
      );
      return;
    }
    await _run('配置发布', () async {
      await _mesh.setModelPublication(
        nodeAddress: widget.node.unicastAddress,
        modelId: widget.modelId,
        publishAddress: addr,
        appKeyIndex: _appKeyIndex,
      );
    });
  }

  Future<void> _addSubscription() async {
    final addr = _selectedSubscribeAddress;
    if (addr == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择订阅分组')),
      );
      return;
    }
    await _run('添加订阅', () async {
      await _mesh.addModelSubscription(
        nodeAddress: widget.node.unicastAddress,
        modelId: widget.modelId,
        subscriptionAddress: addr,
      );
    });
  }

  Future<void> _clearSubscription() async {
    final addr = _selectedSubscribeAddress;
    if (addr == null) return;
    await _run('清除订阅', () async {
      await _mesh.removeModelSubscription(
        nodeAddress: widget.node.unicastAddress,
        modelId: widget.modelId,
        subscriptionAddress: addr,
      );
    });
    if (mounted) setState(() => _selectedSubscribeAddress = null);
  }

  Widget _buildGroupDropdown({
    required String label,
    required int? value,
    required ValueChanged<int?> onChanged,
  }) {
    final groups = _uniqueGroups;
    final effectiveValue = value != null &&
            groups.any((g) => g.address == value)
        ? value
        : null;

    return DropdownButtonFormField<int?>(
      value: effectiveValue,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      hint: Text(groups.isEmpty ? '暂无分组' : '（未选择）'),
      items: groups
          .map(
            (g) => DropdownMenuItem<int?>(
              value: g.address,
              child: Text('${g.name}'),
            ),
          )
          .toList(),
      onChanged: groups.isEmpty ? null : onChanged,
    );
  }

  Future<void> _bindAppKey() async {
    await _run('AppKey 绑定', () async {
      await _mesh.configureModel(
        nodeAddress: widget.node.unicastAddress,
        modelId: widget.modelId,
        mode: MeshModelMessagingMode.appKeyOnly,
        appKeyIndex: _appKeyIndex,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final modelHex =
        '0x${widget.modelId.toRadixString(16).toUpperCase()}';

    return Scaffold(
      appBar: AppBar(
        title: Text(_modelDisplayName(widget.modelId)),
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoRow(
                      label: '元素',
                      value: widget.element.hexAddress,
                      mono: true,
                    ),
                    _InfoRow(label: '模型 ID', value: modelHex, mono: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // AppKey 绑定
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionHeader(
                      icon: Icons.vpn_key_outlined,
                      title: 'AppKey 绑定',
                    ),
                    const SizedBox(height: 12),
                    if (_appKeyOptions.isEmpty)
                      const Text('暂无可用 AppKey')
                    else
                      DropdownButtonFormField<int>(
                        value: _appKeyOptions
                                .any((k) => k.index == _appKeyIndex)
                            ? _appKeyIndex
                            : _appKeyOptions.first.index,
                        decoration: const InputDecoration(
                          labelText: '选择 AppKey',
                          border: OutlineInputBorder(),
                        ),
                        items: _appKeyOptions
                            .map(
                              (k) => DropdownMenuItem(
                                value: k.index,
                                child: Text('#${k.index} ${k.name}'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _appKeyIndex = v);
                        },
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _bindAppKey,
                        child: const Text('绑定 AppKey 到模型'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Publish
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionHeader(
                      icon: Icons.publish_outlined,
                      title: 'Publish 发布',
                    ),
                    const SizedBox(height: 12),
                    _buildGroupDropdown(
                      label: '发布分组',
                      value: _selectedPublishAddress,
                      onChanged: (v) =>
                          setState(() => _selectedPublishAddress = v),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _applyPublish(clear: true),
                            child: const Text('清除发布'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _applyPublish(clear: false),
                            child: const Text('应用发布'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Subscriptions
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionHeader(
                      icon: Icons.subscriptions_outlined,
                      title: 'Subscriptions 订阅',
                    ),
                    const SizedBox(height: 12),
                    _buildGroupDropdown(
                      label: '订阅分组',
                      value: _selectedSubscribeAddress,
                      onChanged: (v) =>
                          setState(() => _selectedSubscribeAddress = v),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _clearSubscription,
                            child: const Text('清除订阅'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: _addSubscription,
                            child: const Text('添加订阅'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 操作
            _ModelOperationsCard(
              targetAddress: widget.element.elementAddress,
              modelId: widget.modelId,
              appKeyIndex: _appKeyIndex,
              mesh: _mesh,
              busy: _busy,
              onBusyChanged: (v) => setState(() => _busy = v),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelOperationsCard extends StatefulWidget {
  const _ModelOperationsCard({
    required this.targetAddress,
    required this.modelId,
    required this.appKeyIndex,
    required this.mesh,
    required this.busy,
    required this.onBusyChanged,
  });

  final int targetAddress;
  final int modelId;
  final int appKeyIndex;
  final BleMesh mesh;
  final bool busy;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<_ModelOperationsCard> createState() => _ModelOperationsCardState();
}

class _ModelOperationsCardState extends State<_ModelOperationsCard> {
  bool _onOff = false;
  double _level = 0;
  final _vendorOpcodeController = TextEditingController();
  final _vendorDataController = TextEditingController();

  @override
  void dispose() {
    _vendorOpcodeController.dispose();
    _vendorDataController.dispose();
    super.dispose();
  }

  int get _sigModelId => widget.modelId > 0xFFFF
      ? widget.modelId & 0xFFFF
      : widget.modelId;

  bool get _isVendorModel => widget.modelId > 0xFFFF;

  bool get _hasOps =>
      _sigModelId == 0x1000 ||
      _sigModelId == 0x1002 ||
      _isVendorModel;

  Future<void> _sendVendorMessage() async {
    final opCode = _parseHexInt(_vendorOpcodeController.text);
    if (opCode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('操作码格式无效')),
      );
      return;
    }
    List<int> payload;
    try {
      payload = _parseHexBytes(_vendorDataController.text);
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('数据格式无效：${e.message}')),
        );
      }
      return;
    }

    final companyId = (widget.modelId >> 16) & 0xFFFF;
    final modelId = widget.modelId & 0xFFFF;

    widget.onBusyChanged(true);
    try {
      await widget.mesh.sendVendorMessage(
        address: widget.targetAddress,
        companyId: companyId,
        modelId: modelId,
        opCode: opCode,
        payload: payload,
        appKeyIndex: widget.appKeyIndex,
        acknowledged: false,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已发送 Op=0x${opCode.toRadixString(16).toUpperCase()} '
              'Data=0x${_vendorDataController.text.toUpperCase()}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：$e')),
        );
      }
    } finally {
      widget.onBusyChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasOps) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: Icons.play_arrow_outlined,
              title: '模型操作',
            ),
            const SizedBox(height: 12),
            if (_sigModelId == 0x1000) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Generic OnOff'),
                value: _onOff,
                onChanged: widget.busy
                    ? null
                    : (v) async {
                        widget.onBusyChanged(true);
                        try {
                          await widget.mesh.sendGenericOnOff(
                            address: widget.targetAddress,
                            onOff: v,
                            appKeyIndex: widget.appKeyIndex,
                            acknowledged: true,
                          );
                          setState(() => _onOff = v);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('发送失败：$e')),
                            );
                          }
                        } finally {
                          widget.onBusyChanged(false);
                        }
                      },
              ),
            ],
            if (_sigModelId == 0x1002) ...[
              Text('Generic Level：${_level.round()}'),
              Text(
                '范围 -32768 ~ 32767',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              Slider(
                value: _level.clamp(-32768, 32767),
                min: -32768,
                max: 32767,
                label: '${_level.round()}',
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _level = v),
                onChangeEnd: widget.busy
                    ? null
                    : (v) async {
                        widget.onBusyChanged(true);
                        try {
                          final level = v.round().clamp(-32768, 32767);
                          setState(() => _level = level.toDouble());
                          await widget.mesh.sendGenericLevel(
                            address: widget.targetAddress,
                            level: level,
                            appKeyIndex: widget.appKeyIndex,
                            acknowledged: true,
                          );
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('发送失败：$e')),
                            );
                          }
                        } finally {
                          widget.onBusyChanged(false);
                        }
                      },
              ),
            ],
            if (_isVendorModel) ...[
              TextField(
                controller: _vendorOpcodeController,
                enabled: !widget.busy,
                decoration: const InputDecoration(
                  labelText: '操作码',
                  prefixText: '0x',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace'),
                keyboardType: TextInputType.text,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _vendorDataController,
                enabled: !widget.busy,
                decoration: const InputDecoration(
                  labelText: '数据',
                  prefixText: '0x',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace'),
                keyboardType: TextInputType.text,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: widget.busy ? null : _sendVendorMessage,
                  child: const Text('发送 Vendor 消息'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatHexAddress(int address) =>
    '0x${address.toRadixString(16).toUpperCase().padLeft(4, '0')}';

int? _parseHexInt(String text) {
  final hex = text.trim().toLowerCase().replaceFirst('0x', '');
  if (hex.isEmpty) return null;
  return int.tryParse(hex, radix: 16);
}

List<int> _parseHexBytes(String text) {
  final hex = text
      .trim()
      .toLowerCase()
      .replaceFirst('0x', '')
      .replaceAll(RegExp(r'[\s:]'), '');
  if (hex.isEmpty) return const [];
  if (hex.length.isOdd) {
    throw FormatException('十六进制字节数必须为偶数位');
  }
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

List<MeshKeyInfo> _uniqueAppKeyOptions(
  List<MeshKeyInfo> networkKeys,
  List<int> nodeIndexes,
) {
  final byIndex = <int, MeshKeyInfo>{};
  for (final key in networkKeys) {
    byIndex.putIfAbsent(key.index, () => key);
  }
  for (final index in nodeIndexes) {
    byIndex.putIfAbsent(
      index,
      () => MeshKeyInfo(
        index: index,
        name: 'AppKey #$index',
        keyHex: '',
      ),
    );
  }
  return byIndex.values.toList()..sort((a, b) => a.index.compareTo(b.index));
}

int _initialAppKeyIndex(
  List<MeshKeyInfo> options,
  List<int> nodeIndexes,
) {
  if (options.isEmpty) return 0;
  for (final index in nodeIndexes) {
    if (options.any((k) => k.index == index)) return index;
  }
  return options.first.index;
}

List<MeshGroup> _uniqueGroupsByAddress(List<MeshGroup> groups) {
  final byAddress = <int, MeshGroup>{};
  for (final group in groups) {
    byAddress.putIfAbsent(group.address, () => group);
  }
  return byAddress.values.toList()
    ..sort((a, b) => a.address.compareTo(b.address));
}

String _modelDisplayName(int modelId) {
  if (modelId > 0xFFFF) {
    final cid = (modelId >> 16) & 0xFFFF;
    final mid = modelId & 0xFFFF;
    if (cid == kVendorCompanyId) {
      return switch (mid) {
        0x0001 => 'Vendor Sync Model (0x0001)',
        0x0002 => 'Vendor Device Control (0x0002)',
        _ => 'Vendor Model 0x${mid.toRadixString(16).padLeft(4, '0')}',
      };
    }
    return 'Vendor CID=0x${cid.toRadixString(16)} '
        'Model=0x${mid.toRadixString(16).padLeft(4, '0')}';
  }
  return switch (modelId) {
    0x1000 => 'Generic OnOff Server',
    0x1001 => 'Generic OnOff Client',
    0x1002 => 'Generic Level Server',
    0x1003 => 'Generic Level Client',
    0x1203 => 'Scene Server',
    0x1300 => 'Light Lightness Server',
    _ => 'SIG Model',
  };
}

// ─── 自定义效果预览（GATT bin 下发）──────────────────────────────────────────

/// 固件自定义 Service / 特征 UUID（请按实际固件文档修改）。
///
/// 下方为 Nordic UART Service 示例，便于用 nRF Connect 验证通道。
abstract final class _CustomBleUuids {
  static const service = '0xFFF0'; // 自定义服务 UUID
  static const write = '0xFFF2'; // 写入特征
  static const notify = '0xFFF1'; // 通知特征
}

/// 效果预览 bin（80 字节，与固件协议一致）。
Uint8List _demoEffectBinPayload() {
  return Uint8List.fromList(_kEffectPreviewBin);
}

const _kEffectPreviewBin = <int>[
  0x03, 0x00, 0x00, 0xff, 0xff, 0x03, 0x10, 0x00, 0x04,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00,
  0xff, 0x00, 0xeb,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x94, 0x00, 0xf1,
  0x00, 0xc3,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x2c, 0x00, 0xd5,
  0x00, 0x80,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x5d, 0x00, 0x5d,
  0x00, 0xe3,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

class _CustomEffectPreviewPage extends StatefulWidget {
  const _CustomEffectPreviewPage({
    required this.node,
    required this.connState,
  });

  final MeshNode node;
  final MeshConnectionState connState;

  @override
  State<_CustomEffectPreviewPage> createState() =>
      _CustomEffectPreviewPageState();
}

class _CustomEffectPreviewPageState extends State<_CustomEffectPreviewPage> {
  final _mesh = BleMesh();

  bool _channelConfigured = false;
  bool _customReady = false;
  bool _transferring = false;
  double _progress = 0;
  String? _status;
  String? _lastNotifyHex;

  StreamSubscription<bool>? _readySub;
  StreamSubscription<CustomBleTransferProgress>? _progressSub;
  StreamSubscription<Uint8List>? _notifySub;

  @override
  void initState() {
    super.initState();
    _readySub = _mesh.customBleChannelReady.listen((ready) {
      if (mounted) setState(() => _customReady = ready);
    });
    _progressSub = _mesh.customBleTransferProgress.listen((p) {
      if (mounted) {
        setState(() => _progress = p.fraction);
      }
    });
    _notifySub = _mesh.customBleDataReceived.listen((data) {
      if (mounted) {
        setState(() {
          _lastNotifyHex = data
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ');
        });
      }
    });
    _setupChannel();
  }

  Future<void> _setupChannel() async {
    try {
      await _mesh.configureCustomBleChannel(
        serviceUuid: _CustomBleUuids.service,
        writeCharacteristicUuid: _CustomBleUuids.write,
        notifyCharacteristicUuid: _CustomBleUuids.notify,
      );
      final ready = await _mesh.isCustomBleReady();
      if (mounted) {
        setState(() {
          _channelConfigured = true;
          _customReady = ready;
          _status = ready ? '自定义通道已就绪' : '等待 GATT 发现自定义特征…';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = '配置失败：$e');
    }
  }

  Future<bool> _ensureCustomReady() async {
    if (widget.connState != MeshConnectionState.connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先连接 Proxy')),
        );
      }
      return false;
    }
    if (!_customReady) {
      final ready = await _mesh.isCustomBleReady();
      if (!ready) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('自定义 BLE 通道未就绪，请确认固件 UUID 与 Service'),
            ),
          );
        }
        return false;
      }
      if (mounted) setState(() => _customReady = true);
    }
    return true;
  }

  /// 经自定义 GATT 写特征下发单字节操作码（如固件定义 0x01=开灯）。
  Future<void> _sendCustomOpcode(int opcode, String label) async {
    if (!await _ensureCustomReady()) return;
    setState(() => _status = '正在发送 $label (0x${opcode.toRadixString(16).padLeft(2, '0')})…');
    try {
      await _mesh.writeCustomBleData(Uint8List.fromList([opcode]));
      if (mounted) {
        setState(() => _status = '已发送 $label');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已通过自定义 GATT 发送 $label')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '发送失败：$e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：$e')),
        );
      }
    }
  }

  Future<void> _preview() async {
    if (!await _ensureCustomReady()) return;

    setState(() {
      _transferring = true;
      _progress = 0;
      _status = '正在下发 bin…';
    });
    try {
      await _mesh.transferCustomBleData(_demoEffectBinPayload());
      if (mounted) {
        setState(() => _status = '预览数据已下发');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('bin 数据已通过自定义 GATT 下发')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '下发失败：$e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下发失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  @override
  void dispose() {
    _readySub?.cancel();
    _progressSub?.cancel();
    _notifySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('自定义效果预览')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设备：${widget.node.name}'),
                  const SizedBox(height: 4),
                  Text(
                    'Proxy：${widget.connState.name}',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Service\n${_CustomBleUuids.service}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  Text(
                    'Write\n${_CustomBleUuids.write}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status ??
                        (_channelConfigured
                            ? (_customReady ? '通道就绪' : '等待通道就绪…')
                            : '正在配置通道…'),
                  ),
                  if (_transferring) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 4),
                    Text('${(_progress * 100).toStringAsFixed(0)}%'),
                  ],
                  if (_lastNotifyHex != null) ...[
                    const SizedBox(height: 12),
                    Text('Notify 收到：$_lastNotifyHex'),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionHeader(
                    icon: Icons.toggle_on_outlined,
                    title: '单字节操作码（自定义 GATT）',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '走自定义写特征，单包下发；不限于 80 字节 bin。'
                    '具体含义由固件定义（示例：0x01 开灯）。',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _transferring
                              ? null
                              : () => _sendCustomOpcode(0x01, '开灯'),
                          child: const Text('开灯 0x01'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _transferring
                              ? null
                              : () => _sendCustomOpcode(0x00, '关灯'),
                          child: const Text('关灯 0x00'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _transferring ? null : _preview,
            icon: _transferring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(_transferring ? '下发中…' : '预览并下发 bin'),
          ),
        ],
      ),
    );
  }
}
