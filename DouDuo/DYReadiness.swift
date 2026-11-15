import Foundation

/// 「这一条已经有数据、切过去就能直接出画」的登记表（移植自上游 1.5.2）。
/// 分页器在抬手时查这里：下一条还没就绪就把页面弹回当前页（抖音原版也是等到能出画才让你翻过去）。
/// 故意做成线程安全的静态表：分页 delegate 在 UIKit 回调里同步查，不能 await。
final class DYReadiness {
    private static let lock = NSLock()
    private static var ready = Set<String>()

    static func mark(_ id: String) {
        lock.lock(); ready.insert(id); lock.unlock()
    }

    static func clear(_ id: String) {
        lock.lock(); ready.remove(id); lock.unlock()
    }

    static func isReady(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ready.contains(id)
    }

    static func reset() {
        lock.lock(); ready.removeAll(); lock.unlock()
    }
}
