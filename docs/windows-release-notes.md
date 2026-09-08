# CodexBar for Windows v0.56.8-windows.1

First Windows-fork release, based on upstream CodexBar v0.56.8.

- Native Windows tray app for Intel/AMD x64 and ARM64, with provider usage, credits, reset times,
  credential-source labels, provider search, and configurable startup and refresh behavior.
- Provider requests use the unchanged upstream CodexBar CLI in WSL. Configure supported manual
  credentials in Settings, or use compatible existing provider app/CLI and OpenCode credentials.
- Per-user EXE installers and portable ZIPs include the matching CLI, staging launcher, and runtime
  libraries. Upgrades and uninstall preserve your application settings and credentials.

## Download and install

- Intel/AMD Windows: `CodexBar-v0.56.8-windows.1-windows-x86_64-setup.exe`.
- Windows on ARM: `CodexBar-v0.56.8-windows.1-windows-arm64-setup.exe`.
- Portable packages use the same names without `-setup.exe`, ending in `.zip` instead.

Requires Windows 10/11 and WSL2 with a configured distribution and non-root default user.
Install the EXE and open CodexBar from the Start menu, or extract the entire portable ZIP and run
`CodexBar.exe`. Enable and configure providers in Settings. See the
[Windows guide](https://github.com/hinneslung/CodexBar/blob/v0.56.8-windows.1/docs/windows.md).

## Limitations

- Downloads are unsigned. Windows may display an unknown-publisher or reputation warning.
  SHA-256 checksum files accompany the downloads.
- Provider support varies; some upstream integrations remain unavailable on Windows. Browser
  sessions can expire and require a fresh capture. A displayed credential method is not proof that
  an account is connected.
- Offline UI and native installer tests do not verify live authentication for every provider.
- This is the Windows fork, not an upstream macOS release. It does not update Sparkle or Homebrew.
