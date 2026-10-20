import Foundation
import MacPilotRemoteProtocol
import Network
import Testing

@testable import MacPilot

@Suite("Remote Bonjour registration")
@MainActor
struct RemoteBonjourPublisherTests {
    @Test("a ready listener never claims discovery is available before registration succeeds")
    func listenerReadyIsNotDiscoveryReady() {
        let registration = FakeRegistration()
        let publisher = RemoteBonjourPublisher(registration: registration)
        let server = makeServer(publisher: publisher)
        defer { server.stop() }
        server.handleListenerState(.ready)
        #expect(server.status.isRunning)
        #expect(server.bonjourStatus == .registering)
        registration.replies[0](0, true)
        #expect(server.bonjourStatus == .available)
    }

    @Test("PolicyDenied reaches the server and guidance even while its listener is ready")
    func deniedAdvertisementIsVisible() {
        let registration = FakeRegistration()
        let publisher = RemoteBonjourPublisher(registration: registration)
        let server = makeServer(publisher: publisher)
        defer { server.stop() }
        var notices = 0
        var recoveries = 0
        server.onLocalNetworkPermissionDenied = { notices += 1 }
        server.onLocalNetworkAvailable = { recoveries += 1 }
        server.handleListenerState(.ready)
        registration.replies[0](-65570, false)
        #expect(server.status.isRunning)
        #expect(server.bonjourStatus == .permissionDenied)
        #expect(notices == 1)
        registration.replies[0](-65570, false)
        #expect(notices == 1)
        registration.replies[0](0, true)
        #expect(server.bonjourStatus == .available)
        #expect(recoveries == 1)
    }

