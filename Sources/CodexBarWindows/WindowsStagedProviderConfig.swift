import Foundation

enum WindowsStagedProviderConfigError: LocalizedError, Equatable, Sendable {
  case unsupportedProvider
  case invalidCredentialSet
  case invalidValue(String)
  case payloadTooLarge

  var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "This provider does not support an isolated manual route."
    case .invalidCredentialSet:
      "The saved credential method is no longer supported."
    case .invalidValue(let field):
      "The saved value for \(field) is invalid. Replace or clear it."
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
        if field.required { throw WindowsStagedProviderConfigError.invalidValue(field.label) }
        continue
      }
      guard field.accepts(value) else {
        throw WindowsStagedProviderConfigError.invalidValue(field.label)
      }
    }
    let storageValues = Dictionary(
      uniqueKeysWithValues: record.values.compactMap { fieldID, value in
        allowed[fieldID].map { ($0.storage, value) }
      })
    return (
      try Self.encode(
        provider: provider,
        source: set.source,
        values: storageValues,
        derivesManualCookieSource: set.derivesManualCookieSource),
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
    derivesManualCookieSource: Bool
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
          enterpriseHost: values[.enterpriseHost])
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    guard data.count <= Self.maximumBytes else {
      throw WindowsStagedProviderConfigError.payloadTooLarge
    }
    return data
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
  }
}
