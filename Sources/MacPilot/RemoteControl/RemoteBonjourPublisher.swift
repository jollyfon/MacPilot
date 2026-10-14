import dnssd
import Foundation
import MacPilotRemoteProtocol

/// Port readiness does not imply Bonjour registration succeeded. In particular,
/// NWListener can remain ready while its internal advertiser reports PolicyDenied.
enum RemoteBonjourStatus: Equatable {
    case stopped
    case registering
    case available
    case permissionDenied
    case failed(Int32)
}

@MainActor
protocol RemoteBonjourRegistering: AnyObject {
    func register(name: String, port: UInt16, txtRecord: [String: String],
                  reply: @escaping @MainActor (Int32, Bool) -> Void)
    func cancel()
}

@MainActor
protocol RemoteBonjourRetryScheduling: AnyObject {
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
private final class RemoteBonjourRetryScheduler: RemoteBonjourRetryScheduling {
    private var task: Task<Void, Never>?
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

@MainActor
final class RemoteBonjourPublisher {
    private(set) var status: RemoteBonjourStatus = .stopped
    var onStatusChanged: (@MainActor (RemoteBonjourStatus) -> Void)?
    private let registration: any RemoteBonjourRegistering
    private let retryDelay: Duration
    private let retryScheduler: any RemoteBonjourRetryScheduling
    private var generation = 0
    private var service: (name: String, port: UInt16, txtRecord: [String: String])?

    init(registration: any RemoteBonjourRegistering = DNSRemoteBonjourRegistration(),
         retryScheduler: (any RemoteBonjourRetryScheduling)? = nil,
         retryDelay: Duration = .seconds(3)) {
        self.registration = registration
        self.retryDelay = retryDelay
        self.retryScheduler = retryScheduler ?? RemoteBonjourRetryScheduler()
    }

    func start(name: String, port: UInt16, txtRecord: [String: String]) {
        stop()
        service = (name, port, txtRecord)
        update(.registering)
        register()
    }

    func stop() {
        generation += 1
        retryScheduler.cancel()
        registration.cancel()
        service = nil
        update(.stopped)
    }

    private func register() {
        guard let service else { return }
        generation += 1
        let currentGeneration = generation
        registration.cancel()
        registration.register(name: service.name, port: service.port, txtRecord: service.txtRecord) {
            [weak self] error, added in
            guard let self, self.generation == currentGeneration, self.service != nil else { return }
            if error == 0, added {
                self.retryScheduler.cancel()
                self.update(.available)
            } else {
                self.update(error == -65570 ? .permissionDenied : .failed(error))
                self.scheduleRetry(generation: currentGeneration)
            }
        }
    }

    private func scheduleRetry(generation: Int) {
        retryScheduler.schedule(after: retryDelay) { [weak self] in
            guard let self, self.generation == generation, self.service != nil else { return }
            self.register()
        }
    }

    private func update(_ value: RemoteBonjourStatus) {
        guard status != value else { return }
        status = value
        onStatusChanged?(value)
    }
}

/// DNS-SD exposes both synchronous and asynchronous registration errors, and
/// confirms the published name with its Add callback. Keep AWDL enabled just as
/// with the original NWListener advertiser.
@MainActor
final class DNSRemoteBonjourRegistration: RemoteBonjourRegistering {
    private var handle: DNSRegistrationHandle?

    func register(name: String, port: UInt16, txtRecord: [String: String],
                  reply: @escaping @MainActor (Int32, Bool) -> Void) {
        cancel()
        let context = DNSRegistrationReply(reply: reply)
        let record = Self.encodeTXTRecord(txtRecord)
        var reference: DNSServiceRef?
        let error = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &reference, DNSServiceFlags(kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL), 0,
                name, RemoteProtocolVersion.bonjourServiceType, "local.", nil, port.bigEndian,
                UInt16(record.count), bytes.baseAddress,
                { _, flags, error, _, _, _, rawContext in
                    guard let rawContext else { return }
                    let context = Unmanaged<DNSRegistrationReply>.fromOpaque(rawContext).takeUnretainedValue()
                    // DNSServiceSetDispatchQueue below guarantees the main queue.
                    MainActor.assumeIsolated {
                        context.reply(error, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0)
                    }
                },
                Unmanaged.passUnretained(context).toOpaque()
            )
        }
        guard error == 0, let reference else {
            if let reference { DNSServiceRefDeallocate(reference) }
            reply(error == 0 ? Int32(kDNSServiceErr_Unknown) : error, false)
            return
        }
        let queueError = DNSServiceSetDispatchQueue(reference, .main)
        guard queueError == 0 else {
            DNSServiceRefDeallocate(reference)
            reply(queueError, false)
            return
        }
        handle = DNSRegistrationHandle(reference: reference, context: context)
    }

    func cancel() {
        handle?.close()
        handle = nil
    }

    static func encodeTXTRecord(_ fields: [String: String]) -> Data {
        var result = Data()
        for key in fields.keys.sorted() {
            let entry = Data("\(key)=\(fields[key]!)".utf8)
            // TXT strings have a one-byte length; never emit a malformed record.
            guard entry.count <= 255 else { continue }
            result.append(UInt8(entry.count))
            result.append(entry)
        }
        return result
    }
}

@MainActor
private final class DNSRegistrationReply {
    let reply: @MainActor (Int32, Bool) -> Void
    init(reply: @escaping @MainActor (Int32, Bool) -> Void) { self.reply = reply }
}

/// Owns the C callback context until deallocation on the registration queue.
/// Destruction can occur off-actor; defer cleanup to the main queue in that case.
private final class DNSRegistrationHandle {
    private var reference: DNSServiceRef?
    private let context: DNSRegistrationReply

    init(reference: DNSServiceRef, context: DNSRegistrationReply) {
        self.reference = reference
        self.context = context
    }

    @MainActor func close() {
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
    }

    deinit {
        guard let reference else { return }
        let address = UInt(bitPattern: reference)
        let context = context
        DispatchQueue.main.async {
            if let reference = DNSServiceRef(bitPattern: address) { DNSServiceRefDeallocate(reference) }
            withExtendedLifetime(context) {}
        }
    }
}
