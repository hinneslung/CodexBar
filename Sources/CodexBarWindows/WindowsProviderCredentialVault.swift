import Foundation
import WinSDK

enum WindowsProviderCredentialVaultError: LocalizedError, Equatable, Sendable {
  case localAppDataUnavailable
  case unsupportedProvider
  case invalidCredentialSet
  case invalidValue(String)
  case validationRejected(String)
  case protectedDataUnavailable
  case corruptedCredential
  case credentialTooLarge
  case providerBusy
  case storageFailed

  var errorDescription: String? {
    switch self {
    case .localAppDataUnavailable:
      "Windows application data is unavailable."
    case .unsupportedProvider:
      "Manual credentials are not available for this provider."
    case .invalidCredentialSet:
      "Select a supported credential method."
    case .invalidValue(let field):
      "Enter a valid value for \(field)."
    case .validationRejected(let message):
      message
    case .protectedDataUnavailable:
      "The saved credential cannot be unlocked for this Windows account. Replace or clear it."
    case .corruptedCredential:
      "The saved credential is damaged or belongs to a different provider. Replace or clear it."
    case .credentialTooLarge:
      "The credential is too large to save."
    case .providerBusy:
      "This provider is busy. Try again after its current refresh finishes."
    case .storageFailed:
      "Windows could not update the protected credential."
    }
  }
}

struct WindowsProviderCredentialRecord: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let providerID: String
  let credentialSetID: String
  let revision: String
  let values: [String: String]

  init(
    provider: WindowsProviderID,
    credentialSetID: String,
    revision: Foundation.UUID = Foundation.UUID(),
    values: [String: String]
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.providerID = provider.rawValue
    self.credentialSetID = credentialSetID
    self.revision = revision.uuidString.lowercased()
    self.values = values
  }

  var description: String {
    "WindowsProviderCredentialRecord(provider: \(self.providerID), set: \(self.credentialSetID), "
      + "fields: \(self.values.count))"
  }

  var debugDescription: String { self.description }
}

struct WindowsProviderCredentialVault: Sendable {
  static let maximumPlaintextBytes = 256 * 1024
  static let maximumCiphertextBytes = 512 * 1024

  let directoryURL: URL

  init(directoryURL: URL) {
    self.directoryURL = directoryURL
  }

