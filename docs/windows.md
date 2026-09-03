# Windows

CodexBar for Windows is a notification-area application with a compact popup. Release archives
contain `CodexBar.exe`, its Swift runtime and resources, and the unchanged upstream Linux `codexbar`
CLI used inside WSL as the provider engine.

The Overview shows every enabled provider in configured order. Click a row for all quota windows,
balance, account, reset, and source details. Settings provides one global used/left toggle, the full
upstream provider catalog, provider ordering, and an Automatic or explicit WSL-distribution source.

Click the notification-area icon to show or hide the popup. Clicking elsewhere hides it. Use
**Ctrl+R** to refresh and **Escape** to go back or hide it. CodexBar refreshes every five minutes and
keeps the last successful reading visible when a later refresh fails.

For an offline UI smoke test, set `CODEXBAR_WINDOWS_OFFLINE=1` before starting the application. This
prevents WSL launches, credential reads, and provider requests.

## Build and run

Install Swift 6.2 or newer for Windows and the Microsoft C++ build tools required by Swift, then run:

```powershell
swift build --product CodexBar
swift test
Start-Process .\.build\x86_64-unknown-windows-msvc\debug\CodexBar.exe
```

The application remains in the notification area after the popup is hidden.

To prove both release architectures compile, use the target triples explicitly:

```powershell
swift build -c release --product CodexBar --triple x86_64-unknown-windows-msvc
swift build -c release --product CodexBar --triple aarch64-unknown-windows-msvc
```

The ARM64 command needs the ARM64 MSVC tools and the ARM64 libraries from the Windows Swift SDK. An
ARM64 executable built on x64 can be inspected there, but must be run on an ARM64 Windows machine.

## Release archives

GitHub Releases provides two self-contained archives:

- `CodexBar-v<tag>-windows-x86_64.zip` for x64 Windows.
- `CodexBar-v<tag>-windows-arm64.zip` for ARM64 Windows.

Extract the complete directory and start `CodexBar.exe`. Keep its DLL, resource, and `wsl-cli`
folders beside the executable. The release workflow builds each archive on the matching Windows
architecture, verifies its PE machine and GUI subsystem, requires the app-local Swift and Microsoft
runtime DLLs, and smoke-starts the packaged application before publishing it. These ZIPs are currently
unsigned because this repository has no configured Windows signing identity; Windows may therefore
show its downloaded-app reputation warning.

## Provider engine

The Windows catalog mirrors all current upstream provider IDs. Only Codex and Claude are enabled
initially; this is presentation policy, not special provider handling.

For every enabled provider the app discovers the canonical `codexbar` executable in the selected WSL
distribution and invokes it directly as:

```text
wsl.exe -d <distribution> -- <codexbar-path> usage --provider <cli-name> --json-only
```

The Windows catalog keeps stable provider IDs for configuration and payload matching, while a small
declarative map supplies the upstream CLI spelling where it differs (for example `qwencloud` uses
`qwen-cloud`). No provider-specific execution branch is involved.

Automatic searches registered WSL2 distributions in stable order. An explicit WSL distro limits the
provider to that distribution. Within a distribution, discovery first checks `PATH` and standard
system, Linuxbrew, and user-local binary directories. There is no user-supplied CLI path and no
Windows CodexBar CLI backend. Provider commands such as `codex` and `claude` never receive CodexBar
CLI arguments.

Release users do **not** need to install the CodexBar CLI in WSL manually. Each Windows archive
carries the matching static Linux CLI built from the same release tag. When no user-installed
`codexbar` is found, the app copies that payload to
`~/.local/share/codexbar-windows/<version>/` for the selected non-root WSL user and invokes its exact
path. Packaging verifies the Linux CLI archive's workflow-produced SHA-256 checksum. The installation
uses direct hidden WSL commands, validates the CLI and release-matched staging launcher, and does not
add anything to `PATH`. Ordinary Automatic refresh searches existing CLIs across every candidate
distribution before provisioning the bundled payload. Manual and OpenCode-isolated routes first use
that policy to choose the distribution, then require the matching bundled CLI and launcher within it.
Plain `swift build` developer output does not stage these release payloads, so a development run still
needs an existing WSL CLI for Automatic usage and a complete `wsl-cli` directory beside
`CodexBar.exe` for Manual or OpenCode-isolated usage.

