package com.ble_mesh.ble_mesh

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.LinkedList
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * BLE GATT 代理连接管理器。
 *
 * 负责管理与已配网 Mesh 节点的 GATT 代理（Proxy）连接。
 * 已配网设备通过 Mesh Proxy Service (UUID 0x1828) 提供代理功能，
 * 允许手机通过 GATT 收发 Mesh 消息。
 *
 * ## GATT 服务结构
 * - Mesh Proxy Service: 0x1828
 *   - Mesh Proxy Data In: 0x2ADD（写入，发送 Mesh PDU）
 *   - Mesh Proxy Data Out: 0x2ADE（通知，接收 Mesh PDU）
 *
 * ## 与 nRF Mesh 库的集成
 * 收到的 GATT 通知数据需要传递给 [BleMeshNetworkManager]（MeshManagerApi）处理。
 * 发送数据时由 MeshManagerApi 生成 PDU，再通过此类的 [sendPdu] 方法写入 GATT。
 */
class BleGattManager(
    private val context: Context,
    private val networkManager: BleMeshNetworkManager,
    private val eventSink: MeshEventStreamHandler,
) {

    companion object {
        private const val TAG = "BleGattManager"

        /** Mesh Proxy Service UUID */
        val MESH_PROXY_SERVICE: UUID = UUID.fromString("00001828-0000-1000-8000-00805F9B34FB")

        /** Mesh Proxy Data In Characteristic（写入通道：APP -> Mesh 节点） */
        val MESH_PROXY_DATA_IN: UUID = UUID.fromString("00002ADD-0000-1000-8000-00805F9B34FB")

        /** Mesh Proxy Data Out Characteristic（通知通道：Mesh 节点 -> APP） */
        val MESH_PROXY_DATA_OUT: UUID = UUID.fromString("00002ADE-0000-1000-8000-00805F9B34FB")

        /** CCCD（Client Characteristic Configuration Descriptor）UUID，用于开启通知 */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

        /** GATT MTU 大小，BLE Mesh 建议值 */
        private const val MESH_MTU = 517

        /** 将 16/32 位短 UUID（含 0x 前缀）或完整 UUID 字符串解析为 [UUID]。 */
        fun parseBleUuid(value: String): UUID {
            val hex = normalizeBleUuidHex(value)
            return when (hex.length) {
                4 -> UUID.fromString(
                    "0000$hex-0000-1000-8000-00805F9B34FB",
                )
                8 -> UUID.fromString(
                    "0000${hex.takeLast(4)}-0000-1000-8000-00805F9B34FB",
                )
                else -> UUID.fromString(value.trim())
            }
        }

        /** 去掉 0x 前缀并转为大写十六进制（不含连字符的短 UUID）。 */
        fun normalizeBleUuidHex(value: String): String {
            var s = value.trim()
            if (s.startsWith("0x", ignoreCase = true)) {
                s = s.substring(2)
            }
            if (s.contains("-")) {
                return s.uppercase()
            }
            return s.uppercase()
        }
    }

    private data class CustomWriteItem(
        val data: ByteArray,
        val onSuccess: (() -> Unit)? = null,
    )

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    }

    /** 当前 GATT 连接实例。 */
    private var bluetoothGatt: BluetoothGatt? = null

    /** 当前目标设备的 MAC 地址。 */
    private var targetAddress: String? = null

    /** 当前连接状态。 */
    @Volatile
    private var connectionState = BluetoothProfile.STATE_DISCONNECTED

    /** 当前协商到的 MTU 载荷大小（ATT MTU - 3）。 */
    private var currentMtu = MESH_MTU - 3

    /** Data In 特征，用于向节点写入数据。 */
    private var dataInCharacteristic: BluetoothGattCharacteristic? = null

    /** Proxy 通知已开启（与 Dart 层 connectionState=connected 事件对齐）。 */
    @Volatile
    private var proxyNotificationsReady = false

    /**
     * 待发送 PDU 队列。
     *
     * BLE GATT 每次只能有一个 outstanding write。多个 PDU 必须串行发送，
     * 上一个写入的 [onCharacteristicWrite] 回调触发后才发下一个。
     */
    private val writeQueue = LinkedList<ByteArray>()

    /** 当前是否有写操作正在进行。 */
    @Volatile
    private var isWriting = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /** NO_RESPONSE 写入后的最小间隔，避免 GATT 繁忙丢包。 */
    private val proxyWriteGapMs = 8L

    // ── 自定义 BLE 通道（与 Proxy 共用 GATT 连接）────────────────────────────

    private var customServiceUuid: UUID? = null
    private var customWriteUuid: UUID? = null
    private var customNotifyUuid: UUID? = null
    private var customWriteCharacteristic: BluetoothGattCharacteristic? = null
    private var customNotifyCharacteristic: BluetoothGattCharacteristic? = null

    @Volatile
    private var customChannelReady = false

    private val customWriteQueue = LinkedList<CustomWriteItem>()

    @Volatile
    private var customWriting = false

    @Volatile
    private var activeTransferDeferred: CompletableDeferred<Unit>? = null

    private var activeTransferTotalBytes = 0
    private var activeTransferBytesSent = 0

    // ── GATT 回调 ──────────────────────────────────────────────────────────────

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            connectionState = newState
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    targetAddress = gatt.device.address.uppercase()
                    Log.d(TAG, "GATT 连接成功，开始发现服务...")
                    MeshEventStreamHandler.sendConnectionState(
                        "connecting",
                        gatt.device.address,
                    )
                    // 请求更大的 MTU 以提升传输效率
                    gatt.requestMtu(MESH_MTU)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.d(TAG, "GATT 连接已断开")
                    targetAddress = null
                    dataInCharacteristic = null
                    proxyNotificationsReady = false
                    clearCustomChannel(failActiveTransfer = true)
                    synchronized(writeQueue) {
                        writeQueue.clear()
                        isWriting = false
                    }
                    bluetoothGatt?.close()
                    bluetoothGatt = null
                    MeshEventStreamHandler.sendConnectionState("disconnected")
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            currentMtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu - 3 else MESH_MTU - 3
            Log.d(TAG, "MTU 更新为 $mtu（载荷 $currentMtu），开始发现 GATT 服务...")
            // MTU 确认后再发现服务，确保后续数据包不被截断
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "服务发现失败，status=$status")
                MeshEventStreamHandler.sendError("GATT_ERROR", "GATT 服务发现失败")
                return
            }

            val proxyService = gatt.getService(MESH_PROXY_SERVICE)
            if (proxyService == null) {
                Log.e(TAG, "未找到 Mesh Proxy Service，设备可能不是代理节点")
                MeshEventStreamHandler.sendError(
                    "NO_PROXY_SERVICE",
                    "设备不支持 Mesh Proxy Service",
                )
                return
            }

            // 获取 Data In 特征（用于发送）
            dataInCharacteristic = proxyService.getCharacteristic(MESH_PROXY_DATA_IN)

            // 订阅 Data Out 特征的通知（用于接收）
            val dataOut = proxyService.getCharacteristic(MESH_PROXY_DATA_OUT)
            if (dataOut != null) {
                enableNotifications(gatt, dataOut)
            }

            resolveCustomCharacteristics(gatt)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == MESH_PROXY_DATA_OUT) {
                @Suppress("DEPRECATION")
                val value = characteristic.value ?: return
                Log.v(TAG, "收到代理数据: ${value.size} 字节")
                networkManager.meshManagerApi.handleNotifications(currentMtu, value)
                return
            }
            val notifyUuid = customNotifyUuid
            if (notifyUuid != null && characteristic.uuid == notifyUuid) {
                @Suppress("DEPRECATION")
                val value = characteristic.value ?: return
                MeshEventStreamHandler.sendEvent(
                    mapOf(
                        "type" to "customBleDataReceived",
                        "data" to value.map { it.toInt() and 0xFF },
                    ),
                )
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            val writeUuid = customWriteUuid
            if (writeUuid != null && characteristic.uuid == writeUuid) {
                handleCustomWriteComplete(status)
                return
            }
            if (characteristic.uuid != MESH_PROXY_DATA_IN) return
            synchronized(writeQueue) {
                if (!isWriting) return
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.v(TAG, "写入成功（回调）")
                    val sentData = characteristic.value
                    if (sentData != null) {
                        networkManager.meshManagerApi.handleWriteCallbacks(
                            currentMtu,
                            sentData,
                        )
                    }
                } else {
                    Log.e(TAG, "写入失败，status=$status")
                }
                isWriting = false
            }
            mainHandler.post { drainWriteQueue() }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (descriptor.uuid != CCCD_UUID || status != BluetoothGatt.GATT_SUCCESS) {
                return
            }
            // 仅 Proxy Data Out 的 CCCD 表示 Mesh Proxy 就绪，勿与自定义 notify 混淆
            if (descriptor.characteristic?.uuid != MESH_PROXY_DATA_OUT) {
                return
            }
            Log.d(TAG, "通知已开启，代理连接就绪")
            proxyNotificationsReady = true
            MeshEventStreamHandler.sendConnectionState("connected", gatt.device.address)
            // Proxy 就绪后自动触发 AppKey 分发（首次配网后立即可控制）
            networkManager.onProxyConnected()
        }
    }

    // ── 公开方法 ───────────────────────────────────────────────────────────────

    /**
     * 连接到指定蓝牙地址的 Mesh 代理节点。
     *
     * @param address 目标设备的蓝牙 MAC 地址。
     */
    fun connect(address: String) {
        val adapter = bluetoothAdapter
            ?: throw BluetoothUnavailableException()

        if (!adapter.isEnabled) throw BluetoothDisabledException()

        val normalizedAddress = address.uppercase()
        if (isReadyForProxy(normalizedAddress)) {
            Log.d(TAG, "已连接到 $normalizedAddress，跳过重复连接")
            return
        }
        if (isConnectingTo(normalizedAddress)) {
            Log.d(TAG, "正在连接 $normalizedAddress，跳过重复连接")
            return
        }

        val device: BluetoothDevice = adapter.getRemoteDevice(address)
        Log.d(TAG, "连接代理节点: $address")
        targetAddress = normalizedAddress
        proxyNotificationsReady = false
        dataInCharacteristic = null

        // 断开已有连接
        bluetoothGatt?.disconnect()

        connectionState = BluetoothProfile.STATE_CONNECTING
        MeshEventStreamHandler.sendConnectionState("connecting", address)

        // autoConnect=false 确保立即连接而非等待设备出现
        bluetoothGatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, gattCallback)
        }
    }

    /**
     * 断开当前代理连接，清空写入队列。
     */
    fun disconnect() {
        synchronized(writeQueue) {
            writeQueue.clear()
            isWriting = false
        }
        clearCustomChannel(failActiveTransfer = true)
        targetAddress = null
        proxyNotificationsReady = false
        dataInCharacteristic = null
        bluetoothGatt?.disconnect()
        bluetoothGatt?.close()
        bluetoothGatt = null
        connectionState = BluetoothProfile.STATE_DISCONNECTED
    }

    /** 是否已连接到指定 MAC 且 Proxy 通道就绪。 */
    fun isReadyForProxy(address: String): Boolean {
        val normalized = address.uppercase()
        return proxyNotificationsReady &&
            connectionState == BluetoothProfile.STATE_CONNECTED &&
            targetAddress == normalized &&
            dataInCharacteristic != null
    }

    /** 是否正在连接指定 MAC。 */
    fun isConnectingTo(address: String): Boolean {
        val normalized = address.uppercase()
        return connectionState == BluetoothProfile.STATE_CONNECTING &&
            targetAddress == normalized
    }

    /**
     * 将 Mesh PDU 加入写入队列，串行写入代理节点的 Data In 特征。
     *
     * 与 [PbGattManager] 一致，所有写入操作串行执行，避免 BLE 写入冲突。
     *
     * @param pdu 要发送的 Mesh PDU 字节数组。
     */
    fun sendPdu(pdu: ByteArray) {
        if (bluetoothGatt == null || dataInCharacteristic == null) {
            Log.e(TAG, "sendPdu 失败：代理未连接或服务未发现")
            return
        }
        Log.d(TAG, "PDU 入队 ${pdu.size} 字节（队列长度: ${writeQueue.size + 1}）")
        synchronized(writeQueue) { writeQueue.add(pdu) }
        drainWriteQueue()
    }

    /**
     * 当前是否已连接到代理节点。
     */
    val isConnected: Boolean
        get() = connectionState == BluetoothProfile.STATE_CONNECTED

    /** 返回与 Dart [MeshConnectionState] 对应的连接状态字符串。 */
    fun getMeshConnectionState(): String = when {
        proxyNotificationsReady &&
            connectionState == BluetoothProfile.STATE_CONNECTED -> "connected"
        connectionState == BluetoothProfile.STATE_CONNECTING -> "connecting"
        else -> "disconnected"
    }

    /** 当前已连接或正在连接的 Proxy MAC 地址。 */
    fun getProxyAddress(): String? = targetAddress

    /**
     * 当前协商到的 MTU 载荷大小（供 nRF Mesh 库使用）。
     */
    fun getMtu(): Int = currentMtu

    /**
     * 配置自定义 BLE 通道 UUID；若 GATT 已连接会立即尝试发现特征。
     */
    fun configureCustomChannel(
        serviceUuid: String,
        writeCharacteristicUuid: String,
        notifyCharacteristicUuid: String?,
    ) {
        val serviceUuidParsed = parseBleUuid(serviceUuid)
        val writeUuidParsed = parseBleUuid(writeCharacteristicUuid)
        val notifyUuidParsed = notifyCharacteristicUuid?.let { parseBleUuid(it) }
        if (customServiceUuid == serviceUuidParsed &&
            customWriteUuid == writeUuidParsed &&
            customNotifyUuid == notifyUuidParsed &&
            customChannelReady &&
            customWriteCharacteristic != null
        ) {
            return
        }
        customServiceUuid = serviceUuidParsed
        customWriteUuid = writeUuidParsed
        customNotifyUuid = notifyUuidParsed
        customChannelReady = false
        customWriteCharacteristic = null
        customNotifyCharacteristic = null
        bluetoothGatt?.let { gatt ->
            val serviceUuidParsed = customServiceUuid ?: return@let
            if (gatt.getService(serviceUuidParsed) != null) {
                resolveCustomCharacteristics(gatt)
            } else {
                Log.d(TAG, "自定义 Service 未缓存，重新发现 GATT 服务…")
                gatt.discoverServices()
            }
        }
    }

    /** 自定义写特征是否已就绪。 */
    fun isCustomChannelReady(): Boolean =
        customChannelReady && customWriteCharacteristic != null

    /** 写入单包自定义数据（不超过当前 MTU）。 */
    suspend fun writeCustomData(data: ByteArray) {
        if (!isCustomChannelReady()) {
            throw IllegalStateException("自定义 BLE 通道未就绪")
        }
        if (data.size > currentMtu) {
            throw IllegalArgumentException("数据长度 ${data.size} 超过 MTU $currentMtu")
        }
        suspendCancellableCoroutine { cont ->
            val item = CustomWriteItem(data) {
                cont.resume(Unit)
            }
            synchronized(customWriteQueue) { customWriteQueue.add(item) }
            cont.invokeOnCancellation {
                synchronized(customWriteQueue) { customWriteQueue.remove(item) }
            }
            drainCustomWriteQueue()
        }
    }

    /** 按 MTU 分包写入自定义数据（带响应写入）。 */
    suspend fun transferCustomData(data: ByteArray) {
        if (!isCustomChannelReady()) {
            throw IllegalStateException("自定义 BLE 通道未就绪")
        }
        if (data.isEmpty()) return
        val chunkSize = maxOf(20, minOf(currentMtu, 512))
        activeTransferDeferred?.completeExceptionally(
            IllegalStateException("上一次传输被新请求取代"),
        )
        val deferred = CompletableDeferred<Unit>()
        activeTransferDeferred = deferred
        activeTransferTotalBytes = data.size
        activeTransferBytesSent = 0
        var offset = 0
        while (offset < data.size) {
            val end = minOf(offset + chunkSize, data.size)
            val chunk = data.copyOfRange(offset, end)
            val isLast = end == data.size
            val item = CustomWriteItem(chunk) {
                activeTransferBytesSent += chunk.size
                MeshEventStreamHandler.sendEvent(
                    mapOf(
                        "type" to "customBleTransferProgress",
                        "bytesSent" to activeTransferBytesSent,
                        "totalBytes" to activeTransferTotalBytes,
                    ),
                )
                if (isLast) {
                    activeTransferDeferred = null
                    deferred.complete(Unit)
                }
            }
            synchronized(customWriteQueue) { customWriteQueue.add(item) }
            offset = end
        }
        drainCustomWriteQueue()
        deferred.await()
    }

    // ── 私有方法 ───────────────────────────────────────────────────────────────

    /**
     * 从写入队列取出下一条 PDU 发送到 GATT。
     *
     * 必须在 [onCharacteristicWrite] 回调后调用，确保每次只有一个写操作进行。
     */
    @Suppress("DEPRECATION")
    private fun drainWriteQueue() {
        synchronized(writeQueue) {
            if (isWriting || writeQueue.isEmpty()) return
            val pdu = writeQueue.poll() ?: return
            val gatt = bluetoothGatt ?: return
            val characteristic = dataInCharacteristic ?: return
            isWriting = true
            characteristic.value = pdu
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            val ok = gatt.writeCharacteristic(characteristic)
            if (!ok) {
                Log.w(TAG, "writeCharacteristic 繁忙，PDU 重新入队")
                writeQueue.addFirst(pdu)
                isWriting = false
                mainHandler.postDelayed({ drainWriteQueue() }, 20L)
            } else {
                Log.d(TAG, "GATT 写入 ${pdu.size} 字节 → Data In")
                networkManager.meshManagerApi.handleWriteCallbacks(
                    currentMtu,
                    pdu,
                )
                // NO_RESPONSE 往往无 onCharacteristicWrite，需立即释放写锁
                isWriting = false
                mainHandler.postDelayed({ drainWriteQueue() }, proxyWriteGapMs)
            }
        }
    }

    /**
     * 开启 GATT 特征的通知功能（写入 CCCD 描述符）。
     */
    @Suppress("DEPRECATION")
    private fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: return
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        gatt.writeDescriptor(descriptor)
    }

    private fun resolveCustomCharacteristics(gatt: BluetoothGatt) {
        val serviceUuid = customServiceUuid ?: return
        val writeUuid = customWriteUuid ?: return
        val service = gatt.getService(serviceUuid) ?: return
        customWriteCharacteristic = service.getCharacteristic(writeUuid)
        customNotifyUuid?.let { notifyUuid ->
            val notifyChar = service.getCharacteristic(notifyUuid)
            customNotifyCharacteristic = notifyChar
            notifyChar?.let { enableNotifications(gatt, it) }
        }
        val ready = customWriteCharacteristic != null
        if (ready != customChannelReady) {
            customChannelReady = ready
            if (ready) {
                Log.d(TAG, "自定义 BLE 通道已就绪")
                MeshEventStreamHandler.sendEvent(
                    mapOf("type" to "customBleChannelReady", "ready" to true),
                )
            }
        }
    }

    private fun clearCustomChannel(failActiveTransfer: Boolean) {
        if (failActiveTransfer) {
            activeTransferDeferred?.completeExceptionally(
                IllegalStateException("GATT 连接已断开"),
            )
        }
        activeTransferDeferred = null
        synchronized(customWriteQueue) {
            customWriteQueue.clear()
            customWriting = false
        }
        customWriteCharacteristic = null
        customNotifyCharacteristic = null
        customChannelReady = false
    }

    @Suppress("DEPRECATION")
    private fun drainCustomWriteQueue() {
        synchronized(customWriteQueue) {
            if (customWriting || customWriteQueue.isEmpty()) return
            val item = customWriteQueue.peek() ?: return
            val gatt = bluetoothGatt ?: return
            val characteristic = customWriteCharacteristic ?: return
            customWriting = true
            characteristic.value = item.data
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            val ok = gatt.writeCharacteristic(characteristic)
            if (!ok) {
                customWriting = false
                mainHandler.postDelayed({ drainCustomWriteQueue() }, 20L)
            }
        }
    }

    private fun handleCustomWriteComplete(status: Int) {
        val item: CustomWriteItem?
        synchronized(customWriteQueue) {
            customWriting = false
            item = if (status == BluetoothGatt.GATT_SUCCESS) {
                customWriteQueue.poll()
            } else {
                customWriteQueue.clear()
                null
            }
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            Log.e(TAG, "自定义 BLE 写入失败，status=$status")
            activeTransferDeferred?.completeExceptionally(
                IllegalStateException("自定义 BLE 写入失败: $status"),
            )
            activeTransferDeferred = null
            return
        }
        item?.onSuccess?.invoke()
        mainHandler.post { drainCustomWriteQueue() }
    }
}