  init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard
      let localAppData = environment["LOCALAPPDATA"]?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !localAppData.isEmpty
    else { throw WindowsProviderCredentialVaultError.localAppDataUnavailable }
    self.directoryURL = URL(fileURLWithPath: localAppData, isDirectory: true)
      .appendingPathComponent("CodexBar", isDirectory: true)
      .appendingPathComponent("Credentials", isDirectory: true)
  }

  func contains(_ provider: WindowsProviderID, fileManager: FileManager = .default) -> Bool {
    guard Self.isSupportedProvider(provider) else { return false }
    return fileManager.fileExists(atPath: self.fileURL(for: provider).path)
  }

  func protectedBlobIdentity(_ provider: WindowsProviderID) throws
    -> WindowsProviderProtectedBlobIdentity?
  {
    try WindowsProviderOperationLock.withLock(provider: provider) {
      try self.protectedBlobIdentityUnlocked(provider)
    }
  }

  func load(_ provider: WindowsProviderID, fileManager: FileManager = .default) throws
    -> WindowsProviderCredentialRecord?
  {
    try WindowsProviderOperationLock.withLock(provider: provider) {
      try self.loadUnlocked(provider, fileManager: fileManager)
    }
  }

  @discardableResult
  func save(
    provider: WindowsProviderID,
    credentialSetID: String,
    submittedValues: [String: String],
    fileManager: FileManager = .default
  ) throws -> WindowsProviderCredentialRecord {
    try WindowsProviderOperationLock.withLock(provider: provider) {
      guard
        let set = WindowsProviderConfigurationCatalog.credentialSet(
          provider: provider,
          id: credentialSetID)
      else { throw WindowsProviderCredentialVaultError.invalidCredentialSet }

      let existing = try self.loadUnlocked(provider, fileManager: fileManager)
      var values: [String: String] = [:]
      for field in set.fields {
        let submitted = submittedValues[field.id]
        if let submitted, !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          guard let normalized = field.normalized(submitted) else {
            if let message = field.displaySafeValidationMessage(submitted) {
              throw WindowsProviderCredentialVaultError.validationRejected(message)
            }
            throw WindowsProviderCredentialVaultError.invalidValue(field.label)
          }
          values[field.id] = normalized
        } else if field.secret, existing?.credentialSetID == credentialSetID,
          let retained = existing?.values[field.id]
        {
          values[field.id] = retained
        } else if field.required {
          if let message = field.displaySafeValidationMessage(submitted ?? "") {
            throw WindowsProviderCredentialVaultError.validationRejected(message)
          }
          throw WindowsProviderCredentialVaultError.invalidValue(field.label)
        }
      }
      let allowed = Set(set.fields.map(\.id))
      guard submittedValues.keys.allSatisfy(allowed.contains) else {
        throw WindowsProviderCredentialVaultError.invalidCredentialSet
      }

      let record = WindowsProviderCredentialRecord(
        provider: provider,
        credentialSetID: credentialSetID,
        values: values)
      try Self.validate(record, provider: provider)
      let plaintext = try JSONEncoder().encode(record)
      guard plaintext.count <= Self.maximumPlaintextBytes else {
        throw WindowsProviderCredentialVaultError.credentialTooLarge
      }
      let ciphertext = try Self.protect(plaintext)
      guard ciphertext.count <= Self.maximumCiphertextBytes else {
        throw WindowsProviderCredentialVaultError.credentialTooLarge
      }
      try self.writeAtomically(ciphertext, provider: provider, fileManager: fileManager)
      return record
    }
  }

  func clear(_ provider: WindowsProviderID, fileManager: FileManager = .default) throws {
    try WindowsProviderOperationLock.withLock(provider: provider) {
      guard Self.isSupportedProvider(provider) else {
        throw WindowsProviderCredentialVaultError.unsupportedProvider
      }
      let url = self.fileURL(for: provider)
      guard fileManager.fileExists(atPath: url.path) else { return }
      let deleted = WindowsWideString.withPointer(url.path) { DeleteFileW($0) }
      guard deleted || GetLastError() == DWORD(ERROR_FILE_NOT_FOUND) else {
        throw WindowsProviderCredentialVaultError.storageFailed
      }
    }
  }

  private func loadUnlocked(
    _ provider: WindowsProviderID,
    fileManager: FileManager
  ) throws -> WindowsProviderCredentialRecord? {
    guard Self.isSupportedProvider(provider) else {
      throw WindowsProviderCredentialVaultError.unsupportedProvider
    }
    let url = self.fileURL(for: provider)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard
      let metadata = try? url.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
      metadata.isRegularFile == true,
      metadata.isSymbolicLink != true,
      let fileSize = metadata.fileSize,
      fileSize > 0,
      fileSize <= Self.maximumCiphertextBytes
    else { throw WindowsProviderCredentialVaultError.corruptedCredential }
    let ciphertext = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard !ciphertext.isEmpty, ciphertext.count <= Self.maximumCiphertextBytes else {
      throw WindowsProviderCredentialVaultError.corruptedCredential
    }
    let plaintext = try Self.unprotect(ciphertext)
    guard !plaintext.isEmpty, plaintext.count <= Self.maximumPlaintextBytes else {
      throw WindowsProviderCredentialVaultError.corruptedCredential
    }
    let record: WindowsProviderCredentialRecord
    do {
      record = try JSONDecoder().decode(WindowsProviderCredentialRecord.self, from: plaintext)
    } catch {
      throw WindowsProviderCredentialVaultError.corruptedCredential
    }
    try Self.validate(record, provider: provider)
    return record
  }

  private func protectedBlobIdentityUnlocked(_ provider: WindowsProviderID) throws
    -> WindowsProviderProtectedBlobIdentity?
  {
    guard Self.isSupportedProvider(provider) else {
      throw WindowsProviderCredentialVaultError.unsupportedProvider
    }
    let handle = WindowsWideString.withPointer(self.fileURL(for: provider).path) { path in
      CreateFileW(
        path,
        0,
        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
        nil,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_ATTRIBUTE_NORMAL),
        nil)
    }
    guard handle != INVALID_HANDLE_VALUE, let handle else {
      let error = GetLastError()
      if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) {
        return nil
      }
      throw WindowsProviderCredentialVaultError.storageFailed
    }
    defer { _ = CloseHandle(handle) }
    var information = BY_HANDLE_FILE_INFORMATION()
    guard GetFileInformationByHandle(handle, &information),
      information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
    else { throw WindowsProviderCredentialVaultError.storageFailed }
    return WindowsProviderProtectedBlobIdentity(
      volumeSerialNumber: information.dwVolumeSerialNumber,
      fileIndexHigh: information.nFileIndexHigh,
      fileIndexLow: information.nFileIndexLow,
      fileSizeHigh: information.nFileSizeHigh,
      fileSizeLow: information.nFileSizeLow,
      lastWriteHigh: information.ftLastWriteTime.dwHighDateTime,
      lastWriteLow: information.ftLastWriteTime.dwLowDateTime)
  }

  private func writeAtomically(
    _ data: Data,
    provider: WindowsProviderID,
    fileManager: FileManager
  ) throws {
    try Self.createProtectedDirectory(self.directoryURL, fileManager: fileManager)
    let destination = self.fileURL(for: provider)
    let temporary = self.directoryURL.appendingPathComponent(
      ".\(provider.rawValue).\(UUID().uuidString).tmp",
      isDirectory: false)
    defer { try? fileManager.removeItem(at: temporary) }

    let descriptor = try WindowsProtectedSecurityDescriptor()
    var security = descriptor.securityAttributes
    let handle = WindowsWideString.withPointer(temporary.path) { path in
      CreateFileW(
        path,
        DWORD(GENERIC_WRITE),
        0,
        &security,
        DWORD(CREATE_NEW),
        DWORD(FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY),
        nil)
    }
    guard handle != INVALID_HANDLE_VALUE, let handle else {
      throw WindowsProviderCredentialVaultError.storageFailed
    }
    var fileHandle: HANDLE? = handle
    defer {
      if let fileHandle { _ = CloseHandle(fileHandle) }
    }

    let wrote = data.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        var count: DWORD = 0
        let length = min(bytes.count - offset, Int(DWORD.max))
        guard
          WriteFile(handle, bytes.baseAddress?.advanced(by: offset), DWORD(length), &count, nil),
          count > 0
        else { return false }
        offset += Int(count)
      }
      return true
    }
    guard wrote, FlushFileBuffers(handle) else {
      throw WindowsProviderCredentialVaultError.storageFailed
    }
    _ = CloseHandle(handle)
    fileHandle = nil

    let replaced = WindowsWideString.withPointer(temporary.path) { source in
      WindowsWideString.withPointer(destination.path) { target in
        MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
      }
    }
    guard replaced else { throw WindowsProviderCredentialVaultError.storageFailed }
  }

  private func fileURL(for provider: WindowsProviderID) -> URL {
    self.directoryURL.appendingPathComponent("\(provider.rawValue).bin", isDirectory: false)
  }

  private static func validate(
    _ record: WindowsProviderCredentialRecord,
    provider: WindowsProviderID
  ) throws {
    guard record.schemaVersion == WindowsProviderCredentialRecord.currentSchemaVersion,
      record.providerID == provider.rawValue,
      Foundation.UUID(uuidString: record.revision) != nil,
      let set = WindowsProviderConfigurationCatalog.credentialSet(
        provider: provider,
        id: record.credentialSetID)
    else { throw WindowsProviderCredentialVaultError.corruptedCredential }
    let allowed = Dictionary(uniqueKeysWithValues: set.fields.map { ($0.id, $0) })
    guard record.values.keys.allSatisfy({ allowed[$0] != nil }) else {
      throw WindowsProviderCredentialVaultError.corruptedCredential
    }
    for field in set.fields {
      guard let value = record.values[field.id] else {
        if field.required { throw WindowsProviderCredentialVaultError.corruptedCredential }
        continue
      }
      guard field.accepts(value) else {
        throw WindowsProviderCredentialVaultError.corruptedCredential
      }
    }
  }

  private static func isSupportedProvider(_ provider: WindowsProviderID) -> Bool {
    guard WindowsProviderConfigurationCatalog.byProvider[provider] != nil,
      !provider.rawValue.isEmpty, provider.rawValue.utf8.count <= 64
    else { return false }
    return provider.rawValue.unicodeScalars.allSatisfy {
      (48...57).contains($0.value) || (97...122).contains($0.value) || $0.value == 45
    }
  }

  private static func createProtectedDirectory(_ url: URL, fileManager: FileManager) throws {
    if fileManager.fileExists(atPath: url.path) {
      let descriptor = try WindowsProtectedSecurityDescriptor()
      let secured = WindowsWideString.withPointer(url.path) { path in
        SetFileSecurityW(
          path,
          DWORD(DACL_SECURITY_INFORMATION) | DWORD(PROTECTED_DACL_SECURITY_INFORMATION),
          descriptor.pointer)
      }
      guard secured else { throw WindowsProviderCredentialVaultError.storageFailed }
      return
    }
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let descriptor = try WindowsProtectedSecurityDescriptor()
    var security = descriptor.securityAttributes
    let created = WindowsWideString.withPointer(url.path) { CreateDirectoryW($0, &security) }
    guard created || GetLastError() == DWORD(ERROR_ALREADY_EXISTS) else {
      throw WindowsProviderCredentialVaultError.storageFailed
    }
  }

  static func protect(_ data: Data) throws -> Data {
    try Self.transform(
      data,
      operation: { input, output in
        CryptProtectData(
          input,
          nil,
          nil,
          nil,
          nil,
          DWORD(CRYPTPROTECT_UI_FORBIDDEN),
          output)
      })
  }

  private static func unprotect(_ data: Data) throws -> Data {
    do {
      return try Self.transform(
        data,
        operation: { input, output in
          CryptUnprotectData(
            input,
            nil,
            nil,
            nil,
            nil,
            DWORD(CRYPTPROTECT_UI_FORBIDDEN),
            output)
        })
    } catch {
      throw WindowsProviderCredentialVaultError.protectedDataUnavailable
    }
  }

  private typealias DPAPIOperation = (
    UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>
  )
    -> Bool

  private static func transform(_ data: Data, operation: DPAPIOperation) throws -> Data {
    var inputBytes = [UInt8](data)
    defer {
      _ = inputBytes.withUnsafeMutableBytes {
        $0.initializeMemory(as: UInt8.self, repeating: 0)
      }
    }
    var output = DATA_BLOB()
    let succeeded = inputBytes.withUnsafeMutableBytes { bytes -> Bool in
      var input = DATA_BLOB(
        cbData: DWORD(bytes.count),
        pbData: bytes.bindMemory(to: BYTE.self).baseAddress)
      return operation(&input, &output)
    }
    guard succeeded, output.cbData > 0, let bytes = output.pbData else {
      throw WindowsProviderCredentialVaultError.protectedDataUnavailable
    }
    defer { _ = LocalFree(UnsafeMutableRawPointer(bytes)) }
    return Data(bytes: bytes, count: Int(output.cbData))
  }

}

