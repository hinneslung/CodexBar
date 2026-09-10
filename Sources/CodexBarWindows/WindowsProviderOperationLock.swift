import Foundation
import WinSDK

enum WindowsProviderOperationLock {
    private static let timeoutMilliseconds: DWORD = 75000

    static func withLock<T>(
        provider: WindowsProviderID,
        operation: () throws -> T) throws -> T
    {
        try self.withLock(
            profileID: .defaultID(for: provider),
            timeoutMilliseconds: self.timeoutMilliseconds,
            operation: operation)
    }

    static func withLock<T>(
        profileID: WindowsProviderProfileID,
        operation: () throws -> T) throws -> T
    {
        try self.withLock(
            profileID: profileID,
            timeoutMilliseconds: self.timeoutMilliseconds,
            operation: operation)
    }

    static func withLock<T>(
        provider: WindowsProviderID,
        timeoutMilliseconds: DWORD,
        operation: () throws -> T) throws -> T
    {
        try self.withLock(
            profileID: .defaultID(for: provider),
            timeoutMilliseconds: timeoutMilliseconds,
            operation: operation)
    }

    static func withLock<T>(
        profileID: WindowsProviderProfileID,
        timeoutMilliseconds: DWORD,
        operation: () throws -> T) throws -> T
    {
        guard WindowsProviderProfileID.isValid(profileID.rawValue), let sid = currentUserSID() else {
            throw WindowsProviderCredentialVaultError.unsupportedProvider
        }
        let name = "Local\\CodexBar.Provider.\(sid).\(profileID.rawValue)"
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
}
