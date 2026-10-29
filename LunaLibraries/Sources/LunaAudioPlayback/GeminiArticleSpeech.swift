import AVFoundation
import CryptoKit
import Darwin
import Foundation
import LunaModels
import LunaAppConfig
import LunaStorage

public enum GeminiSpeechCredential {
    private static var service: String { AppConfig.appGroupID + ".gemini-speech" }
    public static var apiKey: String? {
        get { CredentialKeychain.read(service: service, account: "api-key") }
        set {
            let key = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            CredentialKeychain.write(key, service: service, account: "api-key")
        }
    }
}

enum GeminiSpeechError: LocalizedError, Equatable {
    case missingKey, quota, unauthorized, permissionDenied, paymentRequired, projectSetupRequired
    case requestRejected, modelUnavailable, unavailable, invalidAudio, incomplete, timedOut
    var errorDescription: String? {
        switch self {
        case .missingKey: return L10n.string("Gemini_missingKey")
        case .quota: return L10n.string("Gemini_quota")
        case .unauthorized: return L10n.string("Gemini_unauthorized")
        case .permissionDenied: return L10n.string("Gemini_permissionDenied")
        case .paymentRequired: return L10n.string("Gemini_paymentRequired")
        case .projectSetupRequired: return L10n.string("Gemini_projectSetupRequired")
        case .requestRejected: return L10n.string("Gemini_requestRejected")
        case .modelUnavailable, .unavailable: return L10n.string("Gemini_unavailable")
        case .invalidAudio: return L10n.string("Gemini_invalidAudio")
        case .incomplete: return L10n.string("Gemini_incomplete")
        case .timedOut: return L10n.string("Gemini_timedOut")
        }
    }
}

/// Sentence-aligned, disjoint requests preserve all text, including unspaced scripts.
/// Every chunk is cached independently so a quota failure never discards earlier work.
struct GeminiSpeechPlan {
    let voice: GeminiNarrationVoice
    let chunks: [String]
    let blockRanges: [Int: NSRange]
    let chunkRanges: [NSRange]
    let fingerprint: String