struct WindowsProviderProtectedBlobIdentity: Equatable, Sendable {
  let volumeSerialNumber: DWORD
  let fileIndexHigh: DWORD
  let fileIndexLow: DWORD
  let fileSizeHigh: DWORD
  let fileSizeLow: DWORD
  let lastWriteHigh: DWORD
  let lastWriteLow: DWORD
}

private final class WindowsProtectedSecurityDescriptor {
  let pointer: PSECURITY_DESCRIPTOR

  init() throws {
    guard let userSID = WindowsProviderOperationLock.currentUserSID() else {
      throw WindowsProviderCredentialVaultError.storageFailed
    }
    var pointer: PSECURITY_DESCRIPTOR?
    let sddlValue = "D:P(A;;FA;;;SY)(A;;FA;;;\(userSID))"
    let converted = WindowsWideString.withPointer(sddlValue) { sddl in
      ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl,
        DWORD(SDDL_REVISION_1),
        &pointer,
        nil)
    }
    guard converted, let pointer else {
      throw WindowsProviderCredentialVaultError.storageFailed
    }
    self.pointer = pointer
  }

  deinit { _ = LocalFree(self.pointer) }

  var securityAttributes: SECURITY_ATTRIBUTES {
    var attributes = SECURITY_ATTRIBUTES()
    attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
    attributes.lpSecurityDescriptor = self.pointer
    attributes.bInheritHandle = false
    return attributes
  }
}