    @Test("a policy denial records which console account owns the Local Network decision")
    func denialRecordsConsolePolicyOwner() {
        let registration = FakeRegistration()
        let publisher = RemoteBonjourPublisher(registration: registration)
        var logs: [String] = []
        let server = makeServer(publisher: publisher, log: { logs.append($0) })
        defer { server.stop() }
        server.handleListenerState(.ready)
        registration.replies[0](-65570, false)
        #expect(server.localNetworkConsoleUser == LocalNetworkSessionDiagnosis.consoleUserName())
        #expect(logs.contains {
            $0.hasPrefix("Local network policy consoleUser=")
                && $0.contains("processUser=")
                && $0.contains("consoleMismatch=")
        })
    }

    @Test("granting permission restores publication automatically without touching paired identities")
    func automaticRecoveryPreservesPairings() throws {
        let registration = FakeRegistration()
        let scheduler = FakeRetryScheduler()
        let publisher = RemoteBonjourPublisher(registration: registration, retryScheduler: scheduler)
        let store = makeStore()
        let macID = store.ensureDeviceIdentity()
        store.registerPairedDevice(clientID: "existing-phone", name: "iPhone", address: "192.0.2.5")
        let originalSettings = store.settings
        let server = makeServer(publisher: publisher, store: store)
        defer { server.stop() }
        var notices = 0
        server.onLocalNetworkPermissionDenied = { notices += 1 }
        server.handleListenerState(.ready)
        registration.replies[0](-65570, false)
        #expect(scheduler.delay == .seconds(3))
        let retry = try #require(scheduler.pending)
        retry()
        #expect(registration.replies.count == 2)
        #expect(server.bonjourStatus == .permissionDenied)
        registration.replies[1](0, true)
        #expect(server.bonjourStatus == .available)
        #expect(store.settings == originalSettings)
        #expect(store.deviceID == macID)
        #expect(notices == 1)
        #expect(scheduler.pending == nil)
        #expect(registration.replies.count == 2)
    }

    @Test("stopping cancels retry and rejects queued callbacks from an old registration")
    func stopRejectsLateCallbacks() throws {
        let registration = FakeRegistration()
        let scheduler = FakeRetryScheduler()
        let publisher = RemoteBonjourPublisher(registration: registration, retryScheduler: scheduler)
        publisher.start(name: "Mac", port: 43847, txtRecord: [:])
        registration.replies[0](-65570, false)
        let lateRetry = try #require(scheduler.pending)
        publisher.stop()
        registration.replies[0](0, true)
        lateRetry()
        #expect(scheduler.pending == nil)
        #expect(publisher.status == .stopped)
        #expect(registration.replies.count == 1)
    }

    @Test("a replacement registration cannot be overwritten by an old success")
    func replacementRejectsStaleSuccess() {
        let registration = FakeRegistration()
        let publisher = RemoteBonjourPublisher(registration: registration)
        defer { publisher.stop() }
        publisher.start(name: "Old Mac", port: 43847, txtRecord: [:])
        publisher.start(name: "New Mac", port: 43848, txtRecord: [:])
        registration.replies[1](-65570, false)
        registration.replies[0](0, true)
        #expect(publisher.status == .permissionDenied)
    }

    @Test("each later policy rejection recovers again without retaining an earlier success")
    func recurringPolicyFailuresKeepRecovering() throws {
        let registration = FakeRegistration()
        let scheduler = FakeRetryScheduler()
        let publisher = RemoteBonjourPublisher(registration: registration, retryScheduler: scheduler)
        defer { publisher.stop() }
        publisher.start(name: "Mac", port: 43847, txtRecord: [:])
        registration.replies[0](0, true)
        for attempt in 0..<3 {
            registration.replies[attempt](-65570, false)
            #expect(publisher.status == .permissionDenied)
            let retry = try #require(scheduler.pending)
            retry()
            registration.replies[attempt](0, true) // A late result from the replaced registration.
            #expect(publisher.status == .permissionDenied)
            registration.replies[attempt + 1](0, true)
            #expect(publisher.status == .available)
            #expect(scheduler.pending == nil)
        }
        #expect(registration.replies.count == 4)
    }

    @Test("NoAuth and a removed service never masquerade as granted local network access")
    func unrelatedFailuresStayDistinct() {
        let registration = FakeRegistration()
        let publisher = RemoteBonjourPublisher(registration: registration)
        defer { publisher.stop() }
        publisher.start(name: "Mac", port: 43847, txtRecord: [:])
        registration.replies[0](-65555, false)
        #expect(publisher.status == .failed(-65555))
        registration.replies[0](0, true)
        #expect(publisher.status == .available)
        registration.replies[0](0, false)
        #expect(publisher.status == .failed(0))
    }

    @Test("the DNS-SD TXT payload preserves the phone's discovery identity and capabilities")
    func publishedRecordKeepsWireContract() throws {
        let info = RemoteServiceInfo(deviceID: UUID(), name: "开发者的 Mac", version: "1.2.1",
                                     capabilities: [.lock, .remoteDesktop])
        let bytes = [UInt8](DNSRemoteBonjourRegistration.encodeTXTRecord(info.txtRecord()))
        var fields: [String: String] = [:]
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            let end = offset + 1 + length
            #expect(end <= bytes.count)
            let entry = String(decoding: bytes[(offset + 1)..<end], as: UTF8.self)
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            fields[String(pair[0])] = String(pair[1])
            offset = end
        }
        #expect(try #require(RemoteServiceInfo(txtRecord: fields)) == info)
    }

    private func makeStore() -> RemoteDeviceStore {
        RemoteDeviceStore(keychainService: "tests.bonjour.\(UUID().uuidString)",
                          secretStore: InMemorySecretStore(), persist: {}, log: { _ in })
    }

    private func makeServer(
        publisher: RemoteBonjourPublisher,
        store: RemoteDeviceStore? = nil,
        log: @escaping (String) -> Void = { _ in }
    ) -> RemoteControlServer {
        RemoteControlServer(
            deviceStore: store ?? makeStore(),
            screenControl: MacScreenControlService(
                credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }), log: { _ in }),
            bonjourPublisher: publisher, log: log)
    }

    private final class FakeRegistration: RemoteBonjourRegistering {
        var replies: [@MainActor (Int32, Bool) -> Void] = []
        func register(name: String, port: UInt16, txtRecord: [String: String],
                      reply: @escaping @MainActor (Int32, Bool) -> Void) { replies.append(reply) }
        func cancel() {}
    }

    private final class FakeRetryScheduler: RemoteBonjourRetryScheduling {
        var pending: (@MainActor () -> Void)?
        var delay: Duration?
        func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            pending = action
        }
        func cancel() { pending = nil }
    }
}
