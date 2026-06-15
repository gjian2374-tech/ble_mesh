package com.ble_mesh.ble_mesh

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * 蓝牙权限管理工具类。
 *
 * 根据 Android 版本自动选择需要请求的权限：
 * - Android 12 (API 31) 及以上：使用 BLUETOOTH_SCAN 和 BLUETOOTH_CONNECT
 * - Android 11 及以下：使用 ACCESS_FINE_LOCATION（扫描时必须）
 */
object PermissionManager {

    /** 权限请求码，用于 onRequestPermissionsResult 回调识别。 */
    private const val REQUEST_CODE = 0xBEA7

    /** 待回调的结果处理器。 */
    private var pendingCallback: ((Boolean) -> Unit)? = null

    /**
     * 获取当前 Android 版本所需的蓝牙权限列表。
     */
    private fun requiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            // Android 11 及以下
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }
    }

    /**
     * 检查所有必要权限是否已授予。
     */
    fun hasPermissions(activity: Activity): Boolean {
        return requiredPermissions().all { permission ->
            ContextCompat.checkSelfPermission(activity, permission) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * 请求所有必要的蓝牙权限。
     *
     * 如果权限已全部授予，直接回调 `true`。
     * 否则弹出系统权限请求对话框，结果通过 [callback] 返回。
     *
     * @param activity 当前 Activity。
     * @param callback 权限请求结果回调，`true` 表示全部授权。
     */
    fun requestPermissions(activity: Activity, callback: (Boolean) -> Unit) {
        if (hasPermissions(activity)) {
            callback(true)
            return
        }
        pendingCallback = callback
        ActivityCompat.requestPermissions(activity, requiredPermissions(), REQUEST_CODE)
    }

    /**
     * 在 Activity 的 onRequestPermissionsResult 中调用此方法以处理权限结果。
     *
     * @param requestCode 请求码。
     * @param grantResults 权限授予结果数组。
     * @return 是否处理了此权限请求（false 表示 requestCode 不匹配）。
     */
    fun handlePermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val allGranted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingCallback?.invoke(allGranted)
        pendingCallback = null
        return true
    }
}
