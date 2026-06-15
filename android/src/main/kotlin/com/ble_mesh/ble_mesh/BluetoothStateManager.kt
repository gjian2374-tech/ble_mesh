package com.ble_mesh.ble_mesh

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter

/**
 * 蓝牙适配器状态监控工具类。
 *
 * 提供获取当前蓝牙状态及监听状态变化广播的功能。
 */
object BluetoothStateManager {

    /**
     * 获取当前蓝牙适配器状态字符串。
     *
     * 返回值对应 Dart 层 [BluetoothState] 枚举的 name 字段：
     * - "unknown" — 状态未知
     * - "unsupported" — 设备不支持蓝牙
     * - "poweredOff" — 蓝牙已关闭
     * - "poweredOn" — 蓝牙已开启
     * - "resetting" — 蓝牙正在重置
     */
    fun getState(context: Context): String {
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
            ?: return "unsupported"

        return when (adapter.state) {
            BluetoothAdapter.STATE_ON -> "poweredOn"
            BluetoothAdapter.STATE_OFF -> "poweredOff"
            BluetoothAdapter.STATE_TURNING_ON -> "resetting"
            BluetoothAdapter.STATE_TURNING_OFF -> "resetting"
            else -> "unknown"
        }
    }

    /**
     * 注册蓝牙状态变化广播监听器。
     *
     * 当蓝牙开关状态发生变化时，会调用 [onStateChanged] 回调。
     *
     * @return 注册的 [BroadcastReceiver]，调用者负责在适当时机取消注册。
     */
    fun registerStateReceiver(
        context: Context,
        onStateChanged: (String) -> Unit,
    ): BroadcastReceiver {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return

                val newState = when (
                    intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                ) {
                    BluetoothAdapter.STATE_ON -> "poweredOn"
                    BluetoothAdapter.STATE_OFF -> "poweredOff"
                    BluetoothAdapter.STATE_TURNING_ON -> "resetting"
                    BluetoothAdapter.STATE_TURNING_OFF -> "resetting"
                    else -> "unknown"
                }
                onStateChanged(newState)
            }
        }

        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        context.registerReceiver(receiver, filter)
        return receiver
    }
}
