package com.ble_mesh.ble_mesh

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * BleMesh Flutter 插件主类。
 *
 * 实现了 [FlutterPlugin]（Flutter 引擎生命周期）和 [ActivityAware]
 * （Activity 生命周期），以便访问 Activity Context 进行权限请求和 BLE 操作。
 *
 * MethodChannel: `ble_mesh` — 处理来自 Dart 的方法调用
 * EventChannel:  `ble_mesh/events` — 向 Dart 推送实时事件
 */
class BleMeshPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware {

    // ── MethodChannel & EventChannel ──────────────────────────────────────────

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    // ── 内部管理器 ────────────────────────────────────────────────────────────

    /** 应用上下文，在 onAttachedToEngine 时获取。 */
    private lateinit var appContext: Context

    /** 当前绑定的 Activity，用于权限请求。 */
    private var activity: Activity? = null

    /** Mesh 网络管理器，处理配网、消息收发、节点/组/场景管理。 */
    private var networkManager: BleMeshNetworkManager? = null

    /** BLE 扫描管理器，扫描未配网设备。 */
    private var scanManager: BleScanManager? = null

    /** GATT 代理连接管理器，管理与代理节点的连接。 */
    private var gattManager: BleGattManager? = null

    /** 插件协程作用域，在 onDetachedFromEngine 时取消。 */
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ── FlutterPlugin 生命周期 ────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        // 设置 MethodChannel
        methodChannel = MethodChannel(binding.binaryMessenger, "ble_mesh")
        methodChannel.setMethodCallHandler(this)

        // 设置 EventChannel（广播流，支持多个监听器）
        eventChannel = EventChannel(binding.binaryMessenger, "ble_mesh/events")
        eventChannel.setStreamHandler(MeshEventStreamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)

