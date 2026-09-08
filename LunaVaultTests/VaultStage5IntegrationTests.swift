import Foundation
import UIKit
import XCTest
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultSync
import LunaVaultUI
import VaultTestKit

/// Cross-tier checks for the production seams introduced by Stage 5. The
/// lower-level media tests remain focused on protected storage and transport;
/// these tests prove that the UIKit surface actually reaches those services.
final class VaultStage5IntegrationTests: XCTestCase {
    private struct TestProtection: VaultFileProtectionApplying {
        func apply(to url: URL) throws {}
        func hasRequiredProtection(at url: URL) throws -> Bool { true }
    }

    @MainActor
    func testImportButtonReachesProtectedImportCoordinator() throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-import-seam")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let source = directory.url.appendingPathComponent("note.txt")
        try Data("private import".utf8).write(to: source)
        let coordinator = try VaultImportCoordinator(
            repository: repository, protectionApplier: protection)
        var imported: VaultImportResult?
        let root = VaultRootViewController(importHandler: {
            imported = try? coordinator.importFile(VaultImportSource(
                fileURL: source, contentType: "text/plain"))
        })
        root.loadViewIfNeeded()
        root.triggerImportForTesting()
        let result = try XCTUnwrap(imported)
        XCTAssertEqual(try repository.readContent(for: result.objectID), Data("private import".utf8))
        XCTAssertTrue(try repository.jobs().contains { $0.kind == .index && $0.objectID == result.objectID })
    }

    @MainActor
    func testRecentAndSearchResultReachVerifiedPreviewPlan() async throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-preview-seam")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let bytes = Data("private searchable text".utf8)
        try repository.upsert(VaultObjectRecord(
            id: objectID, revision: revision, logicalTime: 1, size: Int64(bytes.count),
            contentType: "text/plain", createdAt: now, updatedAt: now, accessedAt: now,
            deviceID: "test"))
        _ = try repository.writeContent(bytes, for: objectID)
        let index = try VaultSearchIndex(databaseURL: directory.url.appendingPathComponent("index.sqlite"))
        try index.upsert(VaultIndexedDocument(
            id: objectID, revision: revision, logicalTime: 1, deviceID: "test",
            filename: "note.txt", bodyText: "private searchable text",
            createdAt: now, updatedAt: now, accessedAt: now))
        let router = VaultPreviewRouter(repository: repository, protectionApplier: protection)
        let plans = LockedPlanResults()
        let root = VaultRootViewController(
            services: VaultRuntimeServices(
                policy: VaultStoragePolicy(location: .device), repository: repository,
                deviceBackend: VaultDeviceBackend(store: repository), remoteBackend: nil,
                syncCoordinator: nil),
            searchIndex: index,
            openHandler: { id in
                Task {
                    if let plan = try? await router.plan(objectID: id) {
                        plans.append(plan)
                    }
                }
            })
        root.loadViewIfNeeded()

        // Recents and groups load off the main thread; poll for the row
        // instead of reading the hierarchy synchronously after loadView.
        let recent = try await waitForView(
            in: root.view, identifier: "vault.recent.\(objectID.rawValue.uuidString)", as: UIButton.self)
        recent.sendActions(for: .touchUpInside)
        try await waitForPlans(plans, count: 1)

        let search = try XCTUnwrap(root.view.viewWithAccessibilityIdentifier(
            VaultAccessibilityID.search) as? UITextField)
        search.text = "searchable"
        search.sendActions(for: .editingChanged)
        let result = try await waitForView(
            in: root.view, identifier: "vault.result.open.\(objectID.rawValue.uuidString)", as: UIButton.self)
        result.sendActions(for: .touchUpInside)
        try await waitForPlans(plans, count: 2)

        XCTAssertEqual(plans.values.map(\.availability), [.ready, .ready])
        XCTAssertTrue(plans.values.allSatisfy { $0.capability?.authenticated == true })
        XCTAssertTrue(plans.values.allSatisfy { $0.localURL != nil })
    }

    @MainActor
    func testSetupMaintenanceSchedulesRepairIndexAndThumbnailWork() async throws {
        final class Submitter: VaultBackgroundTaskSubmitting, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var submitted: [String] = []
            func submit(identifier: String, requiresNetworkConnectivity: Bool,
                        requiresExternalPower: Bool, earliestBeginDate: Date?) throws {
                lock.lock(); submitted.append(identifier); lock.unlock()
            }
            func cancel(identifier: String) {}
        }
        let submitter = Submitter()
        let scheduler = VaultBackgroundTaskScheduler(identifierPrefix: "stage5.vault",
                                                      submitter: submitter)
        for kind in [VaultBackgroundTaskKind.importRepair, .index, .thumbnailMaintenance] {
            scheduler.register(kind: kind) { true }
        }
        let tasks = try [
            scheduler.schedule(kind: .importRepair, earliestBeginDate: nil),
            scheduler.schedule(kind: .index, earliestBeginDate: nil),
            scheduler.schedule(kind: .thumbnailMaintenance, earliestBeginDate: nil),
        ]
        for task in tasks {
            let succeeded = await task.value
            XCTAssertTrue(succeeded)
        }
        XCTAssertEqual(Set(submitter.submitted), [
            "stage5.vault.importRepair", "stage5.vault.index", "stage5.vault.thumbnailMaintenance",
        ])
    }

    func testICloudAndMacDownloadProducesAuthenticatedCapability() async throws {
        var directories: [VaultTemporaryDirectory] = []
        for location in [VaultStorageLocation.iCloud, .mac] {
            let directory = try VaultTemporaryDirectory(name: "stage5-\(location.rawValue)-download")
            // Keep cleanup until the repository has gone out of scope. A
            // repository owns an open WAL connection; removing its directory
            // from a loop defer can unlink the database while SQLite still
            // has file descriptors open.
            directories.append(directory)
            let protection = TestProtection()
            let policy = VaultStoragePolicy(location: location)
            let repository = try VaultRepository(
                configuration: VaultStorageConfiguration(policy: policy),
                testContainerURL: directory.url, protectionApplier: protection)
            let objectID = VaultObjectID(rawValue: UUID())
            let revision = UUID()
            let bytes = Data("authenticated remote bytes".utf8)
            let now = Date(timeIntervalSinceReferenceDate: 2_000)
            try repository.upsert(VaultObjectRecord(
                id: objectID, revision: revision, logicalTime: 1, size: Int64(bytes.count),
                contentType: "text/plain", createdAt: now, updatedAt: now, accessedAt: now,
                deviceID: "remote"))
            let root = try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))
            let frames = try VaultChunkedCryptor(
                chunkSize: 16, vaultID: "default", random: VaultTestRandomBytes(seed: 55))
                .seal(bytes, objectID: objectID, revision: revision, root: root)
            let payload = try VaultAuthenticatedCiphertext(
                vaultID: "default", kind: .content, encryptedFrames: frames)

            let plaintextURL = directory.url.appendingPathComponent("plaintext.txt")
            try bytes.write(to: plaintextURL)
            let encryptedFileURL = directory.url.appendingPathComponent("content.lvf")
            try VaultChunkedCryptor(
                chunkSize: 16, vaultID: "default", random: VaultTestRandomBytes(seed: 55))
                .sealFile(plaintextURL: plaintextURL, fileURL: encryptedFileURL,
                          kind: .content, objectID: objectID, revision: revision, root: root)

            let backend: any VaultBackendTransport
            if location == .iCloud {
                let coordinator = InMemoryVaultUbiquitousCoordinator()
                let value = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
                    containerIdentifier: "iCloud.stage5", retryPolicy: VaultBackendRetryPolicy(maximumAttempts: 1)),
                    coordinator: coordinator)
                let file = try VaultAuthenticatedCiphertextFile(
                    fileURL: encryptedFileURL, expectedIdentity: payload.identity,
                    vaultID: "default")
                _ = try await value.put(file.verified(rootKey: { _ in root }), expectedRevision: nil)
                let direct = try await value.payloadFile(for: payload.identity)
                XCTAssertNotNil(direct)
                backend = value
            } else {
                backend = InMemoryVaultBackend(values: [payload.identity: payload])
            }
            let payloadStore = try VaultFileSyncPayloadStore(
                rootURL: directory.url.appendingPathComponent("sync"), vaultID: "default",
                repository: repository, rootKey: { _ in root })
            let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                            payloadSource: payloadStore, owner: "stage5")
            _ = try await sync.download(payload.identity, wakeReason: .userRequested)
            let capability = try XCTUnwrap(repository.localContentCapability(for: objectID))
            XCTAssertTrue(capability.authenticated)
            XCTAssertEqual(try Data(contentsOf: capability.localURL), bytes)
            let plan = try await VaultPreviewRouter(
                repository: repository, backend: backend,
                protectionApplier: protection).plan(objectID: objectID)
            XCTAssertEqual(plan.availability, .ready)
            XCTAssertEqual(plan.capability, capability)
        }
        for directory in directories { try? directory.cleanUp() }
    }

    @MainActor
    private func waitForView<T: UIView>(in root: UIView, identifier: String,
                                        as type: T.Type) async throws -> T {
        for _ in 0..<40 {
            if let view = root.viewWithAccessibilityIdentifier(identifier) as? T { return view }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for view \(identifier)")
        throw XCTSkip("view \(identifier) never appeared")
    }

    private func waitForPlans(_ plans: LockedPlanResults, count: Int) async throws {
        for _ in 0..<20 {
            if plans.values.count >= count { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(count) preview plans")
    }
}

private final class LockedPlanResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [VaultPreviewPlan] = []
    func append(_ plan: VaultPreviewPlan) {
        lock.lock(); values.append(plan); lock.unlock()
    }
}

private extension UIView {
    func viewWithAccessibilityIdentifier(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.viewWithAccessibilityIdentifier(identifier) }.first
    }
}
