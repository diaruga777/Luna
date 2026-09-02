//
//  PluginExportsBridgeTests.swift
//  LunaTests
//

import Foundation
import LunaModels
import LunaPluginExport
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage
import XCTest

/// `luna.exports`' read-state surface (§6.16) as a plugin reaches it, and the
/// store transitions the shipped queue makes underneath.
final class PluginExportsBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var containerURL: URL!
    private var store: SavesStore!

    private let pluginID = "test.plugin.exports"
    private let destinationID = "test.plugin.exports"

    private var source: String {
        """
        /* luna-plugin
        {
          "id": "\(pluginID)",
          "name": "Exports",
          "version": "1.0.0",
          "api": 1,
          "capabilities": ["exports"]
        }
        */
        luna.register({
            async onAction(input) {
                const key = input && input.key;
                if (key === "pendingDeletes") {
                    return { rows: await luna.exports.pendingDeletes() };
                }
                if (key === "readOnDevice") {
                    await luna.exports.markReadOnDevice(input.saveId);
                    return {};
                }
                if (key === "remoteDeleted") {
                    await luna.exports.markRemoteDeleted(input.saveId);
                    return {};
                }
                return {};
            },
        });
        """
    }

    private struct Action: Encodable { let key: String; let saveId: String? }
    private struct Answer: Decodable {
        struct Row: Decodable { let saveId: String; let title: String; let remoteName: String }
        let rows: [Row]?
    }

    private func boot(processKind: PluginProcessKind = .app) throws {
        runner = PluginJSFixtureRunner(processKind: processKind)
        containerURL = runner.containerURL
        store = SavesStore(containerURL: containerURL)
        runner.capabilities.register(
            PluginExportsBridge(
                processKind: processKind, scheduler: runner.runtime,
                queue: CoordinatorPluginExportQueue(store: store)))
        try runner.load(source)
    }

    override func tearDown() {
        runner?.cleanUp()
        // XCTest keeps every test-case instance alive for the whole run, so a
        // fixture left in a property outlives its test. The runner owns a
        // JSVirtualMachine and the store a SQLite connection.
        runner = nil
        store = nil
        containerURL = nil
        super.tearDown()
    }

    private func call(
        _ key: String, saveID: String? = nil
    ) async -> Result<Answer?, PluginInvocationFailure> {
        await runner.runtime.invoke(
            .onAction, pluginID: pluginID, argument: Action(key: key, saveId: saveID),
            timeout: 5, decode: Answer?.self)
    }

    @discardableResult
    private func deliveredSave(remoteName: String = "Book.epub") -> UUID {
        let item = store.add(urlString: "https://example.com/\(UUID().uuidString)")
        store.recordRemoteDelivery(
            for: item.id, destination: destinationID, remoteName: remoteName)
        return item.id
    }

    // MARK: - pendingDeletes

    /// Only a delivery the user finished in Luna is stale, and only one whose
    /// remote name Luna recorded can be named in a delete op.
    func testPendingDeletesListsOnlyStaleDeliveriesWithARecordedName() async throws {
        try boot()
        let stale = deliveredSave(remoteName: "Finished.epub")
        store.markFinishedReading(stale)
        deliveredSave(remoteName: "StillReading.epub")     // delivered, not finished
        let unnamed = store.add(urlString: "https://example.com/no-name")
        store.markFinishedReading(unnamed.id)              // finished, never delivered

        let answer = try await call("pendingDeletes").get()
        let rows = try XCTUnwrap(XCTUnwrap(answer).rows)

        XCTAssertEqual(rows.map(\.remoteName), ["Finished.epub"])
        XCTAssertEqual(rows.first?.saveId, stale.uuidString)
    }

    func testMarkRemoteDeletedClosesOutThePendingDelete() async throws {
        try boot()
        let stale = deliveredSave(remoteName: "Finished.epub")
        store.markFinishedReading(stale)

        _ = try await call("remoteDeleted", saveID: stale.uuidString).get()

        XCTAssertEqual(store.item(withID: stale)?.remoteDeleteStatus(for: destinationID), .deleted)
        let answer = try await call("pendingDeletes").get()
        let rows = try XCTUnwrap(XCTUnwrap(answer).rows)
        XCTAssertTrue(rows.isEmpty, "a deleted remote copy is not offered again")
    }

    // MARK: - markReadOnDevice

    /// The parity that matters: a receiver's own read report must leave the
    /// save where `XteinkBLECentral.handleReadIDs` leaves it, because the two
    /// apps write the one store.
    func testMarkReadOnDeviceMatchesTheSwiftReadReportPath() async throws {
        try boot()
        let throughThePlugin = deliveredSave()
        let throughSwift = deliveredSave()

        _ = try await call("readOnDevice", saveID: throughThePlugin.uuidString).get()

        // What `handleReadIDs` does, in its order.
        store.markRemoteDeliveryReadOnDevice(for: throughSwift, destination: destinationID)
        store.markFinishedReading(throughSwift)

        let plugin = try XCTUnwrap(store.item(withID: throughThePlugin))
        let swift = try XCTUnwrap(store.item(withID: throughSwift))
        XCTAssertEqual(plugin.readState, swift.readState)
        XCTAssertEqual(plugin.readingProgress, swift.readingProgress)
        XCTAssertEqual(
            plugin.remoteDeleteStatus(for: destinationID),
            swift.remoteDeleteStatus(for: destinationID))
        XCTAssertEqual(plugin.pendingArchiveAt != nil, swift.pendingArchiveAt != nil)
    }

    /// A book the reader itself filed away must never also be queued for a
    /// remote delete — that is the whole reason the two store calls are
    /// ordered the way they are.
    func testAReadReportQueuesNoRemoteDelete() async throws {
        try boot()
        let id = deliveredSave()

        _ = try await call("readOnDevice", saveID: id.uuidString).get()

        XCTAssertEqual(
            store.item(withID: id)?.remoteDeleteStatus(for: destinationID), .readOnDevice)
        let answer = try await call("pendingDeletes").get()
        let rows = try XCTUnwrap(XCTUnwrap(answer).rows)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Refusals

    func testANonUUIDSaveIDIsRefusedRatherThanIgnored() async throws {
        try boot()
        guard case .failure(let failure) = await call("readOnDevice", saveID: "nope") else {
            return XCTFail("a bad save id must reject")
        }
        XCTAssertTrue("\(failure)".contains("bad-argument"), "\(failure)")
    }

    /// The whole namespace is the app's: an extension has no send queue to
    /// drive, and says so rather than answering wrongly.
    func testTheReadStateSurfaceIsRefusedOutsideTheApp() async throws {
        try boot(processKind: .share)
        let id = deliveredSave()
        for key in ["pendingDeletes", "readOnDevice", "remoteDeleted"] {
            guard case .failure(let failure) = await call(key, saveID: id.uuidString) else {
                return XCTFail("\(key) must reject outside the app")
            }
            XCTAssertTrue("\(failure)".contains("unavailable-here"), "\(key): \(failure)")
        }
    }
}
