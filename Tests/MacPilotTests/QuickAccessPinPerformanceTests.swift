import AppKit
import Combine
import Testing
@testable import MacPilot

@MainActor
struct QuickAccessPinPerformanceTests {
  @Test func repeatedPointerPositionsPublishOnlyEntryAndExit() {
    let state = QuickAccessPinWindowState(id: UUID(), text: "test", baseSize: CGSize(width: 100, height: 100))
    var publications = 0
    let observation = state.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }

    for _ in 0..<1_000 { state.updateMouseInside(false) }
    #expect(publications == 0)
    for _ in 0..<1_000 { state.updateMouseInside(true) }
    #expect(publications == 1)
    for _ in 0..<1_000 { state.updateMouseInside(false) }
    #expect(publications == 2)
  }

  private final class Target: QuickAccessPinMouseTracking {
    var positions: [CGPoint] = []
    func updateMousePassthrough(at point: CGPoint, now: Date) {
      positions.append(point)
    }
  }

  @Test func pinsShareMonitorsAndLastRemovalStopsBoth() {
    var installations = 0
    var removals = 0
    let monitor = QuickAccessPinMouseMonitor(install: { _ in
      installations += 1
      return [NSObject(), NSObject()]
    }, uninstall: { _ in removals += 1 })
    let first = Target()
    let second = Target()
    monitor.add(first)
    monitor.add(first)
    monitor.add(second)
    #expect(installations == 1)
    let point = CGPoint(x: 21, y: 34)
    monitor.dispatch(at: point, now: Date())
    #expect(first.positions == [point])
    #expect(second.positions == [point])

    monitor.remove(first)
    monitor.dispatch(at: point, now: Date())
    #expect(first.positions.count == 1)
    #expect(second.positions.count == 2)
    #expect(removals == 0)
    monitor.remove(second)
    #expect(removals == 2)
    monitor.remove(second)
    #expect(removals == 2)

    monitor.add(first)
    #expect(installations == 2)
    monitor.remove(first)
    #expect(removals == 4)
  }

  @Test func monitoringDoesNotRetainClosedTargets() {
    var removals = 0
    let monitor = QuickAccessPinMouseMonitor(install: { _ in [NSObject(), NSObject()] },
                                           uninstall: { _ in removals += 1 })
    var target: Target? = Target()
    weak var reference = target
    monitor.add(target!)
    target = nil
    #expect(reference == nil)
    monitor.dispatch(at: .zero, now: Date())
    #expect(removals == 2)
  }

  @Test func zoomGestureReusesItsHideTimerAndReleasesItWhenFinished() throws {
    let image = NSImage(size: NSSize(width: 100, height: 100))
    let state = QuickAccessPinWindowState(id: UUID(), url: nil, image: image, thumbnail: image,
                                        baseSize: image.size, maxSize: NSSize(width: 200, height: 200))
    state.updateZoomFactor(1.1)
    let timer = try #require(state.zoomInteractionTimer)
    for index in 0..<120 {
      state.updateZoomFactor(1.1 + Double(index) / 1_000)
      #expect(state.zoomInteractionTimer === timer)
    }
    #expect(state.isZoomInteractionLive)
    timer.fire()
    timer.invalidate()
    #expect(!state.isZoomInteractionLive)
    #expect(state.zoomInteractionTimer == nil)
  }

  @Test func unchangedScreenSizingDoesNotInvalidateThePin() {
    let size = CGSize(width: 100, height: 100)
    let state = QuickAccessPinWindowState(id: UUID(), text: "test", baseSize: size)
    var publications = 0
    let observation = state.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }
    for _ in 0..<100 { _ = state.updateSizing(baseSize: size, maxSize: size) }
    #expect(publications == 0)
    let wider = CGSize(width: 120, height: 100)
    _ = state.updateSizing(baseSize: wider, maxSize: wider)
    #expect(publications == 1)
    #expect(state.displaySize == wider)
  }

  @Test func zoomEasingTakesTheSameTimeAtSixtyAndOneHundredTwentyHertz() {
    var sixty: CGFloat = 1
    var oneTwenty: CGFloat = 1
    for _ in 0..<6 {
      sixty = QuickAccessPinZoomAnimation.nextFactor(current: sixty, target: 2, elapsed: 1.0 / 60)
    }
    for _ in 0..<12 {
      oneTwenty = QuickAccessPinZoomAnimation.nextFactor(current: oneTwenty, target: 2, elapsed: 1.0 / 120)
    }
    #expect(abs(sixty - oneTwenty) < 0.000_001)
    #expect(QuickAccessPinZoomAnimation.nextFactor(current: 1, target: 2, elapsed: 0) == 1)
  }
}
