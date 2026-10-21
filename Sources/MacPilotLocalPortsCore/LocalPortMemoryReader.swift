import Darwin
import Foundation

/// 进程物理内存占用，口径与活动监视器「内存」列一致（phys footprint）。
/// 读取不到（例如其他用户的进程）时返回 nil，由界面省略这一项。
public enum LocalPortMemoryReader {
    public static func footprint(of pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        let byteCount = MemoryLayout<rusage_info_current>.stride
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<rusage_info_current>.alignment
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let slot = buffer.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, slot) == 0 else { return nil }
        let footprint = buffer.assumingMemoryBound(to: rusage_info_v3.self).pointee.ri_phys_footprint
        return footprint > 0 ? footprint : nil
    }
}