All child processes use Windows' no-window creation flag, bounded output, and a timeout. Provider
errors are reduced to display-safe messages. The upstream CLI remains unchanged and continues to own
provider fetching and its normal OAuth, API-key, cookie, CLI, and local-file discovery behavior.

The manual editor is driven by one pinned Windows credential catalog. It exposes verified API-key
routes, the browser-session routes listed below, and required companion fields such as Azure OpenAI
endpoint and deployment, proxy base URLs, and xAI team ID. Unsupported or unverified routes do not
receive a field. Provider-specific fetching remains in the unchanged upstream CLI; Windows keeps
only declarative input, validation, and staging metadata.

## Manual browser sessions

Windows does not inspect browser databases. For a supported provider, select **Browser session** in
its settings page and follow the Chrome-specific instructions shown there. Press F12, open **Network**,
reload the page, and select a request that shows **Cookie** under **Headers > Request Headers**. Either
right-click **Cookie > Copy value**, or right-click the request and choose
**Copy > Copy as cURL (bash)**. Chrome's **Copy as cURL (cmd)** form is not accepted. The editor
validates the paste locally and displays only a hidden-value marker after saving.

| Provider | Accepted manual input |
|---|---|
| Alibaba Token Plan | Cookie value or Chrome Copy as cURL (bash) |
| Amp | Cookie value or Chrome Copy as cURL (bash) |
| Command Code | Cookie value or Chrome Copy as cURL (bash) |
| Cursor | Cookie value or Chrome Copy as cURL (bash) |
| Grok | Cookie value or Chrome Copy as cURL (bash) |
| OpenCode Go | Cookie value or Chrome Copy as cURL (bash) |
| Qwen Cloud | Cookie value or Chrome Copy as cURL (bash) |
| Sakana AI | Cookie value or Chrome Copy as cURL (bash) |
| Ollama | Cookie value, Chrome Copy as cURL (bash), or supported session value |
| Qoder | Cookie value or full Chrome Copy as cURL (bash) |
| LongCat | Cookie value or Chrome Copy as cURL (bash) |
| Manus | Cookie value or Chrome Copy as cURL (bash) |
| Xiaomi MiMo | Cookie value or Chrome Copy as cURL (bash) |
| Mistral | Cookie value or Chrome Copy as cURL (bash) |
| OpenCode | Cookie value or Chrome Copy as cURL (bash) |
| Perplexity | Cookie value or Chrome Copy as cURL (bash) |
| T3 Chat | Cookie value or Chrome Copy as cURL (bash) |
| Notion AI | Cookie value or Chrome Copy as cURL (bash) |
| ZoomMate | Full Chrome Copy as cURL (bash), including the Authorization header |

StepFun uses a separate **Session token** method. Paste the Oasis-Token value itself; it is not a
browser Cookie/cURL field.

Cookie-only routes discard the URL and unrelated request headers before protection. Full-request
routes retain only one allowlisted HTTPS URL and the small provider-specific header set the upstream
fetcher consumes, including Cookie or Authorization only where that route requires it. Pasted cURL is
parsed as data and is never executed; shell
operators, request bodies, file references, proxies, output paths, multiple URLs, and unknown hosts
are rejected.

Browser sessions can grant account access and may expire. Replace or clear them from the same
provider page. Abacus AI, Devin, Windsurf, and Zed are labelled **Unavailable on Windows** because
their unchanged Linux implementation cannot complete a supported route. The app does not add a
provider-specific Windows fetcher to bypass that limitation. GitHub Copilot's optional browser-budget
enrichment remains outside the manual catalog; its existing API/OpenCode routes are unchanged.

## Credentials

