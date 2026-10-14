import CoreBluetooth
import Foundation

@MainActor
final class BLEMonitoredDeviceRuntime {
    let uuid: UUID
    var peripheral: CBPeripheral?
    var presence = false
    var lastRSSI: Int?
    var activeMode = false
    var latestRSSIs: [Double] = []
    var rssiReadGate = BLERequestGate()
    var connectionRetryGate = BLEConnectionRetryGate()
    var proximityTimer: BackgroundTask?
    var signalTimer: BackgroundTask?
    var signalTimerGeneration: UInt64 = 0
    var activeModeTimer: BackgroundTask?
    var connectionTimer: BackgroundTask?
    var rssiRequestTimeoutTimer: BackgroundTask?

    init(uuid: UUID) {
        self.uuid = uuid
    }

    func invalidateTimers() {
        proximityTimer?.stop()
        proximityTimer = nil
        signalTimer?.stop()
        signalTimer = nil
        signalTimerGeneration &+= 1
        activeModeTimer?.stop()
        activeModeTimer = nil
        connectionTimer?.stop()
        connectionTimer = nil
        rssiRequestTimeoutTimer?.stop()
        rssiRequestTimeoutTimer = nil
        rssiReadGate.reset()
        connectionRetryGate.reset()
        activeMode = false
    }
}

