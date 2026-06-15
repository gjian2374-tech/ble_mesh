import Flutter
import CoreBluetooth
import NordicMesh
import UIKit

// ── BLE Mesh UUID 常量 ──────────────────────────────────────────────────────

/// BLE Mesh 配网服务 UUID（Mesh Provisioning Service）。
let kMeshProvisioningServiceUUID = CBUUID(string: "1827")

/// BLE Mesh 代理服务 UUID（Mesh Proxy Service）。
let kMeshProxyServiceUUID = CBUUID(string: "1828")

/// Mesh Proxy Data In 特征 UUID（写入通道）。
let kMeshProxyDataInUUID = CBUUID(string: "2ADD")

/// Mesh Proxy Data Out 特征 UUID（通知通道）。
let kMeshProxyDataOutUUID = CBUUID(string: "2ADE")

// ── 插件主类 ────────────────────────────────────────────────────────────────

/**
 * BleMesh Flutter 插件 iOS 实现。
 *
 * 通过 CoreBluetooth 框架实现 BLE Mesh 功能：
 * - 扫描未配网设备（Mesh Provisioning Service）
 * - GATT 代理连接管理（Mesh Proxy Service）
 * - Mesh 消息收发（通过代理）
 *
 * ## 注意
 * iOS 上的完整 BLE Mesh 支持建议集成 Nordic nRF Mesh 库（Swift 版本）：
 * https://github.com/NordicSemiconductor/IOS-nRF-Mesh-Library
 * 添加方式：在 podspec 中添加 `s.dependency 'nRFMeshProvision', '~> 4.0'`
 */
public class BleMeshPlugin: NSObject, FlutterPlugin {

    // MARK: - 属性

    /// MethodChannel 实例，处理来自 Dart 的方法调用。
    private var methodChannel: FlutterMethodChannel?

    /// EventChannel 实例，向 Dart 推送实时事件。
    private var eventChannel: FlutterEventChannel?

    /// EventSink 实例，当 Dart 端开始监听时由 StreamHandler 设置。
    private var eventSink: FlutterEventSink?

    /// CoreBluetooth 中心管理器，负责 BLE 扫描和连接。
    private var centralManager: CBCentralManager?

    /// 当前的 GATT 代理连接外设。
    private var connectedPeripheral: CBPeripheral?

    /// Data In 特征，用于向代理节点写入数据。
    private var dataInCharacteristic: CBCharacteristic?

    /// GATT Proxy 写入队列（对齐 Android BleGattManager.writeQueue 串行写）。
    private var proxyWriteQueue: [Data] = []
    private var proxyWriteInProgress = false

    /// 删除节点前若 Proxy 未连接，先连上再发 ConfigNodeReset。
    private var pendingDeleteUnicastAddress: UInt16?
    private var pendingDeleteResult: FlutterResult?
    /// 删除完成后等待 GATT 真正断开再回调 Flutter（避免立即重连时 GATT 仍被占用）。
    private var pendingDeleteFlutterResult: FlutterResult?
    private var waitingDeleteDisconnect = false
    private var deleteDisconnectTimer: Timer?
    /// 删除时记录节点 UUID，用于清理 Plugin 侧缓存。
    private var pendingDeleteNodeUuid: String?

    /// 配网前若需等待 GATT 断开，暂存此请求。
    private struct PendingProvisionRequest {
        let uuid: String
        let peripheral: CBPeripheral
        let nodeName: String?
        let result: FlutterResult
    }
    private var pendingProvision: PendingProvisionRequest?
    private var isDisconnectingForProvision = false
    private var provisionDisconnectTimer: Timer?

    /// 扫描定时器，用于超时自动停止扫描。
    private var scanTimer: Timer?

    /// 已发现设备的 UUID 集合（用于去重）。
    private var discoveredDeviceUUIDs = Set<String>()

    /// 已发现外设缓存（CoreBluetooth 外设 UUID → CBPeripheral）。
    private var discoveredPeripherals: [String: CBPeripheral] = [:]

    /// Mesh 设备 UUID → CoreBluetooth 外设 UUID。
    private var meshUuidToPeripheralId: [String: String] = [:]

    /// 正在等待连接的 Proxy 目标地址（外设 UUID / Mesh UUID / 历史 MAC）。
    private var pendingProxyAddress: String?

    /// Proxy 扫描超时定时器。
    private var proxyConnectTimer: Timer?

    /// 配网后首次 Proxy 连接：强制全量 GATT 服务发现（ESP 无法发 Service Change 时必需）。
    private var forceRediscoverProxyServices = false

    /// Proxy 服务发现重试次数（单次连接内）。
    private var proxyServiceDiscoveryAttempts = 0

    /// 配网后 Proxy 重连剩余次数。
    private var proxyPostProvisionRetriesLeft = 0

    /// 配网后待重连的外设 ID。
    private var proxyPostProvisionPeripheralId: String?

    /// Nordic Mesh 网络桥接（真实 PB-GATT 配网）。
    private var meshBridge: IosMeshNetworkBridge?

    /// iOS 侧本地缓存的节点、分组、场景数据。
    private var nodes = [[String: Any?]]()
    private var groups = [[String: Any?]]()
    private var scenes = [[String: Any?]]()
    private var subscriptions = [[String: Int]]()
    private var publications = [[String: Int]]()
    private var networkId = "ios-local-network"
    private var networkName = "iOS Mesh Network"

    // MARK: - 注册

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BleMeshPlugin()