    init(script: AudioScript, voice: GeminiNarrationVoice = .kore) {
        self.voice = voice
        var text = ""
        var ranges: [Int: NSRange] = [:]
        var previousBlock: Int?
        for block in script.spokenBlocks {
            let body = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if let previousBlock {
                text += "\n\n"
                ranges[previousBlock]!.length += 2
            }
            let start = text.utf16.count
            text += body
            ranges[block.blockIndex] = NSRange(location: start, length: text.utf16.count - start)
            previousBlock = block.blockIndex
        }
        let source = text as NSString
        let sentences = script.spokenBlocks.flatMap { block -> [NSRange] in
            guard let range = ranges[block.blockIndex] else { return [] }
            return GeminiSpeechSentences.ranges(in: source.substring(with: range)).map {
                NSRange(location: range.location + $0.location, length: $0.length)
            }
        }
        self.chunkRanges = GeminiSpeechSentences.chunks(in: text, sentences: sentences)
        self.chunks = chunkRanges.map { source.substring(with: $0) }
        self.blockRanges = ranges
        // Include block boundaries, voice, model and cache schema, but never the API key.
        // A bounded single request has exactly the same text/range as v2, so
        // existing short readouts can still play without spending more quota.
        let unchangedSingleChunk = chunks.count == 1 && text.utf8.count <= 7_500 && AudioWordIndexing.wordCount(in: text) <= 1_200
        let schema = unchangedSingleChunk ? "v2-aac" : "v3-sentences-aac"
        let boundaries = unchangedSingleChunk ? "" : String(describing: chunkRanges)
        let identity = schema + "|gemini-3.8-flash-tts|" + voice.rawValue + "|" + String(describing: script.spokenBlocks.map { $0.blockIndex }) + boundaries + text
        self.fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reader, explicit Music readouts and Reader's nightly pre-generation share this cache.
/// Ingestion, extensions and autoplay misses never generate speech.
public actor GeminiArticleSpeech {
    public static let shared = GeminiArticleSpeech()
    static let models = ["gemini-3.8-flash-tts", "gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts"]
    private let availability = GeminiSpeechModelAvailability()
    private let directory: URL
    private let legacyDirectory: URL?
    typealias Stream = (URLRequest, @escaping (Data) throws -> Void) async throws -> URLResponse
    private let stream: Stream
    private var pending: [String: (id: UUID, task: Task<URL, Error>, live: GeminiSpeechSpool)] = [:]
    private let apiKey: () -> String?
    private var authorVoice: (String) async -> GeminiNarrationVoice = GeminiAuthorVoice.infer
    private let now: () -> Date
    private let requestTimeout: TimeInterval
    private let recognize: GeminiSpeechAlignment.Recognize

    public init(directory: URL? = nil) {
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeminiArticleSpeech", isDirectory: true)
        let shared = AppConfig.sharedContainerURL()?.appendingPathComponent("GeminiArticleSpeech", isDirectory: true) ?? local
        self.directory = directory ?? shared
        self.legacyDirectory = directory == nil && local != shared ? local : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        self.now = Date.init
        self.requestTimeout = 120
        self.recognize = GeminiSpeechAlignment.recognize
        self.stream = { request, receive in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw GeminiSpeechError.unavailable }
            if !(200..<300).contains(http.statusCode) {
                var body = Data()
                for try await byte in bytes {
                    guard body.count < 1_048_576 else { throw GeminiSpeechError.unavailable }
                    body.append(byte)
                }
                if http.statusCode == 429 {
                    throw GeminiSpeechQuotaFailure(retryAt: GeminiSpeechModelAvailability.retryDate(body: body, response: http))
                }
                throw Self.speechError(statusCode: http.statusCode, apiCode: Self.apiErrorCode(from: body))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
            if body?["stream"] as? Bool == true {
                guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                    throw GeminiSpeechError.incomplete
                }
                var events = GeminiSpeechEvents()
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    try events.line(line, receive: receive)
                }
                try events.finish(receive: receive)
            } else {
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 96 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
                    data.append(byte)
                }
                try receive(Self.unaryPCM(from: data))
            }
            return response
        }
        self.apiKey = { GeminiSpeechCredential.apiKey }
    }

    init(directory: URL, legacyDirectory: URL? = nil, requestTimeout: TimeInterval = 120, now: @escaping () -> Date = Date.init, apiKey: @escaping () -> String? = { "test-key" }, authorVoice: @escaping (String) async -> GeminiNarrationVoice = GeminiAuthorVoice.infer, send: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.authorVoice = authorVoice
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.now = now
        self.requestTimeout = requestTimeout
        self.recognize = GeminiSpeechAlignment.recognize
        self.stream = { request, receive in
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw GeminiSpeechError.unavailable }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.speechError(statusCode: http.statusCode, apiCode: Self.apiErrorCode(from: data))
            }
            try receive(Self.unaryPCM(from: data))
            return response
        }
        self.apiKey = apiKey
    }

    init(directory: URL, requestTimeout: TimeInterval = 120, now: @escaping () -> Date = Date.init, apiKey: @escaping () -> String? = { "test-key" }, recognize: @escaping GeminiSpeechAlignment.Recognize = GeminiSpeechAlignment.recognize, stream: @escaping Stream) {
        self.directory = directory; self.legacyDirectory = nil; self.requestTimeout = requestTimeout
        self.now = now; self.apiKey = apiKey; self.stream = stream; self.recognize = recognize
    }

    public func renderer(itemID: UUID, script: AudioScript, author: String? = nil, allowGeneration: Bool,
                         progress: @escaping (Double) -> Void = { _ in },
                         startBeforeCompletion: Bool = false) async throws -> SpeechRendering? {
        try await prepareRenderer(itemID: itemID, script: script, author: author, allowGeneration: allowGeneration,
                                  progress: progress, startBeforeCompletion: startBeforeCompletion)
    }

    /// Background work never joins/cancels a foreground playback operation.
    public func cacheForNightlyReadout(itemID: UUID, script: AudioScript, author: String? = nil, deadline: Date) async throws {
        guard !pending.keys.contains(where: { $0.hasPrefix(itemID.uuidString + "/") }) else { return }
        _ = try await prepareRenderer(itemID: itemID, script: script, author: author, allowGeneration: true,
                                      nightlyDeadline: deadline)
    }

    private func prepareRenderer(itemID: UUID, script: AudioScript, author: String? = nil, allowGeneration: Bool,
                                 progress: @escaping (Double) -> Void = { _ in },
                                 startBeforeCompletion: Bool = false,
                                 nightlyDeadline: Date? = nil) async throws -> SpeechRendering? {
        let now = self.now
        func checkWindow() throws {
            try Task.checkCancellation()
            if let deadline = nightlyDeadline {
                guard NightlyArticleAudioWindow.deadline(at: now()) == deadline, now() < deadline else {
                    throw CancellationError()
                }
            }
        }
        try checkWindow()
        let voice = try await narrationVoice(itemID: itemID, script: script, author: author, allowGeneration: allowGeneration, allowOnDeviceModel: nightlyDeadline == nil)
        try checkWindow()
        let plan = GeminiSpeechPlan(script: script, voice: voice)
        guard !plan.chunks.isEmpty else { throw GeminiSpeechError.incomplete }
        let key = itemID.uuidString + "/" + plan.fingerprint
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        if Self.isComplete(folder, count: plan.chunks.count) {
            DiagnosticLog.shared.record("cache hit item=\(itemID)", category: "gemini-tts")
            progress(1)
            return try cachedRenderer(folder: folder, plan: plan, progressive: startBeforeCompletion)
        }
        // Previously generated Reader-local audio is adopted before requiring a
        // key or network permission, including cache-only autoplay/restoration.
        if let legacy = legacyDirectory?.appendingPathComponent(key), Self.isComplete(legacy, count: plan.chunks.count) {
            let lock = try await Self.acquireCacheLock(directory)
            defer { Self.releaseCacheLock(lock) }
            try Self.migrateCache(from: legacy, to: folder, count: plan.chunks.count)
            DiagnosticLog.shared.record("migrated cache item=\(itemID)", category: "gemini-tts")
            progress(1)
            return try cachedRenderer(folder: folder, plan: plan, progressive: startBeforeCompletion)
        }
        guard allowGeneration else { return nil }
        if let operation = pending[key], !operation.task.isCancelled, operation.live.snapshot(0).error == nil {
            guard nightlyDeadline == nil else { return nil }
            operation.live.observeProgress(progress)
            if startBeforeCompletion {
                let renderer = GeminiProgressiveSpeechRenderer(folder: folder, plan: plan, live: operation.live, task: operation.task, recognize: self.recognize)
                try await withTaskCancellationHandler { try await renderer.ready() } onCancel: { operation.task.cancel() }
                return renderer
            }
            let folder = try await withTaskCancellationHandler {
                try await operation.task.value
            } onCancel: { operation.task.cancel() }
            progress(1)
            return try cachedRenderer(folder: folder, plan: plan, progressive: startBeforeCompletion)
        }
        let stream = self.stream
        let availability = self.availability
        let live = try GeminiSpeechSpool(count: plan.chunks.count)
        live.observeProgress(progress)
        let apiKey = self.apiKey
        let directory = self.directory
        let timeout = self.requestTimeout
        let recognize = self.recognize
        let task = Task<URL, Error> {
            do {
                // Actors only serialize within one app. This advisory lock also
                // excludes another Reader/Music process until its complete result
                // can be reused, and the OS releases it if the generating app dies.
                DiagnosticLog.shared.record("prepare item=\(itemID) chunks=\(plan.chunks.count)", category: "gemini-tts")
                let lock = try await Self.acquireCacheLock(directory, timeout: timeout)
                defer { Self.releaseCacheLock(lock) }
                try checkWindow()
                if Self.isComplete(folder, count: plan.chunks.count) { live.reportProgress(1); return folder }
                guard let apiKey = apiKey(), !apiKey.isEmpty else { throw GeminiSpeechError.missingKey }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                BackupPolicy.excludeFromBackups(folder)
                var preferredModelIndex = 0
                for (index, text) in plan.chunks.enumerated() {
                    try checkWindow()
                    let file = folder.appendingPathComponent("\(index).m4a")
                    if Self.isPlayable(file) {
                        live.reportProgress(Double(index + 1) / Double(plan.chunks.count))
                        continue
                    }
                    let partial = try GeminiSpeechPartial(folder: folder, chunk: index, text: text)
                    let prefix = try await partial.recover(text: text, recognize: recognize)
                    if !prefix.isEmpty { try live.append(prefix, chunk: index) }
                    live.prepare(index, boundaries: partial.boundaries)
                    let remainingText = (text as NSString).substring(from: partial.boundary.textEnd)
                    let initialBytes = live.snapshot(index).bytes
                    var succeeded = false
                    for modelIndex in preferredModelIndex..<Self.models.count {
                        let model = Self.models[modelIndex]
                        guard availability.available(model, credential: apiKey) else {
                            if nightlyDeadline != nil { throw GeminiSpeechError.quota }
                            continue
                        }
                        try checkWindow()
                        let remaining = nightlyDeadline.map { $0.timeIntervalSince(now()) } ?? timeout
                        let requestTimeout = min(timeout, remaining)
                        var request = try Self.request(text: remainingText, apiKey: apiKey, model: model, voice: plan.voice)
                        request.timeoutInterval = requestTimeout
                        DiagnosticLog.shared.record("request item=\(itemID) chunk=\(index + 1)/\(plan.chunks.count) model=\(model)", category: "gemini-tts")
                        let started = Date()
                        do {
                            _ = try await Self.streamWithinDeadline(request, timeout: requestTimeout, stream: stream) { delta in
                                try partial.append(delta)
                                try checkWindow()
                                try live.append(delta, chunk: index)
                                // The provider sends no alignment or final byte count. Estimate
                                // within a chunk from audio duration; only finalized chunks reach 100%.
                                let expectedBytes = max(48_000, Double(AudioWordIndexing.wordCount(in: text)) / 170 * 60 * 48_000)
                                let fraction = min(0.95, Double(live.snapshot(index).bytes) / expectedBytes)
                                live.reportProgress((Double(index) + fraction) / Double(plan.chunks.count))
                            }
                            succeeded = true
                            DiagnosticLog.shared.record("response item=\(itemID) chunk=\(index + 1) model=\(model) bytes=\(live.snapshot(index).bytes) seconds=\(Int(Date().timeIntervalSince(started)))", category: "gemini-tts")
                            break
                        } catch {
                            let retryAt: Date
                            if let quota = error as? GeminiSpeechQuotaFailure { retryAt = quota.retryAt }
                            else if let speech = error as? GeminiSpeechError, speech == .quota || speech == .modelUnavailable {
                                retryAt = Date().addingTimeInterval(speech == .quota ? 60 : 3600)
                            } else { throw error }
                            availability.suspend(model, credential: apiKey, until: retryAt)
                            if nightlyDeadline != nil { throw error }
                            // Restarting after emitting PCM could repeat words already heard.
                            guard live.snapshot(index).bytes == initialBytes else { throw GeminiSpeechError.quota }
                            preferredModelIndex = modelIndex + 1
                            DiagnosticLog.shared.record("fallback item=\(itemID) model=\(model)", category: "gemini-tts")
                        }
                    }
                    guard succeeded else { throw GeminiSpeechError.quota }
                    try checkWindow()
                    let audio = try Self.wav(fromPCM: live.data(index))
                    try Self.cacheAudio(audio, at: file, validatePublication: checkWindow)
                    guard Self.isPlayable(file) else {
                        try? FileManager.default.removeItem(at: file)
                        throw GeminiSpeechError.invalidAudio
                    }
                    partial.remove()
                    live.complete(index)
                    // Report completed work, not the chunk we're about to request.
                    live.reportProgress(Double(index + 1) / Double(plan.chunks.count))
                }
                live.reportProgress(1)
                DiagnosticLog.shared.record("ready item=\(itemID)", category: "gemini-tts")
                return folder
            } catch {
                live.fail(error)
                throw error
            }
        }
        let operationID = UUID()
        pending[key] = (operationID, task, live)
        Task { [weak self] in
            if case .failure(let error) = await task.result {
                DiagnosticLog.shared.record("generation failed item=\(itemID) error=\(String(describing: type(of: error))) code=\((error as NSError).code)", category: "gemini-tts")
            }
            await self?.finishOperation(key: key, id: operationID)
        }
        do {
            if startBeforeCompletion {
                let renderer = GeminiProgressiveSpeechRenderer(folder: folder, plan: plan, live: live, task: task, recognize: recognize)
                try await withTaskCancellationHandler { try await renderer.ready() } onCancel: { task.cancel() }
                return renderer
            }
            let completed = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            return try GeminiCachedSpeechRenderer(folder: completed, plan: plan)
        } catch {
            finishOperation(key: key, id: operationID)
            // Only error type/code; neither the credential nor server messages
            // (which can echo request data) enter diagnostics.
            DiagnosticLog.shared.record("failed item=\(itemID) error=\(String(describing: type(of: error))) code=\((error as NSError).code)", category: "gemini-tts")
            if (error as? URLError)?.code == .timedOut { throw GeminiSpeechError.timedOut }
            throw error
        }
    }

    /// Persist before any chunks are generated so retries, cache-only playback and
    /// the other app use the same voice even when Apple Intelligence is unavailable.
    private func narrationVoice(itemID: UUID, script: AudioScript, author: String?, allowGeneration: Bool, allowOnDeviceModel: Bool = true) async throws -> GeminiNarrationVoice {
        guard let author = GeminiAuthorVoice.normalizedAuthor(author) else { return .kore }
        let digest = SHA256.hash(data: Data(author.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        let itemFolder = directory.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let choice = itemFolder.appendingPathComponent("voice-v1-" + digest + ".json")
        func savedVoice() -> GeminiNarrationVoice? {
            guard let data = try? Data(contentsOf: choice) else { return nil }
            return try? JSONDecoder().decode(GeminiNarrationVoice.self, from: data)
        }
        if let voice = savedVoice() { return voice }
        guard allowGeneration, apiKey()?.isEmpty == false else { return .kore }
        let lock = try await Self.acquireCacheLock(directory, timeout: requestTimeout)
        defer { Self.releaseCacheLock(lock) }
        if let voice = savedVoice() { return voice }
        try Task.checkCancellation()
        let oldPlan = GeminiSpeechPlan(script: script)
        let oldKey = itemID.uuidString + "/" + oldPlan.fingerprint
        // Preserve completed pre-feature audio without spending quota to replace it.
        let alreadyGenerated = [directory, legacyDirectory].compactMap { $0 }.contains {
            Self.isComplete($0.appendingPathComponent(oldKey), count: oldPlan.chunks.count)
        }
        let voice: GeminiNarrationVoice
        if alreadyGenerated { voice = .kore }
        else if allowOnDeviceModel { voice = await authorVoice(author) }
        else { voice = GeminiAuthorVoice.lookup(author) ?? .kore }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(itemFolder)
        try JSONEncoder().encode(voice).write(to: choice, options: .atomic)
        return voice
    }

    private func cachedRenderer(folder: URL, plan: GeminiSpeechPlan, progressive: Bool) throws -> SpeechRendering {
        if progressive {
            return GeminiProgressiveSpeechRenderer(folder: folder, plan: plan,
                live: try GeminiSpeechSpool(count: plan.chunks.count), task: Task { folder }, recognize: recognize)
        }
        return try GeminiCachedSpeechRenderer(folder: folder, plan: plan)
    }

    private func finishOperation(key: String, id: UUID) {
        if pending[key]?.id == id { pending[key] = nil }
    }

    private static func streamWithinDeadline(_ request: URLRequest, timeout: TimeInterval, stream: @escaping Stream,
                                             receive: @escaping (Data) throws -> Void) async throws -> URLResponse {
        try await withThrowingTaskGroup(of: URLResponse.self) { group in
            group.addTask { try await stream(request, receive) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000))
                throw GeminiSpeechError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public func clearCache() async throws {
        for operation in pending.values { operation.task.cancel() }
        pending.removeAll()
        let lock = try await Self.acquireCacheLock(directory)
        defer { Self.releaseCacheLock(lock) }
        for folder in [directory, legacyDirectory].compactMap({ $0 }) where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Called on saves changes so deleting an article also removes its generated audio.
    public func removeAudio(except itemIDs: Set<UUID>) async throws {
        let names = Set(itemIDs.map { $0.uuidString })
        for key in Array(pending.keys) where !names.contains(String(key.prefix(36))) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        let lock = try await Self.acquireCacheLock(directory)
        defer { Self.releaseCacheLock(lock) }
        for root in [directory, legacyDirectory].compactMap({ $0 }) where FileManager.default.fileExists(atPath: root.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where !names.contains(folder.lastPathComponent) {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// TTL starts at each chunk's atomic publication, never at last playback.
    /// Legacy chunks use their original modification date; migration preserves it.
    public func pruneAudio(for items: [SavedItem], now: Date = Date()) async throws {
        let states = Dictionary(items.map { ($0.id.uuidString, $0.readState) }, uniquingKeysWith: { _, last in last })
        for key in Array(pending.keys) where states[String(key.prefix(36))] == nil {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        let lock = try await Self.acquireCacheLock(directory)
        defer { Self.releaseCacheLock(lock) }
        let fm = FileManager.default
        for root in [directory, legacyDirectory].compactMap({ $0 }) where fm.fileExists(atPath: root.path) {
            for itemFolder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                guard let state = states[itemFolder.lastPathComponent] else {
                    try fm.removeItem(at: itemFolder)
                    continue
                }
                let lifetime: TimeInterval = (state == .read ? 2 : 14) * 24 * 60 * 60
                guard let files = fm.enumerator(at: itemFolder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
                for case let file as URL in files where file.pathExtension == "m4a" || file.lastPathComponent.hasSuffix(".partial.pcm") {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values.isRegularFile == true else { continue }
                    if values.contentModificationDate.map({ now.timeIntervalSince($0) >= lifetime }) ?? true {
                        try fm.removeItem(at: file)
                        if file.lastPathComponent.hasSuffix(".partial.pcm") {
                            try? fm.removeItem(at: file.deletingPathExtension().appendingPathExtension("json"))
                        }
                    }
                }
                // Empty fingerprint/item directories carry no reusable state.
                if let folders = try? fm.contentsOfDirectory(at: itemFolder, includingPropertiesForKeys: nil) {
                    for folder in folders where (try? fm.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                        try? fm.removeItem(at: folder)
                    }
                }
                if (try? fm.contentsOfDirectory(atPath: itemFolder.path).isEmpty) == true { try? fm.removeItem(at: itemFolder) }
            }
        }
    }

    private static func migrateCache(from legacy: URL, to folder: URL, count: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(folder)
        for index in 0..<count {
            let destination = folder.appendingPathComponent("\(index).m4a")
            if isPlayable(destination) { continue }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            let source = legacy.appendingPathComponent("\(index).m4a")
            try FileManager.default.copyItem(at: source, to: destination)
            if let date = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
            }
        }
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
    }

    private static func acquireCacheLock(_ directory: URL, timeout: TimeInterval = 120) async throws -> Int32 {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Outside the cache itself so clearing it never unlinks a held lock.
        let path = parent.appendingPathComponent(".\(directory.lastPathComponent).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw GeminiSpeechError.unavailable }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                if ProcessInfo.processInfo.systemUptime - started >= timeout { throw GeminiSpeechError.timedOut }
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw GeminiSpeechError.unavailable }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func releaseCacheLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func request(text: String, apiKey: String, model: String = models[0], voice: GeminiNarrationVoice = .kore) throws -> URLRequest {
        if model == models[2] {
            // Gemini 2.5 does not stream. Use its documented GenerateContent
            // API rather than assuming legacy models support Interactions.
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [["role": "user", "parts": [["text": "Read aloud the following transcript verbatim. Do not add commentary.\n\nTranscript:\n" + text]]]],
                "generationConfig": ["responseModalities": ["AUDIO"], "maxOutputTokens": 16_384,
                    "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice.rawValue]]]],
            ])
            return request
        }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Older TTS models need an explicit synthesis preamble. 3.8 accepts
        // verbatim transcript text, with no directions that might be spoken.
        let transcript = model == models[0] ? text : "Read aloud the following transcript verbatim. Do not add commentary.\n\nTranscript:\n" + text
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "store": false,
            "input": [["type": "user_input", "content": [["type": "text", "text": transcript]]]],
            "stream": true,
            "response_format": ["type": "audio", "mime_type": "audio/l16", "sample_rate": 24_000],
            "generation_config": ["max_output_tokens": 16_384, "speech_config": [["voice": voice.rawValue]]],
        ])
        return request
    }

    /// Google returns structured error bodies for non-2xx Interactions API
    /// responses. Keep the machine code for diagnostics, but never log or show
    /// the server message because it may contain request details.
    static func apiErrorCode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        if let code = error["code"] as? String { return code }
        if let status = error["status"] as? String { return status.lowercased() }
        guard let value = error["code"] else { return nil }
        if let code = value as? NSNumber { return code.stringValue }
        return nil
    }

    static func speechError(statusCode: Int, apiCode: String?) -> GeminiSpeechError {
        if let code = apiCode?.lowercased() {
            if code.contains("resource_exhausted") || code.contains("quota") { return .quota }
            if code == "not_found" { return .modelUnavailable }
        }
        switch statusCode {
        case 400: return apiCode == "failed_precondition" ? .projectSetupRequired : .requestRejected
        case 401: return .unauthorized
        case 402: return .paymentRequired
        case 403: return .permissionDenied
        case 404: return .modelUnavailable
        case 408: return .timedOut
        case 429: return .quota
        default: return .unavailable
        }
    }

    static func audio(from data: Data) throws -> Data {
        struct Response: Decodable {
            struct APIError: Decodable { let code: String? }
            struct Step: Decodable {
                struct Content: Decodable { let type: String; let data: String?; let mime_type: String? }
                let type: String
                let content: [Content]?
            }
            let status: String
            let steps: [Step]?
            let errors: [APIError]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GeminiSpeechError.incomplete
        }
        guard response.status == "completed" else {
            let code = response.errors?.compactMap(\.code).joined(separator: ",") ?? "none"
            DiagnosticLog.shared.record("interaction ended status=\(response.status) code=\(code)", category: "gemini-tts")
            throw GeminiSpeechError.incomplete
        }
        let parts = (response.steps ?? []).filter { $0.type == "model_output" }.flatMap { $0.content ?? [] }.filter { $0.type == "audio" }
        // Unary TTS returns one complete WAV. Reject unexpected multipart output rather than truncating it.
        guard parts.count == 1, parts[0].mime_type == "audio/wav", let encoded = parts[0].data,
              let audio = Data(base64Encoded: encoded), audio.count > 44,
              String(data: audio.prefix(4), encoding: .ascii) == "RIFF",
              String(data: audio[8..<12], encoding: .ascii) == "WAVE"
        else { throw GeminiSpeechError.invalidAudio }
        return audio
    }

    private static func unaryPCM(from data: Data) throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GeminiSpeechError.incomplete }
        if root["candidates"] == nil { return try pcm(fromWAV: audio(from: data)) }
        guard let candidates = root["candidates"] as? [[String: Any]], candidates.count == 1,
              candidates[0]["finishReason"] as? String == "STOP",
              let content = candidates[0]["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]], parts.count == 1,
              let inline = parts[0]["inlineData"] as? [String: Any],
              let mime = (inline["mimeType"] as? String)?.lowercased(),
              let encoded = inline["data"] as? String, let audio = Data(base64Encoded: encoded), !audio.isEmpty else {
            throw GeminiSpeechError.incomplete
        }
        if mime == "audio/wav" { return try pcm(fromWAV: audio) }
        guard mime == "audio/l16;codec=pcm;rate=24000" || mime == "audio/l16",
              audio.count.isMultiple(of: 2), audio.count <= 64 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
        return audio
    }

    static func pcm(fromWAV data: Data) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try pcm(fromAudioAt: url)
    }

    static func pcm(fromAudioAt url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.processingFormat.sampleRate == 24_000, file.processingFormat.channelCount == 1, file.length > 0,
              file.length <= 32 * 1_024 * 1_024,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw GeminiSpeechError.invalidAudio
        }
        try file.read(into: buffer)
        guard let samples = buffer.int16ChannelData?[0] else { throw GeminiSpeechError.invalidAudio }
        return Data(bytes: samples, count: Int(buffer.frameLength) * 2)
    }

    static func wav(fromPCM data: Data) throws -> Data {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 64 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
        append(UInt32(data.count + 36)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(data.count)); wav.append(data)
        return wav
    }

    /// AAC keeps a library of readouts small. Publish only a finalized container;
    /// temporary response/audio files are removed on both success and failure.
    private static func cacheAudio(_ data: Data, at destination: URL, validatePublication: () throws -> Void = {}) throws {
        let folder = destination.deletingLastPathComponent()
        let source = folder.appendingPathComponent(UUID().uuidString + ".wav")
        let staging = folder.appendingPathComponent(UUID().uuidString + ".m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        try data.write(to: source, options: .atomic)
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
        else { throw GeminiSpeechError.invalidAudio }
        var output: AVAudioFile? = try AVAudioFile(forWriting: staging, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ])
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw GeminiSpeechError.invalidAudio }
            try output?.write(from: buffer)
        }
        output = nil
        try Task.checkCancellation()
        try validatePublication()
        // The destination may contain a corrupt old entry; replacement is local
        // and there is only one generation operation for this article identity.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    private static func isComplete(_ folder: URL, count: Int) -> Bool {
        (0..<count).allSatisfy { isPlayable(folder.appendingPathComponent("\($0).m4a")) }
    }
    static func isPlayable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.processingFormat.sampleRate > 0
    }
}