CodexBar does not write, refresh, or alter imported provider, OpenCode, or upstream CodexBar files.
`%LOCALAPPDATA%\CodexBar\config.json` remains secret-free. Each complete manual credential set is
instead stored as current-user DPAPI ciphertext at
`%LOCALAPPDATA%\CodexBar\Credentials\<provider-id>.bin`, under a current-user and SYSTEM-only DACL.
Another process running as that same user can still request DPAPI decryption.

Manual values do not belong to a WSL distribution. For each request the app resolves the WSL
distribution normally, decrypts only that provider, and streams a minimal upstream-compatible config
through anonymous stdin to the bundled staging launcher. The launcher holds it in a private anonymous
Linux descriptor, sets `CODEXBAR_CONFIG` only for the unchanged bundled CLI lifetime, and leaves no
named plaintext config. Secrets never enter argv, Windows or WSL config files, `WSLENV`, logs, or UI
messages. Refresh and Save/Clear share a user-scoped per-provider operation lock; credential changes
cancel an in-process refresh and stale results are discarded.

Codex and Claude normally work directly because the upstream CLI runs in the same WSL home as their
installed tools. For compatible OpenCode accounts, the Windows app reads only the selected WSL
user's standard `~/.local/share/opencode/auth.json` and projects the requested provider's credential
into that one isolated `codexbar` child process. The minimal staged config contains no OpenCode
secret, but prevents the user's normal upstream config from silently overriding the projected
credential. Nothing is persisted and credential values are never placed in UI messages or logs.
Imported API keys and OAuth tokens remain ephemeral.

Resolution is deterministic: a valid manual provider file wins and fails closed; otherwise a
compatible OpenCode mapping wins and fails closed; otherwise the app performs ordinary Automatic
upstream discovery. The app does not read OpenCode `auth.json` when a manual file is present.

The bridge is declarative. API-key records currently cover:

- ai&, Alibaba Coding Plan, Chutes, ClinePass, Crof, DeepInfra, DeepSeek, Fireworks, Kilo, Kimi,
  MiniMax, Moonshot, Ollama Cloud, OpenCode Go, OpenRouter, Poe, Synthetic, Venice, and z.ai.
- GitHub Copilot and Poe are the only mappings that explicitly permit an OpenCode OAuth access token.

Moonshot and z.ai aliases project their supported region variables. The Alibaba CN and MiniMax CN
aliases are intentionally not projected: CodexBar 0.54.1 exposes their region only through its own
configuration, not an environment variable, so silently using a global endpoint would be unsafe.

An OpenCode credential helps only when upstream CodexBar supports that provider and accepts the
corresponding credential kind. Inference keys are not substituted for unrelated management,
organization, browser-session, or admin-usage credentials.

WSL distribution metadata comes from the current user's registry. The selected non-root default home
is resolved from that distribution's `/etc/passwd` through `\\wsl.localhost`; other users and root are
not scanned.

## Presentation rules

- Reset labels use a relative duration below 24 hours, local weekday and time within seven days, and
  local date and time after that. The redundant word “Resets” and timezone suffixes are omitted.
- Providers without a known allocation do not get an invented progress bar. Poe shows its available
  point balance and always labels it as left, even when percentage mode is set to used.
- The notification-area tooltip mirrors enabled Overview rows in order and is truncated only at whole
  provider lines to fit Windows' tooltip limit.
- A provider settings page shows an error only after that source was applied and its refresh failed.

## Verification

Offline tests use fictitious credentials and deterministic payloads. A deliberate live check can use:

```powershell
$env:CODEXBAR_LIVE_PROVIDER_TESTS = '1'
swift test --filter WindowsConfiguredProviderLiveTests
```

This runs the enabled providers through the same hidden WSL execution path as the application.

The opt-in bundled-CLI installation check uses a disposable app-owned version directory and removes
it after execution:

```powershell
$env:CODEXBAR_LIVE_WSL_PROVISION_TESTS = '1'
$env:CODEXBAR_LIVE_WSL_DISTRIBUTION = 'Ubuntu'
$env:CODEXBAR_LIVE_WSL_HOME = '/home/example'
swift test --filter WindowsBundledWSLCLIProvisionerTests.provisionsLiveWSLPayload
```
