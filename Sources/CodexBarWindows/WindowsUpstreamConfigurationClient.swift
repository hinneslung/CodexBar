import Foundation

enum WindowsProviderConfigurationError: LocalizedError, Equatable, Sendable {
  case unsupportedProvider
  case invalidInput(String)
  case storageUnavailable

  var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "Manual credentials are not available for this provider."
    case .invalidInput(let field):
      "Enter a valid value for \(field)."
    case .storageUnavailable:
      "Windows could not update the protected credential."
    }
  }
}

struct WindowsUpstreamConfigurationStatus: Equatable, Sendable {
  let provider: WindowsProviderID
  let credentialSetID: String?
  let configuredFieldIDs: Set<String>
  let companionValues: [String: String]
  let revision: String?

  var apiKeyConfigured: Bool {
    self.credentialSetID == "api-key" && self.configuredFieldIDs.contains("apiKey")
  }

  static func make(
    provider: WindowsProviderID,
    record: WindowsProviderCredentialRecord?
  ) throws -> Self {
    guard let record else {
      return Self(
        provider: provider,
        credentialSetID: nil,
        configuredFieldIDs: [],
        companionValues: [:],
        revision: nil)
    }
    guard
      let set = WindowsProviderConfigurationCatalog.credentialSet(
        provider: provider,
        id: record.credentialSetID)
    else { throw WindowsProviderCredentialVaultError.corruptedCredential }
    var visible: [String: String] = [:]
    for field in set.fields where !field.secret {
      if let value = record.values[field.id] { visible[field.id] = value }
    }
    return Self(
      provider: provider,
      credentialSetID: record.credentialSetID,
      configuredFieldIDs: Set(record.values.keys),
      companionValues: visible,
      revision: record.revision)
  }
}

/// App-owned provider setup. This type never invokes or mutates CodexBar CLI configuration.
struct WindowsProviderConfigurationClient: Sendable {
  private let vault: WindowsProviderCredentialVault?

  init(vault: WindowsProviderCredentialVault? = try? WindowsProviderCredentialVault()) {
    self.vault = vault
  }

  func contains(provider: WindowsProviderID) -> Bool {
    self.vault?.contains(provider) == true
  }

  func status(provider: WindowsProviderID) throws -> WindowsUpstreamConfigurationStatus {
    guard let vault = self.vault else {
      throw WindowsProviderConfigurationError.storageUnavailable
    }
    return try WindowsUpstreamConfigurationStatus.make(
      provider: provider,
      record: vault.load(provider))
  }

  @discardableResult
  func save(
    provider: WindowsProviderID,
    credentialSetID: String,
    values: [String: String]
  ) throws -> WindowsUpstreamConfigurationStatus {
    guard let vault = self.vault else {
      throw WindowsProviderConfigurationError.storageUnavailable
    }
    let record = try vault.save(
      provider: provider,
      credentialSetID: credentialSetID,
      submittedValues: values)
    return try WindowsUpstreamConfigurationStatus.make(provider: provider, record: record)
  }

  func clear(provider: WindowsProviderID) throws -> WindowsUpstreamConfigurationStatus {
    guard let vault = self.vault else {
      throw WindowsProviderConfigurationError.storageUnavailable
    }
    try vault.clear(provider)
    return try WindowsUpstreamConfigurationStatus.make(provider: provider, record: nil)
  }
}
