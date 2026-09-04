import Foundation
import WinSDK

enum WindowsProviderOperationLock {
  private static let timeoutMilliseconds: DWORD = 75_000

  static func withLock<T>(
    provider: WindowsProviderID,
    operation: () throws -> T
  ) throws -> T {
    try Self.withLock(
      provider: provider,
      timeoutMilliseconds: Self.timeoutMilliseconds,
      operation: operation)
  }

  static func withLock<T>(
    provider: WindowsProviderID,
    timeoutMilliseconds: DWORD,
    operation: () throws -> T
  ) throws -> T {
    guard Self.isSafeProviderID(provider.rawValue), let sid = Self.currentUserSID() else {
      throw WindowsProviderCredentialVaultError.unsupportedProvider
    }
    let name = "Local\\CodexBar.Provider.\(sid).\(provider.rawValue)"
    let mutex = WindowsWideString.withPointer(name) { CreateMutexW(nil, false, $0) }
    guard let mutex else { throw WindowsProviderCredentialVaultError.storageFailed }
    defer { _ = CloseHandle(mutex) }
    let wait = WaitForSingleObject(mutex, timeoutMilliseconds)
    guard wait == DWORD(WAIT_OBJECT_0) || wait == DWORD(0x0000_0080) else {
      throw WindowsProviderCredentialVaultError.providerBusy
    }
    defer { _ = ReleaseMutex(mutex) }
    return try operation()
  }

  static func currentUserSID() -> String? {
    var token: HANDLE?
    guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else {
      return nil
    }
    defer { _ = CloseHandle(token) }
    var required: DWORD = 0
    _ = GetTokenInformation(token, TokenUser, nil, 0, &required)
    guard required > 0 else { return nil }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(required), alignment: 16)
    defer { memory.deallocate() }
    guard GetTokenInformation(token, TokenUser, memory, required, &required) else { return nil }
    let user = memory.assumingMemoryBound(to: TOKEN_USER.self).pointee
    var sidString: LPWSTR?
    guard ConvertSidToStringSidW(user.User.Sid, &sidString), let sidString else { return nil }
    defer { _ = LocalFree(UnsafeMutableRawPointer(sidString)) }
    return String(decodingCString: sidString, as: UTF16.self)
  }

  private static func isSafeProviderID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 64 else { return false }
    return value.unicodeScalars.allSatisfy {
      (48...57).contains($0.value) || (97...122).contains($0.value) || $0.value == 45
    }
  }
}
