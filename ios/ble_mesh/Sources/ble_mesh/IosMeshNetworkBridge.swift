import CoreBluetooth
import Foundation
import NordicMesh

// MARK: - 桥接层主类

/// iOS 端 Nordic Mesh 网络桥接层。
///
/// 负责：网络持久化、PB-GATT 配网、Proxy 传输层对接、
/// 通过 Nordic 加密栈发送 / 接收所有 Mesh 控制消息。
final class IosMeshNetworkBridge: NSObject {

    // MARK: - 属性

    let meshManager: MeshNetworkManager
    private let sendEvent: ([String: Any?]) -> Void

    // -- 配网 --
    private var activeProvisioningManager: ProvisioningManager?
    private var activeProvisioningBearer: PBGattBearer?
    private var activeProvisioningDelegate: MeshProvisioningDelegateBridge?
    private var provisioningSemaphore: DispatchSemaphore?
    private var provisioningError: Error?
    private var provisioningPeripheralId: String?

    // -- Proxy 传输层（SAR 重组） --
    private var sarBuffer = Data()
    private var sarType: UInt8 = 0
    /// 当前 GATT 会话是否已收到 Secure Network Beacon（断连后须重新等待）。
    private var proxyBeaconReceivedForCurrentSession = false

    // -- 配网后自动配置（对齐 Android autoDistributeAppKey） --
    private static let sigModelsToBind: [UInt16] = [0x1000, 0x1002]
    private static let vendorModelsToBind: [(UInt16, UInt16)] = [
        (0x02E5, 0x0001), // Sync Model
        (0x02E5, 0x0002), // Device Control Model
    ]
    private var pendingProxyInitializationAddresses = Set<UInt16>()
    private var proxyInitializationInProgress = false

    // -- 外设缓存 --
    private var peripheralIdByNodeKey: [String: String] = [:]

    /// 配网完成后请求 Proxy 重连的回调（传入外设 UUID）。
    var onProxyConnectRequested: ((String) -> Void)?

    // MARK: - 初始化

    init(sendEvent: @escaping ([String: Any?]) -> Void) {
        self.sendEvent = sendEvent
        meshManager = MeshNetworkManager(
            using: LocalStorage(fileName: "ble_mesh_network.json")
        )
        super.init()
        meshManager.delegate = self
    }

    func initialize() throws {
        MeshLog.d("initialize: 开始加载 Mesh 网络")
        meshManager.localElements = []
        if try meshManager.load() {
            try ensureDefaultAppKey()
            MeshLog.d("initialize: 已加载现有网络")
            sendEvent(["type": "networkLoaded"])
            return
        }
        _ = meshManager.createNewMeshNetwork(
            withName: "Mesh Network",
            by: "nRF Mesh Provisioner"
        )
        meshManager.localElements = []
        try ensureDefaultAppKey()
        _ = meshManager.save()
        sendEvent(["type": "networkLoaded"])
    }

    // MARK: - Proxy 传输层

    /// 当 GATT Proxy Data Out 通知使能成功时由 BleMeshPlugin 调用。
    ///
    /// BleMeshPlugin 本身实现 Nordic `Transmitter` 协议，通过 Data In 特征写数据。
    func notifyProxyConnected(transmitter: Transmitter) {
        resetProxySessionState()
        meshManager.transmitter = transmitter
        MeshLog.d("Proxy 已连接，Transmitter 已注入 Nordic 加密栈")
    }

    /// 当 Proxy GATT 断连时由 BleMeshPlugin 调用。
    func notifyProxyDisconnected() {
        meshManager.transmitter = nil
        resetProxySessionState()
        // 清除 proxyNetworkKey / proxy 地址 / filter，避免重连后沿用已删除节点的陈旧状态。
        meshManager.proxyFilter.proxyDidDisconnect()
        MeshLog.d("Proxy 已断开，已重置 Proxy Filter 会话状态")
    }

    private func resetProxySessionState() {
        sarBuffer = Data()
        sarType = 0
        proxyBeaconReceivedForCurrentSession = false
    }

    /// 处理从 Data Out 特征收到的原始 GATT Proxy PDU（含 SAR 重组）。
    func handleProxyData(_ raw: Data) {
        guard !raw.isEmpty else { return }
        let header  = raw[0]
        let sar     = (header >> 6) & 0x03   // bits 7-6
        let typeRaw = header & 0x3F           // bits 5-0
        let payload = Data(raw.dropFirst())
        MeshLog.d(
            "PROXY",
            "DataOut SAR=\(sar) type=\(typeRaw) len=\(raw.count) "
                + "payload=\(payload.count)"
        )

        switch sar {
        case 0x00:
            deliverToStack(payload, type: typeRaw)
        case 0x01:
            sarBuffer = payload
            sarType   = typeRaw
        case 0x02:
            sarBuffer.append(payload)
        case 0x03:
            sarBuffer.append(payload)
            deliverToStack(sarBuffer, type: sarType)
            sarBuffer = Data()
        default:
            break
        }
    }

    private func deliverToStack(_ data: Data, type typeRaw: UInt8) {
        guard let pduType = PduType(rawValue: typeRaw) else { return }
        if pduType == .meshBeacon {
            proxyBeaconReceivedForCurrentSession = true
        }
        meshManager.bearerDidDeliverData(data, ofType: pduType)
    }

    // MARK: - 配网

    /// 配网前清理：关闭残留 PB-GATT 连接、移除同 UUID 旧节点。
    func prepareForProvisioning(uuid hexUuid: String) {
        logNetworkState("配网前")
        closeActiveProvisioningBearer(reason: "prepareForProvisioning")

        guard meshManager.isNetworkCreated,
              let network = meshManager.meshNetwork,
              let deviceUuid = UUID(meshHexString: hexUuid) else { return }

        if let existing = network.node(withUuid: deviceUuid),
           existing.uuid != network.localProvisioner?.uuid {
            MeshLog.d(
                "PROVISION",
                "移除同 UUID 旧节点 0x\(String(format: "%04X", existing.primaryUnicastAddress)) uuid=\(hexUuid.prefix(8))…"
            )
            network.remove(node: existing)
            pendingProxyInitializationAddresses.remove(existing.primaryUnicastAddress)
            removePeripheralCache(for: existing)
            _ = meshManager.save()
            logNetworkState("移除旧节点后")
            logAddressAvailability(label: "移除旧节点后")
        }
    }

    func provisionDevice(
        uuid hexUuid: String,
        peripheralId: String,
        nodeName: String?,
        peripheral: CBPeripheral
    ) throws {
        guard meshManager.isNetworkCreated,
              let network = meshManager.meshNetwork else {
            throw MeshBridgeError.networkNotReady
        }
        guard let deviceUuid = UUID(meshHexString: hexUuid) else {
            throw MeshBridgeError.invalidUuid(hexUuid)
        }

        closeActiveProvisioningBearer(reason: "provisionDevice 开始")

        provisioningError = nil
        provisioningPeripheralId = peripheralId
        registerPeripheralId(peripheralId, forMeshUuid: hexUuid)
        MeshLog.d("provisionDevice: uuid=\(hexUuid) peripheral=\(peripheralId)")
        sendEvent(["type": "provisioningStateChanged", "state": "connecting", "uuid": hexUuid])

        MeshLog.d("PROVISION", "创建 UnprovisionedDevice uuid=\(hexUuid)")
        let unprovisioned = NordicMesh.UnprovisionedDevice(
            name: nodeName ?? peripheral.name,
            uuid: deviceUuid
        )
        let bearer = PBGattBearer(target: peripheral)
        bearer.dataDelegate = meshManager
        bearer.delegate = self
        activeProvisioningBearer = bearer

        MeshLog.d("PROVISION", "创建 ProvisioningManager…")
        let manager = try meshManager.provision(
            unprovisionedDevice: unprovisioned,
            over: bearer
        )
        let delegate = MeshProvisioningDelegateBridge(
            bridge: self,
            hexUuid: hexUuid,
            manager: manager,
            bearer: bearer
        )
        activeProvisioningDelegate = delegate
        manager.delegate = delegate
        manager.networkKey = network.networkKeys.first

        // 不预分配单播地址：等 capabilities 后由 Nordic 用 nextAvailableUnicastAddress
        // 自动跳过 exclusion list 中已删除节点占用的地址（避免重配网 0x0002 冲突）。
        activeProvisioningManager = manager
        logAddressAvailability(label: "配网前")

        let sem = DispatchSemaphore(value: 0)
        provisioningSemaphore = sem
        MeshLog.d(
            "PROVISION",
            "peripheral.state=\(peripheral.state.rawValue) "
                + "(0=disconnected 1=connecting 2=connected) "
                + "Plugin 与 PBGattBearer 使用不同 Central，需确保无残留 PB-GATT 连接"
        )
        MeshLog.d("PROVISION", "PBGattBearer.open()…")
        bearer.open()

        if sem.wait(timeout: .now() + 120) == .timedOut {
            MeshLog.e("PROVISION", "配网超时 120s")
            cleanupProvisioning()
            throw MeshBridgeError.provisioningTimeout
        }
        if let error = provisioningError {
            MeshLog.e("PROVISION", "配网错误: \(error.localizedDescription)")
            cleanupProvisioning()
            throw error
        }
        MeshLog.d("PROVISION", "配网流程结束，清理 bearer")
        cleanupProvisioning()
    }

