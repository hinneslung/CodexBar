# Windows development

- [User setup](windows.md) · [Branch and release process](windows-fork.md) · [README](../README.md)

## Build and run

- Install Swift **6.3.3** and the Microsoft C++ build tools and Windows SDK listed in [Swift's Windows installation guide](https://www.swift.org/install/windows/). This matches the toolchain used by CI.
- Clone the branch used for Windows development, then build and run the tests:

  ```powershell
  git clone --branch windows-native-app https://github.com/hinneslung/CodexBar-for-Windows.git
  cd CodexBar-for-Windows
  swift build --product CodexBar -Xswiftc -warnings-as-errors
  swift test --no-parallel -Xswiftc -warnings-as-errors
  ```

- Find the built executable and launch it:

  ```powershell
  $binDirectory = (swift build --product CodexBar --show-bin-path).Trim()
  Start-Process (Join-Path $binDirectory 'CodexBar.exe') -WindowStyle Hidden
  ```

- `swift build` builds the Windows app, but does not bundle the Linux tools used to fetch usage. Put a complete, matching `wsl-cli` folder beside the executable to test provider connections. Some Automatic connections can use a CodexBar CLI already installed in WSL; saved keys, OpenCode connections, and providers using `diagnose` need the bundled tools.
- For UI-only work, set `CODEXBAR_WINDOWS_OFFLINE=1` before launch to prevent provider requests, WSL launches, and credential reads. Use `CODEXBAR_WINDOWS_SHOW_ON_START=1` to open the popup at launch. Remove these variables before normal runtime testing.
- Before launching, check whether CodexBar is already running and which executable it uses. Otherwise, you may test an older copy or start a second tray icon.

## Build directories

- Default x64 debug app: `.build/x86_64-unknown-windows-msvc/debug/CodexBar.exe`.
- Native ARM64 output: `.build/aarch64-unknown-windows-msvc/debug/CodexBar.exe`.
- Linux tools: `wsl-cli/` beside the app. Copy the complete folder from a matching release package, including the CLI, launcher, version file, and checksums.
- Local release inputs: `.build/windows/release-inputs/<architecture>/<version>/`.
- Local release outputs: `.build/windows/releases/<version>/<architecture>/`.
- Temporary test scratch and QA: `%TEMP%/CodexBar/swiftpm/` and `%TEMP%/CodexBar/qa/`.
- Do not create feature-, date-, or agent-named directories under `.build`. Follow the local `.build/README.md` when present.

## Code layout

- `Sources/CodexBarWindows/`: the Windows interface, settings, encrypted credential storage, CLI lookup, process execution, and response parsing.
- `Sources/CodexBarLinuxStagingLauncher/`: a small Linux helper that passes temporary settings to the CLI and enforces a request timeout.
- `Sources/CodexBarCLI/` and `Sources/CodexBarCore/`: the original CodexBar code that contacts providers and reads usage. Keep this code unchanged for the Windows app; do not add a second implementation of provider requests in Windows.
- `WindowsProviderCatalog`: stable provider IDs and display names.
- `WindowsProviderConfigurationCatalog`: each provider's settings fields, input checks, instructions, supported sign-in methods, and choice of CLI command.
- `WindowsProviderCredentialBridge`: which OpenCode connections the app can use and how to pass them to the CLI.
- `WindowsProviderSourcePresentation`: labels for supported sign-in methods and the source of a usage reading. It shows the Linux distribution first. Listing a method must not imply that an account is connected.
- These provider definitions are maintained in the Windows code, not discovered by asking the CLI. Check them against the bundled upstream version whenever you rebase.

### CLI selection and commands

- With **WSL distro → Automatic**, the app checks installed WSL2 distributions for an existing CLI in a fixed order. If none is found, it tries installing the bundled CLI. Choosing a distribution limits this search to that distribution.
- The bundled tools are installed under `~/.local/share/codexbar-windows/<version>/` for the selected Linux user, not `root`. They are not added to `PATH`.
- Requests using saved credentials, OpenCode, or `diagnose` choose the distribution the same way, then use the bundled CLI there. They must not switch to a different distribution when that step fails.
- Direct Automatic usage requests run `usage --provider <cli-name> --json-only`. Requests with temporary settings go through the Linux launcher, which runs `usage` with an explicit source and JSON output.
- Providers marked for diagnostics in the catalog run `diagnose --provider <cli-name> --format json --redact`. The Windows decoder validates the response version, provider, and source before reading usage fields.
- A `diagnose` response may contain less information than a `usage` response. Only display fields the decoder explicitly supports; do not reuse diagnostic messages as an account name, plan, or balance.
- CLI processes run without visible terminal windows, with output limits and timeouts. The app retries selected temporary failures once; it does not retry indefinitely.

### Credential handling

- Check saved credentials before looking up OpenCode. If a saved value cannot be read or is invalid, return an error instead of trying a different account.
- Windows DPAPI encrypts saved credentials for the current user. File permissions allow only that user and SYSTEM. A lock and revision checks for each profile prevent Save/Clear from racing with that profile's refresh.
- To use a saved credential, send only the settings needed for that request through an anonymous stdin pipe. The Linux launcher stores them in memory with `memfd_create`. Its fallback creates a restricted temporary file and removes its directory entry before writing credentials. `CODEXBAR_CONFIG` points to the open file descriptor, not a persistent settings file.
- DeepSeek receives its key through the CLI's existing token-account configuration, with a new UUID and an empty account label. It needs no special CLI command or secret environment variable from Windows.
- OpenCode works differently: the app reads the selected Linux user's auth file, then uses `WSLENV` to pass the matching credentials as child-process environment variables. The temporary settings file contains no OpenCode secret.
- Keep these security limits clear: OpenCode credentials do enter the child-process environment, and the upstream CLI may update a provider's own sign-in files during normal use.
- Parse pasted browser requests without executing them. Keep only the allowed cookies, headers, and URL fields. Never include real credentials or copied requests in logs, tests, or screenshots.

## Tests and checks

- Run the Windows tests with `swift test --no-parallel -Xswiftc -warnings-as-errors`. Running tests one at a time avoids scheduling problems with blocking test helpers; tests of concurrent behavior still start their own concurrent tasks.
- Focus a suite when needed: `swift test --no-parallel --filter WindowsBrowserCredentialParserTests`.
- Run `make check` for repository formatting and lint, and `make test` for the upstream test suite. These commands need Bash and the upstream development tools; use the SwiftPM command above for native Windows tests.
- Use the repository's pinned formatter through `Scripts/lint.sh`; Apple's `swift format` is not a substitute for the repository SwiftFormat rules.
- Keep routine tests offline. Live tests may access real accounts, browsers, or Keychain; run them only with the account owner's explicit permission.
- To test real provider connections, set `CODEXBAR_LIVE_PROVIDER_TESTS=1`, then run `swift test --filter WindowsConfiguredProviderLiveTests`.
- To test installing the bundled tools into WSL, set `CODEXBAR_LIVE_WSL_PROVISION_TESTS=1` and supply the target distribution and Linux home in `CODEXBAR_LIVE_WSL_DISTRIBUTION` and `CODEXBAR_LIVE_WSL_HOME`. Run `swift test --filter WindowsBundledWSLCLIProvisionerTests.provisionsLiveWSLPayload`.
- CI runs tests on both x64 and ARM64 machines. Building ARM64 code on an x64 PC does not prove that it runs correctly on ARM64.
- For visual checks, record which executable you tested and capture only the app window. Use separate test data where possible. State whether you tested only the interface or also contacted real providers.

## Packaging

- Use the [Release artifacts workflow](https://github.com/hinneslung/CodexBar-for-Windows/actions/workflows/release-cli.yml) to build the Windows app and matching Linux tools for both x64 and ARM64.
- Running this workflow manually produces downloadable files without publishing a release. Choose the branch to build separately: the optional tag field only changes the output names.
- Local release build: `swift build -c release --product CodexBar -Xswiftc -warnings-as-errors`.
- Build a portable archive with `Scripts/package_windows_release.ps1`:
  - Required inputs: `AppBinDirectory`, `CLIArchive`, `StagingLauncher`, `SafeRefName`, `AssetArchitecture`, and `OutputDirectory`.
  - Use the static Linux-musl CLI and launcher built from the same source version, with their checksums. Do not substitute a CLI installed elsewhere in WSL.
  - `AssetArchitecture` is `x86_64` or `arm64`; follow the workflow for runtime-library resolution.
- Build an installer from the verified archive with `Scripts/package_windows_installer.ps1`:
  - Required inputs: `Archive`, `AssetArchitecture`, `SafeRefName`, and `OutputDirectory`.
  - Obtain the pinned compiler with `Scripts/install_inno_setup.ps1` and pass its path as `CompilerPath`.
  - The script refuses to overwrite an existing installer file.
- Packaging checks the file layout, checksums, version files, required libraries, and CPU architecture of both Windows and Linux executables.
- Release jobs run on each architecture and test app startup, installation, upgrade, and uninstall. They also compare the installed files with the package and check that settings and startup preferences survive where intended.
- Follow the [release checklist](windows-fork.md#builds-and-releases) before publishing. The upstream macOS signing, Sparkle, and Homebrew instructions do not apply to Windows releases.
