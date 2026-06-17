package com.ble_mesh.ble_mesh

import android.bluetooth.BluetoothManager
import android.content.Context
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import no.nordicsemi.android.mesh.ApplicationKey
import no.nordicsemi.android.mesh.Group
import no.nordicsemi.android.mesh.MeshManagerApi
import no.nordicsemi.android.mesh.MeshManagerCallbacks
import no.nordicsemi.android.mesh.MeshStatusCallbacks
import no.nordicsemi.android.mesh.MeshNetwork
import no.nordicsemi.android.mesh.MeshProvisioningStatusCallbacks
import no.nordicsemi.android.mesh.NodeKey
import no.nordicsemi.android.mesh.provisionerstates.ProvisioningState
import no.nordicsemi.android.mesh.transport.ConfigAppKeyStatus
import no.nordicsemi.android.mesh.transport.ConfigCompositionDataGet
import no.nordicsemi.android.mesh.transport.ConfigCompositionDataStatus
import no.nordicsemi.android.mesh.provisionerstates.UnprovisionedMeshNode
import no.nordicsemi.android.mesh.transport.ConfigAppKeyAdd
import no.nordicsemi.android.mesh.transport.ConfigModelAppBind
import no.nordicsemi.android.mesh.transport.ConfigModelAppStatus
import no.nordicsemi.android.mesh.transport.ConfigModelAppUnbind
import no.nordicsemi.android.mesh.transport.ConfigModelPublicationSet
import no.nordicsemi.android.mesh.transport.ConfigModelSubscriptionAdd
import no.nordicsemi.android.mesh.transport.ConfigModelSubscriptionDelete
import no.nordicsemi.android.mesh.transport.ConfigNodeReset
import no.nordicsemi.android.mesh.transport.ControlMessage
import no.nordicsemi.android.mesh.transport.Element
import no.nordicsemi.android.mesh.transport.GenericLevelSet
import no.nordicsemi.android.mesh.transport.GenericLevelSetUnacknowledged
import no.nordicsemi.android.mesh.transport.GenericOnOffSet
import no.nordicsemi.android.mesh.transport.GenericOnOffSetUnacknowledged
import no.nordicsemi.android.mesh.transport.LightLightnessSet
import no.nordicsemi.android.mesh.transport.LightLightnessSetUnacknowledged
import no.nordicsemi.android.mesh.transport.MeshMessage
import no.nordicsemi.android.mesh.transport.ProvisionedMeshNode
import no.nordicsemi.android.mesh.transport.SceneDelete
import no.nordicsemi.android.mesh.transport.SceneRecall
import no.nordicsemi.android.mesh.transport.SceneStore
import no.nordicsemi.android.mesh.transport.VendorModelMessageAcked
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/**
 * BLE Mesh 网络管理器——基于 Nordic nRF Mesh Library (3.3.7) 的真实实现。
 *
 * 实现了 [MeshManagerCallbacks] 和 [MeshProvisioningStatusCallbacks]，
 * 将 nRF Mesh 库的回调转换为 EventChannel 事件推送给 Dart 层。
 *
 * ## 配网流程（PB-GATT）
 * 1. [provisionDevice] → 通过 [PbGattManager] 连接设备的 0x1827 服务
 * 2. 连接成功后调用 [MeshManagerApi.identifyNode]，库发送 Provisioning Invite
 * 3. 设备回应 Capabilities → 库触发 [onProvisioningStateChanged]
 * 4. 自动调用 [MeshManagerApi.startProvisioning]，执行密钥交换
 * 5. 配网完成 → [onProvisioningCompleted] → 自动分发 AppKey 并绑定模型
 *
 * ## 消息发送流程
 * 1. 调用 [sendGenericOnOff] 等方法 → 调用 [MeshManagerApi.createMeshPdu]
 * 2. 库触发 [onMeshPduCreated] 回调，将加密后的 PDU 交给 [BleGattManager] 写入 GATT
 */
