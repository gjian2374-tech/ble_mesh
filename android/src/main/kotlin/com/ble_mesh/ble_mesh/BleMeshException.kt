package com.ble_mesh.ble_mesh

/**
 * BLE Mesh 插件内部异常基类。
 *
 * @param code 错误码，与 Dart 层 [BleMeshException.code] 对应。
 * @param message 错误描述。
 * @param details 可选的额外信息。
 */
open class BleMeshException(
    val code: String,
    override val message: String,
    val details: Any? = null,
) : Exception(message)

/** 蓝牙不可用（设备不支持）时抛出。 */
class BluetoothUnavailableException :
    BleMeshException("BLUETOOTH_UNAVAILABLE", "设备不支持蓝牙")

/** 蓝牙已关闭时抛出。 */
class BluetoothDisabledException :
    BleMeshException("BLUETOOTH_DISABLED", "蓝牙已关闭，请开启蓝牙")

/** 缺少必要权限时抛出。 */
class PermissionDeniedException(detail: String? = null) :
    BleMeshException("PERMISSION_DENIED", "蓝牙权限被拒绝", detail)

/** 未连接代理节点时执行需要连接的操作时抛出。 */
class NotConnectedException :
    BleMeshException("NOT_CONNECTED", "未连接到 Mesh 代理节点")

/** 配网失败时抛出。 */
class ProvisioningFailedException(reason: String) :
    BleMeshException("PROVISIONING_FAILED", "配网失败: $reason")
