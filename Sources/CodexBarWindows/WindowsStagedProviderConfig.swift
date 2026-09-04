import Foundation

enum WindowsStagedProviderConfigError: LocalizedError, Equatable, Sendable {
  case unsupportedProvider
  case invalidCredentialSet
  case invalidValue(String)
  case validationRejected(String)
  case payloadTooLarge

  var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "This provider does not support an isolated manual route."
    case .invalidCredentialSet:
      "The saved credential method is no longer supported."
    case .invalidValue(let field):
      "The saved value for \(field) is invalid. Replace or clear it."
    case .validationRejected(let message):
      message
    case .payloadTooLarge:
      "The isolated provider configuration is too large."
    }
  }
}

enum WindowsStagedProviderConfig {
  static let maximumBytes = 256 * 1024

  static func encodeManual(
    provider: WindowsProviderID,
    record: WindowsProviderCredentialRecord
  ) throws -> (data: Data, source: String, revision: String) {
    guard let schema = WindowsProviderConfigurationCatalog.byProvider[provider] else {
      throw WindowsStagedProviderConfigError.unsupportedProvider
    }
    guard record.providerID == provider.rawValue,
      let set = schema.credentialSet(id: record.credentialSetID)
    else { throw WindowsStagedProviderConfigError.invalidCredentialSet }
    let allowed = Dictionary(uniqueKeysWithValues: set.fields.map { ($0.id, $0) })
    guard record.values.keys.allSatisfy({ allowed[$0] != nil }) else {
      throw WindowsStagedProviderConfigError.invalidCredentialSet
    }
    for field in set.fields {
      guard let value = record.values[field.id] else {
        if field.required {
          if let message = field.displaySafeValidationMessage("") {
            throw WindowsStagedProviderConfigError.validationRejected(message)
          }
          throw WindowsStagedProviderConfigError.invalidValue(field.label)
        }
        continue
      }
      guard field.accepts(value) else {
        if let message = field.displaySafeValidationMessage(value) {
          throw WindowsStagedProviderConfigError.validationRejected(message)
        }
        throw WindowsStagedProviderConfigError.invalidValue(field.label)
      }
    }
    var storageValues = Dictionary(
      uniqueKeysWithValues: record.values.compactMap { fieldID, value in
        allowed[fieldID].map { ($0.storage, value) }
      })
    let input: Data
    switch set.secretTransport {
    case .stagedConfig:
      input = try Self.encode(
        provider: provider,
        source: set.source,
        values: storageValues,
        derivesManualCookieSource: set.derivesManualCookieSource)
    case .stagedTokenAccount:
      guard provider == .deepSeek else {
        throw WindowsStagedProviderConfigError.invalidCredentialSet
      }
      let secretFields = set.fields.filter(\.secret)
      guard secretFields.count == 1, let secretField = secretFields.first,
        let secret = record.values[secretField.id]
      else { throw WindowsStagedProviderConfigError.invalidCredentialSet }
      storageValues.removeValue(forKey: secretField.storage)
      input = try Self.encode(
        provider: provider,
        source: set.source,
        values: storageValues,
        derivesManualCookieSource: set.derivesManualCookieSource,
        tokenAccountToken: secret)
    }
    return (
      input,
      set.source,
      record.revision
    )
  }

  static func encodeBridge(
    provider: WindowsProviderID,
    source: String = "api",
    companionValues: [String: String] = [:]
  ) throws -> Data {
    guard let schema = WindowsProviderConfigurationCatalog.byProvider[provider],
      let set = schema.credentialSets.first(where: { $0.source == source && $0.acceptsOpenCode })
    else { throw WindowsStagedProviderConfigError.unsupportedProvider }
    let fields = Dictionary(uniqueKeysWithValues: set.fields.map { ($0.id, $0) })
    var storageValues: [WindowsProviderConfigurationField.Storage: String] = [:]
    for (fieldID, value) in companionValues {
      guard let field = fields[fieldID], !field.secret, field.accepts(value) else {
        throw WindowsStagedProviderConfigError.invalidValue(fieldID)
      }
      storageValues[field.storage] = value
    }
    return try Self.encode(
      provider: provider,
      source: source,
      values: storageValues,
      derivesManualCookieSource: false)
  }

  private static func encode(
    provider: WindowsProviderID,
    source: String,
    values: [WindowsProviderConfigurationField.Storage: String],
    derivesManualCookieSource: Bool,
    tokenAccountToken: String? = nil
  ) throws -> Data {
    guard ["api", "web", "oauth", "cli"].contains(source) else {
      throw WindowsStagedProviderConfigError.invalidCredentialSet
    }
    let payload = ConfigPayload(
      version: 1,
      providers: [
        ProviderPayload(
          id: provider.rawValue,
          enabled: true,
          source: source,
          apiKey: values[.apiKey],
          secretKey: values[.secretKey],
          cookieHeader: values[.cookieHeader],
          cookieSource: derivesManualCookieSource ? "manual" : nil,
          region: values[.region],
          workspaceID: values[.workspaceID],
          enterpriseHost: values[.enterpriseHost],
          tokenAccounts: tokenAccountToken.map(Self.ephemeralTokenAccounts))
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    guard data.count <= Self.maximumBytes else {
      throw WindowsStagedProviderConfigError.payloadTooLarge
    }
    return data
  }

  private static func ephemeralTokenAccounts(token: String) -> TokenAccountDataPayload {
    TokenAccountDataPayload(
      version: 1,
      accounts: [
        TokenAccountPayload(
          id: Foundation.UUID().uuidString.lowercased(),
          label: "",
          token: token,
          addedAt: 0)
      ],
      activeIndex: 0)
  }

  private struct ConfigPayload: Encodable {
    let version: Int
    let providers: [ProviderPayload]
  }

  private struct ProviderPayload: Encodable {
    let id: String
    let enabled: Bool
    let source: String
    let apiKey: String?
    let secretKey: String?
    let cookieHeader: String?
    let cookieSource: String?
    let region: String?
    let workspaceID: String?
    let enterpriseHost: String?
    let tokenAccounts: TokenAccountDataPayload?
  }

  private struct TokenAccountDataPayload: Encodable {
    let version: Int
    let accounts: [TokenAccountPayload]
    let activeIndex: Int
  }

  private struct TokenAccountPayload: Encodable {
    let id: String
    let label: String
    let token: String
    let addedAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
      case id
      case label
      case token
      case addedAt
      case lastUsed
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(self.id, forKey: .id)
      try container.encode(self.label, forKey: .label)
      try container.encode(self.token, forKey: .token)
      try container.encode(self.addedAt, forKey: .addedAt)
      try container.encodeNil(forKey: .lastUsed)
    }
  }
}