class BleMeshNetworkManager(
    private val context: Context,
    @Suppress("unused") private val eventSink: MeshEventStreamHandler,
) : MeshManagerCallbacks, MeshProvisioningStatusCallbacks {

    companion object {
        private const val TAG = "BleMeshNetworkManager"
        private const val CONFIG_TIMEOUT_MS = 8_000L
        private const val DEFAULT_APP_KEY_INDEX = 0

        /** 配网后等待 Proxy 广播的最短间隔（设备切换 PB-GATT → Proxy）。 */
        private const val PROXY_MIN_SWITCH_MS = 400L

        /** 配网后扫描 Proxy 广播的最长等待。 */
        private const val PROXY_SCAN_TIMEOUT_MS = 4_000L

        /** 配置消息之间的间隔（过短可能导致设备丢包）。 */
        private const val CONFIG_STEP_DELAY_MS = 100L
        private const val CONFIG_BIND_DELAY_MS = 60L
        private const val CONFIG_INITIAL_DELAY_MS = 120L

        /** 配网完成后自动绑定 AppKey 的 SIG Model IDs（16 位）。 */
        private val SIG_MODELS_TO_BIND = listOf(
            0x1000, // Generic OnOff Server
            0x1002, // Generic Level Server
        )

        /**
         * 需要绑定的 Vendor Model 列表（Pair<companyId, modelId>）。
         *
         * CID 0x02e5 为设备固件中定义的厂商标识（Espressif）。
         * 绑定后应用层方可向这两个 Vendor Model 发送消息。
         */
        private val VENDOR_MODELS_TO_BIND = listOf(
            0x02e5 to 0x0001, // 同步模型（Sync Model）
            0x02e5 to 0x0002, // 设备控制模型（Device Control Model）
        )
    }

    // ── nRF Mesh API ──────────────────────────────────────────────────────────

    val meshManagerApi = MeshManagerApi(context)

    /** 协程作用域，用于配网后的自动 AppKey 分发。 */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ── 外部注入依赖 ──────────────────────────────────────────────────────────

    /** 配网专用 PB-GATT 管理器，由 [provisionDevice] 创建。 */
    private var pbGattManager: PbGattManager? = null

    /** 代理通信 GATT 管理器，由 [BleMeshPlugin] 注入。 */
    var gattManager: BleGattManager? = null

    /** BLE 扫描管理器，用于配网后主动检测 Proxy 广播。 */
    var scanManager: BleScanManager? = null

    // ── 临时状态 ──────────────────────────────────────────────────────────────

    /** 当前正在配网的设备 UUID，配网结束后清空。 */
    private var pendingProvisionUuid: String? = null

    /** 当前正在配网的设备 MAC 地址，配网完成后持久保存到缓存。 */
    private var pendingProvisionAddress: String? = null

    /** 当前正在配网的节点，用于 startProvisioning 调用。 */
    private var pendingMeshNode: UnprovisionedMeshNode? = null

    /**
     * UUID → MAC 地址的运行时缓存（不持久化，App 重启后需重新扫描）。
     * 配网时填充，供后续 Proxy 连接使用。
     */
    private val nodeAddressCache = mutableMapOf<String, String>()

    /** TID 计数器（Transaction Identifier，0x00-0xFF 循环）。 */
    private val tidCounter = AtomicInteger(0)

    /**
     * 刚完成配网、等待在 Proxy 阶段继续下发 AppKey / 绑定模型的节点地址。
     *
     * 不再依赖 provisionerAddress 排除逻辑，避免首个真实节点为 0x0001 时被误跳过。
     */
    private val pendingProxyInitializationAddresses = linkedSetOf<Int>()

    /** 正在执行自动 Proxy 重连的节点地址，避免重复发起连接。 */
    private val autoConnectingProxyAddresses = linkedSetOf<Int>()

    private val pendingCompositionRequests =
        mutableMapOf<Int, CompletableDeferred<ConfigCompositionDataStatus>>()
    private val pendingAppKeyStatusRequests =
        mutableMapOf<Int, CompletableDeferred<ConfigAppKeyStatus>>()
    private val pendingModelBindRequests =
        mutableMapOf<String, CompletableDeferred<ConfigModelAppStatus>>()

    private var isRepairingMeshNetwork = false

    private var networkImportDeferred: CompletableDeferred<Unit>? = null

    /** 配网前等待网络修复完成。 */
    private var networkReadyDeferred: CompletableDeferred<Unit>? = null

    /** 防止 Proxy 就绪回调重复触发配置流程。 */
    @Volatile
    private var proxyInitializationInProgress = false

    private val meshStatusCallbacks = object : MeshStatusCallbacks {
        override fun onTransactionFailed(dst: Int, hasIncompleteTimerExpired: Boolean) {
            Log.e(
                TAG,
                "配置事务失败: dst=0x${dst.toString(16)} incompleteTimerExpired=$hasIncompleteTimerExpired",
            )
            failPendingConfiguration(dst, "配置事务失败")
        }

        override fun onUnknownPduReceived(src: Int, accessPayload: ByteArray) {
            Log.w(TAG, "收到未知 PDU: src=0x${src.toString(16)} len=${accessPayload.size}")
        }

        override fun onBlockAcknowledgementProcessed(
            src: Int,
            message: ControlMessage,
        ) {
        }

        override fun onBlockAcknowledgementReceived(
            src: Int,
            message: ControlMessage,
        ) {
        }

        override fun onHeartbeatMessageReceived(
            src: Int,
            message: ControlMessage,
        ) {
        }

        override fun onMeshMessageProcessed(src: Int, message: MeshMessage) {
            handleConfigStatusMessage(src, message)
        }

        override fun onMeshMessageReceived(src: Int, message: MeshMessage) {
            handleConfigStatusMessage(src, message)
        }

        override fun onMessageDecryptionFailed(meshLayer: String, errorMessage: String) {
            Log.e(TAG, "消息解密失败: layer=$meshLayer error=$errorMessage")
        }
    }

    // ── 初始化 ─────────────────────────────────────────────────────────────────

    init {
        meshManagerApi.setMeshManagerCallbacks(this)
        meshManagerApi.setProvisioningStatusCallbacks(this)
        meshManagerApi.setMeshStatusCallbacks(meshStatusCallbacks)
    }

    /** 加载或创建 Mesh 网络。必须在所有操作之前调用。 */
    fun initialize() {
        Log.d(TAG, "加载 Mesh 网络...")
        meshManagerApi.loadMeshNetwork()
    }

    /** 释放资源，清理 GATT 连接和网络数据。 */
    fun dispose() {
        pbGattManager?.disconnect()
        pbGattManager = null
    }

    // ── MeshManagerCallbacks ───────────────────────────────────────────────────

    override fun onNetworkLoaded(meshNetwork: MeshNetwork) {
        if (!ensureNordicCompatibleNetwork(meshNetwork)) {
            return
        }

        try {
            ensureDefaultAppKey(meshNetwork)
        } catch (e: Exception) {
            Log.e(TAG, "初始化网络默认配置失败: ${e.message}")
            MeshEventStreamHandler.sendError(
                "NETWORK_INIT_FAILED",
                "初始化网络默认配置失败: ${e.message}",
            )
        }
        Log.d(TAG, "Mesh 网络已加载: ${meshNetwork.meshName}")
        logNetworkState(meshNetwork)
        networkReadyDeferred?.complete(Unit)
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkLoaded"))
    }

    /** 打印 Mesh 网络状态，用于调试。 */
    private fun logNetworkState(network: MeshNetwork) {
        val provisioner = network.selectedProvisioner
        val provAddr = provisioner?.provisionerAddress
        Log.d(TAG, "===== Mesh 网络状态 =====")
        Log.d(TAG, "Provisioner 地址: ${provAddr?.let { "0x${it.toString(16)}" } ?: "null"}")
        Log.d(TAG, "NetKey 数: ${network.netKeys.size}, AppKey 数: ${network.appKeys.size}")
        Log.d(TAG, "节点分配范围: ${provisioner?.allocatedUnicastRanges?.joinToString { "[0x${it.lowAddress.toString(16)}-0x${it.highAddress.toString(16)}]" } ?: "无"}")
        Log.d(TAG, "已配网节点数: ${network.nodes.size}")
        network.nodes.forEach { n ->
            Log.d(TAG, "  节点: ${n.nodeName} → 0x${n.unicastAddress.toString(16)} (AppKeys: ${n.addedAppKeys?.size ?: 0})")
        }
        Log.d(TAG, "=========================")
    }

    override fun onNetworkUpdated(meshNetwork: MeshNetwork) {
        Log.d(TAG, "Mesh 网络已更新")
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    override fun onNetworkLoadFailed(error: String) {
        Log.e(TAG, "加载网络失败: $error")
        if (!isRepairingMeshNetwork) {
            isRepairingMeshNetwork = true
            Log.w(TAG, "现有 Mesh DB 不可用，按 nRF 默认流程重建网络")
            meshManagerApi.createMeshNetwork()
            return
        }
        MeshEventStreamHandler.sendError("NETWORK_LOAD_FAILED", "加载 Mesh 网络失败: $error")
    }

    override fun onNetworkImported(meshNetwork: MeshNetwork) {
        Log.d(TAG, "Mesh 网络已导入: ${meshNetwork.meshName}")
        networkImportDeferred?.complete(Unit)
        networkImportDeferred = null
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkLoaded"))
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    override fun onNetworkImportFailed(error: String) {
        Log.e(TAG, "导入网络失败: $error")
        networkImportDeferred?.completeExceptionally(
            IllegalStateException("导入网络失败: $error"),
        )
        networkImportDeferred = null
        MeshEventStreamHandler.sendError("NETWORK_IMPORT_FAILED", error)
    }

    /**
     * nRF Mesh 库需要发送配网 PDU 时触发，将数据路由到 [PbGattManager]。
     */
    override fun sendProvisioningPdu(meshNode: UnprovisionedMeshNode, pdu: ByteArray) {
        Log.v(TAG, "发送配网 PDU: ${pdu.size} 字节")
        pbGattManager?.sendPdu(pdu)
            ?: Log.e(TAG, "sendProvisioningPdu 失败：PbGattManager 未初始化")
    }

    /**
     * nRF Mesh 库需要发送加密 Mesh PDU 时触发（替代旧版 sendMeshPdu）。
     *
     * 将已加密的 PDU 路由到 [BleGattManager] 通过 Proxy Service 写入设备。
     * 若此回调被调用，说明库确实尝试向外部设备发送数据（未被内部截获）。
     */
    override fun onMeshPduCreated(pdu: ByteArray) {
        val gatt = gattManager
        if (gatt == null) {
            Log.e(TAG, "onMeshPduCreated: BleGattManager 为 null，PDU 无法发出！请先连接 Proxy")
        } else if (!gatt.isConnected) {
            Log.e(TAG, "onMeshPduCreated: Proxy 未连接（isConnected=false），PDU 无法发出！")
        } else {
            Log.d(TAG, "onMeshPduCreated: 发送 ${pdu.size} 字节到 GATT → 0x${pdu.take(4).joinToString("") { "%02X".format(it) }}...")
            gatt.sendPdu(pdu)
        }
    }

    /** 返回当前可用的 MTU 载荷大小。 */
    override fun getMtu(): Int =
        pbGattManager?.getMtu() ?: gattManager?.getMtu() ?: 69

    // ── MeshProvisioningStatusCallbacks ───────────────────────────────────────

    /**
     * 配网各阶段状态变化回调。
     *
     * 当状态为 [ProvisioningState.States.PROVISIONING_CAPABILITIES]（设备能力已接收）时，
     * 自动调用 [MeshManagerApi.startProvisioning] 继续配网流程。
     */
    override fun onProvisioningStateChanged(
        meshNode: UnprovisionedMeshNode,
        state: ProvisioningState.States,
        data: ByteArray?,
    ) {
        val uuid = pendingProvisionUuid ?: meshNode.deviceUuid.toString()
        val stateStr = when (state) {
            ProvisioningState.States.PROVISIONING_INVITE -> "connecting"
            ProvisioningState.States.PROVISIONING_CAPABILITIES -> {
                pendingMeshNode = meshNode
                scope.launch {
                    try {
                        val network = meshManagerApi.meshNetwork
                            ?: throw IllegalStateException("meshNetwork 为 null")
                        val unicastAddress = resolveNextUnicastAddress(meshNode)
                        network.assignUnicastAddress(unicastAddress)
                        Log.d(
                            TAG,
                            "收到设备能力，分配单播地址 0x${unicastAddress.toString(16)}，开始密钥交换...",
                        )
                        meshManagerApi.startProvisioning(meshNode)
                    } catch (e: Exception) {
                        Log.e(TAG, "startProvisioning 异常: ${e.message}")
                        MeshEventStreamHandler.sendProvisioningState("failed", uuid)
                        MeshEventStreamHandler.sendError(
                            "PROVISIONING_FAILED",
                            "配网启动失败: ${e.message}",
                        )
                    }
                }
                "identifying"
            }
            ProvisioningState.States.PROVISIONING_START,
            ProvisioningState.States.PROVISIONING_PUBLIC_KEY_SENT,
            ProvisioningState.States.PROVISIONING_PUBLIC_KEY_WAITING,
            ProvisioningState.States.PROVISIONING_PUBLIC_KEY_RECEIVED,
            ProvisioningState.States.PROVISIONING_AUTHENTICATION_INPUT_OOB_WAITING,
            ProvisioningState.States.PROVISIONING_AUTHENTICATION_OUTPUT_OOB_WAITING,
            ProvisioningState.States.PROVISIONING_AUTHENTICATION_STATIC_OOB_WAITING,
            ProvisioningState.States.PROVISIONING_AUTHENTICATION_INPUT_ENTERED,
            ProvisioningState.States.PROVISIONING_INPUT_COMPLETE -> "exchangingKeys"
            ProvisioningState.States.PROVISIONING_CONFIRMATION_SENT,
            ProvisioningState.States.PROVISIONING_CONFIRMATION_RECEIVED,
            ProvisioningState.States.PROVISIONING_RANDOM_SENT,
            ProvisioningState.States.PROVISIONING_RANDOM_RECEIVED,
            ProvisioningState.States.PROVISIONING_DATA_SENT -> "provisioning"
            else -> "provisioning"
        }
        Log.d(TAG, "配网阶段: $state → Dart 状态: $stateStr")
        MeshEventStreamHandler.sendProvisioningState(stateStr, uuid)
    }

    /** 配网失败回调。 */
    override fun onProvisioningFailed(
        meshNode: UnprovisionedMeshNode,
        state: ProvisioningState.States,
        data: ByteArray?,
    ) {
        val uuid = pendingProvisionUuid ?: meshNode.deviceUuid.toString()
        Log.e(TAG, "配网失败，阶段: $state")
        MeshEventStreamHandler.sendProvisioningState("failed", uuid)
        MeshEventStreamHandler.sendError("PROVISIONING_FAILED", "配网失败，阶段: $state")
        clearProvisioningState()
    }

    /**
     * 配网成功回调。
     *
     * 配网完成后自动执行：
     * 1. 向节点分发 AppKey（[ConfigAppKeyAdd]）
     * 2. 绑定常用模型（[ConfigModelAppBind]）
     */
    override fun onProvisioningCompleted(
        meshNode: ProvisionedMeshNode,
        state: ProvisioningState.States,
        data: ByteArray?,
    ) {
        val uuid = pendingProvisionUuid ?: meshNode.uuid
        val mac = pendingProvisionAddress
        Log.d(
            TAG,
            "配网成功: ${meshNode.nodeName} 地址=0x${meshNode.unicastAddress.toString(16)} mac=$mac",
        )

        // 缓存 UUID → MAC，供后续 Proxy 连接使用
        if (mac != null) nodeAddressCache[uuid] = mac

        clearProvisioningState()
        pbGattManager?.disconnect()
        pbGattManager = null

        val nodeMap = buildNodeMap(meshNode)
        pendingProxyInitializationAddresses += meshNode.unicastAddress
        Log.d(
            TAG,
            "节点 0x${meshNode.unicastAddress.toString(16)} 已加入待 Proxy 初始化队列",
        )
        MeshEventStreamHandler.sendProvisioningState("complete", uuid)
        MeshEventStreamHandler.sendConfigurationState(
            state = "pendingProxy",
            uuid = uuid,
            unicastAddress = meshNode.unicastAddress,
            message = "配网完成，等待通过 Proxy 继续下发 Config AppKey Add / Model App Bind",
        )
        MeshEventStreamHandler.sendNodeAdded(nodeMap)
        if (mac != null) {
            scheduleAutomaticProxyConnection(
                uuid = uuid,
                macAddress = mac,
                unicastAddress = meshNode.unicastAddress,
            )
        } else {
            MeshEventStreamHandler.sendConfigurationState(
                state = "failed",
                uuid = uuid,
                unicastAddress = meshNode.unicastAddress,
                message = "缺少节点 MAC 地址，无法自动切换到 Proxy",
            )
        }
    }

    // ── 配网操作 ───────────────────────────────────────────────────────────────

    /**
     * 通过 PB-GATT 对目标设备执行真实的 BLE Mesh 配网。
     *
     * 连接设备的 Mesh Provisioning Service (0x1827)，启动 nRF Mesh 库的
     * 完整配网协议（Invite → Capabilities → Start → Key Exchange → Data → Complete）。
     *
     * @param uuid 设备 UUID（从扫描结果获取，16 字节 UUID 字符串格式）。
     * @param address 设备蓝牙 MAC 地址。
     * @param nodeName 配网后节点名称（当前版本仅打印日志，库内部自动分配）。
     */
    suspend fun provisionDevice(uuid: String, address: String, nodeName: String?) {
        Log.d(TAG, "开始配网: uuid=$uuid address=$address name=$nodeName")
        try {
            ensureNetworkReadyForProvisioning()
        } catch (e: Exception) {
            Log.e(TAG, "配网前网络检查失败: ${e.message}")
            MeshEventStreamHandler.sendProvisioningState("failed", uuid)
            MeshEventStreamHandler.sendError(
                "NETWORK_NOT_READY",
                "Mesh 网络未就绪，无法开始配网: ${e.message}",
            )
            return
        }

        pendingProvisionUuid = uuid
        pendingProvisionAddress = address

        val adapter =
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            MeshEventStreamHandler.sendError("INVALID_ADDRESS", "蓝牙地址格式无效: $address")
            return
        }

        MeshEventStreamHandler.sendProvisioningState("connecting", uuid)

        pbGattManager?.disconnect()
        pbGattManager = PbGattManager(
            context = context,
            onDataReceived = { mtu, data ->
                meshManagerApi.handleNotifications(mtu, data)
            },
            onDataSent = { mtu, data ->
                meshManagerApi.handleWriteCallbacks(mtu, data)
            },
            onConnected = {
                Log.d(TAG, "PB-GATT 就绪，发送配网 Invite...")
                MeshEventStreamHandler.sendProvisioningState("connecting", uuid)
                try {
                    meshManagerApi.identifyNode(UUID.fromString(uuid))
                } catch (e: Exception) {
                    Log.e(TAG, "identifyNode 异常: ${e.message}")
                    MeshEventStreamHandler.sendProvisioningState("failed", uuid)
                    MeshEventStreamHandler.sendError(
                        "PROVISIONING_FAILED",
                        "设备识别失败: ${e.message}",
                    )
                    clearProvisioningState()
                }
            },
            onDisconnected = {
                Log.d(TAG, "PB-GATT 已断开")
                if (pendingProvisionUuid != null) {
                    MeshEventStreamHandler.sendProvisioningState(
                        "failed",
                        pendingProvisionUuid,
                    )
                    MeshEventStreamHandler.sendError(
                        "PROVISIONING_FAILED",
                        "配网期间连接断开，请重试",
                    )
                    clearProvisioningState()
                }
            },
            onError = { message ->
                Log.e(TAG, "PB-GATT 错误: $message")
                MeshEventStreamHandler.sendProvisioningState("failed", uuid)
                MeshEventStreamHandler.sendError("PROVISIONING_FAILED", message)
                clearProvisioningState()
            },
        )
        pbGattManager!!.connect(device)
    }

    /**
     * Proxy 连接建立后调用，自动向网络中所有节点（跳过 Provisioner 自身）分发 AppKey。
     *
     * 由 [BleGattManager] 在代理通道（0x1828）就绪时触发。
     * 即使节点记录中已有 AppKey（可能是上次会话遗留），也会重新尝试分发，
     * 确保设备真实收到密钥。
     */
    fun onProxyConnected() {
        if (proxyInitializationInProgress) {
            Log.d(TAG, "Proxy 配置流程已在进行，跳过重复触发")
            return
        }

        Log.d(TAG, "Proxy 已连接，开始向设备节点下发配置消息...")
        val network = meshManagerApi.meshNetwork ?: run {
            Log.e(TAG, "Proxy 连接后 meshNetwork 为 null，无法分发 AppKey")
            return
        }

        scope.launch {
            proxyInitializationInProgress = true
            try {
            val queuedAddresses = pendingProxyInitializationAddresses.toSet()
            val deviceNodes = when {
                queuedAddresses.isNotEmpty() ->
                    network.nodes.filter { node ->
                        node.unicastAddress in queuedAddresses &&
                            !isProvisionerNode(network, node)
                    }

                else ->
                    network.nodes.filter { node ->
                        !isProvisionerNode(network, node) &&
                            node.addedAppKeys.isNullOrEmpty()
                    }
            }

            Log.d(
                TAG,
                "待分发节点数: ${deviceNodes.size} " +
                    "(queued=${queuedAddresses.joinToString { "0x${it.toString(16)}" }})",
            )

            if (deviceNodes.isEmpty()) {
                Log.d(TAG, "当前无待初始化节点，跳过 AppKey 分发")
                return@launch
            }

            for (node in deviceNodes) {
                val addr = node.unicastAddress
                val uuid = node.uuid
                Log.d(
                    TAG,
                    "向节点 0x${addr.toString(16)} 分发 AppKey " +
                        "(当前已绑定: ${node.addedAppKeys?.size ?: 0} 个)...",
                )
                MeshEventStreamHandler.sendConfigurationState(
                    state = "proxyConnected",
                    uuid = uuid,
                    unicastAddress = addr,
                    message = "Proxy 已连接，开始下发配置消息",
                )
                try {
                    autoDistributeAppKey(node)
                    pendingProxyInitializationAddresses.remove(addr)
                    autoConnectingProxyAddresses.remove(addr)
                    MeshEventStreamHandler.sendConfigurationState(
                        state = "complete",
                        uuid = uuid,
                        unicastAddress = addr,
                        message = "Config AppKey Add / Model App Bind 已发送完成",
                    )
                    Log.d(TAG, "节点 0x${addr.toString(16)} 初始化序列已发送")
                } catch (e: Exception) {
                    autoConnectingProxyAddresses.remove(addr)
                    MeshEventStreamHandler.sendConfigurationState(
                        state = "failed",
                        uuid = uuid,
                        unicastAddress = addr,
                        message = e.message ?: "初始化失败",
                    )
                    MeshEventStreamHandler.sendError(
                        "CONFIGURATION_FAILED",
                        "节点 0x${addr.toString(16)} 配置失败: ${e.message}",
                    )
                    Log.e(
                        TAG,
                        "节点 0x${addr.toString(16)} 初始化失败，将保留在待处理队列: ${e.message}",
                    )
                }
            }
            Log.d(TAG, "所有节点 AppKey 分发任务完成")
            } finally {
                proxyInitializationInProgress = false
            }
        }
    }

    /** 取消正在进行的配网。 */
    fun cancelProvisioning() {
        pbGattManager?.disconnect()
        pbGattManager = null
        val uuid = pendingProvisionUuid
        clearProvisioningState()
        if (uuid != null) {
            MeshEventStreamHandler.sendProvisioningState("idle", uuid)
        }
    }

    // ── 节点管理 ───────────────────────────────────────────────────────────────

    /** 获取所有已配网设备节点（不含本地 Provisioner），返回 Map 列表供 Dart 层解析。 */
    fun getNodes(): List<Map<String, Any?>> {
        val network = meshManagerApi.meshNetwork ?: return emptyList()
        return network.nodes
            .filterNot { isProvisionerNode(network, it) }
            .map { buildNodeMap(it) }
    }

    /** 查询当前 Proxy 连接状态。 */
    fun getConnectionState(): String =
        gattManager?.getMeshConnectionState() ?: "disconnected"

    /** 指定地址的 Proxy 是否已就绪（通知已开启）。 */
    fun isProxyReady(address: String): Boolean =
        gattManager?.isReadyForProxy(address) ?: false

    /** 返回 nRF Mesh App 首页风格的网络摘要信息。 */
    fun getNetworkInfo(): Map<String, Any?> {
        val network = meshManagerApi.meshNetwork ?: return emptyMap()
        val provisioner = network.selectedProvisioner
        val provisionerAddress = provisioner?.provisionerAddress ?: 0
        val provisionerNode = network.getNode(provisionerAddress)
        val sequenceNumber = provisionerNode?.sequenceNumber ?: 0
        val ivIndexState = network.ivIndex

        return mapOf(
            "networkId" to (network.meshUUID ?: ""),
            "name" to (network.meshName ?: "Mesh Network"),
            "ivIndex" to ivIndexState.ivIndex,
            "ivUpdateActive" to ivIndexState.isIvUpdateActive,
            "sequenceNumber" to sequenceNumber,
            "provisionerAddress" to provisionerAddress,
            "networkKeys" to network.netKeys.map { key ->
                mapOf(
                    "index" to key.keyIndex,
                    "name" to (key.name ?: "NetKey ${key.keyIndex}"),
                    "keyHex" to key.key.joinToString("") { "%02X".format(it) },
                    "phase" to key.phase,
                )
            },
            "appKeys" to network.appKeys.map { key ->
                mapOf(
                    "index" to key.keyIndex,
                    "name" to (key.name ?: "AppKey ${key.keyIndex}"),
                    "keyHex" to key.key.joinToString("") { "%02X".format(it) },
                    "phase" to 0,
                )
            },
            "nodeCount" to network.nodes.size,
        )
    }

    /** 导出完整 Mesh 网络 JSON（Mesh Configuration Database Profile 1.0）。 */
    fun exportNetworkJson(): String {
        val json = meshManagerApi.exportMeshNetwork()
            ?: throw IllegalStateException("导出网络失败")
        return json
    }

    /** 从 JSON 导入 Mesh 网络，等待原生回调完成。 */
    suspend fun importNetworkJson(json: String) {
        if (json.isBlank()) {
            throw IllegalArgumentException("导入内容为空")
        }
        val deferred = CompletableDeferred<Unit>()
        networkImportDeferred = deferred
        try {
            meshManagerApi.importMeshNetworkJson(json)
            withTimeout(30_000) {
                deferred.await()
            }
        } catch (e: TimeoutCancellationException) {
            networkImportDeferred = null
            throw IllegalStateException("导入网络超时")
        } catch (e: Exception) {
            if (networkImportDeferred === deferred) {
                networkImportDeferred = null
            }
            throw e
        }
    }

    /** 返回当前网络快照，供 Dart 层映射为 MeshNetwork。 */
    fun getNetworkSnapshot(): Map<String, Any?> {
        val network = meshManagerApi.meshNetwork
        val provisioner = network?.selectedProvisioner
        val provisionerAddress = provisioner?.provisionerAddress ?: 0
        val addressRange =
            provisioner?.allocatedUnicastRanges
                ?.firstOrNull()
                ?.let { listOf(it.lowAddress, it.highAddress) } ?: emptyList()

        return mapOf(
            "networkId" to (network?.meshUUID ?: ""),
            "name" to "Mesh Network",
            "networkKeys" to (
                network?.netKeys?.map { key ->
                    mapOf(
                        "keyId" to "net-${key.keyIndex}",
                        "key" to "",
                        "index" to key.keyIndex,
                        "enabled" to true,
                    )
                } ?: emptyList()
            ),
            "appKeys" to (
                network?.appKeys?.map { key ->
                    mapOf(
                        "keyId" to "app-${key.keyIndex}",
                        "key" to "",
                        "index" to key.keyIndex,
                        "enabled" to true,
                    )
                } ?: emptyList()
            ),
            "nodes" to getNodes(),
            "groups" to getGroups(),
            "provisioner" to mapOf(
                "name" to "Provisioner",
                "provisionerId" to provisionerAddress.toString(),
                "addressRange" to addressRange,
            ),
        )
    }

    /** best-effort 保存当前网络；当前实现由原生 SDK 自动维护持久化。 */
    fun saveNetwork(): Boolean = meshManagerApi.meshNetwork != null

    /**
     * 向节点发送 Config Node Reset，并从网络中删除该节点。
     *
     * @param unicastAddress 要删除的节点单播地址。
     */
    suspend fun deleteNode(unicastAddress: Int) {
        val network = meshManagerApi.meshNetwork ?: return
        val node = network.getNode(unicastAddress) ?: return
        if (isProvisionerNode(network, node)) {
            Log.w(TAG, "拒绝删除 Provisioner 节点: 0x${unicastAddress.toString(16)}")
            MeshEventStreamHandler.sendError(
                "CANNOT_DELETE_PROVISIONER",
                "不能删除本地 Provisioner 节点",
            )
            return
        }
        sendConfigMessage(unicastAddress, ConfigNodeReset())
        network.deleteNode(node)
        Log.d(TAG, "节点已删除: 0x${unicastAddress.toString(16)}")
        MeshEventStreamHandler.sendNodeDeleted(unicastAddress)
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    // ── 分组管理 ───────────────────────────────────────────────────────────────

    /** 获取所有已定义分组。 */
    fun getGroups(): List<Map<String, Any?>> =
        meshManagerApi.meshNetwork?.groups?.map { group ->
            mapOf(
                "address" to group.address,
                "name" to group.name,
            "parentAddress" to null,
        )
        } ?: emptyList()

    /** 在 Mesh 网络中创建新分组（仅本地存储，无需发送 Mesh 消息）。 */
    fun createGroup(name: String, address: Int) {
        val network = meshManagerApi.meshNetwork ?: return
        val group = Group(address, network.meshUUID).apply { this.name = name }
        network.addGroup(group)
        Log.d(TAG, "创建分组: $name 0x${address.toString(16)}")
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    /** 从本地网络中删除分组。 */
    fun deleteGroup(address: Int) {
        val network = meshManagerApi.meshNetwork ?: return
        val group = network.getGroup(address) ?: return
        network.removeGroup(group)
        Log.d(TAG, "删除分组: 0x${address.toString(16)}")
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    /**
     * 发送 Config Model Subscription Add，将模型加入分组。
     */
    suspend fun addSubscription(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        subscriptionAddress: Int,
    ) {
        val msg = ConfigModelSubscriptionAdd(elementAddress, subscriptionAddress, modelId)
        sendConfigMessage(nodeAddress, msg)
        Log.d(
            TAG,
            "订阅添加: node=0x${nodeAddress.toString(16)} " +
                "model=0x${modelId.toString(16)} → 0x${subscriptionAddress.toString(16)}",
        )
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    /**
     * 发送 Config Model Subscription Delete，将模型从分组中移除。
     */
    suspend fun removeSubscription(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        subscriptionAddress: Int,
    ) {
        val msg = ConfigModelSubscriptionDelete(elementAddress, subscriptionAddress, modelId)
        sendConfigMessage(nodeAddress, msg)
        Log.d(
            TAG,
            "订阅删除: node=0x${nodeAddress.toString(16)} model=0x${modelId.toString(16)}",
        )
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    /**
     * 发送 Config Model App Bind，将指定 AppKey 绑定到模型。
     */
    suspend fun bindAppKey(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        appKeyIndex: Int,
    ) {
        val msg = ConfigModelAppBind(elementAddress, modelId, appKeyIndex)
        sendConfigMessage(nodeAddress, msg)
        Log.d(
            TAG,
            "模型绑定 AppKey: node=0x${nodeAddress.toString(16)} " +
                "element=0x${elementAddress.toString(16)} " +
                "model=0x${modelId.toString(16)} appKeyIndex=$appKeyIndex",
        )
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    /**
     * 发送 Config Model App Unbind，将指定 AppKey 从模型解绑。
     */
    suspend fun unbindAppKey(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        appKeyIndex: Int,
    ) {
        val msg = ConfigModelAppUnbind(elementAddress, modelId, appKeyIndex)
        sendConfigMessage(nodeAddress, msg)
        Log.d(
            TAG,
            "模型解绑 AppKey: node=0x${nodeAddress.toString(16)} " +
                "element=0x${elementAddress.toString(16)} " +
                "model=0x${modelId.toString(16)} appKeyIndex=$appKeyIndex",
        )
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    // ── 消息发送 ───────────────────────────────────────────────────────────────

    /** 发送 Generic On/Off Set 消息。 */
    fun sendGenericOnOff(
        address: Int,
        onOff: Boolean,
        appKeyIndex: Int,
        acknowledged: Boolean,
    ) {
        val appKey = getAppKey(appKeyIndex) ?: return
        val msg: MeshMessage = if (acknowledged) {
            GenericOnOffSet(appKey, onOff, nextTid())
        } else {
            GenericOnOffSetUnacknowledged(appKey, onOff, nextTid())
        }
        Log.d(TAG, "Generic OnOff: addr=0x${address.toString(16)} onOff=$onOff")
        meshManagerApi.createMeshPdu(address, msg)
    }

    /** 发送 Generic Level Set 消息（-32768 到 32767）。 */
    fun sendGenericLevel(
        address: Int,
        level: Int,
        appKeyIndex: Int,
        acknowledged: Boolean,
    ) {
        val appKey = getAppKey(appKeyIndex) ?: return
        val msg: MeshMessage = if (acknowledged) {
            GenericLevelSet(appKey, level, nextTid())
        } else {
            GenericLevelSetUnacknowledged(appKey, level, nextTid())
        }
        Log.d(TAG, "Generic Level: addr=0x${address.toString(16)} level=$level")
        meshManagerApi.createMeshPdu(address, msg)
    }

    /** 发送 Light Lightness Set 消息（0 到 65535）。 */
    fun sendLightLightness(
        address: Int,
        lightness: Int,
        appKeyIndex: Int,
        acknowledged: Boolean,
    ) {
        val appKey = getAppKey(appKeyIndex) ?: return
        val msg: MeshMessage = if (acknowledged) {
            LightLightnessSet(appKey, lightness, nextTid())
        } else {
            LightLightnessSetUnacknowledged(appKey, lightness, nextTid())
        }
        Log.d(TAG, "Light Lightness: addr=0x${address.toString(16)} lightness=$lightness")
        meshManagerApi.createMeshPdu(address, msg)
    }

    /**
     * 发送 Vendor Model 消息（操作码按 BLE Mesh Vendor OpCode 格式，3 字节）。
     *
     * 注意：nRF Mesh Library 3.3.x 仅提供 [VendorModelMessageAcked]，
     * `acknowledged` 参数保留接口兼容性，当前两种情况均发送 Acked 消息。
     */
    fun sendVendorMessage(
        address: Int,
        companyId: Int,
        modelId: Int,
        opCode: Int,
        payload: ByteArray,
        appKeyIndex: Int,
        @Suppress("UNUSED_PARAMETER") acknowledged: Boolean,
    ) {
        val appKey = getAppKey(appKeyIndex) ?: return
        val msg = VendorModelMessageAcked(appKey, modelId, companyId, opCode, payload)
        Log.d(
            TAG,
            "Vendor Message: addr=0x${address.toString(16)} " +
                "model=0x${modelId.toString(16)} opCode=0x${opCode.toString(16)}",
        )
        meshManagerApi.createMeshPdu(address, msg)
    }

    // ── 场景管理 ───────────────────────────────────────────────────────────────

    fun getScenes(): List<Map<String, Any?>> = emptyList()

    suspend fun storeScene(nodeAddress: Int, sceneNumber: Int) {
        val appKey = getAppKey(0) ?: return
        sendAppMessage(nodeAddress, SceneStore(appKey, sceneNumber))
        Log.d(TAG, "Scene Store: node=0x${nodeAddress.toString(16)} scene=$sceneNumber")
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    suspend fun recallScene(address: Int, sceneNumber: Int, appKeyIndex: Int) {
        val appKey = getAppKey(appKeyIndex) ?: return
        sendAppMessage(address, SceneRecall(appKey, sceneNumber, nextTid()))
        Log.d(TAG, "Scene Recall: addr=0x${address.toString(16)} scene=$sceneNumber")
    }

    suspend fun deleteScene(nodeAddress: Int, sceneNumber: Int) {
        val appKey = getAppKey(0) ?: return
        sendAppMessage(nodeAddress, SceneDelete(appKey, sceneNumber))
        Log.d(TAG, "Scene Delete: node=0x${nodeAddress.toString(16)} scene=$sceneNumber")
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    // ── 发布设置 ───────────────────────────────────────────────────────────────

    /**
     * 发送 Config Model Publication Set 消息。
     *
     * @param publishPeriod 发布周期步数（0 = 禁用），分辨率固定为 100ms/步。
     */
    suspend fun setPublication(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        publishAddress: Int,
        appKeyIndex: Int,
        publishTtl: Int,
        publishPeriod: Int,
    ) {
        val msg = ConfigModelPublicationSet(
            elementAddress,
            publishAddress,
            appKeyIndex,
            false,          // credential flag（false = master security material）
            publishTtl,
            publishPeriod,  // publication steps
            0,              // publication resolution（0 = 100ms/步）
            0,              // retransmit count
            0,              // retransmit interval steps
            modelId,
        )
        sendConfigMessage(nodeAddress, msg)
        Log.d(
            TAG,
            "Publication Set: node=0x${nodeAddress.toString(16)} → 0x${publishAddress.toString(16)}",
        )
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
    }

    // ── 私有方法 ───────────────────────────────────────────────────────────────

    /** 获取指定索引的 ApplicationKey，不存在时上报错误。 */
    private fun getAppKey(index: Int): ApplicationKey? {
        val key = meshManagerApi.meshNetwork?.getAppKey(index)
        if (key == null) {
            Log.e(TAG, "AppKey 索引 $index 不存在")
            MeshEventStreamHandler.sendError(
                "NO_APP_KEY",
                "AppKey 索引 $index 不存在，请先完成配网并分发 AppKey",
            )
        }
        return key
    }

    /**
     * 确保网络数据库中始终存在默认 AppKey 0。
     *
     * 当前 Dart/Example 层大量默认使用 `appKeyIndex = 0`。若网络里没有
     * AppKey 0，则后续 `Config AppKey Add`、模型绑定和应用消息都会失败。
     */
    private fun ensureDefaultAppKey(network: MeshNetwork): ApplicationKey {
        network.getAppKey(DEFAULT_APP_KEY_INDEX)?.let { return it }

        val primaryNetKey = network.primaryNetworkKey ?: network.netKeys.firstOrNull()
            ?: throw IllegalStateException("网络中无 NetKey，无法创建默认 AppKey")

        val appKey = network.createAppKey().apply {
            keyIndex = DEFAULT_APP_KEY_INDEX
            boundNetKeyIndex = primaryNetKey.keyIndex
            meshUuid = network.meshUUID
            name = "AppKey $DEFAULT_APP_KEY_INDEX"
        }

        if (!network.addAppKey(appKey)) {
            throw IllegalStateException("创建默认 AppKey 失败")
        }

        Log.d(
            TAG,
            "已自动创建默认 AppKey: index=${appKey.keyIndex}, boundNetKey=${appKey.boundNetKeyIndex}",
        )
        MeshEventStreamHandler.sendEvent(mapOf("type" to "networkUpdated"))
        return network.getAppKey(DEFAULT_APP_KEY_INDEX) ?: appKey
    }

    /**
     * 为待配网设备计算下一个可用单播地址。
     *
     * nRF 默认网络中 Provisioner 占用 `0x0001`，首个真实设备应从 `0x0002` 起。
     * 库内部的 [MeshNetwork.nextAvailableUnicastAddress] 有时不会排除
     * Provisioner 地址，因此这里做显式修正。
     */
    private fun resolveNextUnicastAddress(meshNode: UnprovisionedMeshNode): Int {
        val network = meshManagerApi.meshNetwork
            ?: throw IllegalStateException("meshNetwork 为 null")
        val provisioner = network.selectedProvisioner
            ?: throw IllegalStateException("无 selected Provisioner")
        val elementCount = meshNode.provisioningCapabilities
            ?.numberOfElements
            ?.toInt()
            ?.takeIf { it > 0 }
            ?: meshNode.numberOfElements.takeIf { it > 0 }
            ?: 1
        val provisionerAddress = provisioner.provisionerAddress ?: 0x0001

        var nextAddress = network.nextAvailableUnicastAddress(elementCount, provisioner)
        if (nextAddress <= 0) {
            throw IllegalStateException("无可用单播地址（elements=$elementCount）")
        }

        if (nextAddress <= provisionerAddress) {
            nextAddress = provisionerAddress + 1
            Log.w(
                TAG,
                "地址分配修正: 使用 0x${nextAddress.toString(16)} " +
                    "（避开 Provisioner 0x${provisionerAddress.toString(16)}）",
            )
        }

        Log.d(
            TAG,
            "节点地址分配: elements=$elementCount → 0x${nextAddress.toString(16)}",
        )
        return nextAddress
    }

    /**
     * 判断节点是否为本地 Provisioner（手机自身），不可作为普通设备删除或控制。
     */
    private fun isProvisionerNode(
        network: MeshNetwork,
        node: ProvisionedMeshNode,
    ): Boolean {
        val provisionerUuid = network.selectedProvisioner
            ?.provisionerUuid
            ?.toString()
            ?.lowercase()
            ?: return false
        return node.uuid?.lowercase() == provisionerUuid
    }

    /**
     * 检查网络是否满足 nRF Mesh 配网/配置前提，不触发修复。
     *
     * @return `null` 表示可用，否则返回失败原因。
     */
    private fun validateNetworkForProvisioning(network: MeshNetwork): String? {
        val provisioner = network.selectedProvisioner
            ?: return "缺少 selected provisioner"

        val provisionerAddress = provisioner.provisionerAddress
            ?: return "Provisioner address 未设置"

        val provisionerUuid = provisioner.provisionerUuid
        val provisionerNode = network.getNode(provisionerUuid)
            ?: return "缺少本地 Provisioner 节点"

        if (provisionerNode.unicastAddress != provisionerAddress) {
            return "Provisioner 节点地址不一致: node=0x${provisionerNode.unicastAddress.toString(16)} " +
                "provisioner=0x${provisionerAddress.toString(16)}"
        }

        val collidesWithOtherNode = network.nodes.any { node ->
            !node.uuid.equals(provisionerUuid, ignoreCase = true) &&
                node.unicastAddress == provisionerAddress
        }
        if (collidesWithOtherNode) {
            return "Provisioner 地址与其他节点冲突: 0x${provisionerAddress.toString(16)}"
        }

        return null
    }

    /**
     * 配网前确保 Mesh 网络可用；若 Provisioner 被误删则自动重建并等待加载完成。
     */
    private suspend fun ensureNetworkReadyForProvisioning() {
        val network = meshManagerApi.meshNetwork
        if (network != null && validateNetworkForProvisioning(network) == null) {
            ensureDefaultAppKey(network)
            return
        }

        val deferred = CompletableDeferred<Unit>()
        networkReadyDeferred = deferred
        try {
            if (network != null) {
                ensureNordicCompatibleNetwork(network)
            } else {
                meshManagerApi.loadMeshNetwork()
            }
            withTimeout(15_000) {
                deferred.await()
            }
            val readyNetwork = meshManagerApi.meshNetwork
                ?: throw IllegalStateException("网络重建后仍为 null")
            val reason = validateNetworkForProvisioning(readyNetwork)
            if (reason != null) {
                throw IllegalStateException(reason)
            }
            ensureDefaultAppKey(readyNetwork)
        } catch (e: TimeoutCancellationException) {
            throw IllegalStateException("等待 Mesh 网络重建超时", e)
        } finally {
            networkReadyDeferred = null
        }
    }

    /**
     * 按 nRF Mesh 的前提条件验证当前网络是否可用于后续配置消息。
     *
     * 必须同时满足：
     * 1. 有 selected provisioner
     * 2. provisioner address 已设置
     * 3. 网络里存在与 provisioner UUID 对应的本地 Provisioner 节点
     * 4. 本地 Provisioner 节点地址与 provisioner address 一致
     * 5. 不与其他真实节点地址冲突
     *
     * 若这些前提不满足，后续 identifyNode/createMeshPdu 可能触发空指针。
     */
    private fun ensureNordicCompatibleNetwork(network: MeshNetwork): Boolean {
        val reason = validateNetworkForProvisioning(network)
        if (reason == null) {
            isRepairingMeshNetwork = false
            return true
        }
        repairMeshNetwork(reason)
        return false
    }

    private fun repairMeshNetwork(reason: String) {
        Log.w(TAG, "当前 Mesh DB 不符合 nRF 流程要求，准备重建: $reason")
        if (isRepairingMeshNetwork) {
            return
        }
        isRepairingMeshNetwork = true
        meshManagerApi.resetMeshNetwork()
    }

    /** 发送配置消息（使用 DeviceKey，无需 AppKey）。 */
    private fun sendConfigMessage(address: Int, message: MeshMessage) {
        meshManagerApi.createMeshPdu(address, message)
    }

    /** 发送应用消息（使用 AppKey）。 */
    private fun sendAppMessage(address: Int, message: MeshMessage) {
        meshManagerApi.createMeshPdu(address, message)
    }

    private fun bindRequestKey(
        sourceAddress: Int,
        elementAddress: Int,
        modelIdentifier: Int,
    ): String = "$sourceAddress:$elementAddress:$modelIdentifier"

    private fun handleConfigStatusMessage(src: Int, message: MeshMessage) {
        when (message) {
            is ConfigCompositionDataStatus -> {
                pendingCompositionRequests.remove(src)?.complete(message)
            }

            is ConfigAppKeyStatus -> {
                pendingAppKeyStatusRequests.remove(src)?.complete(message)
            }

            is ConfigModelAppStatus -> {
                val key = bindRequestKey(
                    src,
                    message.elementAddress,
                    message.modelIdentifier,
                )
                pendingModelBindRequests.remove(key)?.complete(message)
            }
        }
    }

    private fun failPendingConfiguration(nodeAddress: Int, reason: String) {
        pendingCompositionRequests.remove(nodeAddress)?.completeExceptionally(
            IllegalStateException(reason),
        )
        pendingAppKeyStatusRequests.remove(nodeAddress)?.completeExceptionally(
            IllegalStateException(reason),
        )
        val prefix = "$nodeAddress:"
        val keys = pendingModelBindRequests.keys.filter { it.startsWith(prefix) }
        keys.forEach { key ->
            pendingModelBindRequests.remove(key)?.completeExceptionally(
                IllegalStateException(reason),
            )
        }
    }

    private suspend fun fetchCompositionData(
        meshNode: ProvisionedMeshNode,
    ): ConfigCompositionDataStatus {
        val deferred = CompletableDeferred<ConfigCompositionDataStatus>()
        pendingCompositionRequests[meshNode.unicastAddress] = deferred
        MeshEventStreamHandler.sendConfigurationState(
            state = "compositionGetting",
            uuid = meshNode.uuid,
            unicastAddress = meshNode.unicastAddress,
            message = "发送 Config Composition Data Get",
        )
        sendConfigMessage(meshNode.unicastAddress, ConfigCompositionDataGet())

        return try {
            val status = withTimeout(CONFIG_TIMEOUT_MS) { deferred.await() }
            MeshEventStreamHandler.sendConfigurationState(
                state = "compositionReceived",
                uuid = meshNode.uuid,
                unicastAddress = meshNode.unicastAddress,
                message = buildCompositionSummary(status),
            )
            status
        } catch (e: TimeoutCancellationException) {
            throw IllegalStateException("Composition Data Get 超时")
        } finally {
            pendingCompositionRequests.remove(meshNode.unicastAddress)
        }
    }

    private suspend fun addAppKeyWithStatus(
        meshNode: ProvisionedMeshNode,
        netKey: no.nordicsemi.android.mesh.NetworkKey,
        appKey: ApplicationKey,
    ) {
        val deferred = CompletableDeferred<ConfigAppKeyStatus>()
        pendingAppKeyStatusRequests[meshNode.unicastAddress] = deferred
        MeshEventStreamHandler.sendConfigurationState(
            state = "appKeyAdding",
            uuid = meshNode.uuid,
            unicastAddress = meshNode.unicastAddress,
            message = "发送 Config AppKey Add",
        )
        sendConfigMessage(meshNode.unicastAddress, ConfigAppKeyAdd(netKey, appKey))

        try {
            val status = withTimeout(CONFIG_TIMEOUT_MS) { deferred.await() }
            if (!status.isSuccessful) {
                throw IllegalStateException(
                    "Config AppKey Add 失败: netIdx=${status.netKeyIndex} appIdx=${status.appKeyIndex}",
                )
            }
        } catch (e: TimeoutCancellationException) {
            throw IllegalStateException("Config AppKey Add 超时")
        } finally {
            pendingAppKeyStatusRequests.remove(meshNode.unicastAddress)
        }
    }

    private suspend fun bindModelWithStatus(
        meshNode: ProvisionedMeshNode,
        target: ModelBindTarget,
        appKeyIndex: Int,
    ) {
        val requestKey = bindRequestKey(
            meshNode.unicastAddress,
            target.elementAddress,
            target.modelIdentifier,
        )
        val deferred = CompletableDeferred<ConfigModelAppStatus>()
        pendingModelBindRequests[requestKey] = deferred
        MeshEventStreamHandler.sendConfigurationState(
            state = "modelBinding",
            uuid = meshNode.uuid,
            unicastAddress = meshNode.unicastAddress,
            modelId = target.rawModelId,
            companyId = target.companyId,
            message = target.label,
        )
        sendConfigMessage(
            meshNode.unicastAddress,
            ConfigModelAppBind(
                target.elementAddress,
                target.modelIdentifier,
                appKeyIndex,
            ),
        )

        try {
            val status = withTimeout(CONFIG_TIMEOUT_MS) { deferred.await() }
            if (!status.isSuccessful) {
                throw IllegalStateException("模型绑定失败: ${target.label}")
            }
        } catch (e: TimeoutCancellationException) {
            throw IllegalStateException("模型绑定超时: ${target.label}")
        } finally {
            pendingModelBindRequests.remove(requestKey)
        }
    }

    private fun resolveModelBindTargets(
        compositionStatus: ConfigCompositionDataStatus,
    ): List<ModelBindTarget> {
        val targets = mutableListOf<ModelBindTarget>()
        compositionStatus.elements.forEach { (_, element) ->
            val elementAddress = element.elementAddress
            val modelIdentifiers = element.meshModels.keys
            for (modelId in SIG_MODELS_TO_BIND) {
                if (modelIdentifiers.contains(modelId)) {
                    targets += ModelBindTarget(
                        elementAddress = elementAddress,
                        modelIdentifier = modelId,
                        rawModelId = modelId,
                        companyId = null,
                        label = "绑定 SIG Model 0x${modelId.toString(16)} @0x${elementAddress.toString(16)}",
                    )
                }
            }

            for ((companyId, modelId) in VENDOR_MODELS_TO_BIND) {
                val vendorIdentifier = (companyId shl 16) or modelId
                if (modelIdentifiers.contains(vendorIdentifier)) {
                    targets += ModelBindTarget(
                        elementAddress = elementAddress,
                        modelIdentifier = vendorIdentifier,
                        rawModelId = modelId,
                        companyId = companyId,
                        label =
                            "绑定 Vendor Model CID=0x${companyId.toString(16)} " +
                                "Model=0x${modelId.toString(16)} @0x${elementAddress.toString(16)}",
                    )
                }
            }
        }
        return targets
    }

    private fun buildCompositionSummary(
        compositionStatus: ConfigCompositionDataStatus,
    ): String {
        val parts = compositionStatus.elements.entries.map { (address, element) ->
            val models = element.meshModels.keys.joinToString { "0x${it.toString(16)}" }
            "0x${address.toString(16)}[$models]"
        }
        return "Composition Data 已收到: ${parts.joinToString(" ; ")}"
    }

    private data class ModelBindTarget(
        val elementAddress: Int,
        val modelIdentifier: Int,
        val rawModelId: Int,
        val companyId: Int?,
        val label: String,
    )

    /**
     * 配网完成后自动向节点分发 AppKey 并绑定常用模型。
     *
     * 需要已通过代理节点连接（[BleGattManager] 已连接并就绪）。
     */
    private suspend fun autoDistributeAppKey(meshNode: ProvisionedMeshNode) {
        val network = meshManagerApi.meshNetwork ?: return
        val appKey = ensureDefaultAppKey(network)
        val netKey = network.primaryNetworkKey ?: network.netKeys.firstOrNull()
            ?: throw IllegalStateException("网络中无 NetKey，无法下发 AppKey")
        val unicastAddress = meshNode.unicastAddress

        Log.d(TAG, "─── 开始向节点 0x${unicastAddress.toString(16)} 分发 AppKey ───")
        Log.d(TAG, "AppKey 索引=${appKey.keyIndex}, NetKey 索引=${netKey.keyIndex}")

        kotlinx.coroutines.delay(CONFIG_INITIAL_DELAY_MS)
        val compositionStatus = fetchCompositionData(meshNode)
        val bindTargets = resolveModelBindTargets(compositionStatus)
        Log.d(
            TAG,
            "Composition Data 获取成功，待绑定模型数=${bindTargets.size}",
        )

        kotlinx.coroutines.delay(CONFIG_STEP_DELAY_MS)
        Log.d(TAG, "发送 ConfigAppKeyAdd → 0x${unicastAddress.toString(16)}")
        addAppKeyWithStatus(meshNode, netKey, appKey)

        kotlinx.coroutines.delay(CONFIG_STEP_DELAY_MS)
        for (target in bindTargets) {
            Log.d(TAG, target.label)
            bindModelWithStatus(meshNode, target, appKey.keyIndex)
            kotlinx.coroutines.delay(CONFIG_BIND_DELAY_MS)
        }
        Log.d(TAG, "─── AppKey 分发序列完成（SIG×${SIG_MODELS_TO_BIND.size} + Vendor×${VENDOR_MODELS_TO_BIND.size}）───")
    }

    /**
     * 配网完成后自动切换到 Proxy 连接，避免依赖 Dart 层页面逻辑手动触发。
     */
    private fun scheduleAutomaticProxyConnection(
        uuid: String,
        macAddress: String,
        unicastAddress: Int,
    ) {
        if (!autoConnectingProxyAddresses.add(unicastAddress)) {
            Log.d(TAG, "节点 0x${unicastAddress.toString(16)} 已在自动重连队列中，跳过重复调度")
            return
        }

        scope.launch {
            try {
                Log.d(
                    TAG,
                    "节点 0x${unicastAddress.toString(16)} 配网完成，准备自动重连 Proxy: $macAddress",
                )
                MeshEventStreamHandler.sendConfigurationState(
                    state = "pendingProxy",
                    uuid = uuid,
                    unicastAddress = unicastAddress,
                    message = "准备自动连接 Proxy: $macAddress",
                )

                // 主动扫描 Proxy 广播，检测到后立即连接（替代固定 2.5s 等待）
                val scanner = scanManager
                if (scanner != null) {
                    val found = scanner.waitForProxyAdvertisement(
                        targetMac = macAddress,
                        minDelayMs = PROXY_MIN_SWITCH_MS,
                        timeoutMs = PROXY_SCAN_TIMEOUT_MS,
                    )
                    Log.d(
                        TAG,
                        if (found) {
                            "已检测到 Proxy 广播，立即连接"
                        } else {
                            "Proxy 扫描超时，仍尝试 GATT 连接"
                        },
                    )
                } else {
                    kotlinx.coroutines.delay(800)
                }

                val gatt = gattManager ?: throw IllegalStateException("BleGattManager 未初始化")
                if (gatt.isReadyForProxy(macAddress)) {
                    Log.d(TAG, "Proxy 已就绪（$macAddress），直接开始配置")
                    onProxyConnected()
                    return@launch
                }
                if (gatt.isConnectingTo(macAddress)) {
                    Log.d(TAG, "Proxy 正在连接（$macAddress），等待就绪回调")
                    return@launch
                }

                gatt.connect(macAddress)
            } catch (e: Exception) {
                autoConnectingProxyAddresses.remove(unicastAddress)
                MeshEventStreamHandler.sendConfigurationState(
                    state = "failed",
                    uuid = uuid,
                    unicastAddress = unicastAddress,
                    message = "自动连接 Proxy 失败: ${e.message}",
                )
                MeshEventStreamHandler.sendError(
                    "CONFIGURATION_FAILED",
                    "节点 0x${unicastAddress.toString(16)} 自动连接 Proxy 失败: ${e.message}",
                )
            }
        }
    }

    /**
     * 根据已知 UUID 查询缓存的 MAC 地址（可选），供 Proxy 连接使用。
     *
     * @param uuid 节点 UUID 字符串。
     */
    fun getCachedMac(uuid: String): String? = nodeAddressCache[uuid]

    /** 构造节点信息 Map，供 Dart 层解析成 MeshNode。 */
    private fun buildNodeMap(meshNode: ProvisionedMeshNode): Map<String, Any?> {
        val elementsList = meshNode.elements?.entries?.map { (address, element) ->
            mapOf(
                "elementAddress" to address,
                "name" to (element.name ?: "Element 0x${address.toString(16)}"),
                "modelIds" to (element.meshModels?.keys?.toList() ?: emptyList<Int>()),
                "location" to element.locationDescriptor,
            )
        } ?: emptyList<Map<String, Any?>>()

        // getAddedAppKeys() 返回 List<NodeKey>，NodeKey.index 为 AppKey 索引
        val appKeyIndexes = meshNode.addedAppKeys
            ?.filterIsInstance<NodeKey>()
            ?.map { it.index }
            ?: emptyList()

        return mapOf(
            "unicastAddress" to meshNode.unicastAddress,
            "name" to (
                meshNode.nodeName
                    ?: "Node 0x${meshNode.unicastAddress.toString(16).padStart(4, '0')}"
                ),
            "uuid" to meshNode.uuid,
            "macAddress" to nodeAddressCache[meshNode.uuid],
            "deviceKey" to meshNode.deviceKey?.joinToString("") { "%02x".format(it) },
            "isOnline" to true,
            "elements" to elementsList,
            "appKeyIndexes" to appKeyIndexes,
            "ttl" to meshNode.ttl,
            "companyIdentifier" to meshNode.companyIdentifier,
            "productIdentifier" to meshNode.productIdentifier,
        )
    }

    /** 清理配网临时状态（MAC 地址保留在缓存中，不清除）。 */
    private fun clearProvisioningState() {
        pendingProvisionUuid = null
        pendingProvisionAddress = null
        pendingMeshNode = null
    }

    /** TID 自增，0x00-0xFF 循环。 */
    private fun nextTid(): Int = tidCounter.getAndIncrement() and 0xFF
}
