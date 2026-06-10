import Foundation

/// Converts mach absolute time deltas to nanoseconds.
enum MachClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(between earlier: UInt64, and later: UInt64) -> UInt64 {
        let delta = later > earlier ? later - earlier : 0
        return delta * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
