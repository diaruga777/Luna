import Foundation
import LunaVaultModels
import LunaVaultStorage

/// The device backend is the local read/write surface. Its bytes never leave
/// the process through this type and are protected by `VaultRepository`'s
/// complete-until-first-user-authentication Data Protection policy. It does not
/// use the root key: local-at-rest protection is an OS responsibility, while
/// iCloud and Mac transports require client-side encryption.
public final class VaultDeviceBackend: @unchecked Sendable {
    private let store: VaultObjectStoring

    public let capabilities = VaultBackendCapabilities(
        location: .device,
        availability: .available,
        supportsAtomicWrites: true,
        supportsRangeReads: true,
        supportsEviction: false,
        requiresClientSideEncryption: false)

    public init(store: VaultObjectStoring) {
        self.store = store
    }

    public func putContent(_ content: Data, for id: VaultObjectID) async throws {
        try store.setData(content, for: id)
    }

    public func content(for id: VaultObjectID) async throws -> Data? {
        try store.data(for: id)
    }

    public func content(for id: VaultObjectID, range: Range<Int>) async throws -> Data? {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw VaultBackendError.invalidRange
        }
        guard let value = try store.data(for: id) else { return nil }
        guard range.upperBound <= value.count else { throw VaultBackendError.invalidRange }
        return Data(value[range])
    }

    public func removeContent(for id: VaultObjectID) async throws {
        // Deletion is idempotent at the object-store boundary.
        try store.removeData(for: id)
    }
}
