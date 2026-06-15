import Foundation

/// iOS 插件统一日志，输出到 Xcode 控制台（NSLog）。
/// 在 Xcode 控制台搜索 `BleMesh` 过滤。
enum MeshLog {
    private static let tag = "BleMesh"

    static func d(_ message: String) {
        NSLog("[\(tag)] %@", message)
    }

    static func d(_ phase: String, _ message: String) {
        NSLog("[\(tag)][\(phase)] %@", message)
    }

    static func e(_ message: String) {
        NSLog("[\(tag)] ERROR: %@", message)
    }

    static func e(_ phase: String, _ message: String) {
        NSLog("[\(tag)][\(phase)] ERROR: %@", message)
    }

    static func hex(_ data: Data, maxBytes: Int = 16) -> String {
        let slice = data.prefix(maxBytes)
        let s = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > maxBytes ? "\(s)…(\(data.count)B)" : s
    }
}
