package com.ble_mesh.ble_mesh

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.util.Log
import java.util.LinkedList
import java.util.UUID

/**
 * 配网专用 GATT 连接管理器（PB-GATT）。
 *
 * 连接到未配网设备的 Mesh Provisioning Service (UUID 0x1827)，
 * 负责在配网期间向设备写入 PDU 以及接收设备返回的配网数据。
 *
 * ## GATT 服务结构
 * - Mesh Provisioning Service: 0x1827
 *   - Provisioning Data In:  0x2ADB（Write Without Response，APP → 设备）
 *   - Provisioning Data Out: 0x2ADC（Notify，设备 → APP）
 *
 * 数据接收后通过 [onDataReceived] 回调传给 nRF Mesh 库的
 * `MeshManagerApi.handleNotifications(mtu, data)` 处理。
 * 数据写入成功后通过 [onDataSent] 回调让库更新分包状态。
 */
class PbGattManager(
    private val context: Context,
    /** 收到配网数据时的回调，参数为 (mtu, data)。 */
    private val onDataReceived: (mtu: Int, data: ByteArray) -> Unit,
    /**
     * 成功写入配网 PDU 后的回调，参数为 (mtu, data)。
     * 需要调用 `MeshManagerApi.handleWriteCallbacks(mtu, data)` 以更新库内部分包状态。
     */
    private val onDataSent: (mtu: Int, data: ByteArray) -> Unit,
    /** GATT 连接并开启通知后触发（配网通道就绪）。 */
    private val onConnected: () -> Unit,
    /** GATT 连接断开时触发。 */
    private val onDisconnected: () -> Unit,
    /** 发生不可恢复错误时触发。 */
    private val onError: (message: String) -> Unit,
) {
    companion object {
        private const val TAG = "PbGattManager"

        /** Mesh Provisioning Service UUID */
        val PROVISIONING_SERVICE: UUID =
            UUID.fromString("00001827-0000-1000-8000-00805F9B34FB")

        /** Provisioning Data In Characteristic（写入通道）*/
        val PROVISIONING_DATA_IN: UUID =
            UUID.fromString("00002ADB-0000-1000-8000-00805F9B34FB")

        /** Provisioning Data Out Characteristic（通知通道）*/
        val PROVISIONING_DATA_OUT: UUID =
            UUID.fromString("00002ADC-0000-1000-8000-00805F9B34FB")

        /** Client Characteristic Configuration Descriptor */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

        /** 配网 MTU 默认值（BLE Mesh 建议 69，即 ATT MTU=71）。 */
        private const val PROVISIONING_MTU = 69
    }

    private var gatt: BluetoothGatt? = null
    private var dataInCharacteristic: BluetoothGattCharacteristic? = null

    /** 实际协商到的 MTU 大小（减去 ATT Header 3 字节）。 */
    private var currentMtu = PROVISIONING_MTU

    /** GATT 写入队列，保证串行写入。 */
    private val writeQueue = LinkedList<ByteArray>()
    private var isWriting = false

    // ── GATT 回调 ──────────────────────────────────────────────────────────────

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.d(TAG, "PB-GATT 已连接 ${gatt.device.address}，请求 MTU...")
                    // 请求较大 MTU 减少分包
                    gatt.requestMtu(517)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.d(TAG, "PB-GATT 断开 (status=$status)")
                    cleanup()
                    onDisconnected()
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            // MTU 协商后实际可用载荷 = MTU - 3（ATT Header）
            currentMtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu - 3 else PROVISIONING_MTU
            Log.d(TAG, "MTU 协商完成: ATT_MTU=$mtu，Payload=$currentMtu，开始发现服务...")
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                onError("服务发现失败 (status=$status)，请重试")
                return
            }
            val service = gatt.getService(PROVISIONING_SERVICE)
            if (service == null) {
                onError("设备未找到 Mesh Provisioning Service (0x1827)，请确认设备处于未配网状态")
                return
            }
            dataInCharacteristic = service.getCharacteristic(PROVISIONING_DATA_IN)
            if (dataInCharacteristic == null) {
                onError("未找到 Provisioning Data In 特征 (0x2ADB)")
                return
            }
            val dataOut = service.getCharacteristic(PROVISIONING_DATA_OUT)
            if (dataOut == null) {
                onError("未找到 Provisioning Data Out 特征 (0x2ADC)")
                return
            }
            enableNotifications(gatt, dataOut)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.d(TAG, "配网通知已开启，PB-GATT 通道就绪")
                    onConnected()
                } else {
                    onError("开启配网通知失败 (status=$status)")
                }
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == PROVISIONING_DATA_OUT) {
                @Suppress("DEPRECATION")
                val data = characteristic.value ?: return
                Log.v(TAG, "收到配网数据: ${data.size} 字节 [${data.toHex()}]")
                onDataReceived(currentMtu, data)
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.v(TAG, "配网 PDU 写入成功")
                // 通知 nRF Mesh 库更新内部分包/重组状态（必须调用，否则配网分包会卡住）
                val sentData = characteristic.value
                if (sentData != null) {
                    onDataSent(currentMtu, sentData)
                }
            } else {
                Log.e(TAG, "配网 PDU 写入失败 (status=$status)")
            }
            synchronized(writeQueue) { isWriting = false }
            drainWriteQueue()
        }
    }

    // ── 公开方法 ───────────────────────────────────────────────────────────────

    /**
     * 连接到目标设备的配网服务。
     *
     * @param device 目标蓝牙设备（从扫描结果获取）。
     */
    fun connect(device: BluetoothDevice) {
        disconnect()
        Log.d(TAG, "连接配网目标: ${device.address}")
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            device.connectGatt(context, false, gattCallback)
        }
    }

    /**
     * 将配网 PDU 加入写入队列，串行写入设备。
     *
     * 由 nRF Mesh 库的 `MeshManagerCallbacks.sendProvisioningPdu` 触发。
     */
    fun sendPdu(pdu: ByteArray) {
        Log.v(TAG, "入队配网 PDU: ${pdu.size} 字节 [${pdu.toHex()}]")
        synchronized(writeQueue) { writeQueue.add(pdu) }
        drainWriteQueue()
    }

    /** 断开当前配网 GATT 连接。 */
    fun disconnect() {
        gatt?.disconnect()
        cleanup()
    }

    /** 当前协商到的 MTU 载荷大小。 */
    fun getMtu(): Int = currentMtu

    // ── 私有方法 ───────────────────────────────────────────────────────────────

    private fun cleanup() {
        gatt?.close()
        gatt = null
        dataInCharacteristic = null
        synchronized(writeQueue) {
            writeQueue.clear()
            isWriting = false
        }
    }

    @Suppress("DEPRECATION")
    private fun drainWriteQueue() {
        synchronized(writeQueue) {
            if (isWriting || writeQueue.isEmpty()) return
            val pdu = writeQueue.poll() ?: return
            val g = gatt ?: return
            val char = dataInCharacteristic ?: return
            isWriting = true
            char.value = pdu
            char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            val success = g.writeCharacteristic(char)
            if (!success) {
                Log.e(TAG, "writeCharacteristic 返回 false，可能 GATT 队列繁忙")
                isWriting = false
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun enableNotifications(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
    ) {
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: run {
            onError("未找到 CCCD 描述符，无法开启配网通知")
            return
        }
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        gatt.writeDescriptor(descriptor)
    }

    private fun ByteArray.toHex(): String =
        joinToString(" ") { "%02X".format(it) }
}
