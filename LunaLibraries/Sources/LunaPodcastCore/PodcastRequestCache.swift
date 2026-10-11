import Foundation

/// Small, transient cache shared by navigation and speculative requests. A cancelled
/// screen never cancels a request another screen is awaiting; failures are not cached.
public actor PodcastRequestCache<Value: Sendable> {
    private struct Entry { var value: Value; var date: Date }
    private var entries: [String: Entry] = [:]
    private var requests: [String: Task<Value, Error>] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int
    public init(lifetime: TimeInterval = 300, capacity: Int = 24) {
        self.lifetime = lifetime; self.capacity = capacity
    }
    public func value(for key: String, force: Bool = false, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if !force, let entry = entries[key], Date().timeIntervalSince(entry.date) < lifetime { return entry.value }
        if let request = requests[key] { return try await request.value }
        let request = Task { try await load() }
        requests[key] = request
        defer { requests[key] = nil }
        let value = try await request.value
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key { entries[oldest] = nil }
        entries[key] = Entry(value: value, date: Date())
        return value
    }
}

/// Bounds even a slowly trickling response, not just time between received bytes.
public enum PodcastNetwork {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
