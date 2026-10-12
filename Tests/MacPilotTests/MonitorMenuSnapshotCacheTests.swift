import Foundation
import Testing
@testable import MacPilot

@MainActor
struct MonitorMenuSnapshotCacheTests {
    @Test func hiddenReadsAfterExpiryReuseTheInitialWarmSnapshot() {
        var now: TimeInterval = 10
        var sampleCount = 0
        let cache = MonitorMenuSnapshotCache<Int>(
            clock: { now },
            sample: {
                sampleCount += 1
                return sampleCount
            }
        )

        #expect(cache.snapshot(maxAge: 2, allowsRefresh: false) == 1)
        for _ in 0..<100 {
            now += 3
            #expect(cache.snapshot(maxAge: 2, allowsRefresh: false) == 1)
        }
        #expect(sampleCount == 1)
    }

    @Test func activeReadsRefreshAtExpiryUsingTheInjectedClock() {
        var monotonicTime: TimeInterval = 20
        var sampleCount = 0
        let cache = MonitorMenuSnapshotCache<Int>(
            clock: { monotonicTime },
            sample: {
                sampleCount += 1
                return sampleCount
            }
        )

        #expect(cache.snapshot(maxAge: 2, allowsRefresh: true) == 1)
        monotonicTime = 21.9
        #expect(cache.snapshot(maxAge: 2, allowsRefresh: true) == 1)
        #expect(sampleCount == 1)

        monotonicTime = 22
        #expect(cache.snapshot(maxAge: 2, allowsRefresh: true) == 2)
        #expect(sampleCount == 2)
    }

    @Test func anExpiredHiddenReadWaitsForTheNextActiveReadToRefresh() {
        var now: TimeInterval = 30
        var sampleCount = 0
        let cache = MonitorMenuSnapshotCache<Int>(
            clock: { now },
            sample: {
                sampleCount += 1
                return sampleCount
            }
        )

        #expect(cache.snapshot(maxAge: 2, allowsRefresh: true) == 1)
        now = 33
        #expect(cache.snapshot(maxAge: 2, allowsRefresh: false) == 1)
        #expect(sampleCount == 1)

        now = 36
        #expect(cache.snapshot(maxAge: 2, allowsRefresh: true) == 2)
        #expect(sampleCount == 2)
    }

    @Test func clearingTheCacheMakesTheNextHiddenReadWarmItAgain() {
        var sampleCount = 0
        let cache = MonitorMenuSnapshotCache<Int>(
            clock: { 40 },
            sample: {
                sampleCount += 1
                return sampleCount
            }
        )

        #expect(cache.snapshot(allowsRefresh: false) == 1)
        cache.clear()
        #expect(cache.snapshot(allowsRefresh: false) == 2)
        #expect(sampleCount == 2)
    }
}
