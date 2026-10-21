import UIKit
import Network
import BackgroundTasks
import Darwin
import OSLog

// Feasibility fixture, deliberately independent of Luna identity and transports.
// It never forwards traffic, reads Apple pairing secrets, or dials a remote host.
@main @MainActor final class ProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var running = false
    private let status = UILabel()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "probe")
    private var taskID: String { Bundle.main.bundleIdentifier! + ".probe" }
    private var report: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.jsonl")
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.event("invocation", ["reason": "background", "invocationID": UUID().uuidString])
                self.schedule()
                let work = Task { @MainActor in
                    await self.run(reason: "background")
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
        event("registration", ["registered": registered])
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let run = UIButton(type: .system); run.setTitle("Run Checks", for: .normal)
        run.addAction(UIAction { [weak self] _ in Task { await self?.run(reason: "foreground") } }, for: .touchUpInside)
        let schedule = UIButton(type: .system); schedule.setTitle("Schedule Background Check", for: .normal)
        schedule.addAction(UIAction { [weak self] _ in self?.schedule() }, for: .touchUpInside)
        let export = UIButton(type: .system); export.setTitle("Export Results", for: .normal)
        export.addAction(UIAction { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            let share = UIActivityViewController(activityItems: [self.report], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = export
            controller.present(share, animated: true)
        }, for: .touchUpInside)
        status.text = "Ready"; status.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [status, run, schedule, export])
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 40)])
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = controller
        window.makeKeyAndVisible(); self.window = window
        // Explicit CLI probe launch only. Install never launches the fixture.
        if ProcessInfo.processInfo.arguments.contains("--probe") { Task { await self.run(reason: "foreground-cli") } }
        return true
    }
    private func event(_ stage: String, _ fields: [String: Any] = [:]) {
        var record = fields
        record["stage"] = stage; record["schemaVersion"] = 1
        record["time"] = ISO8601DateFormatter().string(from: Date())
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        record["os"] = UIDevice.current.systemVersion
        record["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        record["protectedDataAvailable"] = UIApplication.shared.isProtectedDataAvailable
        record["lifecycle"] = UIApplication.shared.applicationState.rawValue
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); data.append(10)
            // Small bounded fixture log. Production journaling remains a separate milestone.
            let old = (try? Data(contentsOf: report)) ?? Data()
            try ((old.count + data.count > 1_000_000 ? Data() : old) + data).write(to: report, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            logger.info("probe stage=\(stage, privacy: .public)")
        } catch { logger.error("Probe journal write failed: \(error.localizedDescription)") }
    }
    private func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = false; request.requiresExternalPower = false
        request.earliestBeginDate = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 1), matchingPolicy: .nextTime)
        do {
            try BGTaskScheduler.shared.submit(request)
            event("scheduled", ["nextRequestedDate": request.earliestBeginDate!.timeIntervalSince1970])
            status.text = "Background check requested"
        } catch {
            event("submissionFailed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            status.text = "Couldn’t schedule a check"
        }
    }
    private func run(reason: String) async {
        guard !running else { return }; running = true; defer { running = false }
        let invocation = UUID().uuidString
        event("started", ["invocationID": invocation, "reason": reason, "timeZone": TimeZone.current.identifier])
        status.text = "Checking…"
        let local = Self.localAddresses()
        let discovered = await OwnServiceDiscovery.addresses(local: local)
        event("discovery", ["invocationID": invocation, "ownServiceCount": discovered.count])
        // Fixed well-known service candidates are hypotheses, not advertised capabilities.
        // An optional port must come from a captured Apple service/tunnel on this phone.
        let args = ProcessInfo.processInfo.arguments
        var ports: [UInt16] = [62078, 58783]
        if let i = args.firstIndex(of: "--port"), args.indices.contains(i + 1), let port = UInt16(args[i + 1]), port > 0 { ports.append(port) }
        var endpoints = local.flatMap { address in ports.map { ProbeEndpoint(host: address.host, label: address.label, port: $0) } }
        endpoints += discovered
        for endpoint in endpoints.prefix(48) {
            if Task.isCancelled { break }
            let result = await TCPCheck.check(endpoint)
            event("tcpCheck", ["invocationID": invocation, "interface": endpoint.label,
                "port": endpoint.port, "result": result])
        }
        event(Task.isCancelled ? "expired" : "completed", ["invocationID": invocation,
            "installationVerified": false, "appleAuthenticationVerified": false])
        status.text = Task.isCancelled ? "Check interrupted" : "Checks saved"
    }
    private static func localAddresses() -> [ProbeAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }; defer { freeifaddrs(first) }
        var result: [ProbeAddress] = []
        var current = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(ProbeAddress(host: String(cString: host), label: String(cString: item.pointee.ifa_name)))
        }
        return Array(result.prefix(12))
    }
}

struct ProbeAddress { let host: String; let label: String }
struct ProbeEndpoint { let host: String; let label: String; let port: UInt16 }

// Discover dynamic pairing ports, but resolve/dial only addresses assigned to
// this iPhone. No TXT records, addresses or pairing identifiers enter the log.
@MainActor final class OwnServiceDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var found: [ProbeEndpoint] = []
    private var local: [ProbeAddress] = []
    static func addresses(local: [ProbeAddress]) async -> [ProbeEndpoint] {
        let discovery = OwnServiceDiscovery(); discovery.local = local
        discovery.browser.delegate = discovery
        discovery.browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        try? await Task.sleep(for: .seconds(5))
        discovery.browser.stop(); discovery.services.forEach { $0.stop() }
        return discovery.found
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 8 else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 3)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port) else { return }
        for data in sender.addresses ?? [] {
            let address: String? = data.withUnsafeBytes { bytes in
                guard let raw = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else { return nil }
                let value = raw.assumingMemoryBound(to: sockaddr.self)
                guard Int(value.pointee.sa_len) <= bytes.count else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(value, socklen_t(value.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            if let address, let own = local.first(where: { $0.host == address }) {
                found.append(ProbeEndpoint(host: own.host, label: own.label + "/bonjour", port: UInt16(sender.port)))
            }
        }
    }
}

// Exactly one completion on a serial queue, including timeout/cancellation.
// Opening TCP alone does not prove Apple handshake, forwarding or installation.
final class TCPCheck: @unchecked Sendable {
    private let queue = DispatchQueue(label: "InstallProbe.tcp")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String, Never>?
    private var cancelled = false
    init(_ endpoint: ProbeEndpoint) {
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
    }
    static func check(_ endpoint: ProbeEndpoint) async -> String {
        let check = TCPCheck(endpoint)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                check.queue.async {
                    check.continuation = continuation
                    if check.cancelled { check.finish("cancelled"); return }
                    check.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: check.finish("tcpConnected")
                        case .failed(let error): check.finish("failed:\(error)")
                        default: break
                        }
                    }
                    check.connection.start(queue: check.queue)
                    check.queue.asyncAfter(deadline: .now() + 2) { check.finish("timeout") }
                }
            }
        } onCancel: {
            check.queue.async { check.cancelled = true; check.finish("cancelled") }
        }
    }
    private func finish(_ result: String) {
        guard let continuation else { return }
        self.continuation = nil; connection.stateUpdateHandler = nil; connection.cancel()
        continuation.resume(returning: result)
    }
}
