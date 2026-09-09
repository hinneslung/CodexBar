# Windows user guide

- [Download](https://github.com/hinneslung/CodexBar-for-Windows/releases/latest) · [README](../README.md) · [Developer guide](windows-development.md)
- **Windows Subsystem for Linux 2 (WSL2) is required to load usage.** CodexBar has a Windows interface, but uses the original CodexBar command-line tool inside Linux to contact your providers. That tool is included in the download; you do not need to install it separately.

## Set up WSL2

1. Follow [Microsoft's WSL installation instructions](https://learn.microsoft.com/windows/wsl/install).
2. Open your Linux distribution, such as Ubuntu, and finish creating a user account. Use this account to run WSL, rather than the Linux administrator account (`root`).
3. In PowerShell, run `wsl --list --verbose` and confirm that the distribution shows version `2`.
4. If you want CodexBar to use a sign-in from a provider's tool or OpenCode, sign in to that tool inside the same Linux distribution. Signing in only on Windows is not enough.

- You can install CodexBar before setting up WSL, but it cannot load usage until WSL2 is ready.
- The installer links to Microsoft's guide if WSL is missing. You must install and finish setting up the Linux distribution yourself.
- You do not need to install CodexBar CLI separately in WSL.

## Install, upgrade, or uninstall

- Download from [GitHub Releases](https://github.com/hinneslung/CodexBar-for-Windows/releases/latest):
  - Intel/AMD x64: the file ending in `windows-x86_64-setup.exe`.
  - Windows on ARM: the file ending in `windows-arm64-setup.exe`.
  - Portable: the corresponding `windows-x86_64.zip` or `windows-arm64.zip`.
- The installer puts CodexBar in `%LOCALAPPDATA%\Programs\CodexBar` for your Windows account. No administrator permission is needed. Open the app from the Start menu.
- For portable use, extract the entire ZIP. Keep the DLLs, resources, and `wsl-cli` folder beside `CodexBar.exe`.
- Downloads are unsigned, so Windows may warn about an unknown publisher. To check that a download is intact, open PowerShell in your download folder and run this command with your file's name:

  ```powershell
  Get-FileHash .\CodexBar-v0.56.8-windows.1-windows-x86_64-setup.exe -Algorithm SHA256
  ```

- Download the `.sha256` file with the same name from the release page and open it in a text editor. Its long code should match the **Hash** shown by PowerShell. This checks for a damaged or changed download; it does not verify who published it.
- Upgrade an installed copy by running the newer installer. Setup can close the installed app if needed.
- To uninstall, quit CodexBar from its notification-area menu, then use Windows Settings → Apps.
- Updating or uninstalling leaves your settings and saved keys in `%LOCALAPPDATA%\CodexBar`, and does not remove your WSL data. To remove a key or browser session, click **Clear** in that provider's settings before uninstalling.
- If you download a test build from [GitHub Actions](https://github.com/hinneslung/CodexBar-for-Windows/actions/workflows/release-cli.yml), GitHub adds an outer ZIP. Extract it to find the installer or portable package and its checksum.

## Use the app

- Click the CodexBar icon near the Windows clock to open or hide the app. If you cannot see it, check the hidden-icons arrow.
- In Settings, choose the providers you want to track and their order. You can also show usage as an amount used or remaining, change how often the app refreshes, and turn on **Run at startup**.
- Use search to find a provider. Providers you are not tracking appear alphabetically; when you uncheck one, it moves to the top so you can find it again easily.
- Click a provider to see its usage, balance, quota reset times, and sign-in method. The details available vary by provider.
- Use **Ctrl+R** or the refresh icon to refresh; use **Escape** to go back or hide the popup.
- The app refreshes every five minutes by default. If a refresh fails, it may still show the previous reading alongside an error. Check the update time to see how old the numbers are.

## Credential methods

- Open a provider's settings. **WSL distro** chooses which Linux distribution to use; **Credentials** chooses how to connect your account.
- Leave **WSL distro** on **Automatic** to let CodexBar find a suitable installed distribution. Choose a name if your sign-in is in a particular distribution.
- The labels under a provider's name tell you which connection methods it supports. They do not mean you are already signed in.
- **Provider app/CLI:** use the provider's own app or command-line tool in WSL to sign in or start its service. Then choose **Automatic** in CodexBar. The exact setup depends on the provider.
- **OpenCode:** connect the provider in OpenCode inside WSL, then choose **Automatic** in CodexBar. Connections saved by OpenCode on Windows are not used.
- **Automatic** checks for a supported OpenCode connection first. Otherwise, it looks for sign-ins or settings the CodexBar CLI can already use, including its existing configuration. It does not open a sign-in page or create an account for you.
- **API key:** select this option and paste your key. Some providers need a special key for checking usage rather than the key you use to send AI requests. Follow the instructions and fill in any other fields shown.
- **Browser session:** select this option to use your browser sign-in. Open **How to obtain this** and follow the steps to copy the required cookie or cURL request.
- **Session token:** StepFun uses this option instead of Browser session. See the [StepFun instructions](#browser-sessions).
- After pasting a key, cookie, or token, click **Apply**. The saved value is hidden. To replace it, paste a new value and click **Apply** again; to remove it, click **Clear**.
- A value you save in CodexBar is used instead of OpenCode or an existing sign-in. If it fails, replace it or click **Clear** before trying Automatic again. An expired OpenCode connection also needs to be reconnected or replaced; the app will not silently switch accounts.
- After usage loads, **Source** shows the Linux distribution followed by the method that worked, such as `Ubuntu · API key`. If a refresh fails, the previous reading keeps its previous source label.

### Providers by credential method

- Find your provider below to see how you can connect it. A provider may support several methods. Support can depend on your account or plan; not every plan has been tested.
- **Provider app/CLI:** Amp, Antigravity, Augment, AWS Bedrock, Claude, Codebuff, Codex, Doubao, Droid (Factory), Gemini, Grok, JetBrains AI, Kilo, Kimi, Kiro, Vertex AI, Wayfinder.
- **OpenCode:** ai&, Alibaba Coding Plan, Chutes, ClinePass, Copilot, Crof, DeepInfra, DeepSeek, Fireworks, Kilo, Kimi, MiniMax, Moonshot, Ollama, OpenCode Go, OpenRouter, Poe, Synthetic, Venice, z.ai.
  - For Copilot, use an OpenCode sign-in connection. For Poe, a sign-in connection or API key can work. The other providers listed here require an API key saved in OpenCode.
  - A working OpenCode connection does not always support usage checks. CodexBar also needs the correct key type, account, and region for that provider.
- **API key:** ai&, Alibaba Coding Plan, Amp, Azure OpenAI, Chutes, Claude, ClawRouter, ClinePass, Codebuff, Copilot, Crof, Deepgram, DeepInfra, DeepSeek, Doubao, Droid (Factory), ElevenLabs, Fireworks, GroqCloud, IBM Bob, Kilo, Kimi, LiteLLM, LLM Proxy, MiniMax, Moonshot, Neuralwatt, Ollama, OpenAI, OpenCode Go, OpenRouter, Poe, Sub2API, Synthetic, Venice, Warp, xAI, z.ai, ZenMux.
  - MiniMax requires a Coding Plan key beginning with `sk-cp-`, not a general `sk-api-` key.
  - If the app asks for an API address, region, workspace, deployment, or team ID, follow the instructions beside that field.
- **Browser session:** Alibaba Token Plan, Amp, Command Code, Cursor, Grok, LongCat, Manus, Mistral, Notion AI, Ollama, OpenCode, OpenCode Go, Perplexity, Qoder, Qwen Cloud, Sakana AI, T3 Chat, Xiaomi MiMo, ZoomMate.
- **Session token:** StepFun.
- **Unavailable on Windows:**
  - Abacus AI: CodexBar can only check its usage on macOS.
  - Devin: the Linux version of CodexBar CLI cannot accept the sign-in details it needs.
  - Windsurf: CodexBar needs browser or app data that it can only read on macOS.
  - Zed: CodexBar needs a sign-in saved in macOS Keychain.
  - You cannot turn these providers on in the Windows app. Click their names for an explanation and links to more information.

## Browser sessions

1. Select **Browser session**, then open **How to obtain this**. It tells you which website to visit and which request to copy.
2. Sign in to that site in Chrome. Press **F12**, open **Network**, and reload the page.
3. Select the request described by the app, then use the format it asks for:
   - Cookie value: under **Headers → Request Headers**, right-click **Cookie → Copy value**.
   - cURL: right-click the request → **Copy → Copy as cURL (bash)**. Do not choose **cURL (cmd)**.
4. Paste into CodexBar, fill in any other required fields, and click **Apply**.

- Most providers accept either the Cookie value or cURL (bash). Copy the request named in the instructions, not just any request on the page.
- **ZoomMate** needs the full cURL request because its sign-in details are in the Authorization header, not just a cookie.
- **Qoder** also accepts the full cURL request. This includes the website address, allowing CodexBar to distinguish its regional services.
- **Ollama** also accepts the session cookie's value on its own, without the cookie name.
- **StepFun:** choose **Session token**, not Browser session. Follow the app's instructions for a Step Plan usage request; paste the Cookie value containing `Oasis-Token=…` or only the value after `Oasis-Token=`. Do not paste cURL into this field.
- Treat browser-session values like passwords. They can grant account access and may expire when you sign out. Do not post cookies or cURL captures in issues.

## Storage and security

- App settings are saved in `%LOCALAPPDATA%\CodexBar\config.json`. Keys and browser sessions you enter are stored separately.
- Saved keys and sessions are in `%LOCALAPPDATA%\CodexBar\Credentials\<provider-id>.bin`. Windows encrypts these files for your account and limits file access to you and the Windows system account.
- Malicious software running under your Windows account may still decrypt them. Encryption does not protect a compromised account.
- Your saved values stay on Windows even if you change Linux distributions. The app passes them to the CLI when needed, without keeping a second, unencrypted settings file in WSL.
- Pasting cURL does not run a command. The app only reads the request details it needs. It does not open your Windows browser's cookie database.
- For OpenCode, the app reads `~/.local/share/opencode/auth.json` from your Linux account and passes the matching sign-in details to the CLI. It does not edit that file.
- To check usage, the app sends the required sign-in details to your provider or the service address you configured. Do not share saved credential files or copied browser requests.

## Troubleshooting

- **WSL or CLI unavailable:** run `wsl --list --verbose` in PowerShell and confirm version 2. Open the selected Linux distribution to finish setup, using the user account you created rather than `root`.
- **Automatic fails:** check that you are signed in to the provider's tool or OpenCode inside the selected Linux distribution. If the provider offers another option under **Credentials**, choose it to enter a key or session yourself.
- **Saved key or session fails:** check the key type, region, and any other fields. Paste a replacement and click **Apply**, or click **Clear** to remove it before trying Automatic again.
- **OpenCode sign-in expired:** reconnect that provider in OpenCode within the selected distribution, then refresh.
- **Browser capture rejected:** use the provider's request instructions and cURL (bash), not cURL (cmd). Copy a fresh request after signing in; do not paste the response body.
- **Old values remain after an error:** they are the last successful reading, not confirmation that the latest request succeeded.
- **Cannot uninstall CodexBar:** quit the app from its menu near the Windows clock, then try uninstalling again.
- **Report a problem:** [open an issue](https://github.com/hinneslung/CodexBar-for-Windows/issues). Include your CodexBar version, whether your PC is x64 or ARM64, Linux distribution and WSL version, provider name, the option chosen under **Credentials**, and the error message. Hide email addresses and account IDs in screenshots. Never include API keys, cookies, copied cURL requests, or sign-in files.