        // 清理资源
        networkManager?.dispose()
        scanManager?.stopScan()
        gattManager?.disconnect()
        pluginScope.cancel()
    }

    // ── ActivityAware 生命周期 ─────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        // 权限请求结果需要 Activity 传递
        binding.addRequestPermissionsResultListener { requestCode, _, grantResults ->
            PermissionManager.handlePermissionResult(requestCode, grantResults)
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // ── MethodChannel 方法处理 ────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        pluginScope.launch {
            try {
                handleMethodCall(call, result)
            } catch (e: BleMeshException) {
                result.error(e.code, e.message, e.details)
            } catch (e: Exception) {
                result.error("UNKNOWN_ERROR", e.message ?: "未知错误", null)
            }
        }
    }

    /**
     * 根据方法名路由到对应的处理器。
     */
    private suspend fun handleMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // ── 初始化 ────────────────────────────────────────────────────────
            "initialize" -> handleInitialize(result)

            "requestPermissions" -> handleRequestPermissions(result)

            "getBluetoothState" -> handleGetBluetoothState(result)

            // ── 扫描 ──────────────────────────────────────────────────────────
            "startScan" -> {
                val timeoutMs = call.argument<Int>("timeoutMs")
                handleStartScan(timeoutMs?.toLong(), result)
            }

            "stopScan" -> handleStopScan(result)

            // ── 配网 ──────────────────────────────────────────────────────────
            "provisionDevice" -> {
                val uuid = call.argument<String>("uuid")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 uuid 参数", null)
                val address = call.argument<String>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                val nodeName = call.argument<String>("nodeName")
                handleProvisionDevice(uuid, address, nodeName, result)
            }

            "cancelProvisioning" -> handleCancelProvisioning(result)

            // ── 连接管理 ──────────────────────────────────────────────────────
            "connectToProxy" -> {
                val address = call.argument<String>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                handleConnectToProxy(address, result)
            }

            "disconnectFromProxy" -> handleDisconnectFromProxy(result)

            "getConnectionState" -> handleGetConnectionState(result)

            "isProxyReady" -> {
                val address = call.argument<String>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                handleIsProxyReady(address, result)
            }

            "getNetworkInfo" -> handleGetNetworkInfo(result)

            "exportNetworkJson" -> handleExportNetworkJson(result)

            "importNetworkJson" -> {
                val json = call.argument<String>("json")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 json 参数", null)
                handleImportNetworkJson(json, result)
            }

            // ── 控制消息 ──────────────────────────────────────────────────────
            "sendGenericOnOff" -> {
                val address = call.argument<Int>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                val onOff = call.argument<Boolean>("onOff")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 onOff 参数", null)
                val appKeyIndex = call.argument<Int>("appKeyIndex") ?: 0
                val acknowledged = call.argument<Boolean>("acknowledged") ?: true
                handleSendGenericOnOff(address, onOff, appKeyIndex, acknowledged, result)
            }

            "sendGenericLevel" -> {
                val address = call.argument<Int>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                val level = call.argument<Int>("level")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 level 参数", null)
                val appKeyIndex = call.argument<Int>("appKeyIndex") ?: 0
                val acknowledged = call.argument<Boolean>("acknowledged") ?: true
                handleSendGenericLevel(address, level, appKeyIndex, acknowledged, result)
            }

            // ── 节点管理 ──────────────────────────────────────────────────────
            "getNodes" -> handleGetNodes(result)

            "fetchReportedModels" -> {
                val unicastAddress = call.argument<Int>("unicastAddress")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 unicastAddress 参数", null)
                handleFetchReportedModels(unicastAddress, result)
            }

            "deleteNode" -> {
                val unicastAddress = call.argument<Int>("unicastAddress")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 unicastAddress 参数", null)
                handleDeleteNode(unicastAddress, result)
            }

            // ── 分组管理 ──────────────────────────────────────────────────────
            "getGroups" -> handleGetGroups(result)

            "createGroup" -> {
                val name = call.argument<String>("name")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 name 参数", null)
                val address = call.argument<Int>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                handleCreateGroup(name, address, result)
            }

            "deleteGroup" -> {
                val address = call.argument<Int>("address")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 address 参数", null)
                handleDeleteGroup(address, result)
            }

            "addSubscription" -> {
                val nodeAddress = call.argument<Int>("nodeAddress")!!
                val elementAddress = call.argument<Int>("elementAddress")!!
                val modelId = call.argument<Int>("modelId")!!
                val subscriptionAddress = call.argument<Int>("subscriptionAddress")!!
                handleAddSubscription(nodeAddress, elementAddress, modelId, subscriptionAddress, result)
            }

            "removeSubscription" -> {
                val nodeAddress = call.argument<Int>("nodeAddress")!!
                val elementAddress = call.argument<Int>("elementAddress")!!
                val modelId = call.argument<Int>("modelId")!!
                val subscriptionAddress = call.argument<Int>("subscriptionAddress")!!
                handleRemoveSubscription(nodeAddress, elementAddress, modelId, subscriptionAddress, result)
            }

            "bindAppKey" -> {
                val nodeAddress = call.argument<Int>("nodeAddress")!!
                val elementAddress = call.argument<Int>("elementAddress")!!
                val modelId = call.argument<Int>("modelId")!!
                val appKeyIndex = call.argument<Int>("appKeyIndex")!!
                handleBindAppKey(nodeAddress, elementAddress, modelId, appKeyIndex, result)
            }

            // ── Vendor 模型消息 ───────────────────────────────────────────────
            "sendVendorMessage" -> {
                val address = call.argument<Int>("address")!!
                val companyId = call.argument<Int>("companyId")!!
                val modelId = call.argument<Int>("modelId")!!
                val opCode = call.argument<Int>("opCode")!!
                val payloadList = call.argument<List<Int>>("payload") ?: emptyList()
                val payload = ByteArray(payloadList.size) { payloadList[it].toByte() }
                val appKeyIndex = call.argument<Int>("appKeyIndex") ?: 0
                val acknowledged = call.argument<Boolean>("acknowledged") ?: false
                handleSendVendorMessage(
                    address, companyId, modelId, opCode, payload,
                    appKeyIndex, acknowledged, result,
                )
            }

            // ── 发布设置 ──────────────────────────────────────────────────────
            "setPublication" -> {
                val nodeAddress = call.argument<Int>("nodeAddress")!!
                val elementAddress = call.argument<Int>("elementAddress")!!
                val modelId = call.argument<Int>("modelId")!!
                val publishAddress = call.argument<Int>("publishAddress")!!
                val appKeyIndex = call.argument<Int>("appKeyIndex") ?: 0
                val publishTtl = call.argument<Int>("publishTtl") ?: 5
                val publishPeriod = call.argument<Int>("publishPeriod") ?: 0
                handleSetPublication(
                    nodeAddress, elementAddress, modelId,
                    publishAddress, appKeyIndex, publishTtl, publishPeriod, result
                )
            }

            // ── 自定义 BLE 通道 ───────────────────────────────────────────────
            "configureCustomBleChannel" -> {
                val serviceUuid = call.argument<String>("serviceUuid")
                    ?: return result.error("INVALID_ARGUMENT", "缺少 serviceUuid", null)
                val writeUuid = call.argument<String>("writeCharacteristicUuid")
                    ?: return result.error(
                        "INVALID_ARGUMENT",
                        "缺少 writeCharacteristicUuid",
                        null,
                    )
                val notifyUuid = call.argument<String>("notifyCharacteristicUuid")
                gattManager?.configureCustomChannel(serviceUuid, writeUuid, notifyUuid)
                result.success(null)
            }

            "isCustomBleReady" -> {
                result.success(gattManager?.isCustomChannelReady() == true)
            }

            "writeCustomBleData" -> {
                val data = byteArrayFromCall(call, "data")
                gattManager?.writeCustomData(data)
                result.success(null)
            }

            "transferCustomBleData" -> {
                val data = byteArrayFromCall(call, "data")
                gattManager?.transferCustomData(data)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ── 各方法处理器 ──────────────────────────────────────────────────────────

    private fun handleInitialize(result: Result) {
        try {
            // 初始化 Mesh 网络管理器（集成 nRF Mesh Library）
            networkManager = BleMeshNetworkManager(
                context = appContext,
                eventSink = MeshEventStreamHandler,
            )
            networkManager!!.initialize()

            // 初始化扫描管理器
            scanManager = BleScanManager(
                context = appContext,
                eventSink = MeshEventStreamHandler,
            )

            // 初始化代理 GATT 管理器
            gattManager = BleGattManager(
                context = appContext,
                networkManager = networkManager!!,
                eventSink = MeshEventStreamHandler,
            )

            // 双向注入：GATT 管理器需要网络管理器（解析 PDU），
            // 网络管理器需要 GATT 管理器（发送 Mesh PDU）
            networkManager!!.gattManager = gattManager
            networkManager!!.scanManager = scanManager

            result.success(null)
        } catch (e: Exception) {
            result.error("INIT_FAILED", "初始化失败: ${e.message}", null)
        }
    }

    private fun handleRequestPermissions(result: Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "无法获取 Activity 实例", null)
            return
        }
        PermissionManager.requestPermissions(currentActivity) { granted ->
            result.success(granted)
        }
    }

    private fun handleGetBluetoothState(result: Result) {
        val state = BluetoothStateManager.getState(appContext)
        result.success(state)
    }

    private fun handleStartScan(timeoutMs: Long?, result: Result) {
        val manager = scanManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.startScan(timeoutMs)
        result.success(null)
    }

    private fun handleStopScan(result: Result) {
        scanManager?.stopScan()
        result.success(null)
    }

    private suspend fun handleProvisionDevice(
        uuid: String,
        address: String,
        nodeName: String?,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.provisionDevice(uuid, address, nodeName)
        result.success(null)
    }

    private fun handleCancelProvisioning(result: Result) {
        networkManager?.cancelProvisioning()
        result.success(null)
    }

    private suspend fun handleConnectToProxy(address: String, result: Result) {
        val manager = gattManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.connect(address)
        result.success(null)
    }

    private fun handleDisconnectFromProxy(result: Result) {
        gattManager?.disconnect()
        result.success(null)
    }

    private fun handleGetConnectionState(result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        result.success(manager.getConnectionState())
    }

    private fun handleIsProxyReady(address: String, result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        result.success(manager.isProxyReady(address))
    }

    private fun handleGetNetworkInfo(result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        result.success(manager.getNetworkInfo())
    }

    private fun handleExportNetworkJson(result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        try {
            result.success(manager.exportNetworkJson())
        } catch (e: Exception) {
            result.error("EXPORT_FAILED", e.message, null)
        }
    }

    private suspend fun handleImportNetworkJson(json: String, result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        try {
            manager.importNetworkJson(json)
            result.success(null)
        } catch (e: Exception) {
            result.error("NETWORK_IMPORT_FAILED", e.message, null)
        }
    }

    private fun handleSendGenericOnOff(
        address: Int,
        onOff: Boolean,
        appKeyIndex: Int,
        acknowledged: Boolean,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.sendGenericOnOff(address, onOff, appKeyIndex, acknowledged)
        result.success(null)
    }

    private fun handleSendGenericLevel(
        address: Int,
        level: Int,
        appKeyIndex: Int,
        acknowledged: Boolean,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.sendGenericLevel(address, level, appKeyIndex, acknowledged)
        result.success(null)
    }

    /**
     * 处理 Vendor 消息发送请求。
     *
     * 将 Dart 层传入的参数转发给 [BleMeshNetworkManager.sendVendorMessage]。
     */
    private fun handleSendVendorMessage(
        address: Int,
        companyId: Int,
        modelId: Int,
        opCode: Int,
        payload: ByteArray,
        appKeyIndex: Int,
        acknowledged: Boolean,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.sendVendorMessage(
            address, companyId, modelId, opCode, payload, appKeyIndex, acknowledged,
        )
        result.success(null)
    }

    private fun handleGetNodes(result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        result.success(manager.getNodes())
    }

    private suspend fun handleFetchReportedModels(unicastAddress: Int, result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        try {
            result.success(manager.fetchReportedModels(unicastAddress))
        } catch (e: IllegalArgumentException) {
            result.error("NODE_NOT_FOUND", e.message, null)
        } catch (e: IllegalStateException) {
            val code = if (e.message?.contains("Proxy") == true) {
                "NOT_CONNECTED"
            } else {
                "COMPOSITION_FAILED"
            }
            result.error(code, e.message, null)
        }
    }

    private suspend fun handleDeleteNode(unicastAddress: Int, result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.deleteNode(unicastAddress)
        result.success(null)
    }

    private fun handleGetGroups(result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        result.success(manager.getGroups())
    }

    private fun handleCreateGroup(name: String, address: Int, result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.createGroup(name, address)
        result.success(null)
    }

    private fun handleDeleteGroup(address: Int, result: Result) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.deleteGroup(address)
        result.success(null)
    }

    private suspend fun handleAddSubscription(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        subscriptionAddress: Int,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.addSubscription(nodeAddress, elementAddress, modelId, subscriptionAddress)
        result.success(null)
    }

    private suspend fun handleRemoveSubscription(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        subscriptionAddress: Int,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.removeSubscription(nodeAddress, elementAddress, modelId, subscriptionAddress)
        result.success(null)
    }

    private suspend fun handleBindAppKey(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        appKeyIndex: Int,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.bindAppKey(nodeAddress, elementAddress, modelId, appKeyIndex)
        result.success(null)
    }

    private suspend fun handleSetPublication(
        nodeAddress: Int,
        elementAddress: Int,
        modelId: Int,
        publishAddress: Int,
        appKeyIndex: Int,
        publishTtl: Int,
        publishPeriod: Int,
        result: Result,
    ) {
        val manager = networkManager
            ?: return result.error("NOT_INITIALIZED", "请先调用 initialize()", null)
        manager.setPublication(
            nodeAddress, elementAddress, modelId,
            publishAddress, appKeyIndex, publishTtl, publishPeriod
        )
        result.success(null)
    }

    /**
     * 从 MethodCall 解析二进制参数。
     *
     * Flutter 的 [Uint8List] 在 Android 侧为 [ByteArray]，
     * 若用 [MethodCall.argument] 强转为 List 会触发 ClassCastException。
     */
    @Suppress("UNCHECKED_CAST")
    private fun byteArrayFromCall(call: MethodCall, key: String): ByteArray {
        val args = call.arguments as? Map<String, Any?> ?: return ByteArray(0)
        return when (val raw = args[key]) {
            null -> ByteArray(0)
            is ByteArray -> raw
            is List<*> -> ByteArray(raw.size) { index ->
                (raw[index] as Number).toInt().toByte()
            }
            else -> ByteArray(0)
        }
    }
}
