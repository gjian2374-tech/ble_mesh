package com.ble_mesh.ble_mesh

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * BLE 扫描管理器。
 *
 * 负责扫描附近广播了 BLE Mesh 配网服务（Mesh Provisioning Service）的
 * 未配网设备，并通过 [MeshEventStreamHandler] 将结果推送给 Dart 层。
 *
 * BLE Mesh 配网服务 UUID: 0x1827（Mesh Provisioning Service）
 * BLE Mesh 代理服务 UUID:  0x1828（Mesh Proxy Service）
 */
class BleScanManager(
    private val context: Context,
    private val eventSink: MeshEventStreamHandler,
) {

    companion object {
        private const val TAG = "BleScanManager"

        /** BLE Mesh 配网服务 UUID（Mesh Provisioning Service）。 */
        val MESH_PROVISIONING_UUID: UUID = UUID.fromString("00001827-0000-1000-8000-00805F9B34FB")

        /** BLE Mesh 代理服务 UUID（Mesh Proxy Service）。 */
        val MESH_PROXY_UUID: UUID = UUID.fromString("00001828-0000-1000-8000-00805F9B34FB")
    }

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 是否正在扫描。 */
    @Volatile
    private var isScanning = false

    /** 已发现设备的 UUID 集合，用于去重。 */
    private val discoveredUuids = mutableSetOf<String>()

    /** 扫描超时 Runnable，超时后自动停止扫描。 */
    private val stopScanRunnable = Runnable {
        if (isScanning) {
            stopScan()
            MeshEventStreamHandler.sendScanStopped()
        }
    }

    // ── BLE 扫描回调 ───────────────────────────────────────────────────────────

    /**
     * 扫描到未配网设备时的回调。
     */
    private val provisioningScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            handleScanResult(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            results.forEach { handleScanResult(it) }
        }

        override fun onScanFailed(errorCode: Int) {
            val reason = when (errorCode) {
                ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "扫描已在进行中"
                ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED ->
                    "应用注册失败，请重启蓝牙后重试"
                ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "内部错误，请重启蓝牙后重试"
                ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "设备不支持此扫描功能"
                6 -> "扫描过于频繁，请稍后再试（Android 12+ 限制）"
                else -> "未知错误码: $errorCode"
            }
            Log.e(TAG, "扫描失败：$reason（错误码: $errorCode）")
            isScanning = false
            MeshEventStreamHandler.sendError("SCAN_FAILED", "BLE 扫描失败：$reason", errorCode)
        }
    }

    // ── 公开方法 ───────────────────────────────────────────────────────────────

    /**
     * 开始扫描附近的未配网 BLE Mesh 设备。
     *
     * 只扫描广播了配网服务 UUID (0x1827) 的设备。
     * 如果当前已在扫描，先停止再重新开始。
     *
     * @param timeoutMs 扫描超时时间（毫秒），null 表示持续扫描。
     */
    fun startScan(timeoutMs: Long? = null) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            MeshEventStreamHandler.sendError("BLUETOOTH_DISABLED", "蓝牙未开启")
            return
        }

        if (isScanning) stopScan()
        discoveredUuids.clear()

        // 只扫描配网服务 UUID，减少无关设备干扰
        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(MESH_PROVISIONING_UUID))
                .build()
        )

        // 使用低延迟模式以尽快发现设备（会增加功耗）
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            Log.e(TAG, "bluetoothLeScanner 为 null，蓝牙可能正在开启中或状态异常")
            MeshEventStreamHandler.sendError(
                "SCAN_FAILED",
                "无法获取 BLE 扫描器，请确认蓝牙已完全开启后重试",
            )
            return
        }
        scanner.startScan(filters, settings, provisioningScanCallback)
        isScanning = true
        Log.d(TAG, "开始扫描 BLE Mesh 设备（UUID: 0x1827）...")

        // 设置超时自动停止
        if (timeoutMs != null && timeoutMs > 0) {
            mainHandler.removeCallbacks(stopScanRunnable)
            mainHandler.postDelayed(stopScanRunnable, timeoutMs)
        }
    }

    /**
     * 停止当前扫描。
     */
    fun stopScan() {
        if (!isScanning) return
        mainHandler.removeCallbacks(stopScanRunnable)
        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(provisioningScanCallback)
        } catch (e: Exception) {
            Log.w(TAG, "停止扫描时发生异常（忽略）: ${e.message}")
        }
        isScanning = false
        Log.d(TAG, "扫描已停止")
    }

    /**
     * 主动扫描 Mesh Proxy Service，直到目标 MAC 开始广播或超时。
     *
     * 配网后设备需从 PB-GATT (0x1827) 切换到 Proxy (0x1828)，固定等待会浪费 1–2s；
     * 一旦检测到 Proxy 广播即可立即发起 GATT 连接。
     *
     * @param targetMac 目标设备 MAC 地址。
     * @param minDelayMs 最短等待时间，给设备切换广播留出窗口。
     * @param timeoutMs 扫描超时。
     * @return 是否在超时前检测到 Proxy 广播。
     */
    suspend fun waitForProxyAdvertisement(
        targetMac: String,
        minDelayMs: Long = 400L,
        timeoutMs: Long = 4_000L,
    ): Boolean {
        delay(minDelayMs)

        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) return false

        val normalized = targetMac.uppercase()
        val scanner = adapter.bluetoothLeScanner ?: return false

        if (isScanning) stopScan()

        return suspendCancellableCoroutine { cont ->
            var timeoutRunnable: Runnable? = null

            val callback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    if (result.device.address.uppercase() == normalized) {
                        Log.d(TAG, "检测到 Proxy 广播: $normalized RSSI=${result.rssi}")
                        cleanup()
                        if (cont.isActive) cont.resume(true)
                    }
                }

                override fun onScanFailed(errorCode: Int) {
                    Log.w(TAG, "Proxy 等待扫描失败: $errorCode")
                    cleanup()
                    if (cont.isActive) cont.resume(false)
                }

                fun cleanup() {
                    timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                    try {
                        scanner.stopScan(this)
                    } catch (_: Exception) {
                    }
                }
            }

            timeoutRunnable = Runnable {
                Log.d(TAG, "Proxy 广播扫描超时 ($timeoutMs ms): $normalized")
                callback.cleanup()
                if (cont.isActive) cont.resume(false)
            }

            val filters = listOf(
                ScanFilter.Builder()
                    .setServiceUuid(ParcelUuid(MESH_PROXY_UUID))
                    .build(),
            )
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()

            try {
                scanner.startScan(filters, settings, callback)
                mainHandler.postDelayed(timeoutRunnable!!, timeoutMs)
            } catch (e: Exception) {
                Log.w(TAG, "启动 Proxy 扫描失败: ${e.message}")
                if (cont.isActive) cont.resume(false)
                return@suspendCancellableCoroutine
            }

            cont.invokeOnCancellation {
                callback.cleanup()
            }
        }
    }

    // ── 私有方法 ───────────────────────────────────────────────────────────────

    /**
     * 处理单条扫描结果，提取设备信息并推送给 Dart 层。
     */
    private fun handleScanResult(result: ScanResult) {
        // 从广播数据中提取 Mesh 配网 UUID
        val serviceData = result.scanRecord?.getServiceData(ParcelUuid(MESH_PROVISIONING_UUID))
        val deviceUuid = if (serviceData != null && serviceData.size >= 16) {
            // 配网服务数据的前 16 字节是设备 UUID
            bytesToUuidString(serviceData.take(16).toByteArray())
        } else {
            // 回退到蓝牙地址作为唯一标识
            result.device.address
        }

        // 去重处理：同一个设备只上报一次
        if (discoveredUuids.contains(deviceUuid)) return
        discoveredUuids.add(deviceUuid)

        val deviceName = result.device.name
            ?: result.scanRecord?.deviceName
            ?: "未知设备"

        val deviceMap = mapOf(
            "uuid" to deviceUuid,
            "name" to deviceName,
            "rssi" to result.rssi,
            "address" to result.device.address,
            "capabilities" to extractCapabilities(serviceData),
        )

        Log.d(TAG, "发现设备: $deviceName ($deviceUuid) RSSI=${result.rssi}")
        MeshEventStreamHandler.sendScanResult(deviceMap)
    }

    /**
     * 从配网服务数据中提取设备能力信息（Capabilities）。
     *
     * 配网广播数据格式（Mesh Profile Specification）：
     * - Bytes 0-15: Device UUID
     * - Bytes 16-17: OOB Information
     * - Bytes 18-21: URI Hash（可选）
     */
    private fun extractCapabilities(serviceData: ByteArray?): Map<String, Any>? {
        if (serviceData == null || serviceData.size < 18) return null
        val oobInfo = ((serviceData[16].toInt() and 0xFF) shl 8) or
            (serviceData[17].toInt() and 0xFF)
        return mapOf("oobInfo" to oobInfo)
    }

    /**
     * 将 16 字节数组转换为标准 UUID 字符串格式。
     */
    private fun bytesToUuidString(bytes: ByteArray): String {
        if (bytes.size < 16) return bytes.joinToString("") { "%02x".format(it) }
        val hex = bytes.joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-" +
            "${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
    }
}
