# Windows development

- [User setup](windows.md) · [Branch and release process](windows-fork.md) · [README](../README.md)

## Build and run

- Match Windows CI: Swift **6.3.3**, Microsoft C++ build tools, and the Windows SDK required by Swift. See [Swift's Windows installation guide](https://www.swift.org/install/windows/).
- Clone the Windows integration branch:

  ```powershell
  git clone --branch windows-native-app https://github.com/hinneslung/CodexBar-for-Windows.git
  cd CodexBar-for-Windows
  swift build --product CodexBar -Xswiftc -warnings-as-errors
  swift test --no-parallel -Xswiftc -warnings-as-errors
  ```

- Launch from SwiftPM's native output directory:

  ```powershell
  $binDirectory = (swift build --product CodexBar --show-bin-path).Trim()
  Start-Process (Join-Path $binDirectory 'CodexBar.exe') -WindowStyle Hidden
  ```

- `swift build` does not assemble the bundled Linux payload. Automatic routes need an existing WSL CLI or a complete matching `wsl-cli` directory beside the app; manual, OpenCode, and diagnostic routes require the bundled payload.
- For UI-only work, set `CODEXBAR_WINDOWS_OFFLINE=1` before launch to prevent provider requests, WSL launches, and credential reads. Use `CODEXBAR_WINDOWS_SHOW_ON_START=1` to open the popup at launch. Remove these variables before normal runtime testing.
- Avoid starting a second tray instance unintentionally; identify the executable already running before testing a new build.

## Build directories

- Default x64 debug app: `.build/x86_64-unknown-windows-msvc/debug/CodexBar.exe`.
- Native ARM64 output: `.build/aarch64-unknown-windows-msvc/debug/CodexBar.exe`.
- Bundled runtime input: `wsl-cli/` beside the app, with the matching CLI, staging launcher, VERSION, and checksums from a release package.
- Local release inputs: `.build/windows/release-inputs/<architecture>/<version>/`.
- Local release outputs: `.build/windows/releases/<version>/<architecture>/`.
- Temporary test scratch and QA: `%TEMP%/CodexBar/swiftpm/` and `%TEMP%/CodexBar/qa/`.
- Do not create feature-, date-, or agent-named directories under `.build`. Follow the local `.build/README.md` when present.

## Runtime and source ownership

- `Sources/CodexBarWindows/`: native Windows UI, configuration, credential protection, discovery, process runner, and payload decoding.
- `Sources/CodexBarLinuxStagingLauncher/`: bounded Linux helper for temporary configuration transport.
- `Sources/CodexBarCLI/` and `Sources/CodexBarCore/`: upstream provider implementation; do not duplicate fetching logic in Windows.
- `WindowsProviderCatalog`: stable provider IDs and display names.
- `WindowsProviderConfigurationCatalog`: manual fields, validation, supported source metadata, capture instructions, and execution mode.
- `WindowsProviderCredentialBridge`: supported OpenCode connection mappings.
- `WindowsProviderSourcePresentation`: distro-first source formatting and capability summaries; a supported method is not a connected credential.
- Windows metadata is maintained against the bundled upstream revision; it is not dynamically discovered from the CLI. Recheck it during rebases.

### CLI selection and commands

- Automatic distro selection searches registered WSL2 distributions in stable order for an existing CLI before provisioning a bundled one. An explicit distro restricts selection to that distro.
- Bundled payloads are provisioned under `~/.local/share/codexbar-windows/<version>/` for the selected non-root Linux user, without adding them to `PATH`.
- Manual, OpenCode, and Automatic diagnostic routes first use the ordinary selection policy to choose the distro, then require the bundled CLI within that same distro.
- Normal usage routes invoke `usage --provider <cli-name> --json-only`.
- Catalog-marked diagnostic routes invoke `diagnose --provider <cli-name> --format json --redact`; the decoder checks schema/provider/source and maps supported fields to the Windows snapshot.
- Diagnostic routes may expose less detail than usage routes. Do not promote arbitrary diagnostic text into account, plan, or balance fields.
- Hidden child processes have bounded output and timeouts. Selected transient failures receive one retry; authentication and malformed-payload failures do not become unlimited retries.

### Credential handling

- Manual authority is resolved before OpenCode lookup. An unreadable or invalid saved manual credential is an error, not permission to fall back to another account.
- Manual sets are protected by current-user DPAPI and a user/SYSTEM-only file ACL. Save/Clear and refresh coordinate through a per-provider operation lock and revision checks.
- Manual staging sends a minimal config through anonymous stdin; the Linux launcher uses `memfd_create`, or creates a restricted file and unlinks it before writing credential bytes. `CODEXBAR_CONFIG` points at the temporary descriptor.
- DeepSeek uses the existing upstream token-account config shape with a fresh UUID and empty display label, not a new CLI command or launcher environment-injection protocol.
- OpenCode uses a separate transport: the Windows bridge reads the selected Linux user's auth file and supplies mapped child-process environment variables via `WSLENV`; the isolated staged config itself contains no OpenCode secret.
- Do not describe all credential routes as environment-free. Do not claim upstream Automatic discovery never writes provider-owned authentication state.
- Browser captures are parsed without execution and reduced to the allowed cookie/header/URL fields. Do not log raw credentials or paste captures into test evidence.

## Tests and checks

- Run the native Windows suite: `swift test --no-parallel -Xswiftc -warnings-as-errors`. The flag isolates blocking fixture scheduling; concurrency tests still create their own concurrent tasks.
- Focus a suite when needed: `swift test --no-parallel --filter WindowsBrowserCredentialParserTests`.
- Run repository formatting/lint with `make check` and the upstream sharded suite with `make test` in a supported environment. The Makefile invokes Bash scripts; native Windows testing is the SwiftPM command above.
- Use the repository's pinned formatter through `Scripts/lint.sh`; Apple's `swift format` is not a substitute for the repository SwiftFormat rules.
- Keep ordinary tests offline. Do not enable live flags or trigger browser/keychain access without explicit authorization.
- Opt-in live-provider check: set `CODEXBAR_LIVE_PROVIDER_TESTS=1`, then run `swift test --filter WindowsConfiguredProviderLiveTests`.
- Opt-in provisioning check: set `CODEXBAR_LIVE_WSL_PROVISION_TESTS=1`, `CODEXBAR_LIVE_WSL_DISTRIBUTION`, and `CODEXBAR_LIVE_WSL_HOME`, then run `swift test --filter WindowsBundledWSLCLIProvisionerTests.provisionsLiveWSLPayload`.
- Native CI tests x64 and ARM64 separately. Cross-compiling ARM64 on x64 is a compile check, not ARM64 runtime proof.
- For visual QA, identify the exact executable, use isolated data where appropriate, capture only the app window, and distinguish offline UI checks from live-provider verification.

## Packaging

- Prefer the [Release artifacts workflow](https://github.com/hinneslung/CodexBar-for-Windows/actions/workflows/release-cli.yml) for matching CLI/app outputs on both native architectures.
- Manual dispatch creates downloadable artifacts, not a public release; its tag input labels outputs but does not select the source checkout.
- Local release build: `swift build -c release --product CodexBar -Xswiftc -warnings-as-errors`.
- Build a portable archive with `Scripts/package_windows_release.ps1`:
  - Required inputs: `AppBinDirectory`, `CLIArchive`, `StagingLauncher`, `SafeRefName`, `AssetArchitecture`, and `OutputDirectory`.
  - Use matching static Linux-musl CLI/launcher artifacts and their checksums from the same source/version; do not substitute an unrelated distro CLI.
  - `AssetArchitecture` is `x86_64` or `arm64`; follow the workflow for runtime-library resolution.
- Build an installer from the verified archive with `Scripts/package_windows_installer.ps1`:
  - Required inputs: `Archive`, `AssetArchitecture`, `SafeRefName`, and `OutputDirectory`.
  - Obtain the pinned compiler with `Scripts/install_inno_setup.ps1` and pass its path as `CompilerPath`.
  - Existing installer output is rejected rather than overwritten.
- Packaging verifies checksums, archive layout, Windows PE machines, Linux ELF machines, version markers, and bundled runtimes.
- Native release jobs test packaged startup, installation, upgrade/replacement, uninstall, payload equality, and settings/startup-task preservation on each architecture.
- Follow [release gates](windows-fork.md#builds-and-releases) before publishing. Existing macOS signing, Sparkle, and Homebrew instructions are upstream-only and do not apply to this Windows release.