    fileprivate func completeProvisioning(hexUuid: String, peripheralId: String, node: Node) {
        MeshLog.d("配网完成: 0x\(String(format: "%04X", node.primaryUnicastAddress))")
        _ = meshManager.save()
        sendEvent(["type": "provisioningStateChanged", "state": "complete", "uuid": hexUuid])
        sendEvent([
            "type": "configurationStateChanged",
            "unicastAddress": node.primaryUnicastAddress,
            "uuid": hexUuid,
            "state": "pendingProxy",
            "message": "配网完成，等待 Proxy 连接继续配置",
        ])
        sendEvent(["type": "nodeAdded",
                   "node": buildNodeMap(node: node, peripheralId: peripheralId)])
        sendEvent(["type": "networkUpdated"])
        pendingProxyInitializationAddresses.insert(node.primaryUnicastAddress)
        // 等待设备从 PB-GATT 切换到 Proxy 广播（对齐 Android 2.5s 延迟）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.onProxyConnectRequested?(peripheralId)
        }
    }

    fileprivate func failProvisioning(hexUuid: String, error: Error) {
        let nsError = error as NSError
        MeshLog.e(
            "PROVISION",
            "配网失败 uuid=\(hexUuid.prefix(8))… "
                + "domain=\(nsError.domain) code=\(nsError.code) "
                + "msg=\(error.localizedDescription)"
        )
        provisioningError = error
        sendEvent(["type": "provisioningStateChanged", "state": "failed", "uuid": hexUuid])
        sendEvent(["type": "error", "code": "PROVISIONING_FAILED",
                   "message": error.localizedDescription])
        provisioningSemaphore?.signal()
    }

    fileprivate func signalProvisioningDone() { provisioningSemaphore?.signal() }
    fileprivate func accessMeshNetwork() -> MeshNetwork? { meshManager.meshNetwork }
    fileprivate func closeProvisioningBearer(_ bearer: PBGattBearer) { try? bearer.close() }
    fileprivate var currentProvisioningPeripheralId: String? { provisioningPeripheralId }
    fileprivate func emitEvent(_ event: [String: Any?]) { sendEvent(event) }

    private func closeActiveProvisioningBearer(reason: String) {
        guard activeProvisioningBearer != nil else { return }
        MeshLog.d("PROVISION", "关闭 PBGattBearer (\(reason)) isOpen=\(activeProvisioningBearer?.isOpen ?? false)")
        activeProvisioningBearer?.delegate = nil
        try? activeProvisioningBearer?.close()
        activeProvisioningBearer = nil
        activeProvisioningManager = nil
        activeProvisioningDelegate = nil
    }

    private func cleanupProvisioning() {
        closeActiveProvisioningBearer(reason: "cleanupProvisioning")
        provisioningSemaphore = nil
        provisioningPeripheralId = nil
    }

    // MARK: - 配网后自动配置（对齐 Android onProxyConnected / autoDistributeAppKey）

    /// Proxy GATT 就绪后由 BleMeshPlugin 调用，执行完整配置序列。
    func onProxyConnected() {
        guard meshManager.transmitter != nil else {
            MeshLog.e("onProxyConnected: Transmitter 未就绪")
            return
        }
        guard !proxyInitializationInProgress else {
            MeshLog.d("onProxyConnected: 配置流程已在进行，跳过重复触发")
            return
        }

        let nodes = resolvePendingDeviceNodes()
        guard !nodes.isEmpty else {
            MeshLog.d("onProxyConnected: 无待配置节点")
            return
        }

        proxyInitializationInProgress = true
        MeshLog.d("onProxyConnected: 开始配置 \(nodes.count) 个节点")

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.proxyInitializationInProgress = false
                if !self.pendingProxyInitializationAddresses.isEmpty {
                    MeshLog.d(
                        "onProxyConnected: 队列仍有 "
                            + "\(self.pendingProxyInitializationAddresses.count) 个节点，继续配置"
                    )
                    self.onProxyConnected()
                }
            }

            let targetAddresses = nodes.map(\.primaryUnicastAddress)
            do {
                try await self.prepareProxyBeforeConfiguration(
                    targetAddresses: targetAddresses
                )
            } catch {
                MeshLog.e("PROXY", "Proxy 就绪失败: \(error.localizedDescription)")
                for node in nodes {
                    let addr = node.primaryUnicastAddress
                    self.sendEvent([
                        "type": "configurationStateChanged",
                        "unicastAddress": Int(addr),
                        "uuid": node.uuid.meshHexString,
                        "state": "failed",
                        "message": error.localizedDescription,
                    ])
                }
                return
            }

            for node in nodes {
                let addr = node.primaryUnicastAddress
                let uuid = node.uuid.meshHexString
                self.sendEvent([
                    "type": "configurationStateChanged",
                    "unicastAddress": Int(addr),
                    "uuid": uuid,
                    "state": "proxyConnected",
                    "message": "Proxy 已连接，开始下发配置消息",
                ])
                do {
                    try await self.autoDistributeAppKey(to: addr)
                    self.pendingProxyInitializationAddresses.remove(addr)
                    _ = self.meshManager.save()
                    self.sendEvent([
                        "type": "configurationStateChanged",
                        "unicastAddress": Int(addr),
                        "uuid": uuid,
                        "state": "complete",
                        "message": "Config AppKey Add / Model App Bind 已发送完成",
                    ])
                    self.sendEvent(["type": "networkUpdated"])
                    MeshLog.d("节点 0x\(String(format: "%04X", addr)) 配置完成")
                } catch {
                    self.sendEvent([
                        "type": "configurationStateChanged",
                        "unicastAddress": Int(addr),
                        "uuid": uuid,
                        "state": "failed",
                        "message": error.localizedDescription,
                    ])
                    self.sendEvent([
                        "type": "error",
                        "code": "CONFIGURATION_FAILED",
                        "message": "节点 0x\(String(format: "%04X", addr)) 配置失败: \(error.localizedDescription)",
                    ])
                    MeshLog.e("节点 0x\(String(format: "%04X", addr)) 配置失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Dart `distributeAppKey`：加入待配置队列并触发与 Android 等价的自动配置。
    func distributeAppKey(unicastAddress: UInt16, appKeyIndex: Int) {
        _ = appKeyIndex
        pendingProxyInitializationAddresses.insert(unicastAddress)
        if proxyInitializationInProgress {
            MeshLog.d(
                "distributeAppKey: 配置进行中，节点 0x\(String(format: "%04X", unicastAddress)) 已入队"
            )
            return
        }
        onProxyConnected()
    }

    /// 完整配置序列：Composition → AppKey Add → Model App Bind。
    private func autoDistributeAppKey(to unicastAddress: UInt16) async throws {
        guard let appKey = appKeyObject(at: 0) else {
            throw MeshBridgeError.networkNotReady
        }
        guard let networkKey = primaryNetworkKey() else {
            throw MeshBridgeError.networkNotReady
        }

        MeshLog.d("─── 开始向节点 0x\(String(format: "%04X", unicastAddress)) 分发 AppKey ───")
        try await Task.sleep(nanoseconds: 400_000_000)

        let response = try await sendConfigWithTimeout(
            ConfigCompositionDataGet(),
            to: unicastAddress,
            using: networkKey
        )
        guard let compositionStatus = response as? ConfigCompositionDataStatus,
              compositionStatus.page != nil else {
            throw MeshBridgeError.configFailed("Composition Data 响应无效")
        }

        // Nordic 会在收到 Composition Status 后异步写入 node.elements，轮询直到模型列表就绪。
        var bindTargets: [ModelBindTarget] = []
        for attempt in 1...10 {
            if let node = meshManager.meshNetwork?.node(withAddress: unicastAddress) {
                bindTargets = resolveModelBindTargets(from: node)
                if !bindTargets.isEmpty { break }
            }
            MeshLog.d(
                "GROUP",
                "等待 Composition 同步到 node.elements attempt=\(attempt)/10"
            )
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        MeshLog.d("Composition Data 获取成功，待绑定模型数=\(bindTargets.count)")
        if bindTargets.isEmpty {
            throw MeshBridgeError.configFailed(
                "Composition 后未解析到可绑定模型（Generic OnOff / Level / Vendor）"
            )
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        MeshLog.d("发送 ConfigAppKeyAdd → 0x\(String(format: "%04X", unicastAddress))")
        let appKeyStatus = try await sendConfigWithTimeout(
            ConfigAppKeyAdd(applicationKey: appKey),
            to: unicastAddress,
            using: networkKey
        )
        guard let status = appKeyStatus as? ConfigAppKeyStatus else {
            throw MeshBridgeError.configFailed("AppKey 添加失败：响应无效")
        }
        guard status.isSuccess || status.status == .keyIndexAlreadyStored else {
            throw MeshBridgeError.configFailed(
                "AppKey 添加失败 status=0x\(String(format: "%02X", status.status.rawValue))"
            )
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        for target in bindTargets {
            if isModelAlreadyBound(nodeAddress: unicastAddress, target: target, appKeyIndex: appKey.index) {
                MeshLog.d("GROUP", "跳过已绑定: \(target.label)")
                continue
            }
            MeshLog.d(target.label)
            let bind = DirectConfigModelAppBind(
                applicationKey: appKey,
                elementAddress: target.elementAddress,
                modelIdentifier: target.modelIdentifier,
                companyIdentifier: target.companyIdentifier
            )
            let bindStatus = try await sendConfigWithTimeout(
                bind,
                to: unicastAddress,
                using: networkKey
            )
            guard let modelStatus = bindStatus as? ConfigModelAppStatus,
                  isModelBindStatusAcceptable(modelStatus) else {
                let code = (bindStatus as? ConfigModelAppStatus).map {
                    String(format: "%02X", $0.status.rawValue)
                } ?? "??"
                throw MeshBridgeError.configFailed(
                    "模型绑定失败: \(target.label) status=0x\(code)"
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        MeshLog.d("─── AppKey 分发序列完成 ───")
    }

    /// 对齐 Android：优先处理显式队列；否则仅处理尚未添加 AppKey 的节点。
    private func resolvePendingDeviceNodes() -> [Node] {
        guard let network = meshManager.meshNetwork else { return [] }
        let provisionerUuid = network.localProvisioner?.uuid
        let queued = pendingProxyInitializationAddresses

        let deviceNodes: [Node]
        if !queued.isEmpty {
            deviceNodes = network.nodes.filter { node in
                queued.contains(node.primaryUnicastAddress) &&
                    (provisionerUuid == nil || node.uuid != provisionerUuid)
            }
        } else {
            deviceNodes = network.nodes.filter { node in
                guard provisionerUuid == nil || node.uuid != provisionerUuid else {
                    return false
                }
                return node.applicationKeys.isEmpty
            }
        }

        MeshLog.d(
            "resolvePendingDeviceNodes: count=\(deviceNodes.count) "
                + "queued=\(queued.map { String(format: "0x%04X", $0) }.joined(separator: ","))"
        )
        return deviceNodes
    }

    private struct ModelBindTarget {
        let elementAddress: UInt16
        let modelIdentifier: UInt16
        let companyIdentifier: UInt16?
        let label: String
    }

    private func resolveModelBindTargets(from node: Node) -> [ModelBindTarget] {
        var targets: [ModelBindTarget] = []
        for element in node.elements {
            let elementAddress = element.unicastAddress
            for model in element.models {
                if model.companyIdentifier == nil,
                   Self.sigModelsToBind.contains(model.modelIdentifier) {
                    targets.append(ModelBindTarget(
                        elementAddress: elementAddress,
                        modelIdentifier: model.modelIdentifier,
                        companyIdentifier: nil,
                        label: "绑定 SIG Model 0x\(String(format: "%04X", model.modelIdentifier)) @0x\(String(format: "%04X", elementAddress))"
                    ))
                } else if let cid = model.companyIdentifier {
                    for (vendorCid, vendorMid) in Self.vendorModelsToBind {
                        if cid == vendorCid && model.modelIdentifier == vendorMid {
                            targets.append(ModelBindTarget(
                                elementAddress: elementAddress,
                                modelIdentifier: vendorMid,
                                companyIdentifier: vendorCid,
                                label: "绑定 Vendor Model CID=0x\(String(format: "%04X", vendorCid)) Model=0x\(String(format: "%04X", vendorMid)) @0x\(String(format: "%04X", elementAddress))"
                            ))
                        }
                    }
                }
            }
        }
        return targets
    }

    private func isModelBindStatusAcceptable(_ status: ConfigModelAppStatus) -> Bool {
        status.isSuccess || status.status == .keyIndexAlreadyStored
    }

    private func isModelAlreadyBound(
        nodeAddress: UInt16,
        target: ModelBindTarget,
        appKeyIndex: KeyIndex
    ) -> Bool {
        guard let network = meshManager.meshNetwork,
              let node = network.node(withAddress: nodeAddress),
              let element = node.elements.first(where: {
                  $0.unicastAddress == target.elementAddress
              })
        else { return false }

        let model: Model?
        if let cid = target.companyIdentifier {
            model = element.models.first {
                $0.modelIdentifier == target.modelIdentifier &&
                    $0.companyIdentifier == cid
            }
        } else {
            model = element.models.first {
                $0.modelIdentifier == target.modelIdentifier &&
                    $0.companyIdentifier == nil
            }
        }
        return model?.boundApplicationKeys.contains(where: { $0.index == appKeyIndex }) == true
    }

    // MARK: - 模型配置（绑定 + 订阅）

    /// 发送 ConfigModelAppBind：绑定 AppKey 到节点的指定模型（等待 Status 响应）。
    func bindModelAppKey(
        nodeAddress: UInt16,
        elementAddress: UInt16,
        modelId: UInt32,
        appKeyIndex: Int
    ) async throws {
        guard meshManager.transmitter != nil else {
            throw MeshBridgeError.configFailed("Proxy 未连接，无法绑定 AppKey")
        }
        guard let appKey = appKeyObject(at: appKeyIndex) else {
            throw MeshBridgeError.configFailed("AppKey 未配置")
        }
        if isModelAlreadyBound(
            nodeAddress: nodeAddress,
            target: ModelBindTarget(
                elementAddress: elementAddress,
                modelIdentifier: UInt16(modelId & 0xFFFF),
                companyIdentifier: modelId > 0xFFFF
                    ? UInt16((modelId >> 16) & 0xFFFF) : nil,
                label: "bind-check"
            ),
            appKeyIndex: appKey.index
        ) {
            MeshLog.d("GROUP", "模型已绑定 AppKey，跳过 Bind")
            return
        }

        let isVendor = modelId > 0xFFFF
        let sigId = UInt16(modelId & 0xFFFF)
        let cid: UInt16? = isVendor ? UInt16((modelId >> 16) & 0xFFFF) : nil
        let bind = DirectConfigModelAppBind(
            applicationKey: appKey,
            elementAddress: elementAddress,
            modelIdentifier: sigId,
            companyIdentifier: cid
        )

        MeshLog.d(
            "GROUP",
            "发送 ConfigModelAppBind → node=0x\(String(format: "%04X", nodeAddress)) "
                + "model=0x\(String(format: "%04X", sigId))"
        )

        let response = try await meshManager.send(bind, to: nodeAddress)
        guard let status = response as? ConfigModelAppStatus,
              isModelBindStatusAcceptable(status) else {
            let code = (response as? ConfigModelAppStatus).map {
                String(format: "%02X", $0.status.rawValue)
            } ?? "??"
            throw MeshBridgeError.configFailed("模型绑定失败 status=0x\(code)")
        }
        _ = meshManager.save()
        MeshLog.d("GROUP", "ConfigModelAppBind 成功")
    }

    /// 发送 ConfigModelPublicationSet：配置模型发布地址（Sync Group 主机等）。
    func setModelPublication(
        nodeAddress: UInt16,
        elementAddress: UInt16,
        modelId: UInt32,
        publishAddress: UInt16,
        appKeyIndex: Int,
        publishTtl: Int,
        publishPeriod: Int
    ) async throws {
        guard meshManager.transmitter != nil else {
            throw MeshBridgeError.configFailed("Proxy 未连接，无法设置 Publication")
        }
        guard let network = meshManager.meshNetwork else {
            throw MeshBridgeError.networkNotReady
        }
        guard let appKey = appKeyObject(at: appKeyIndex) else {
            throw MeshBridgeError.configFailed("AppKey 未配置")
        }
        if publishAddress >= 0xC000 && publishAddress <= 0xFEFF {
            guard network.groups.contains(where: { $0.address.address == publishAddress }) else {
                throw MeshBridgeError.configFailed(
                    "分组 0x\(String(format: "%04X", publishAddress)) 不存在，请先 createGroup"
                )
            }
        }

        let isVendor = modelId > 0xFFFF
        let sigId = UInt16(modelId & 0xFFFF)
        let cid: UInt16? = isVendor ? UInt16((modelId >> 16) & 0xFFFF) : nil

        let periodSteps: UInt8
        let periodResolution: StepResolution
        if publishPeriod <= 0 {
            periodSteps = 0
            periodResolution = .hundredsOfMilliseconds
        } else if publishPeriod <= 6300 {
            periodSteps = UInt8(min(publishPeriod / 100, 63))
            periodResolution = .hundredsOfMilliseconds
        } else {
            let period = Publish.Period(TimeInterval(publishPeriod) / 1000.0)
            periodSteps = period.numberOfSteps
            periodResolution = period.resolution
        }

        let pub = DirectConfigModelPublicationSet(
            elementAddress: elementAddress,
            modelIdentifier: sigId,
            companyIdentifier: cid,
            publishAddress: publishAddress,
            appKeyIndex: appKey.index,
            ttl: UInt8(clamping: publishTtl),
            periodSteps: periodSteps,
            periodResolution: periodResolution
        )

        MeshLog.d(
            "GROUP",
            "发送 ConfigModelPublicationSet → node=0x\(String(format: "%04X", nodeAddress)) "
                + "model=0x\(String(format: "%04X", sigId)) "
                + "publish=0x\(String(format: "%04X", publishAddress)) "
                + "ttl=\(publishTtl) period=\(publishPeriod)"
        )

        let response = try await meshManager.send(pub, to: nodeAddress)
        guard let status = response as? ConfigModelPublicationStatus,
              status.isSuccess else {
            let code = (response as? ConfigModelPublicationStatus).map {
                String(format: "%02X", $0.status.rawValue)
            } ?? "??"
            throw MeshBridgeError.configFailed(
                "Publication Set 被拒绝 status=0x\(code)"
            )
        }
        _ = meshManager.save()
        MeshLog.d(
            "GROUP",
            "ConfigModelPublicationSet 成功 → 0x\(String(format: "%04X", publishAddress))"
        )
    }

    /// 发送 ConfigModelSubscriptionAdd：订阅模型到组地址（直接按地址，对齐 Android）。
    func addModelSubscription(
        nodeAddress: UInt16,
        elementAddress: UInt16,
        modelId: UInt32,
        subscriptionAddress: UInt16
    ) async throws {
        guard meshManager.transmitter != nil else {
            throw MeshBridgeError.configFailed("Proxy 未连接，无法下发订阅")
        }
        guard let network = meshManager.meshNetwork else {
            throw MeshBridgeError.networkNotReady
        }
        guard network.groups.contains(where: { $0.address.address == subscriptionAddress }) else {
            throw MeshBridgeError.configFailed(
                "分组 0x\(String(format: "%04X", subscriptionAddress)) 不存在，请先 createGroup"
            )
        }

        let isVendor = modelId > 0xFFFF
        let sigId = UInt16(modelId & 0xFFFF)
        let cid: UInt16? = isVendor ? UInt16((modelId >> 16) & 0xFFFF) : nil
        let sub = DirectConfigModelSubscriptionAdd(
            groupAddress: subscriptionAddress,
            elementAddress: elementAddress,
            modelIdentifier: sigId,
            companyIdentifier: cid
        )

        MeshLog.d(
            "GROUP",
            "发送 ConfigModelSubscriptionAdd → node=0x\(String(format: "%04X", nodeAddress)) "
                + "elem=0x\(String(format: "%04X", elementAddress)) "
                + "model=0x\(String(format: "%04X", sigId)) "
                + "group=0x\(String(format: "%04X", subscriptionAddress))"
        )

        let response = try await meshManager.send(sub, to: nodeAddress)
        guard let status = response as? ConfigModelSubscriptionStatus else {
            throw MeshBridgeError.configFailed("Subscription 响应无效")
        }
        guard status.isSuccess else {
            throw MeshBridgeError.configFailed(
                "Subscription 被拒绝 status=0x\(String(format: "%02X", status.status.rawValue))"
            )
        }
        _ = meshManager.save()
        MeshLog.d(
            "GROUP",
            "ConfigModelSubscriptionAdd 成功 node=0x\(String(format: "%04X", nodeAddress)) "
                + "→ group=0x\(String(format: "%04X", subscriptionAddress))"
        )
    }

    /// 发送 ConfigModelSubscriptionDelete：从组地址取消订阅（直接按地址，对齐 Android）。
    func removeModelSubscription(
        nodeAddress: UInt16,
        elementAddress: UInt16,
        modelId: UInt32,
        subscriptionAddress: UInt16
    ) async throws {
        guard meshManager.transmitter != nil else {
            throw MeshBridgeError.configFailed("Proxy 未连接，无法取消订阅")
        }

        let isVendor = modelId > 0xFFFF
        let sigId = UInt16(modelId & 0xFFFF)
        let cid: UInt16? = isVendor ? UInt16((modelId >> 16) & 0xFFFF) : nil
        let sub = DirectConfigModelSubscriptionDelete(
            groupAddress: subscriptionAddress,
            elementAddress: elementAddress,
            modelIdentifier: sigId,
            companyIdentifier: cid
        )

        MeshLog.d(
            "GROUP",
            "发送 ConfigModelSubscriptionDelete → node=0x\(String(format: "%04X", nodeAddress)) "
                + "elem=0x\(String(format: "%04X", elementAddress)) "
                + "model=0x\(String(format: "%04X", sigId)) "
                + "group=0x\(String(format: "%04X", subscriptionAddress))"
        )

        let response = try await meshManager.send(sub, to: nodeAddress)
        guard let status = response as? ConfigModelSubscriptionStatus else {
            throw MeshBridgeError.configFailed("Subscription Delete 响应无效")
        }
        guard status.isSuccess else {
            throw MeshBridgeError.configFailed(
                "Subscription Delete 被拒绝 status=0x\(String(format: "%02X", status.status.rawValue))"
            )
        }
        _ = meshManager.save()
        MeshLog.d(
            "GROUP",
            "ConfigModelSubscriptionDelete 成功 node=0x\(String(format: "%04X", nodeAddress)) "
                + "← group=0x\(String(format: "%04X", subscriptionAddress))"
        )
    }

    // MARK: - 控制消息

    /// 发送 Generic On/Off Set（加密）。
    func sendGenericOnOff(address: UInt16, onOff: Bool, appKeyIndex: Int, acknowledged: Bool) {
        MeshLog.d("sendGenericOnOff: 0x\(String(format: "%04X", address)) on=\(onOff)")
        guard let appKey = appKeyObject(at: appKeyIndex) else {
            sendEvent(["type": "error", "code": "NO_APP_KEY", "message": "AppKey 未配置"])
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                if acknowledged {
                    _ = try await self.meshManager.send(
                        GenericOnOffSet(onOff),
                        to: MeshAddress(address),
                        using: appKey
                    )
                } else {
                    try await self.meshManager.send(
                        GenericOnOffSetUnacknowledged(onOff),
                        to: MeshAddress(address),
                        using: appKey
                    )
                }
            } catch {
                self.sendEvent(["type": "error", "code": "SEND_FAILED",
                                "message": error.localizedDescription])
            }
        }
    }

    /// 发送 Generic Level Set（加密）。
    func sendGenericLevel(address: UInt16, level: Int, appKeyIndex: Int, acknowledged: Bool) {
        guard let appKey = appKeyObject(at: appKeyIndex) else {
            sendEvent(["type": "error", "code": "NO_APP_KEY", "message": "AppKey 未配置"])
            return
        }
        let lvl = Int16(clamping: level)
        Task { [weak self] in
            guard let self else { return }
            do {
                if acknowledged {
                    _ = try await self.meshManager.send(
                        GenericLevelSet(level: lvl),
                        to: MeshAddress(address),
                        using: appKey
                    )
                } else {
                    try await self.meshManager.send(
                        GenericLevelSetUnacknowledged(level: lvl),
                        to: MeshAddress(address),
                        using: appKey
                    )
                }
            } catch {
                self.sendEvent(["type": "error", "code": "SEND_FAILED",
                                "message": error.localizedDescription])
            }
        }
    }

    /// 发送 Vendor 模型消息（加密）。
    ///
    /// Nordic 3 字节 Vendor opCode 在 UInt32 中的布局：
    /// `opCode = (0xC0 | vendorOp) << 16 | CID_Lo << 8 | CID_Hi`
    func sendVendorMessage(
        address: UInt16,
        companyId: Int,
        opCode: Int,
        payload: Data,
        appKeyIndex: Int
    ) {
        guard let appKey = appKeyObject(at: appKeyIndex) else {
            sendEvent(["type": "error", "code": "NO_APP_KEY", "message": "AppKey 未配置"])
            return
        }
        let b0: UInt32 = UInt32((opCode & 0x3F) | 0xC0)
        let b1: UInt32 = UInt32(companyId & 0xFF)         // CID_Lo
        let b2: UInt32 = UInt32((companyId >> 8) & 0xFF)  // CID_Hi
        let fullOpCode = (b0 << 16) | (b1 << 8) | b2
        let msg = RawVendorMessage(
            opCode: fullOpCode,
            parameters: payload.isEmpty ? nil : payload
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.meshManager.send(
                    msg,
                    to: MeshAddress(address),
                    using: appKey
                )
            } catch {
                self.sendEvent(["type": "error", "code": "SEND_FAILED",
                                "message": error.localizedDescription])
            }
        }
    }

    // MARK: - 节点 / 网络 API

    func getNodes() -> [[String: Any?]] {
        guard let network = meshManager.meshNetwork else { return [] }
        let provisionerUuid = network.localProvisioner?.uuid
        return network.nodes
            .filter { node in
                guard let provisionerUuid else { return true }
                return node.uuid != provisionerUuid
            }
            .map { node in
                let key = node.uuid.meshHexString
                let pid = peripheralIdByNodeKey[key]
                    ?? peripheralIdByNodeKey[normalizeKey(key)]
                return buildNodeMap(node: node, peripheralId: pid)
            }
    }

    func getNetworkInfo() -> [String: Any] {
        guard let network = meshManager.meshNetwork else { return [:] }
        let provisioner = network.localProvisioner
        return [
            "networkId": network.uuid.uuidString,
            "name": network.meshName ?? "Mesh Network",
            "ivIndex": network.ivIndex.index,
            "ivUpdateActive": network.ivIndex.updateActive,
            "sequenceNumber": 0,
            "provisionerAddress": provisioner?.primaryUnicastAddress ?? 0,
            "networkKeys": network.networkKeys.map {
                ["index": $0.index, "name": $0.name,
                 "keyHex": $0.key.hexString, "phase": 0] as [String: Any]
            },
            "appKeys": network.applicationKeys.map {
                ["index": $0.index, "name": $0.name,
                 "keyHex": $0.key.hexString, "phase": 0] as [String: Any]
            },
            "nodeCount": network.nodes.count,
        ]
    }

    func exportNetworkJson() -> String {
        String(data: meshManager.export(), encoding: .utf8) ?? ""
    }

    func importNetworkJson(_ json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw MeshBridgeError.invalidImportJson
        }
        _ = try meshManager.import(from: data)
        meshManager.localElements = []
        try ensureDefaultAppKey()
        _ = meshManager.save()
        sendEvent(["type": "networkLoaded"])
        sendEvent(["type": "networkUpdated"])
    }

    // MARK: - 分组

    func getGroups() -> [[String: Any?]] {
        guard let network = meshManager.meshNetwork else { return [] }
        return network.groups.map { group in
            [
                "address": Int(group.address.address),
                "name": group.name,
                "parentAddress": group.parent.map { Int($0.address.address) },
            ] as [String: Any?]
        }
    }

    func createGroup(name: String, address: UInt16) throws {
        guard let network = meshManager.meshNetwork else {
            throw MeshBridgeError.networkNotReady
        }
        if network.groups.contains(where: { $0.address.address == address }) {
            MeshLog.d("GROUP", "分组已存在 0x\(String(format: "%04X", address))，跳过创建")
            return
        }
        let group = try Group(name: name, address: MeshAddress(address))
        try network.add(group: group)
        _ = meshManager.save()
        MeshLog.d("GROUP", "创建分组 \(name) 0x\(String(format: "%04X", address))")
        sendEvent(["type": "networkUpdated"])
    }

    func deleteGroup(address: UInt16) throws {
        guard let network = meshManager.meshNetwork,
              let group = network.groups.first(where: { $0.address.address == address }) else {
            return
        }
        try network.remove(group: group)
        _ = meshManager.save()
        MeshLog.d("GROUP", "删除分组 0x\(String(format: "%04X", address))")
        sendEvent(["type": "networkUpdated"])
    }

    /// 删除完成后释放 PB-GATT 等资源。
    func releaseAfterDelete() {
        closeActiveProvisioningBearer(reason: "deleteNode完成")
        proxyInitializationInProgress = false
        logNetworkState("delete释放后")
        logPeripheralCache("delete释放后")
    }

    /// 删除后验证本地 Nordic 网络是否已移除该节点。
    func logDeleteVerification(unicastAddress: UInt16, deletedUuid: String?) {
        guard let network = meshManager.meshNetwork else {
            MeshLog.e("DELETE", "验证失败: meshNetwork=nil")
            return
        }
        let byAddress = network.node(withAddress: unicastAddress) != nil
        var byUuid = false
        if let deletedUuid, let uuid = UUID(meshHexString: deletedUuid) {
            byUuid = network.node(withUuid: uuid) != nil
        }
        let visibleNodes = getNodes().count
        let allNodes = network.nodes.count
        let provisionerOnly = allNodes <= 1 && visibleNodes == 0
        MeshLog.d(
            "DELETE",
            "本地验证 addr=0x\(String(format: "%04X", unicastAddress)) "
                + "仍按地址存在=\(byAddress) 仍按UUID存在=\(byUuid) "
                + "network.nodes=\(allNodes) getNodes可见=\(visibleNodes) "
                + "仅Provisioner=\(provisionerOnly)"
        )
        if byAddress || byUuid {
            MeshLog.e("DELETE", "⚠️ 本地节点未清干净！请把此日志发出来")
        } else if provisionerOnly {
            MeshLog.d("DELETE", "✓ 本地网络已清空该节点（仅剩 Provisioner）")
        } else {
            MeshLog.d("DELETE", "✓ 本地已移除目标节点 network.nodes=\(allNodes)")
        }
    }

    func logPeripheralCache(_ label: String) {
        let entries = peripheralIdByNodeKey.map { key, pid in
            "\(key.prefix(8))…→\(pid.prefix(8))…"
        }
        MeshLog.d(
            "CACHE",
            "[\(label)] bridge.peripheralIdByNodeKey=\(peripheralIdByNodeKey.count) "
                + "pendingConfig=\(pendingProxyInitializationAddresses.map { String(format: "0x%04X", $0) })"
        )
        if !entries.isEmpty {
            MeshLog.d("CACHE", "[\(label)] bridge映射: \(entries.joined(separator: ", "))")
        }
    }

    /// 向设备发送 Config Node Reset 并从网络中移除节点（对齐 Android deleteNode）。
    func deleteNode(unicastAddress: UInt16, completion: @escaping (Error?) -> Void) {
        MeshLog.d("DELETE", "deleteNode 0x\(String(format: "%04X", unicastAddress)) transmitter=\(meshManager.transmitter != nil)")
        logPeripheralCache("deleteNode前")
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let network = self.meshManager.meshNetwork,
                      let node = network.node(withAddress: unicastAddress) else {
                    MeshLog.e("DELETE", "节点不存在 0x\(String(format: "%04X", unicastAddress))")
                    throw MeshBridgeError.configFailed("节点不存在")
                }
                let deletedUuid = node.uuid.meshHexString
                let deletedName = node.name ?? "nil"
                MeshLog.d(
                    "DELETE",
                    "删除前快照 uuid=\(deletedUuid) name=\(deletedName) "
                        + "network.nodes=\(network.nodes.count) getNodes=\(self.getNodes().count)"
                )
                if let provisionerUuid = network.localProvisioner?.uuid,
                   node.uuid == provisionerUuid {
                    throw MeshBridgeError.configFailed("不能删除本地 Provisioner 节点")
                }

                if self.meshManager.transmitter != nil {
                    MeshLog.d(
                        "DELETE",
                        "发送 ConfigNodeReset → 0x\(String(format: "%04X", unicastAddress)) "
                            + "（不等待响应，Reset 后设备会立即断连）"
                    )
                    let resetTask = Task {
                        do {
                            if let networkKey = self.primaryNetworkKey() {
                                let response = try await self.meshManager.send(
                                    ConfigNodeReset(),
                                    to: unicastAddress,
                                    using: networkKey
                                )
                                MeshLog.d("DELETE", "ConfigNodeReset 响应: \(type(of: response))")
                            } else {
                                MeshLog.e("DELETE", "无 NetworkKey，跳过 ConfigNodeReset")
                            }
                        } catch {
                            MeshLog.d(
                                "DELETE",
                                "ConfigNodeReset 结束: \(error.localizedDescription) "
                                    + "（设备 Reset 断连属正常现象）"
                            )
                        }
                    }
                    // 等待消息发出即可，不必等响应（Reset 后 Proxy 会立刻断连）
                    try await Task.sleep(nanoseconds: 600_000_000)
                    resetTask.cancel()
                } else {
                    MeshLog.e("DELETE", "Proxy/Transmitter 未连接，跳过 ConfigNodeReset（仅本地删除）")
                }

                MeshLog.d("DELETE", "执行 network.remove(node)…")
                network.remove(node: node)
                self.pendingProxyInitializationAddresses.remove(unicastAddress)
                self.removePeripheralCache(for: node)
                let saved = self.meshManager.save()
                MeshLog.d("DELETE", "meshManager.save()=\(saved)")

                self.logDeleteVerification(unicastAddress: unicastAddress, deletedUuid: deletedUuid)
                self.logNetworkState("删除后")
                self.logPeripheralCache("deleteNode后")
                self.sendEvent([
                    "type": "nodeDeleted",
                    "unicastAddress": Int(unicastAddress),
                    "uuid": deletedUuid,
                ])
                self.sendEvent(["type": "networkUpdated"])
                MeshLog.d("DELETE", "nodeDeleted 事件已发送 addr=0x\(String(format: "%04X", unicastAddress))")
                completion(nil)
            } catch {
                MeshLog.e("DELETE", "deleteNode 失败: \(error.localizedDescription)")
                self.sendEvent([
                    "type": "error",
                    "code": "DELETE_FAILED",
                    "message": error.localizedDescription,
                ])
                completion(error)
            }
        }
    }

    func registerPeripheralId(_ peripheralId: String, forMeshUuid hexUuid: String) {
        peripheralIdByNodeKey[normalizeKey(hexUuid)] = peripheralId
        peripheralIdByNodeKey[peripheralId.uppercased()] = peripheralId
    }

    /// 打印当前 Mesh 网络状态（调试用）。
    func logNetworkState(_ label: String) {
        guard let network = meshManager.meshNetwork else {
            MeshLog.d("NET", "[\(label)] meshNetwork=nil")
            return
        }
        let provisionerUuid = network.localProvisioner?.uuid.meshHexString ?? "nil"
        let nodeList = network.nodes.map { node in
            let isProv = node.uuid.meshHexString == provisionerUuid
            return "0x\(String(format: "%04X", node.primaryUnicastAddress))"
                + (isProv ? "(Provisioner)" : "")
                + " uuid=\(node.uuid.meshHexString.prefix(8))…"
        }
        MeshLog.d(
            "NET",
            "[\(label)] nodes=\(network.nodes.count) [\(nodeList.joined(separator: ", "))] "
                + "appKeys=\(network.applicationKeys.count) "
                + "transmitter=\(meshManager.transmitter != nil) "
                + "pendingConfig=\(pendingProxyInitializationAddresses.map { String(format: "0x%04X", $0) }) "
                + "nextAddr=\(nextAvailableAddressLabel(network: network))"
        )
    }

    /// 打印下一个可用单播地址（跳过 exclusion list 中已删除节点地址）。
    func logAddressAvailability(label: String) {
        guard let network = meshManager.meshNetwork else { return }
        MeshLog.d("NET", "[\(label)] nextAvailable=\(nextAvailableAddressLabel(network: network))")
    }

    private func nextAvailableAddressLabel(network: MeshNetwork) -> String {
        guard let provisioner = network.localProvisioner else { return "nil" }
        guard let addr = network.nextAvailableUnicastAddress(for: 1, elementsUsing: provisioner) else {
            return "无可用地址"
        }
        return "0x\(String(format: "%04X", addr))"
    }

    // MARK: - Private helpers

    private func ensureDefaultAppKey() throws {
        guard let network = meshManager.meshNetwork else { return }
        if !network.applicationKeys.isEmpty { return }
        let appKey = Data.random128BitKey()
        _ = try network.add(applicationKey: appKey, name: "Default App Key")
        _ = meshManager.save()
    }

    private func primaryNetworkKey() -> NetworkKey? {
        meshManager.meshNetwork?.networkKeys.first
    }

    /// 等待 Proxy 通过 Secure Network Beacon 完成 Filter 初始化（对齐 Nordic #689）。
    private func prepareProxyBeforeConfiguration(
        targetAddresses: [UInt16],
        timeout: TimeInterval = 12.0
    ) async throws {
        guard let networkKey = primaryNetworkKey() else {
            throw MeshBridgeError.networkNotReady
        }

        MeshLog.d("PROXY", "等待 Proxy 中继就绪（Network Beacon → Filter 同步）…")
        let deadline = Date().addingTimeInterval(timeout)
        var loggedWait = false
        var triedManualSetup = false
        let setupAfter = Date().addingTimeInterval(min(3.0, timeout * 0.5))
        while Date() < deadline {
            if isProxyRelayReady(networkKey: networkKey, targetAddresses: targetAddresses) {
                let proxyAddr = meshManager.proxyFilter.proxy.map {
                    String(format: "0x%04X", $0.primaryUnicastAddress)
                } ?? "nil"
                MeshLog.d(
                    "PROXY",
                    "Proxy 已就绪 proxy=\(proxyAddr) "
                        + "filterSize=\(meshManager.proxyFilter.addresses.count) "
                        + "beacon=\(proxyBeaconReceivedForCurrentSession)"
                )
                break
            }
            if !triedManualSetup, Date() >= setupAfter,
               let provisioner = meshManager.meshNetwork?.localProvisioner {
                triedManualSetup = true
                MeshLog.d("PROXY", "尝试手动 setup Proxy Filter（Provisioner 地址）")
                meshManager.proxyFilter.setup(for: provisioner)
            }
            if !loggedWait {
                MeshLog.d(
                    "PROXY",
                    "等待 Secure Network Beacon（自定义 GATT 需设备回传 Beacon 才能配置 Filter）"
                )
                loggedWait = true
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        guard isProxyRelayReady(networkKey: networkKey, targetAddresses: targetAddresses) else {
            throw MeshBridgeError.configFailed(
                "Proxy 未在 \(Int(timeout))s 内就绪：未收到 Network Beacon 或 Filter 未同步"
            )
        }

        for address in targetAddresses {
            meshManager.proxyFilter.add(address: address)
            MeshLog.d("PROXY", "Filter 添加目标地址 0x\(String(format: "%04X", address))")
        }
        try await Task.sleep(nanoseconds: 600_000_000)
    }

    private func isProxyRelayReady(
        networkKey: NetworkKey,
        targetAddresses: [UInt16] = []
    ) -> Bool {
        guard proxyBeaconReceivedForCurrentSession else { return false }
        guard let proxy = meshManager.proxyFilter.proxy,
              proxy.knows(networkKey: networkKey) else {
            return false
        }
        if !targetAddresses.isEmpty {
            return targetAddresses.contains(proxy.primaryUnicastAddress)
        }
        if let provisionerAddress = meshManager.meshNetwork?.localProvisioner?
            .primaryUnicastAddress {
            return meshManager.proxyFilter.addresses.contains(Address(provisionerAddress))
        }
        return true
    }

    private func sendConfigWithTimeout(
        _ message: AcknowledgedConfigMessage,
        to destination: Address,
        using networkKey: NetworkKey,
        timeout: TimeInterval = 12.0
    ) async throws -> ConfigResponse {
        try await withThrowingTaskGroup(of: ConfigResponse.self) { group in
            group.addTask {
                try await self.meshManager.send(
                    message,
                    to: destination,
                    using: networkKey
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MeshBridgeError.configFailed(
                    "\(type(of: message)) 超时（\(Int(timeout))s）"
                )
            }
            guard let result = try await group.next() else {
                throw MeshBridgeError.configFailed("配置消息无响应")
            }
            group.cancelAll()
            return result
        }
    }

    private func appKeyObject(at index: Int) -> ApplicationKey? {
        meshManager.meshNetwork?.applicationKeys.first { $0.index == index }
            ?? meshManager.meshNetwork?.applicationKeys.first
    }

    private func findModel(
        nodeAddress: UInt16,
        elementAddress: UInt16,
        modelId: UInt32
    ) -> Model? {
        guard let network = meshManager.meshNetwork,
              let node = network.nodes.first(where: {
                  $0.primaryUnicastAddress == nodeAddress
              }),
              let element = node.elements.first(where: {
                  $0.unicastAddress == elementAddress
              })
        else { return nil }

        let isVendor = modelId > 0xFFFF
        let sigId    = UInt16(modelId & 0xFFFF)
        let cid      = UInt16((modelId >> 16) & 0xFFFF)

        return isVendor
            ? element.models.first { $0.modelIdentifier == sigId && $0.companyIdentifier == cid }
            : element.models.first { $0.modelIdentifier == sigId && $0.companyIdentifier == nil }
    }

    private func buildNodeMap(node: Node, peripheralId: String?) -> [String: Any?] {
        let elements = node.elements.map { element in
            [
                "elementAddress": element.unicastAddress,
                "name": element.name ?? "Element",
                "modelIds": element.models.map { model -> Int in
                    if let cid = model.companyIdentifier {
                        return (Int(cid) << 16) | Int(model.modelIdentifier)
                    }
                    return Int(model.modelIdentifier)
                },
                "location": element.location.rawValue,
            ] as [String: Any]
        }
        let appKeyIndexes = node.elements.flatMap(\.models)
            .flatMap(\.boundApplicationKeys).map(\.index)
        return [
            "unicastAddress": node.primaryUnicastAddress,
            "name": node.name ?? "Node 0x\(String(format: "%04X", node.primaryUnicastAddress))",
            "uuid": node.uuid.meshHexString,
            "macAddress": peripheralId,
            "deviceKey": nil,
            "isOnline": true,
            "elements": elements,
            "appKeyIndexes": Array(Set(appKeyIndexes)).sorted(),
            "ttl": 5,
            "companyIdentifier": node.companyIdentifier,
            "productIdentifier": node.productIdentifier,
        ]
    }

    private func normalizeKey(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func removePeripheralCache(for node: Node) {
        let meshKey = normalizeKey(node.uuid.meshHexString)
        if let peripheralId = peripheralIdByNodeKey[meshKey] {
            peripheralIdByNodeKey.removeValue(forKey: peripheralId.uppercased())
            MeshLog.d("CACHE", "bridge 清除 peripheralId 映射 \(peripheralId.prefix(8))…")
        }
        peripheralIdByNodeKey.removeValue(forKey: meshKey)
        UserDefaults.standard.removeObject(forKey: "ble_mesh_periph_\(meshKey)")
        MeshLog.d("CACHE", "bridge 清除 UserDefaults ble_mesh_periph_\(meshKey.prefix(8))…")
    }
}

// MARK: - MeshNetworkDelegate

extension IosMeshNetworkBridge: MeshNetworkDelegate {

    func meshNetworkManager(
        _ manager: MeshNetworkManager,
        didReceiveMessage message: MeshMessage,
        sentFrom source: Address,
        to destination: MeshAddress
    ) {
        switch message {
        case let status as ConfigModelAppStatus:
            if status.isSuccess {
                MeshLog.d("ConfigModelAppStatus 成功: 0x\(String(format: "%04X", source))")
            } else {
                sendEvent(["type": "error", "code": "BIND_FAILED",
                           "message": "模型绑定失败"])
            }

        case let status as ConfigModelSubscriptionStatus:
            if status.isSuccess {
                MeshLog.d(
                    "GROUP",
                    "ConfigModelSubscriptionStatus 成功: 0x\(String(format: "%04X", source))"
                )
            } else {
                MeshLog.e("GROUP", "ConfigModelSubscriptionStatus 失败: 0x\(String(format: "%04X", source))")
                sendEvent(["type": "error", "code": "SUBSCRIBE_FAILED",
                           "message": "订阅失败"])
            }

        case let status as GenericOnOffStatus:
            sendEvent([
                "type": "meshMessageReceived",
                "source": Int(source),
                "modelType": "genericOnOff",
                "data": ["onOff": status.isOn],
            ])

        case let status as GenericLevelStatus:
            sendEvent([
                "type": "meshMessageReceived",
                "source": Int(source),
                "modelType": "genericLevel",
                "data": ["level": Int(status.level)],
            ])

        default:
            break
        }
    }

    func meshNetworkManager(
        _ manager: MeshNetworkManager,
        didSendMessage message: MeshMessage,
        from localElement: Element,
        to destination: MeshAddress
    ) {}

    func meshNetworkManager(
        _ manager: MeshNetworkManager,
        failedToSendMessage message: MeshMessage,
        from localElement: Element,
        to destination: MeshAddress,
        error: Error
    ) {
        sendEvent(["type": "error", "code": "SEND_FAILED",
                   "message": error.localizedDescription])
    }

}

// MARK: - BearerDelegate（仅用于 PB-GATT 配网）

extension IosMeshNetworkBridge: BearerDelegate {
    func bearerDidOpen(_ bearer: Bearer) {
        MeshLog.d("PROVISION", "PBGattBearer 已打开，发送 identify…")
        guard let manager = activeProvisioningManager else {
            MeshLog.e("PROVISION", "bearerDidOpen 但 activeProvisioningManager=nil")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try manager.identify(andAttractFor: 5)
                MeshLog.d("PROVISION", "identify 已发送")
            } catch {
                MeshLog.e("PROVISION", "identify 失败: \(error.localizedDescription)")
                self.provisioningError = error
                self.provisioningSemaphore?.signal()
            }
        }
    }

    func bearer(_ bearer: Bearer, didClose error: Error?) {
        if let error {
            MeshLog.e("PROVISION", "PBGattBearer 关闭 error=\(error.localizedDescription)")
            if provisioningError == nil { provisioningError = error }
        } else {
            MeshLog.d("PROVISION", "PBGattBearer 正常关闭")
        }
        provisioningSemaphore?.signal()
    }
}

// MARK: - 配网委托（私有）

private final class MeshProvisioningDelegateBridge: NSObject, ProvisioningDelegate {
    private weak var bridge: IosMeshNetworkBridge?
    private let hexUuid: String
    private let manager: ProvisioningManager
    private let bearer: PBGattBearer

    init(bridge: IosMeshNetworkBridge, hexUuid: String,
         manager: ProvisioningManager, bearer: PBGattBearer) {
        self.bridge = bridge; self.hexUuid = hexUuid
        self.manager = manager; self.bearer = bearer
    }

    func authenticationActionRequired(_ action: AuthAction) {
        if case .provideStaticKey(let cb) = action {
            cb(Data(repeating: 0, count: 16))
        }
    }

    func inputComplete() {}

    func provisioningState(
        of device: NordicMesh.UnprovisionedDevice,
        didChangeTo state: ProvisioningState
    ) {
        guard let bridge else { return }
        switch state {
        case .requestingCapabilities:
            MeshLog.d("PROVISION", "状态 → requestingCapabilities")
            bridge.emitEvent(["type": "provisioningStateChanged",
                               "state": "identifying", "uuid": hexUuid])

        case .capabilitiesReceived(let caps):
            let assigned = manager.unicastAddress
            bridge.logAddressAvailability(label: "capabilities后")
            MeshLog.d(
                "PROVISION",
                "状态 → capabilitiesReceived elements=\(caps.numberOfElements) "
                    + "algorithms=\(caps.algorithms) "
                    + "自动分配地址=\(assigned.map { String(format: "0x%04X", $0) } ?? "nil")"
            )
            bridge.emitEvent(["type": "provisioningStateChanged",
                               "state": "exchangingKeys", "uuid": hexUuid])
            let algo: Algorithm = caps.algorithms.contains(.BTM_ECDH_P256_HMAC_SHA256_AES_CCM)
                ? .BTM_ECDH_P256_HMAC_SHA256_AES_CCM
                : .BTM_ECDH_P256_CMAC_AES128_AES_CCM
            MeshLog.d("PROVISION", "选用算法=\(algo)")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.manager.provision(
                        usingAlgorithm: algo,
                        publicKey: .noOobPublicKey,
                        authenticationMethod: .noOob
                    )
                    MeshLog.d("PROVISION", "provision() 调用完成")
                } catch {
                    MeshLog.e("PROVISION", "provision() 失败: \(error.localizedDescription)")
                    bridge.failProvisioning(hexUuid: self.hexUuid, error: error)
                }
            }

        case .provisioning:
            MeshLog.d("PROVISION", "状态 → provisioning（下发 NetKey）")
            bridge.emitEvent(["type": "provisioningStateChanged",
                               "state": "provisioning", "uuid": hexUuid])

        case .complete:
            MeshLog.d("PROVISION", "状态 → complete")
            guard let network = bridge.accessMeshNetwork(),
                  let node = network.node(for: device) else {
                bridge.failProvisioning(hexUuid: hexUuid,
                                        error: MeshBridgeError.nodeNotFoundAfterProvision)
                bridge.signalProvisioningDone()
                return
            }
            let pid = bridge.currentProvisioningPeripheralId ?? ""
            bridge.closeProvisioningBearer(bearer)
            bridge.completeProvisioning(hexUuid: hexUuid, peripheralId: pid, node: node)
            bridge.signalProvisioningDone()

        case .failed(let error):
            MeshLog.e("PROVISION", "状态 → failed: \(error.localizedDescription)")
            bridge.failProvisioning(hexUuid: hexUuid, error: error)
            bridge.signalProvisioningDone()

        case .ready:
            MeshLog.d("PROVISION", "状态 → ready")
            break
        }
    }
}

// MARK: - Vendor 原始消息

/// 任意 opCode 的 Vendor 消息，用于发送自定义 Vendor 模型控制命令。
private struct RawVendorMessage: UnacknowledgedVendorMessage {
    static var opCode: UInt32 { 0 }  // 实例 opCode 覆盖此值
    let opCode: UInt32
    let parameters: Data?
    init?(parameters: Data) { nil }  // 不用于解码
    init(opCode: UInt32, parameters: Data?) {
        self.opCode = opCode
        self.parameters = parameters
    }
}

// MARK: - 错误定义

enum MeshBridgeError: LocalizedError {
    case networkNotReady
    case invalidUuid(String)
    case provisioningTimeout
    case invalidImportJson
    case nodeNotFoundAfterProvision
    case configFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkNotReady:            return "Mesh 网络未就绪"
        case .invalidUuid(let u):         return "无效的设备 UUID: \(u)"
        case .provisioningTimeout:        return "配网超时"
        case .invalidImportJson:          return "导入 JSON 无效"
        case .nodeNotFoundAfterProvision: return "配网完成但未找到节点"
        case .configFailed(let msg):      return msg
        }
    }
}

// MARK: - 直接构造 ConfigModelAppBind（对齐 Android 按地址绑定）

/// 不依赖本地 Model 对象，直接按 elementAddress + modelId 构造绑定消息。
private struct DirectConfigModelAppBind: AcknowledgedConfigMessage,
                                       ConfigAppKeyMessage,
                                       ConfigAnyModelMessage {
    static let opCode: UInt32 = ConfigModelAppBind.opCode
    static let responseType: StaticMeshResponse.Type = ConfigModelAppStatus.self

    let applicationKeyIndex: KeyIndex
    let elementAddress: Address
    let modelIdentifier: UInt16
    let companyIdentifier: UInt16?

    var parameters: Data? {
        let data = Data() + elementAddress + applicationKeyIndex
        if let companyIdentifier {
            return data + companyIdentifier + modelIdentifier
        }
        return data + modelIdentifier
    }

    init?(parameters: Data) { nil }

    init(
        applicationKey: ApplicationKey,
        elementAddress: Address,
        modelIdentifier: UInt16,
        companyIdentifier: UInt16?
    ) {
        self.applicationKeyIndex = applicationKey.index
        self.elementAddress = elementAddress
        self.modelIdentifier = modelIdentifier
        self.companyIdentifier = companyIdentifier
    }
}

// MARK: - 直接构造 ConfigModelSubscriptionAdd（对齐 Android 按地址订阅）

/// 不依赖本地 Model 对象，直接按 elementAddress + modelId + groupAddress 构造订阅消息。
private struct DirectConfigModelSubscriptionAdd: AcknowledgedConfigMessage,
                                                 ConfigAddressMessage,
                                                 ConfigAnyModelMessage {
    static let opCode: UInt32 = ConfigModelSubscriptionAdd.opCode
    static let responseType: StaticMeshResponse.Type = ConfigModelSubscriptionStatus.self

    let address: Address
    let elementAddress: Address
    let modelIdentifier: UInt16
    let companyIdentifier: UInt16?

    var parameters: Data? {
        let data = Data() + elementAddress + address
        if let companyIdentifier {
            return data + companyIdentifier + modelIdentifier
        }
        return data + modelIdentifier
    }

    init?(parameters: Data) { nil }

    init(
        groupAddress: Address,
        elementAddress: Address,
        modelIdentifier: UInt16,
        companyIdentifier: UInt16?
    ) {
        self.address = groupAddress
        self.elementAddress = elementAddress
        self.modelIdentifier = modelIdentifier
        self.companyIdentifier = companyIdentifier
    }
}

// MARK: - 直接构造 ConfigModelPublicationSet（对齐 Android 按地址发布）

private struct DirectConfigModelPublicationSet: AcknowledgedConfigMessage,
                                                ConfigAnyModelMessage {
    static let opCode: UInt32 = ConfigModelPublicationSet.opCode
    static let responseType: StaticMeshResponse.Type = ConfigModelPublicationStatus.self

    let elementAddress: Address
    let modelIdentifier: UInt16
    let companyIdentifier: UInt16?
    let publishAddress: Address
    let appKeyIndex: KeyIndex
    let ttl: UInt8
    let periodSteps: UInt8
    let periodResolution: StepResolution

    var parameters: Data? {
        var data = Data() + elementAddress + publishAddress
        data += UInt8(appKeyIndex & 0xFF)
        data += UInt8(appKeyIndex >> 8) // friendship credentials flag = 0
        data += ttl
        data += (periodSteps & 0x3F) | (periodResolution.rawValue << 6)
        data += UInt8(0) // retransmit disabled
        if let companyIdentifier {
            return data + companyIdentifier + modelIdentifier
        }
        return data + modelIdentifier
    }

    init?(parameters: Data) { nil }

    init(
        elementAddress: Address,
        modelIdentifier: UInt16,
        companyIdentifier: UInt16?,
        publishAddress: Address,
        appKeyIndex: KeyIndex,
        ttl: UInt8,
        periodSteps: UInt8,
        periodResolution: StepResolution
    ) {
        self.elementAddress = elementAddress
        self.modelIdentifier = modelIdentifier
        self.companyIdentifier = companyIdentifier
        self.publishAddress = publishAddress
        self.appKeyIndex = appKeyIndex
        self.ttl = ttl
        self.periodSteps = periodSteps
        self.periodResolution = periodResolution
    }
}

// MARK: - 直接构造 ConfigModelSubscriptionDelete（对齐 Android 按地址取消订阅）

private struct DirectConfigModelSubscriptionDelete: AcknowledgedConfigMessage,
                                                    ConfigAddressMessage,
                                                    ConfigAnyModelMessage {
    static let opCode: UInt32 = ConfigModelSubscriptionDelete.opCode
    static let responseType: StaticMeshResponse.Type = ConfigModelSubscriptionStatus.self

    let address: Address
    let elementAddress: Address
    let modelIdentifier: UInt16
    let companyIdentifier: UInt16?

    var parameters: Data? {
        let data = Data() + elementAddress + address
        if let companyIdentifier {
            return data + companyIdentifier + modelIdentifier
        }
        return data + modelIdentifier
    }

    init?(parameters: Data) { nil }

    init(
        groupAddress: Address,
        elementAddress: Address,
        modelIdentifier: UInt16,
        companyIdentifier: UInt16?
    ) {
        self.address = groupAddress
        self.elementAddress = elementAddress
        self.modelIdentifier = modelIdentifier
        self.companyIdentifier = companyIdentifier
    }
}

// MARK: - UUID / Data 扩展

extension UUID {
    init?(meshHexString hex: String) {
        let cleaned = hex.replacingOccurrences(of: "-", with: "").lowercased()
        guard cleaned.count == 32 else { return nil }
        let s = cleaned
        let formatted = "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-"
            + "\(s.dropFirst(12).prefix(4))-\(s.dropFirst(16).prefix(4))-"
            + "\(s.dropFirst(20))"
        self.init(uuidString: formatted)
    }

    var meshHexString: String {
        uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
