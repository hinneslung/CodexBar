# Windows user guide

- [Download](https://github.com/hinneslung/CodexBar-for-Windows/releases/latest) · [README](../README.md) · [Developer guide](windows-development.md)
- **WSL2 is required for provider requests.** The native Windows app uses the original, unchanged CodexBar CLI inside WSL. Installers and portable ZIPs include the matching CLI and runtime libraries.

## Set up WSL2

1. Follow [Microsoft's WSL installation instructions](https://learn.microsoft.com/windows/wsl/install).
2. Open the distribution once and finish creating its Linux user account. Use a non-root default user.
3. In PowerShell, run `wsl --list --verbose` and confirm that the distribution shows version `2`.
4. If you already use a provider's app/CLI or OpenCode, sign in within the distribution you want CodexBar to use. A Windows-only sign-in is not automatically available inside WSL.

- CodexBar Setup can run before WSL is configured, but provider requests cannot work until WSL2 is ready.
- Setup checks for the WSL command and links to Microsoft's guide; it does not install or initialize a distribution.
- You do not need to install CodexBar CLI separately in WSL.

## Install, upgrade, or uninstall

- Download from [GitHub Releases](https://github.com/hinneslung/CodexBar-for-Windows/releases/latest):
  - Intel/AMD x64: the asset ending in `windows-x86_64-setup.exe`.
  - ARM64: the asset ending in `windows-arm64-setup.exe`.
  - Portable: the corresponding `windows-x86_64.zip` or `windows-arm64.zip`.
- Installers install per user at `%LOCALAPPDATA%\Programs\CodexBar`, without requesting administrator access. Open the app from the Start menu.
- For portable use, extract the entire ZIP. Keep the DLLs, resources, and `wsl-cli` folder beside `CodexBar.exe`.
- Downloads are unsigned. Check the matching `.sha256` file before running an installer or portable app:

  ```powershell
  Get-FileHash .\CodexBar-v0.56.8-windows.1-windows-x86_64-setup.exe -Algorithm SHA256
  ```

- Compare the hash with the same asset's `.sha256` file on the release page. A matching checksum verifies file integrity, not publisher identity.
- Upgrade an installed copy by running the newer installer. Setup can close the installed app if needed.
- To uninstall, quit CodexBar from its notification-area menu, then use Windows Settings → Apps.
- Upgrades and uninstall preserve settings and saved credentials in `%LOCALAPPDATA%\CodexBar`, user-added files, and WSL data. Use **Clear** in a provider's settings to remove its saved manual credential before uninstalling if desired.
- For unreleased builds only: [Actions artifacts](https://github.com/hinneslung/CodexBar-for-Windows/actions/workflows/release-cli.yml) are wrapped in a ZIP by GitHub. Extract that wrapper to get the installer EXE or portable ZIP and checksum.

## Use the app

- Click the notification-area icon to open or hide the popup. Check the hidden-icons area if it is not visible on the taskbar.
- Open Settings to enable providers, reorder them, choose used/remaining percentages, set a refresh interval, or enable **Run at startup**.
- Search below the enabled providers to filter the disabled list. Disabled providers are alphabetical; newly disabled entries stay at the top.
- Click a provider for the details it exposes, such as quota windows, balance, reset times, and source.
- Use **Ctrl+R** or the refresh icon to refresh; use **Escape** to go back or hide the popup.
- The default refresh interval is five minutes. A later error can leave the last successful reading visible; check its age and error status.

## Credential methods

- Open a provider's settings to choose **WSL distro** and **Credentials**.
- **WSL distro → Automatic** searches registered WSL2 distributions; choosing a name restricts that provider to that distribution.
- **Credentials → Automatic** uses a compatible OpenCode connection when available, otherwise upstream CLI discovery. Existing CodexBar CLI configuration can also supply credentials. Automatic is not a login flow or a guarantee that credentials exist.
- **Provider app/CLI** in the provider list means an existing provider tool, sign-in file, or local service can supply a source. It is used through Automatic, not offered as a separate manual choice.
- **OpenCode** in the provider list means a compatible connection can be read from the selected Linux user's `~/.local/share/opencode/auth.json`. Windows OpenCode files are not used by this integration.
- **API key** accepts the provider's supported usage credential, which may differ from an inference key. Fill in any additional fields shown by the app.
- **Browser session** accepts the cookie/cURL formats described in the provider's **How to obtain this** instructions.
- **Session token** is StepFun's separate manual method; see below.
- Choose a manual method, paste the value, and select **Apply**. Saved secrets are hidden. Paste a replacement and Apply again, or select **Clear** to remove the saved credential.
- Saved manual credentials take precedence over OpenCode and Automatic discovery. If a manual credential or selected OpenCode connection fails, the app reports the error rather than silently trying another credential source.
- Capability labels describe available methods, not connected accounts. Enabled rows show the distro first, then the source; a retained reading can retain its last successful source label.

### Providers by credential method

- These lists describe the Windows GUI catalog; a provider may appear in more than one group. They are not a claim that every account or plan has been live-tested.
- **Provider app/CLI:** Amp, Antigravity, Augment, AWS Bedrock, Claude, Codebuff, Codex, Doubao, Droid (Factory), Gemini, Grok, JetBrains AI, Kilo, Kimi, Kiro, Vertex AI, Wayfinder.
- **OpenCode:** ai&, Alibaba Coding Plan, Chutes, ClinePass, Copilot, Crof, DeepInfra, DeepSeek, Fireworks, Kilo, Kimi, MiniMax, Moonshot, Ollama, OpenCode Go, OpenRouter, Poe, Synthetic, Venice, z.ai.
  - Copilot accepts a compatible OAuth access token; Poe accepts a compatible API key or OAuth access token. Other listed mappings accept API-key records.
  - A provider connection must use the credential type and account/region expected by the upstream CLI; not every OpenCode connection is compatible.
- **API key:** ai&, Alibaba Coding Plan, Amp, Azure OpenAI, Chutes, Claude, ClawRouter, ClinePass, Codebuff, Copilot, Crof, Deepgram, DeepInfra, DeepSeek, Doubao, Droid (Factory), ElevenLabs, Fireworks, GroqCloud, IBM Bob, Kilo, Kimi, LiteLLM, LLM Proxy, MiniMax, Moonshot, Neuralwatt, Ollama, OpenAI, OpenCode Go, OpenRouter, Poe, Sub2API, Synthetic, Venice, Warp, xAI, z.ai, ZenMux.
  - MiniMax requires a Coding Plan key beginning with `sk-cp-`, not a general `sk-api-` key.
  - Some providers require an endpoint, region, workspace, deployment, or team identifier; use the fields and instructions shown for that provider.
- **Browser session:** Alibaba Token Plan, Amp, Command Code, Cursor, Grok, LongCat, Manus, Mistral, Notion AI, Ollama, OpenCode, OpenCode Go, Perplexity, Qoder, Qwen Cloud, Sakana AI, T3 Chat, Xiaomi MiMo, ZoomMate.
- **Session token:** StepFun.
- **Unavailable on Windows:**
  - Abacus AI: the upstream integration is macOS-only.
  - Devin: the unchanged Linux CLI has no supported configuration route for its credentials.
  - Windsurf: the upstream integration depends on macOS browser/local app data.
  - Zed: the upstream integration reads macOS Keychain.
  - These providers have no enable checkbox or editable configuration. Their pages explain the limitation and link to upstream notes.

## Browser sessions

1. Select **Browser session**, then expand **How to obtain this** for the provider-specific site and request.
2. Sign in to that site in Chrome. Press **F12**, open **Network**, and reload the page.
3. Select the request described by the app, then use the format it asks for:
   - Cookie value: under **Headers → Request Headers**, right-click **Cookie → Copy value**.
   - cURL: right-click the request → **Copy → Copy as cURL (bash)**. Do not choose **cURL (cmd)**.
4. Paste into CodexBar, fill any required companion fields, and select **Apply**.

- Most browser-session providers accept a Cookie value or cURL (bash); the app checks required cookies and supported request hosts.
- **ZoomMate** requires the full cURL capture, including its Authorization header; a Cookie value alone is insufficient.
- **Qoder** also accepts a full cURL capture to retain the request URL used for regional routing.
- **Ollama** additionally accepts a supported session-cookie value without its name.
- **StepFun:** choose **Session token**, not Browser session. Follow the app's instructions for a Step Plan usage request; paste the Cookie value containing `Oasis-Token=…` or only the value after `Oasis-Token=`. Do not paste cURL into this field.
- Treat browser-session values like passwords. They can grant account access and may expire when you sign out. Do not post cookies or cURL captures in issues.

## Storage and security

- General settings: `%LOCALAPPDATA%\CodexBar\config.json`; manually entered secret fields are stored separately.
- Saved manual credentials: `%LOCALAPPDATA%\CodexBar\Credentials\<provider-id>.bin`, encrypted with Windows DPAPI for the current user and restricted to that user and SYSTEM.
- Other software running as the same Windows user may decrypt those credentials. This is not protection against a compromised account.
- Manual values are stored on Windows, not assigned permanently to a WSL distro. Each request passes temporary configuration to the CLI without leaving a named plaintext configuration file.
- Pasted cURL is parsed as data, never executed as a shell command. The Windows manual editor does not extract cookies from Windows browser databases.
- The Windows OpenCode integration reads the selected user's auth file without rewriting it; it passes matching credentials to the child process for the request. Upstream CLI discovery has its own provider-specific behavior.
- Provider requests send the credentials needed for authentication to the configured provider or service. Do not share saved credential files or raw captures.

## Troubleshooting

- **WSL or CLI unavailable:** run `wsl --list --verbose`, confirm version 2, and open the selected distribution to finish its setup. Use its non-root default user.
- **Automatic fails:** confirm the provider tool or OpenCode is signed in within the selected distribution. If supported, select a manual credential method instead.
- **Saved manual credential fails:** replace or Clear it; it takes precedence over Automatic. Check key type, region, and companion fields.
- **OpenCode sign-in expired:** reconnect that provider in OpenCode within the selected distribution, then refresh.
- **Browser capture rejected:** use the provider's request instructions and cURL (bash), not cURL (cmd). Copy a fresh request after signing in; do not paste the response body.
- **Old values remain after an error:** they are the last successful reading, not confirmation that the latest request succeeded.
- **Installer will not uninstall:** quit the installed CodexBar copy from its notification-area menu and retry.
- **Report a problem:** open a [fork issue](https://github.com/hinneslung/CodexBar-for-Windows/issues) with the app version, Windows architecture, WSL distro/version, provider, credential-method label, and display-safe error. Remove account identifiers from screenshots; never include API keys, cookies, raw cURL, or auth files.
