import Foundation

@MainActor
protocol ConfigurationRestoreCheckpoint {}

@MainActor
protocol ConfigurationRestorePersistence {
    func checkpointVault() throws -> VaultDocument
    func checkpointButtonBar() -> any ConfigurationRestoreCheckpoint
    func saveVault(_ document: VaultDocument) throws
    func restoreVault(_ document: VaultDocument) throws
    func saveButtonBar(_ document: ButtonBarDocument) throws
    func restoreButtonBar(_ checkpoint: any ConfigurationRestoreCheckpoint)
    func saveCatalog(_ catalog: ProfileCatalog) throws
}

@MainActor
struct LiveConfigurationRestorePersistence: ConfigurationRestorePersistence {
    let vault: VaultStore
    let buttonBar: SendStringButtonStore
    let profiles: ProfileStore

    func checkpointVault() throws -> VaultDocument { try vault.snapshot() }
    func checkpointButtonBar() -> any ConfigurationRestoreCheckpoint {
        LiveButtonBarCheckpoint(value: buttonBar.checkpoint())
    }
    func saveVault(_ document: VaultDocument) throws { try vault.replace(document) }
    func restoreVault(_ document: VaultDocument) throws { try vault.replace(document) }
    func saveButtonBar(_ document: ButtonBarDocument) throws { try buttonBar.restore(document) }
    func restoreButtonBar(_ checkpoint: any ConfigurationRestoreCheckpoint) {
        if let checkpoint = checkpoint as? LiveButtonBarCheckpoint { buttonBar.rollback(checkpoint.value) }
    }
    func saveCatalog(_ catalog: ProfileCatalog) throws { try profiles.save(catalog) }
}

@MainActor
private struct LiveButtonBarCheckpoint: ConfigurationRestoreCheckpoint {
    let value: SendStringButtonStore.Checkpoint
}

@MainActor
struct ConfigurationRestoreTransaction {
    let persistence: any ConfigurationRestorePersistence

    func commit(vault: VaultDocument?, buttonBar: ButtonBarDocument?, catalog: ProfileCatalog) throws {
        let previousVault = try vault.map { _ in try persistence.checkpointVault() }
        let previousButtonBar = buttonBar.map { _ in persistence.checkpointButtonBar() }
        do {
            if let vault { try persistence.saveVault(vault) }
            if let buttonBar { try persistence.saveButtonBar(buttonBar) }
            try persistence.saveCatalog(catalog)
        } catch {
            if let previousButtonBar { persistence.restoreButtonBar(previousButtonBar) }
            if let previousVault {
                do { try persistence.restoreVault(previousVault) }
                catch { throw MutyError("Import and password-vault rollback failed. Check password storage before retrying.") }
            }
            throw error
        }
    }
}
