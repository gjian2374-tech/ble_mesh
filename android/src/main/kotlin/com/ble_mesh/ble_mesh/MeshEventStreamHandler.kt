package com.ble_mesh.ble_mesh

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * EventChannel 的 StreamHandler 单例，用于向 Dart 推送实时事件。
 *
 * 所有 Mesh 事件（扫描结果、配网状态、连接状态等）都通过此对象发送。
 * 事件格式为 `Map<String, Any?>`，包含 `type` 字段标识事件类型。
 *
 * 用法示例：
 * ```kotlin
 * MeshEventStreamHandler.sendEvent(mapOf(
 *     "type" to "scanResult",
 *     "device" to mapOf("uuid" to "...", "name" to "...", "rssi" to -60)
 * ))
 * ```
 */
object MeshEventStreamHandler : EventChannel.StreamHandler {

    /** 当前活跃的事件接收器，null 表示 Dart 端没有监听。 */
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    /** 确保在主线程发送事件的 Handler。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── StreamHandler 实现 ────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── 事件发送方法 ──────────────────────────────────────────────────────────

    /**
     * 向 Dart 端发送事件。
     *
     * 此方法是线程安全的，可以从任意线程调用。
     * 内部会确保在主线程上调用 [EventChannel.EventSink.success]。
     *
     * @param event 事件数据，必须包含 `type` 字段。
     */
    fun sendEvent(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            mainHandler.post { eventSink?.success(event) }
        }
    }

    /**
     * 向 Dart 端发送错误事件。
     *
     * @param code 错误码（对应 [BleMeshException.code]）。
     * @param message 错误描述。
     * @param details 可选的额外调试信息。
     */
    fun sendError(code: String, message: String, details: Any? = null) {
        sendEvent(
            mapOf(
                "type" to "error",
                "code" to code,
                "message" to message,
                "details" to details,
            )
        )
    }

    // ── 预定义事件发送便捷方法 ─────────────────────────────────────────────────

    /** 发送蓝牙状态变化事件。 */
    fun sendBluetoothState(state: String) {
        sendEvent(mapOf("type" to "bluetoothStateChanged", "state" to state))
    }

    /** 发送扫描到设备的事件。 */
    fun sendScanResult(device: Map<String, Any?>) {
        sendEvent(mapOf("type" to "scanResult", "device" to device))
    }

    /** 发送扫描停止事件。 */
    fun sendScanStopped() {
        sendEvent(mapOf("type" to "scanStopped"))
    }

    /** 发送代理连接状态变化事件。 */
    fun sendConnectionState(state: String, address: String? = null) {
        sendEvent(
            mapOf(
                "type" to "connectionStateChanged",
                "state" to state,
                "address" to address,
            )
        )
    }

    /** 发送配网状态变化事件。 */
    fun sendProvisioningState(state: String, uuid: String? = null) {
        sendEvent(
            mapOf(
                "type" to "provisioningStateChanged",
                "state" to state,
                "uuid" to uuid,
            )
        )
    }

    /** 发送配置阶段状态变化事件。 */
    fun sendConfigurationState(
        state: String,
        uuid: String? = null,
        unicastAddress: Int? = null,
        modelId: Int? = null,
        companyId: Int? = null,
        message: String? = null,
    ) {
        sendEvent(
            mapOf(
                "type" to "configurationStateChanged",
                "state" to state,
                "uuid" to uuid,
                "unicastAddress" to unicastAddress,
                "modelId" to modelId,
                "companyId" to companyId,
                "message" to message,
            )
        )
    }

    /** 发送新节点加入网络的事件。 */
    fun sendNodeAdded(node: Map<String, Any?>) {
        sendEvent(mapOf("type" to "nodeAdded", "node" to node))
    }

    /** 发送节点删除事件。 */
    fun sendNodeDeleted(unicastAddress: Int) {
        sendEvent(
            mapOf(
                "type" to "nodeDeleted",
                "unicastAddress" to unicastAddress,
            )
        )
    }

    /** 发送收到 Mesh 消息的事件。 */
    fun sendMeshMessage(
        source: Int,
        modelType: String,
        data: Map<String, Any?>,
    ) {
        sendEvent(
            mapOf(
                "type" to "meshMessageReceived",
                "source" to source,
                "modelType" to modelType,
                "data" to data,
            )
        )
    }
}
