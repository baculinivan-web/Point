import Darwin
import Foundation

// libSystem exports this wrapper, but the macOS SDK does not expose its
// declaration. Activity Monitor and Chromium use the same resource-coalition
// accounting to include XPC services whose parent is launchd.
@_silgen_name("coalition_info_resource_usage")
private func coalitionInfoResourceUsage(
    _ coalitionID: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int32

public enum BrowserMemoryReader {
    private static let procPIDCoalitionInfo: Int32 = 20
    private static let coalitionInfoWordCount = 5
    private static let resourceCoalitionIndex = 0
    private static let resourceUsageWordCount = 45
    private static let physicalFootprintIndex = 40

    public static func currentBrowserResidentBytes() -> UInt64 {
        if let bytes = resourceCoalitionPhysicalFootprint(), bytes > 0 {
            return bytes
        }
        return residentBytes(for: getpid())
    }

    private static func resourceCoalitionPhysicalFootprint() -> UInt64? {
        var coalitionInfo = [UInt64](
            repeating: 0,
            count: coalitionInfoWordCount
        )
        let copiedSize = coalitionInfo.withUnsafeMutableBytes { bytes in
            proc_pidinfo(
                getpid(),
                procPIDCoalitionInfo,
                0,
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard copiedSize == coalitionInfo.count * MemoryLayout<UInt64>.stride else {
            return nil
        }

        let coalitionID = coalitionInfo[resourceCoalitionIndex]
        guard coalitionID != 0 else { return nil }

        var usage = [UInt64](repeating: 0, count: resourceUsageWordCount)
        let result = usage.withUnsafeMutableBytes { bytes in
            coalitionInfoResourceUsage(
                coalitionID,
                bytes.baseAddress,
                bytes.count
            )
        }
        guard result == 0 else { return nil }
        return usage[physicalFootprintIndex]
    }

    private static func residentBytes(for pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let copiedSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard copiedSize == expectedSize else { return 0 }
        return info.pti_resident_size
    }
}
