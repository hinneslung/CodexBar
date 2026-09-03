import Foundation

#if os(Windows)
  import WinSDK
#endif

@main
enum CodexBarWindowsMain {
  static func main() async {
    #if os(Windows)
      _ = SetProcessDPIAware()
    #endif
    let environment = ProcessInfo.processInfo.environment
    let configurationStore = try? WindowsConfigurationStore(environment: environment)
    let credentialVault = try? WindowsProviderCredentialVault(environment: environment)
    let credentialRouteResolver = WindowsProviderCredentialRouteResolver(
      credentialVault: credentialVault)
    let dataSource =
      if environment["CODEXBAR_WINDOWS_OFFLINE"] == "1" {
        AnyWindowsProviderDataSource(WindowsUnavailableProviderAdapter())
      } else {
        AnyWindowsProviderDataSource(
          WindowsConfiguredProviderDataSource(
            store: configurationStore,
            environment: environment,
            credentialVault: credentialVault,
            credentialRouteResolver: credentialRouteResolver))
      }
    let exitCode = await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        let application = WindowsTrayApplication(
          dataSource: dataSource,
          configurationStore: configurationStore,
          credentialRouteResolver: credentialRouteResolver,
          providerConfigurationClient: WindowsProviderConfigurationClient(
            vault: credentialVault))
        continuation.resume(returning: application.run())
      }
    }
    #if os(Windows)
      ExitProcess(UINT(exitCode))
    #endif
  }
}