        // 注册 MethodChannel
        let channel = FlutterMethodChannel(
            name: "ble_mesh",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.methodChannel = channel

        // 注册 EventChannel
        let eventChannel = FlutterEventChannel(
            name: "ble_mesh/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
        instance.eventChannel = eventChannel
    }

    // MARK: - MethodCallDelegate

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        // ── 初始化 ─────────────────────────────────────────────────────────
        case "initialize":
            handleInitialize(result: result)

        case "requestPermissions":
            // iOS 不需要手动请求蓝牙权限，CBCentralManager 初始化时系统自动弹出
            result(true)

        case "getBluetoothState":
            handleGetBluetoothState(result: result)

        case "loadNetwork":
            result(buildNetworkSnapshot())

        case "saveNetwork":
            result(true)

        // ── 扫描 ───────────────────────────────────────────────────────────
        case "startScan":
            let timeoutMs = args?["timeoutMs"] as? Int
            handleStartScan(timeoutMs: timeoutMs, result: result)

        case "stopScan":
            handleStopScan(result: result)

        // ── 配网 ───────────────────────────────────────────────────────────
        case "provisionDevice":
            guard let uuid = args?["uuid"] as? String,
                  let address = args?["address"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            let nodeName = args?["nodeName"] as? String
            handleProvisionDevice(uuid: uuid, address: address, nodeName: nodeName, result: result)

        case "cancelProvisioning":
            result(nil)

        case "distributeAppKey":
            guard let unicastAddress = args?["unicastAddress"] as? Int else {
                result(FlutterError(
                    code: "INVALID_ARGUMENT",
                    message: "缺少 unicastAddress 参数",
                    details: nil
                ))
                return
            }
            let appKeyIndex = args?["appKeyIndex"] as? Int ?? 0
            if let bridge = meshBridge {
                bridge.distributeAppKey(
                    unicastAddress: UInt16(unicastAddress),
                    appKeyIndex: appKeyIndex
                )
            }
            result(nil)

        // ── 连接管理 ───────────────────────────────────────────────────────
        case "connectToProxy":
            guard let address = args?["address"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少 address 参数", details: nil))
                return
            }
            handleConnectToProxy(address: address, result: result)

        case "disconnectFromProxy":
            handleDisconnectFromProxy(result: result)

        case "getConnectionState":
            result(resolveConnectionState())

        case "getNetworkInfo":
            result(buildNetworkInfo())

        case "exportNetworkJson":
            handleExportNetworkJson(result: result)

        case "importNetworkJson":
            guard let json = args?["json"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少 json 参数", details: nil))
                return
            }
            handleImportNetworkJson(json: json, result: result)

        // ── 控制消息 ───────────────────────────────────────────────────────
        case "sendGenericOnOff":
            guard let address = args?["address"] as? Int,
                  let onOff = args?["onOff"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            let appKeyIndex = args?["appKeyIndex"] as? Int ?? 0
            let acknowledged = args?["acknowledged"] as? Bool ?? true
            handleSendGenericOnOff(
                address: address, onOff: onOff,
                appKeyIndex: appKeyIndex, acknowledged: acknowledged,
                result: result
            )

        case "sendGenericLevel":
            guard let address = args?["address"] as? Int,
                  let level = args?["level"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            let appKeyIndex = args?["appKeyIndex"] as? Int ?? 0
            let acknowledged = args?["acknowledged"] as? Bool ?? true
            handleSendGenericLevel(
                address: address, level: level,
                appKeyIndex: appKeyIndex, acknowledged: acknowledged,
                result: result
            )

        case "sendLightLightness":
            guard let address = args?["address"] as? Int,
                  let lightness = args?["lightness"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            let appKeyIndex = args?["appKeyIndex"] as? Int ?? 0
            let acknowledged = args?["acknowledged"] as? Bool ?? true
            handleSendLightLightness(
                address: address, lightness: lightness,
                appKeyIndex: appKeyIndex, acknowledged: acknowledged,
                result: result
            )

        // ── 节点、分组、场景管理（iOS 本地缓存实现） ───────────────────────
        case "getNodes":
            result(meshBridge?.getNodes() ?? nodes)

        case "deleteNode":
            guard let unicastAddress = args?["unicastAddress"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少 unicastAddress 参数", details: nil))
                return
            }
            handleDeleteNode(unicastAddress: unicastAddress, result: result)

        case "getGroups":
            result(meshBridge?.getGroups() ?? groups)

        case "createGroup":
            guard let name = args?["name"] as? String,
                  let address = args?["address"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            do {
                try meshBridge?.createGroup(name: name, address: UInt16(address))
                groups.removeAll { ($0["address"] as? Int) == address }
                groups.append(["address": address, "name": name, "parentAddress": nil])
                sendEvent(["type": "networkUpdated"])
                result(nil)
            } catch {
                result(FlutterError(
                    code: "GROUP_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }

        case "deleteGroup":
            guard let address = args?["address"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少 address 参数", details: nil))
                return
            }
            do {
                try meshBridge?.deleteGroup(address: UInt16(address))
                groups.removeAll { ($0["address"] as? Int) == address }
                subscriptions.removeAll { $0["subscriptionAddress"] == address }
                publications.removeAll { $0["publishAddress"] == address }
                sendEvent(["type": "networkUpdated"])
                result(nil)
            } catch {
                result(FlutterError(
                    code: "GROUP_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }

        case "addSubscription":
            guard let nodeAddress = args?["nodeAddress"] as? Int,
                  let elementAddress = args?["elementAddress"] as? Int,
                  let modelId = args?["modelId"] as? Int,
                  let subscriptionAddress = args?["subscriptionAddress"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            guard let bridge = meshBridge else {
                result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
                return
            }
            Task {
                do {
                    try await bridge.addModelSubscription(
                        nodeAddress: UInt16(nodeAddress),
                        elementAddress: UInt16(elementAddress),
                        modelId: UInt32(bitPattern: Int32(modelId)),
                        subscriptionAddress: UInt16(subscriptionAddress)
                    )
                    await MainActor.run { result(nil) }
                } catch {
                    await MainActor.run {
                        result(FlutterError(
                            code: "SUBSCRIBE_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }

        case "removeSubscription":
            guard let nodeAddress = args?["nodeAddress"] as? Int,
                  let elementAddress = args?["elementAddress"] as? Int,
                  let modelId = args?["modelId"] as? Int,
                  let subscriptionAddress = args?["subscriptionAddress"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            guard let bridge = meshBridge else {
                result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
                return
            }
            Task {
                do {
                    try await bridge.removeModelSubscription(
                        nodeAddress: UInt16(nodeAddress),
                        elementAddress: UInt16(elementAddress),
                        modelId: UInt32(bitPattern: Int32(modelId)),
                        subscriptionAddress: UInt16(subscriptionAddress)
                    )
                    await MainActor.run { result(nil) }
                } catch {
                    await MainActor.run {
                        result(FlutterError(
                            code: "UNSUBSCRIBE_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }

        case "bindAppKey":
            guard let nodeAddress = args?["nodeAddress"] as? Int,
                  let elementAddress = args?["elementAddress"] as? Int,
                  let modelId = args?["modelId"] as? Int,
                  let appKeyIndex = args?["appKeyIndex"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            guard let bridge = meshBridge else {
                result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
                return
            }
            Task {
                do {
                    try await bridge.bindModelAppKey(
                        nodeAddress: UInt16(nodeAddress),
                        elementAddress: UInt16(elementAddress),
                        modelId: UInt32(bitPattern: Int32(modelId)),
                        appKeyIndex: appKeyIndex
                    )
                    await MainActor.run { result(nil) }
                } catch {
                    await MainActor.run {
                        result(FlutterError(
                            code: "BIND_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }

        case "unbindAppKey":
            result(nil)

        case "supportsProxyFilter":
            result(false)

        case "supportsAutomaticProxyFilter":
            result(false)

        case "setProxyFilterType":
            result(false)

        case "addProxyFilterAddresses":
            result(false)

        case "removeProxyFilterAddresses":
            result(false)

        case "getScenes":
            result(scenes)

        case "storeScene":
            guard let nodeAddress = args?["nodeAddress"] as? Int,
                  let sceneNumber = args?["sceneNumber"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            scenes.removeAll { ($0["number"] as? Int) == sceneNumber }
            scenes.append(["number": sceneNumber, "name": "场景 \(sceneNumber)", "addresses": [nodeAddress]])
            sendEvent(["type": "networkUpdated"])
            result(nil)

        case "recallScene":
            guard let address = args?["address"] as? Int,
                  let sceneNumber = args?["sceneNumber"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            sendEvent([
                "type": "meshMessageReceived",
                "source": address,
                "modelType": "sceneStatus",
                "data": ["sceneNumber": sceneNumber],
            ])
            result(nil)

        case "deleteScene":
            guard let sceneNumber = args?["sceneNumber"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少 sceneNumber 参数", details: nil))
                return
            }
            scenes.removeAll { ($0["number"] as? Int) == sceneNumber }
            sendEvent(["type": "networkUpdated"])
            result(nil)

        case "sendVendorMessage":
            guard let address = args?["address"] as? Int,
                  let companyId = args?["companyId"] as? Int,
                  let modelId = args?["modelId"] as? Int,
                  let opCode = args?["opCode"] as? Int,
                  let payloadList = args?["payload"] as? [Int] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            let appKeyIndex = args?["appKeyIndex"] as? Int ?? 0
            let acknowledged = args?["acknowledged"] as? Bool ?? false
            let payload = Data(payloadList.map { UInt8($0 & 0xFF) })
            handleSendVendorMessage(
                address: address, companyId: companyId, modelId: modelId,
                opCode: opCode, payload: payload,
                appKeyIndex: appKeyIndex, acknowledged: acknowledged,
                result: result
            )

        case "setPublication":
            guard let nodeAddress = args?["nodeAddress"] as? Int,
                  let elementAddress = args?["elementAddress"] as? Int,
                  let modelId = args?["modelId"] as? Int,
                  let publishAddress = args?["publishAddress"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少必要参数", details: nil))
                return
            }
            let appKeyIndex = args?["appKeyIndex"] as? Int ?? 0
            let publishTtl = args?["publishTtl"] as? Int ?? 5
            let publishPeriod = args?["publishPeriod"] as? Int ?? 0
            guard let bridge = meshBridge else {
                result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
                return
            }
            Task {
                do {
                    try await bridge.setModelPublication(
                        nodeAddress: UInt16(nodeAddress),
                        elementAddress: UInt16(elementAddress),
                        modelId: UInt32(bitPattern: Int32(modelId)),
                        publishAddress: UInt16(publishAddress),
                        appKeyIndex: appKeyIndex,
                        publishTtl: publishTtl,
                        publishPeriod: publishPeriod
                    )
                    await MainActor.run {
                        publications.removeAll {
                            ($0["nodeAddress"] as? Int) == nodeAddress &&
                            ($0["elementAddress"] as? Int) == elementAddress &&
                            ($0["modelId"] as? Int) == modelId
                        }
                        publications.append([
                            "nodeAddress": nodeAddress,
                            "elementAddress": elementAddress,
                            "modelId": modelId,
                            "publishAddress": publishAddress,
                            "appKeyIndex": appKeyIndex,
                            "publishTtl": publishTtl,
                            "publishPeriod": publishPeriod,
                        ])
                        sendEvent(["type": "networkUpdated"])
                        result(nil)
                    }
                } catch {
                    await MainActor.run {
                        result(FlutterError(
                            code: "PUBLICATION_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 初始化

    private func handleInitialize(result: @escaping FlutterResult) {
        centralManager = CBCentralManager(delegate: self, queue: .main)

        let bridge = IosMeshNetworkBridge { [weak self] event in
            self?.sendEvent(event)
        }
        bridge.onProxyConnectRequested = { [weak self] peripheralId in
            self?.schedulePostProvisionProxyConnect(peripheralId: peripheralId)
        }
        meshBridge = bridge

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.initialize()
                let info = bridge.getNetworkInfo()
                if !info.isEmpty {
                    DispatchQueue.main.async {
                        self.networkId = info["networkId"] as? String ?? self.networkId
                        self.networkName = info["name"] as? String ?? self.networkName
                    }
                }
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "INIT_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func resolveConnectionState() -> String {
        if connectedPeripheral != nil, dataInCharacteristic != nil {
            return "connected"
        }
        if connectedPeripheral != nil {
            return "connecting"
        }
        return "disconnected"
    }

    private func buildNetworkInfo() -> [String: Any] {
        let info = meshBridge?.getNetworkInfo() ?? [:]
        if !info.isEmpty {
            return info
        }
        return [
            "networkId": networkId,
            "name": networkName,
            "ivIndex": 0,
            "ivUpdateActive": false,
            "sequenceNumber": 0,
            "provisionerAddress": 1,
            "networkKeys": [] as [[String: Any]],
            "appKeys": [] as [[String: Any]],
            "nodeCount": nodes.count,
        ]
    }

    private func handleExportNetworkJson(result: FlutterResult) {
        if let bridge = meshBridge {
            let json = bridge.exportNetworkJson()
            if !json.isEmpty {
                result(json)
                return
            }
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: buildNetworkSnapshot(),
                options: [.prettyPrinted]
            )
            let json = String(data: data, encoding: .utf8) ?? ""
            result(json)
        } catch {
            result(FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func handleImportNetworkJson(json: String, result: @escaping FlutterResult) {
        guard let bridge = meshBridge else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.importNetworkJson(json)
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "IMPORT_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func buildNetworkSnapshot() -> [String: Any] {
        let appKeyIndexes = Set(
            nodes.flatMap { ($0["appKeyIndexes"] as? [Int]) ?? [] }
        ).sorted()
        let appKeys = appKeyIndexes.map { index in
            [
                "keyId": "app-\(index)",
                "key": "",
                "index": index,
                "enabled": true
            ] as [String: Any]
        }
        return [
            "networkId": networkId,
            "name": networkName,
            "networkKeys": [],
            "appKeys": appKeys,
            "nodes": nodes,
            "groups": groups,
            "provisioner": [
                "name": "iOS Provisioner",
                "provisionerId": networkId,
                "addressRange": [1, 32767]
            ]
        ]
    }

    private func handleGetBluetoothState(result: FlutterResult) {
        let state = bluetoothStateString()
        result(state)
    }

    /// 返回当前蓝牙状态的字符串（对应 Dart 层 BluetoothState 枚举）。
    private func bluetoothStateString() -> String {
        guard let manager = centralManager else { return "unknown" }
        switch manager.state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        default: return "unknown"
        }
    }

    // MARK: - 扫描

    private func handleStartScan(timeoutMs: Int?, result: FlutterResult) {
        guard let central = centralManager, central.state == .poweredOn else {
            result(FlutterError(code: "BLUETOOTH_DISABLED", message: "蓝牙未开启", details: nil))
            return
        }

        discoveredDeviceUUIDs.removeAll()
        scanTimer?.invalidate()

        // 只扫描广播了配网服务 UUID 的设备
        central.scanForPeripherals(
            withServices: [kMeshProvisioningServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // 超时自动停止
        if let timeout = timeoutMs, timeout > 0 {
            scanTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout) / 1000.0, repeats: false) { [weak self] _ in
                self?.centralManager?.stopScan()
                self?.sendEvent(["type": "scanStopped"])
            }
        }

        result(nil)
    }

    private func handleStopScan(result: FlutterResult) {
        scanTimer?.invalidate()
        scanTimer = nil
        centralManager?.stopScan()
        result(nil)
    }

    // MARK: - 配网

    private func handleProvisionDevice(
        uuid: String,
        address: String,
        nodeName: String?,
        result: @escaping FlutterResult
    ) {
        MeshLog.d("PROVISION", "═══ 开始配网请求 ═══")
        MeshLog.d("PROVISION", "uuid=\(uuid) address=\(address) name=\(nodeName ?? "nil")")

        guard let bridge = meshBridge else {
            MeshLog.e("PROVISION", "meshBridge 未初始化")
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }

        bridge.prepareForProvisioning(uuid: uuid)

        guard let peripheral = resolvePeripheral(for: address) else {
            MeshLog.e("PROVISION", "resolvePeripheral 失败 address=\(address)")
            MeshLog.d("PROVISION", "缓存外设数=\(discoveredPeripherals.count) meshUuid映射=\(meshUuidToPeripheralId.count)")
            meshBridge?.logNetworkState("resolvePeripheral 失败")
            result(FlutterError(
                code: "DEVICE_NOT_FOUND",
                message: "未找到设备，请先扫描并确保设备在附近",
                details: nil
            ))
            return
        }

        MeshLog.d("PROVISION", "已解析外设 id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") state=\(peripheral.state.rawValue)")

        scanTimer?.invalidate()
        centralManager?.stopScan()

        cachePeripheral(peripheral, meshUUID: uuid)
        bridge.registerPeripheralId(peripheral.identifier.uuidString, forMeshUuid: uuid)

        let connectedId = connectedPeripheral?.identifier.uuidString
        let peripheralState = peripheral.state.rawValue
        MeshLog.d(
            "PROVISION",
            "GATT 状态 connectedPeripheral=\(connectedId ?? "无") "
                + "dataIn=\(dataInCharacteristic != nil) "
                + "targetPeripheral.state=\(peripheralState) "
                + "pendingProxy=\(pendingProxyAddress ?? "无")"
        )

        // 删除后 Proxy 可能仍占用 GATT；配网前必须断开 Plugin 侧连接
        if connectedPeripheral != nil || dataInCharacteristic != nil {
            MeshLog.d("PROVISION", "存在 Plugin Proxy 连接，先断开再配网…")
            pendingProvision = PendingProvisionRequest(
                uuid: uuid,
                peripheral: peripheral,
                nodeName: nodeName,
                result: result
            )
            isDisconnectingForProvision = true
            provisionDisconnectTimer?.invalidate()
            provisionDisconnectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.failPendingProvision("等待 GATT 断开超时（10s）")
            }
            disconnectProxyGATT()
            return
        }

        executeProvision(uuid: uuid, peripheral: peripheral, nodeName: nodeName, result: result)
    }

    private func executeProvision(
        uuid: String,
        peripheral: CBPeripheral,
        nodeName: String?,
        result: @escaping FlutterResult
    ) {
        provisionDisconnectTimer?.invalidate()
        provisionDisconnectTimer = nil
        pendingProvision = nil
        isDisconnectingForProvision = false

        guard let bridge = meshBridge else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }

        MeshLog.d("PROVISION", "执行 PB-GATT 配网 peripheral=\(peripheral.identifier.uuidString)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.provisionDevice(
                    uuid: uuid,
                    peripheralId: peripheral.identifier.uuidString,
                    nodeName: nodeName,
                    peripheral: peripheral
                )
                MeshLog.d("PROVISION", "═══ 配网成功 ═══")
                DispatchQueue.main.async { result(nil) }
            } catch {
                MeshLog.e("PROVISION", "═══ 配网失败: \(error.localizedDescription) ═══")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "PROVISIONING_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func failPendingProvision(_ message: String) {
        guard let pending = pendingProvision else { return }
        MeshLog.e("PROVISION", "pendingProvision 失败: \(message)")
        provisionDisconnectTimer?.invalidate()
        provisionDisconnectTimer = nil
        pendingProvision = nil
        isDisconnectingForProvision = false
        pending.result(FlutterError(code: "PROVISIONING_FAILED", message: message, details: nil))
    }

    private func resumePendingProvisionAfterDisconnect() {
        guard isDisconnectingForProvision, let pending = pendingProvision else { return }
        MeshLog.d("PROVISION", "Plugin didDisconnect 收到，500ms 后启动 PB-GATT（等设备切回 0x1827 广播）…")
        isDisconnectingForProvision = false
        provisionDisconnectTimer?.invalidate()
        provisionDisconnectTimer = nil
        let req = pending
        pendingProvision = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.executeProvision(
                uuid: req.uuid,
                peripheral: req.peripheral,
                nodeName: req.nodeName,
                result: req.result
            )
        }
    }

    // MARK: - 连接

    private func handleConnectToProxy(address: String, result: FlutterResult) {
        MeshLog.d("PROXY", "connectToProxy 请求 target=\(address)")
        logPluginCacheState("connectToProxy前")
        meshBridge?.logNetworkState("connectToProxy前")
        guard let central = centralManager else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }

        guard central.state == .poweredOn else {
            result(FlutterError(code: "BLUETOOTH_DISABLED", message: "蓝牙未开启", details: nil))
            return
        }

        let normalizedTarget = address.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingProxyAddress = normalizedTarget
        enqueueProxyConfiguration(for: normalizedTarget)

        if let peripheral = resolvePeripheral(for: normalizedTarget) {
            connectToPeripheral(peripheral, reportedAddress: peripheral.identifier.uuidString)
            result(nil)
            return
        }

        // 缓存未命中时扫描 Proxy Service，匹配后再连接（与 nRF Mesh iOS 行为一致）
        sendEvent([
            "type": "connectionStateChanged",
            "state": "connecting",
            "address": normalizedTarget,
        ])
        startProxyScan(for: normalizedTarget)
        result(nil)
    }

    private func handleDisconnectFromProxy(result: FlutterResult) {
        disconnectProxyGATT()
        result(nil)
    }

    /// 断开 Proxy GATT 并释放 Nordic Transmitter（配网 / 删除后必须调用）。
    /// - Returns: 是否曾存在活跃连接（需等待 `didDisconnect`）。
    @discardableResult
    private func disconnectProxyGATT() -> Bool {
        let hadConnection = connectedPeripheral != nil
        let pid = connectedPeripheral?.identifier.uuidString ?? "无"
        MeshLog.d("GATT", "disconnectProxyGATT 开始 hadConnection=\(hadConnection) peripheral=\(pid) dataIn=\(dataInCharacteristic != nil)")
        cancelPendingProxyConnect()
        clearProxyWriteQueue()
        meshBridge?.notifyProxyDisconnected()
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        dataInCharacteristic = nil
        if !hadConnection {
            MeshLog.d("GATT", "无活跃连接，无需等待 didDisconnect")
        }
        sendEvent(["type": "connectionStateChanged", "state": "disconnected"])
        return hadConnection
    }

    /// 打印 Plugin 侧本地缓存（扫描外设、UUID 映射等）。
    private func logPluginCacheState(_ label: String) {
        let meshMappings = meshUuidToPeripheralId.map { "\($0.key.prefix(8))…→\($0.value.prefix(8))…" }
        MeshLog.d(
            "CACHE",
            "[\(label)] discoveredPeripherals=\(discoveredPeripherals.count) "
                + "meshUuidMap=\(meshUuidToPeripheralId.count) "
                + "scanDedup=\(discoveredDeviceUUIDs.count) "
                + "connected=\(connectedPeripheral?.identifier.uuidString ?? "无") "
                + "pendingProxy=\(pendingProxyAddress ?? "无") "
                + "pendingDelete=\(pendingDeleteUnicastAddress.map { String(format: "0x%04X", $0) } ?? "无")"
        )
        if !meshMappings.isEmpty {
            MeshLog.d("CACHE", "[\(label)] meshUuidMap: \(meshMappings.joined(separator: ", "))")
        }
    }

    /// 删除节点后清理 Plugin 侧与该节点相关的映射（保留 discoveredPeripherals 供重新扫描）。
    private func clearPluginCachesForDeletedNode(uuid: String?, unicastAddress: Int) {
        if let uuid {
            let meshKey = normalizeUuidKey(uuid)
            if let peripheralId = meshUuidToPeripheralId[meshKey] {
                meshUuidToPeripheralId.removeValue(forKey: meshKey)
                MeshLog.d("CACHE", "已清除 meshUuidMap \(meshKey.prefix(8))…→\(peripheralId.prefix(8))…")
            }
            UserDefaults.standard.removeObject(forKey: "ble_mesh_periph_\(meshKey)")
            MeshLog.d("CACHE", "已清除 UserDefaults ble_mesh_periph_\(meshKey.prefix(8))…")
        }
    }

    /// 删除流程统一收尾：断开 GATT、审计本地状态、回调 Flutter。
    private func completeDeleteFlow(
        unicastAddress: Int,
        deletedUuid: String?,
        error: Error?
    ) {
        let flutterCallback = pendingDeleteResult
        pendingDeleteResult = nil

        if let error {
            meshBridge?.releaseAfterDelete()
            disconnectProxyGATT()
            MeshLog.e("DELETE", "═══ 删除失败: \(error.localizedDescription) ═══")
            flutterCallback?(FlutterError(
                code: "DELETE_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
            pendingDeleteNodeUuid = nil
            return
        }

        meshBridge?.releaseAfterDelete()
        clearPluginCachesForDeletedNode(uuid: deletedUuid, unicastAddress: unicastAddress)
        logPluginCacheState("删除收尾")
        meshBridge?.logDeleteVerification(
            unicastAddress: UInt16(unicastAddress),
            deletedUuid: deletedUuid
        )

        let needsWait = disconnectProxyGATT()
        if needsWait {
            MeshLog.d("DELETE", "等待 didDisconnect 后再通知 Flutter 删除成功…")
            pendingDeleteFlutterResult = flutterCallback
            waitingDeleteDisconnect = true
            deleteDisconnectTimer?.invalidate()
            deleteDisconnectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                guard let self, self.waitingDeleteDisconnect else { return }
                MeshLog.e("DELETE", "等待 GATT 断开超时（10s），仍回调删除成功")
                self.pendingDeleteFlutterResult?(nil)
                MeshLog.d("DELETE", "═══ 删除完成（GATT 断开超时但本地已清空）═══")
                self.finishDeleteWaitState()
            }
        } else {
            MeshLog.d("DELETE", "═══ 删除完成（本地已清空 + 无 GATT 连接），可重新扫描配网 ═══")
            flutterCallback?(nil)
            pendingDeleteNodeUuid = nil
        }
    }

    private func finishDeleteWaitState() {
        deleteDisconnectTimer?.invalidate()
        deleteDisconnectTimer = nil
        waitingDeleteDisconnect = false
        pendingDeleteFlutterResult = nil
        pendingDeleteNodeUuid = nil
    }

    private func resumePendingDeleteAfterDisconnect() {
        guard waitingDeleteDisconnect, let callback = pendingDeleteFlutterResult else { return }
        MeshLog.d("DELETE", "didDisconnect 收到，删除流程完全结束")
        meshBridge?.logNetworkState("DELETE GATT断开后")
        logPluginCacheState("DELETE GATT断开后")
        callback(nil)
        MeshLog.d("DELETE", "═══ 删除完成（本地已清空 + GATT 已释放），可重新扫描配网 ═══")
        finishDeleteWaitState()
    }

    private func normalizeUuidKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// 手动连 Proxy 前将对应节点加入待配置队列（App 重启后队列会丢失）。
    private func enqueueProxyConfiguration(for targetAddress: String) {
        guard let bridge = meshBridge else { return }
        let trimmed = targetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetKey = normalizeUuidKey(trimmed)
        let knownNodes = bridge.getNodes()

        for node in knownNodes {
            let nodeUuid = normalizeUuidKey((node["uuid"] as? String) ?? "")
            let nodeMac = ((node["macAddress"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = nodeUuid == targetKey
                || nodeMac.caseInsensitiveCompare(trimmed) == .orderedSame
                || normalizeUuidKey(nodeMac) == targetKey
            if matches, let addr = nodeUnicastAddress(from: node) {
                bridge.enqueuePendingConfiguration(unicastAddress: UInt16(addr))
                MeshLog.d(
                    "PROXY",
                    "connectToProxy 入队配置 0x\(String(format: "%04X", addr))"
                )
                return
            }
        }

        let looksLikeMac = trimmed.contains(":") && trimmed.count >= 17
        if looksLikeMac, knownNodes.count == 1,
           let addr = nodeUnicastAddress(from: knownNodes[0]) {
            bridge.enqueuePendingConfiguration(unicastAddress: UInt16(addr))
            MeshLog.d(
                "PROXY",
                "单节点网络 connectToProxy 入队 0x\(String(format: "%04X", addr))"
            )
        }
    }

    /// getNodes 返回的 unicastAddress 可能是 Int 或 UInt16。
    private func nodeUnicastAddress(from map: [String: Any?]) -> Int? {
        if let value = map["unicastAddress"] as? Int { return value }
        if let value = map["unicastAddress"] as? UInt16 { return Int(value) }
        if let value = map["unicastAddress"] as? NSNumber { return value.intValue }
        return nil
    }

    private func extractMeshUUID(from advertisementData: [String: Any]) -> String? {
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            if let provisioningData = serviceData[kMeshProvisioningServiceUUID],
               provisioningData.count >= 16 {
                return provisioningData.prefix(16)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
            if let proxyData = serviceData[kMeshProxyServiceUUID],
               proxyData.count >= 16 {
                return proxyData.prefix(16)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
        }
        return nil
    }

    private func cachePeripheral(_ peripheral: CBPeripheral, meshUUID: String?) {
        let peripheralId = peripheral.identifier.uuidString
        discoveredPeripherals[peripheralId.uppercased()] = peripheral
        discoveredPeripherals[peripheralId.lowercased()] = peripheral

        if let meshUUID = meshUUID {
            let meshKey = normalizeUuidKey(meshUUID)
            meshUuidToPeripheralId[meshKey] = peripheralId.uppercased()
            UserDefaults.standard.set(peripheralId, forKey: "ble_mesh_periph_\(meshKey)")
        }
    }

    private func resolvePeripheral(for address: String) -> CBPeripheral? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let lower = trimmed.lowercased()

        if let cached = discoveredPeripherals[upper] ?? discoveredPeripherals[lower] {
            return cached
        }

        if let uuid = UUID(uuidString: trimmed),
           let retrieved = centralManager?
            .retrievePeripherals(withIdentifiers: [uuid])
            .first {
            cachePeripheral(retrieved, meshUUID: nil)
            return retrieved
        }

        let meshKey = normalizeUuidKey(trimmed)
        if let peripheralId = meshUuidToPeripheralId[meshKey],
           let cached = discoveredPeripherals[peripheralId] {
            return cached
        }

        if let savedId = UserDefaults.standard.string(forKey: "ble_mesh_periph_\(meshKey)"),
           let uuid = UUID(uuidString: savedId),
           let retrieved = centralManager?
            .retrievePeripherals(withIdentifiers: [uuid])
            .first {
            cachePeripheral(retrieved, meshUUID: trimmed)
            return retrieved
        }

        let knownNodes = meshBridge?.getNodes() ?? nodes
        // 节点列表里可能保存了 Mesh UUID 或历史外设 UUID
        for node in knownNodes {
            let nodeUuid = (node["uuid"] as? String) ?? ""
            let nodeMac = (node["macAddress"] as? String) ?? ""
            if normalizeUuidKey(nodeUuid) == meshKey
                || nodeMac.caseInsensitiveCompare(trimmed) == .orderedSame {
                if let peripheralId = meshUuidToPeripheralId[normalizeUuidKey(nodeUuid)],
                   let cached = discoveredPeripherals[peripheralId] {
                    return cached
                }
                if let uuid = UUID(uuidString: nodeMac),
                   let retrieved = centralManager?
                    .retrievePeripherals(withIdentifiers: [uuid])
                    .first {
                    cachePeripheral(retrieved, meshUUID: nodeUuid)
                    return retrieved
                }
            }
        }

        return nil
    }

    private func matchesProxyTarget(
        peripheral: CBPeripheral,
        target: String,
        advertisementData: [String: Any]
    ) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let peripheralId = peripheral.identifier.uuidString
        if peripheralId.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }

        let targetKey = normalizeUuidKey(trimmed)
        if normalizeUuidKey(peripheralId) == targetKey {
            return true
        }

        if let meshUUID = extractMeshUUID(from: advertisementData),
           normalizeUuidKey(meshUUID) == targetKey {
            return true
        }

        let knownNodes = meshBridge?.getNodes() ?? nodes
        for node in knownNodes {
            let nodeUuid = normalizeUuidKey((node["uuid"] as? String) ?? "")
            let nodeMac = ((node["macAddress"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if nodeUuid == targetKey {
                if let advMesh = extractMeshUUID(from: advertisementData),
                   normalizeUuidKey(advMesh) == nodeUuid {
                    return true
                }
                if nodeMac.caseInsensitiveCompare(peripheralId) == .orderedSame {
                    return true
                }
            }
            if nodeMac.caseInsensitiveCompare(trimmed) == .orderedSame {
                return peripheralId.caseInsensitiveCompare(nodeMac) == .orderedSame
                    || nodeUuid == normalizeUuidKey(trimmed)
            }
        }

        // iOS 无法使用 Android MAC；单节点网络时允许连接扫描到的唯一 Proxy
        let looksLikeMac = trimmed.contains(":") && trimmed.count >= 17
        if looksLikeMac && knownNodes.count == 1 {
            return true
        }

        return false
    }

    private func startProxyScan(for targetAddress: String) {
        guard let central = centralManager, central.state == .poweredOn else {
            failProxyConnect(message: "蓝牙未开启")
            return
        }

        cancelPendingProxyConnect()
        pendingProxyAddress = targetAddress

        central.stopScan()
        central.scanForPeripherals(
            withServices: [kMeshProxyServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        proxyConnectTimer = Timer.scheduledTimer(
            withTimeInterval: 15.0,
            repeats: false
        ) { [weak self] _ in
            self?.failProxyConnect(message: "扫描代理节点超时，请靠近设备后重试")
        }
    }

    private func cancelPendingProxyConnect() {
        proxyConnectTimer?.invalidate()
        proxyConnectTimer = nil
        pendingProxyAddress = nil
        centralManager?.stopScan()
    }

    private func failProxyConnect(message: String) {
        if retryPostProvisionProxyConnectIfNeeded(reason: message) {
            return
        }
        cancelPendingProxyConnect()
        connectedPeripheral = nil
        dataInCharacteristic = nil
        failPendingDelete(message: message)
        sendEvent(["type": "connectionStateChanged", "state": "disconnected"])
        sendEvent(["type": "error", "code": "DEVICE_NOT_FOUND", "message": message])
    }

    /// 配网完成后延迟扫描连接 Proxy，避免 ESP GATT 服务表未切换完成。
    private func schedulePostProvisionProxyConnect(peripheralId: String) {
        MeshLog.d(
            "PROXY",
            "配网后自动 Proxy：断开旧 GATT，4s 后扫描连接 id=\(peripheralId)"
        )
        forceRediscoverProxyServices = true
        proxyPostProvisionRetriesLeft = 3
        proxyPostProvisionPeripheralId = peripheralId
        invalidatePeripheralCache(for: peripheralId)
        disconnectProxyGATT()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            self.enqueueProxyConfiguration(for: peripheralId)
            self.startProxyScan(for: peripheralId)
        }
    }

    private func invalidatePeripheralCache(for peripheralId: String) {
        let trimmed = peripheralId.trimmingCharacters(in: .whitespacesAndNewlines)
        discoveredPeripherals.removeValue(forKey: trimmed)
        discoveredPeripherals.removeValue(forKey: trimmed.uppercased())
        discoveredPeripherals.removeValue(forKey: trimmed.lowercased())
    }

    private func retryPostProvisionProxyConnectIfNeeded(reason: String) -> Bool {
        guard proxyPostProvisionRetriesLeft > 0,
              let peripheralId = proxyPostProvisionPeripheralId else {
            return false
        }
        proxyPostProvisionRetriesLeft -= 1
        MeshLog.d(
            "PROXY",
            "配网后 Proxy 重试(\(proxyPostProvisionRetriesLeft) 次剩余) reason=\(reason)"
        )
        forceRediscoverProxyServices = true
        invalidatePeripheralCache(for: peripheralId)
        disconnectProxyGATT()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.enqueueProxyConfiguration(for: peripheralId)
            self.startProxyScan(for: peripheralId)
        }
        return true
    }

    private func clearPostProvisionProxyRetryState() {
        proxyPostProvisionRetriesLeft = 0
        proxyPostProvisionPeripheralId = nil
        forceRediscoverProxyServices = false
    }

    private func discoverProxyServices(on peripheral: CBPeripheral) {
        if forceRediscoverProxyServices || proxyServiceDiscoveryAttempts > 0 {
            MeshLog.d("GATT", "discoverServices(nil) 全量发现 Proxy 服务")
            peripheral.discoverServices(nil)
            return
        }
        peripheral.discoverServices([kMeshProxyServiceUUID])
    }

    private func handleMissingProxyService(on peripheral: CBPeripheral) {
        if proxyServiceDiscoveryAttempts < 2 {
            proxyServiceDiscoveryAttempts += 1
            MeshLog.d(
                "GATT",
                "未发现 0x1828，全量重试 discoverServices(nil) "
                    + "attempt=\(proxyServiceDiscoveryAttempts)"
            )
            peripheral.discoverServices(nil)
            return
        }
        if retryPostProvisionProxyConnectIfNeeded(
            reason: "未发现 Mesh Proxy Service（ESP GATT 可能仍在切换）"
        ) {
            centralManager?.cancelPeripheralConnection(peripheral)
            connectedPeripheral = nil
            dataInCharacteristic = nil
            return
        }
        centralManager?.cancelPeripheralConnection(peripheral)
        connectedPeripheral = nil
        dataInCharacteristic = nil
        sendEvent(["type": "connectionStateChanged", "state": "disconnected"])
        sendEvent([
            "type": "error",
            "code": "NO_PROXY_SERVICE",
            "message": "设备不支持 Mesh Proxy Service（配网后请稍后重试连接）",
        ])
    }

    /// 删除节点：已连 Proxy 则直接 Reset；否则先自动连接 Proxy 再删除。
    private func handleDeleteNode(unicastAddress: Int, result: @escaping FlutterResult) {
        MeshLog.d("DELETE", "═══ 删除节点 0x\(String(format: "%04X", unicastAddress)) ═══")
        guard let bridge = meshBridge else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }
        bridge.logNetworkState("删除前")
        logPluginCacheState("删除前")

        let nodeInfo = bridge.getNodes().first(where: {
            nodeUnicastAddress(from: $0) == unicastAddress
        })
        pendingDeleteNodeUuid = nodeInfo?["uuid"] as? String
        MeshLog.d(
            "DELETE",
            "待删节点 uuid=\(pendingDeleteNodeUuid ?? "nil") "
                + "mac=\(nodeInfo?["macAddress"] as? String ?? "nil") "
                + "Plugin已连Proxy=\(dataInCharacteristic != nil)"
        )

        pendingDeleteResult = result

        let runDelete = {
            bridge.deleteNode(unicastAddress: UInt16(unicastAddress)) { [weak self] error in
                guard let self else { return }
                let uuid = self.pendingDeleteNodeUuid
                MeshLog.d(
                    "DELETE",
                    "deleteNode 桥接回调 error=\(error?.localizedDescription ?? "nil")"
                )
                self.completeDeleteFlow(
                    unicastAddress: unicastAddress,
                    deletedUuid: uuid,
                    error: error
                )
            }
        }

        if dataInCharacteristic != nil {
            MeshLog.d("DELETE", "Proxy 已连接，直接发送 ConfigNodeReset")
            runDelete()
            return
        }

        guard let nodeInfo else {
            pendingDeleteResult = nil
            result(FlutterError(code: "NODE_NOT_FOUND", message: "节点不存在", details: nil))
            return
        }

        let target = (nodeInfo["macAddress"] as? String)
            ?? (nodeInfo["uuid"] as? String)
        guard let target, !target.isEmpty else {
            pendingDeleteResult = nil
            result(FlutterError(
                code: "DEVICE_NOT_FOUND",
                message: "未缓存设备标识，请重新配网后再删除",
                details: nil
            ))
            return
        }

        MeshLog.d("DELETE", "Proxy 未连接，先连接 \(target) 再 Reset")
        pendingDeleteUnicastAddress = UInt16(unicastAddress)
        handleConnectToProxy(address: target, result: { _ in })
    }

    private func completePendingDeleteIfNeeded() {
        guard let address = pendingDeleteUnicastAddress,
              pendingDeleteResult != nil,
              dataInCharacteristic != nil,
              let bridge = meshBridge else { return }

        pendingDeleteUnicastAddress = nil
        MeshLog.d("DELETE", "Proxy 已就绪，继续删除节点 0x\(String(format: "%04X", address))")
        bridge.deleteNode(unicastAddress: address) { [weak self] error in
            guard let self else { return }
            let uuid = self.pendingDeleteNodeUuid
            MeshLog.d(
                "DELETE",
                "deleteNode 桥接回调 error=\(error?.localizedDescription ?? "nil")"
            )
            self.completeDeleteFlow(
                unicastAddress: Int(address),
                deletedUuid: uuid,
                error: error
            )
        }
    }

    private func failPendingDelete(message: String) {
        guard let flutterResult = pendingDeleteResult else { return }
        pendingDeleteUnicastAddress = nil
        pendingDeleteResult = nil
        pendingDeleteNodeUuid = nil
        MeshLog.e("DELETE", "删除中止: \(message)")
        flutterResult(FlutterError(code: "CONNECTION_FAILED", message: message, details: nil))
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral, reportedAddress: String) {
        guard let central = centralManager else { return }

        cancelPendingProxyConnect()

        if let current = connectedPeripheral,
           current.identifier == peripheral.identifier,
           dataInCharacteristic != nil {
            sendEvent([
                "type": "connectionStateChanged",
                "state": "connected",
                "address": reportedAddress,
            ])
            // 已连接时仍需触发配置（避免卡在「等待密钥分发」）。
            triggerPendingAutoConfig()
            return
        }

        if let current = connectedPeripheral,
           current.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(current)
        }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        dataInCharacteristic = nil

        sendEvent([
            "type": "connectionStateChanged",
            "state": "connecting",
            "address": reportedAddress,
        ])
        central.connect(peripheral, options: nil)
    }

    // MARK: - 控制消息（委托给 IosMeshNetworkBridge 加密发送）

    private func handleSendGenericOnOff(
        address: Int,
        onOff: Bool,
        appKeyIndex: Int,
        acknowledged: Bool,
        result: FlutterResult
    ) {
        guard let bridge = meshBridge else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }
        bridge.sendGenericOnOff(
            address: UInt16(address),
            onOff: onOff,
            appKeyIndex: appKeyIndex,
            acknowledged: acknowledged
        )
        result(nil)
    }

    private func handleSendGenericLevel(
        address: Int,
        level: Int,
        appKeyIndex: Int,
        acknowledged: Bool,
        result: FlutterResult
    ) {
        guard let bridge = meshBridge else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }
        bridge.sendGenericLevel(
            address: UInt16(address),
            level: level,
            appKeyIndex: appKeyIndex,
            acknowledged: acknowledged
        )
        result(nil)
    }

    private func handleSendLightLightness(
        address: Int,
        lightness: Int,
        appKeyIndex: Int,
        acknowledged: Bool,
        result: FlutterResult
    ) {
        // Light Lightness → Generic Level 映射（lightness 0-65535 → level -32768~32767）
        handleSendGenericLevel(
            address: address,
            level: Int(lightness) - 32768,
            appKeyIndex: appKeyIndex,
            acknowledged: acknowledged,
            result: result
        )
    }

    // MARK: - Vendor 消息

    private func handleSendVendorMessage(
        address: Int,
        companyId: Int,
        modelId: Int,
        opCode: Int,
        payload: Data,
        appKeyIndex: Int,
        acknowledged: Bool,
        result: FlutterResult
    ) {
        guard let bridge = meshBridge else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "请先调用 initialize()", details: nil))
            return
        }
        bridge.sendVendorMessage(
            address: UInt16(address),
            companyId: companyId,
            opCode: opCode,
            payload: payload,
            appKeyIndex: appKeyIndex
        )
        result(nil)
    }

    /// 向 Dart 端发送事件（线程安全）。
    private func sendEvent(_ event: [String: Any?]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleMeshPlugin: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = bluetoothStateString()
        MeshLog.d("GATT", "centralManagerDidUpdateState → \(state)")
        sendEvent(["type": "bluetoothStateChanged", "state": state])

        if central.state == .poweredOn,
           let pending = pendingProxyAddress,
           connectedPeripheral == nil || dataInCharacteristic == nil {
            if let peripheral = resolvePeripheral(for: pending) {
                connectToPeripheral(peripheral, reportedAddress: peripheral.identifier.uuidString)
            } else {
                startProxyScan(for: pending)
            }
        }
    }

    /// 扫描到广播配网服务的设备时触发。
    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let deviceId = peripheral.identifier.uuidString
        let meshUUID = extractMeshUUID(from: advertisementData)
        cachePeripheral(peripheral, meshUUID: meshUUID)

        if let pending = pendingProxyAddress,
           matchesProxyTarget(
               peripheral: peripheral,
               target: pending,
               advertisementData: advertisementData
           ) {
            connectToPeripheral(peripheral, reportedAddress: deviceId)
            return
        }

        // 配网扫描去重
        guard !discoveredDeviceUUIDs.contains(deviceId) else { return }
        discoveredDeviceUUIDs.insert(deviceId)

        let deviceName = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "未知设备"

        let deviceMap: [String: Any?] = [
            "uuid": meshUUID ?? deviceId,
            "name": deviceName,
            "rssi": RSSI.intValue,
            "address": deviceId,
        ]

        sendEvent(["type": "scanResult", "device": deviceMap])
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MeshLog.d("GATT", "didConnect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil")")
        central.stopScan()
        proxyConnectTimer?.invalidate()
        proxyConnectTimer = nil
        pendingProxyAddress = nil
        proxyServiceDiscoveryAttempts = 0
        discoverProxyServices(on: peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MeshLog.e("GATT", "didFailToConnect id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "nil")")
        connectedPeripheral = nil
        failPendingDelete(message: error?.localizedDescription ?? "连接失败")
        sendEvent(["type": "connectionStateChanged", "state": "disconnected"])
        sendEvent([
            "type": "error",
            "code": "CONNECTION_FAILED",
            "message": error?.localizedDescription ?? "连接失败",
        ])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MeshLog.d(
            "GATT",
            "didDisconnect id=\(peripheral.identifier.uuidString) "
                + "error=\(error?.localizedDescription ?? "nil") "
                + "pendingProvision=\(pendingProvision != nil) "
                + "pendingDelete=\(pendingDeleteUnicastAddress != nil)"
        )
        connectedPeripheral = nil
        dataInCharacteristic = nil
        clearProxyWriteQueue()
        meshBridge?.notifyProxyDisconnected()
        sendEvent(["type": "connectionStateChanged", "state": "disconnected"])
        resumePendingDeleteAfterDisconnect()
        resumePendingProvisionAfterDisconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BleMeshPlugin: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            if retryPostProvisionProxyConnectIfNeeded(
                reason: "服务发现失败: \(error!.localizedDescription)"
            ) {
                return
            }
            sendEvent(["type": "error", "code": "SERVICE_DISCOVERY_FAILED", "message": error!.localizedDescription])
            return
        }

        let serviceUuids = (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
        MeshLog.d("GATT", "didDiscoverServices: [\(serviceUuids)]")

        guard let proxyService = peripheral.services?.first(where: { $0.uuid == kMeshProxyServiceUUID }) else {
            handleMissingProxyService(on: peripheral)
            return
        }

        forceRediscoverProxyServices = false
        peripheral.discoverCharacteristics(
            [kMeshProxyDataInUUID, kMeshProxyDataOutUUID],
            for: proxyService
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else { return }
        guard service.uuid == kMeshProxyServiceUUID else {
            MeshLog.e(
                "GATT",
                "忽略非 Proxy 服务特征 service=\(service.uuid.uuidString)"
            )
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case kMeshProxyDataInUUID:
                // 保存 Data In 特征用于写入
                dataInCharacteristic = characteristic

            case kMeshProxyDataOutUUID:
                // 订阅 Data Out 特征的通知
                peripheral.setNotifyValue(true, for: characteristic)

            default:
                break
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if error != nil {
            let message = error?.localizedDescription ?? "开启 Proxy 通知失败"
            if retryPostProvisionProxyConnectIfNeeded(reason: message) {
                return
            }
            sendEvent([
                "type": "error",
                "code": "GATT_ERROR",
                "message": message,
            ])
            return
        }

        if characteristic.uuid == kMeshProxyDataOutUUID && characteristic.isNotifying {
            MeshLog.d("Proxy Data Out 通知已开启: \(peripheral.identifier.uuidString)")
            clearPostProvisionProxyRetryState()
            meshBridge?.notifyProxyConnected(transmitter: self)

            sendEvent([
                "type": "connectionStateChanged",
                "state": "connected",
                "address": peripheral.identifier.uuidString,
            ])

            if pendingDeleteUnicastAddress != nil {
                completePendingDeleteIfNeeded()
            } else {
                triggerPendingAutoConfig()
            }
        }
    }

    /// GATT 写入完成，继续发送队列中的下一条 Proxy PDU。
    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == kMeshProxyDataInUUID else { return }
        proxyWriteInProgress = false
        if let error {
            MeshLog.e("Proxy GATT 写入失败: \(error.localizedDescription)")
            clearProxyWriteQueue()
            return
        }
        drainProxyWriteQueue()
    }

    /// 收到代理节点推送的 Mesh PDU 通知。
    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == kMeshProxyDataOutUUID,
              let data = characteristic.value else { return }

        // 将原始 GATT Proxy 数据交给 Nordic 加密栈解析（SAR + 解密 + 路由）。
        meshBridge?.handleProxyData(data)
    }
}

// MARK: - FlutterStreamHandler

extension BleMeshPlugin: FlutterStreamHandler {

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

// MARK: - Nordic Mesh Transmitter
//
// BleMeshPlugin 实现 Transmitter 协议，成为 Nordic MeshNetworkManager 的发送通道。
// 当 Nordic 需要向设备写数据时，调用此方法；我们通过 Data In 特征写入。

extension BleMeshPlugin: Transmitter {

    // MARK: - 自动配置触发

    /// Proxy 连接就绪后触发自动配置（对齐 Android onProxyConnected）。
    private func triggerPendingAutoConfig() {
        // ESP Proxy 栈在 GATT 连接后需短暂稳定再发 Config 消息。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.meshBridge?.onProxyConnected()
        }
    }

    /// Nordic 请求通过 GATT Proxy 发送数据（入队串行写入）。
    public func send(_ data: Data, ofType type: PduType) throws {
        guard connectedPeripheral != nil, dataInCharacteristic != nil else {
            MeshLog.e("Transmitter.send 失败: Proxy 未连接")
            throw ProxyTransmitError.notConnected
        }
        let header = UInt8(type.rawValue & 0x3F)
        var pdu = Data([header])
        pdu.append(data)
        MeshLog.d("Transmitter.send 入队: \(pdu.count) 字节 type=\(type.rawValue)")
        proxyWriteQueue.append(pdu)
        drainProxyWriteQueue()
    }

    private func drainProxyWriteQueue() {
        guard !proxyWriteInProgress,
              !proxyWriteQueue.isEmpty,
              let peripheral = connectedPeripheral,
              let characteristic = dataInCharacteristic else { return }

        let pdu = proxyWriteQueue.removeFirst()
        proxyWriteInProgress = true
        let writeType: CBCharacteristicWriteType = characteristic.properties
            .contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(pdu, for: characteristic, type: writeType)

        if writeType == .withoutResponse {
            proxyWriteInProgress = false
            drainProxyWriteQueue()
        }
    }

    private func clearProxyWriteQueue() {
        proxyWriteQueue.removeAll()
        proxyWriteInProgress = false
    }
}

private enum ProxyTransmitError: LocalizedError {
    case notConnected
    var errorDescription: String? { "Mesh Proxy 未连接" }
}
