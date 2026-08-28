import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultSync

public enum VaultTestKitModule {
    public static let identifier = "VaultTestKit"

    /// Compiling this inventory verifies that the test-support product can see
    /// every public Vault seam without production targets depending on it.
    public static let scaffoldModuleIdentifiers = [
        LunaVaultModelsModule.identifier,
        LunaVaultCryptoModule.identifier,
        LunaVaultStorageModule.identifier,
        LunaVaultIndexExtractionModule.identifier,
        LunaVaultEmbeddingsModule.identifier,
        LunaVaultSearchModule.identifier,
        LunaVaultBackendModule.identifier,
        LunaVaultSyncModule.identifier,
        LunaVaultSetupModule.identifier,
    ]
}