/// Google supplies no alignment timestamps. Paragraph seeking uses proportional
/// text offsets; forward playback includes every frame exactly once. Never invent
/// word events that would imply accurate RSVP synchronization.
final class GeminiCachedSpeechRenderer: SpeechRendering {
    let canonicalFormat: AVAudioFormat? = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)
    private let folder: URL
    private let plan: GeminiSpeechPlan
    init(folder: URL, plan: GeminiSpeechPlan) throws {
        self.folder = folder
        self.plan = plan
    }
    func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment {
        guard let range = plan.blockRanges[block.blockIndex], let target = canonicalFormat else { throw GeminiSpeechError.invalidAudio }
        var buffers: [AVAudioPCMBuffer] = []
        for (index, chunkRange) in plan.chunkRanges.enumerated() {
            let intersection = NSIntersectionRange(range, chunkRange)
            guard intersection.length > 0 else { continue }
            let file = try AVAudioFile(forReading: folder.appendingPathComponent("\(index).m4a"))
            let start = AVAudioFramePosition(Double(intersection.location - chunkRange.location) / Double(chunkRange.length) * Double(file.length))
            let end = AVAudioFramePosition(Double(NSMaxRange(intersection) - chunkRange.location) / Double(chunkRange.length) * Double(file.length))
            file.framePosition = start
            var remaining = end - start
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(remaining, 48_000))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw GeminiSpeechError.invalidAudio }
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw GeminiSpeechError.invalidAudio }
                remaining -= AVAudioFramePosition(buffer.frameLength)
                buffers += try AudioFormatConversion.convert([buffer], from: file.processingFormat, to: target)
            }
        }
        let duration = buffers.reduce(0) { $0 + Double($1.frameLength) / target.sampleRate }
        return RenderedSegment(blockIndex: block.blockIndex, buffers: buffers, wordMarkers: [], duration: duration, format: target)
    }
}
