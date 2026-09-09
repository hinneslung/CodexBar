# CodexBar for Windows

- Check your AI service usage, remaining balance, and quota reset times from the Windows taskbar.
- **Requires Windows Subsystem for Linux 2 (WSL2).** The app uses the original [CodexBar command-line tool](https://github.com/steipete/CodexBar) to fetch usage inside Linux. This tool is included; you only need to set up WSL2.
- [Download the latest release](https://github.com/hinneslung/CodexBar-for-Windows/releases/latest) · [User guide](docs/windows.md) · [Report an issue](https://github.com/hinneslung/CodexBar-for-Windows/issues)

![Windows overview showing usage and balances for enabled providers](docs/screenshots/windows-wsl-overview.png)

## For users

### Requirements

- Windows 10/11 on Intel/AMD x64 or ARM64.
- WSL2 with a Linux distribution, such as Ubuntu. Open it once to finish setup and create your Linux user account. Follow [Microsoft's WSL setup guide](https://learn.microsoft.com/windows/wsl/install).
- An account with each AI service you want to track. Some services need an API key or browser sign-in details.

### Install

- Open [Releases](https://github.com/hinneslung/CodexBar-for-Windows/releases/latest):
  - Intel/AMD Windows: choose the installer whose name ends in `windows-x86_64-setup.exe`.
  - Windows on ARM: choose the installer whose name ends in `windows-arm64-setup.exe`.
  - Portable use: download the matching ZIP, extract the whole folder, and run `CodexBar.exe`.
- The installer includes CodexBar and its supporting files. It does not install WSL.
- Downloads are **unsigned**, so Windows may warn that the publisher is unknown. See the [download verification steps](docs/windows.md#install-upgrade-or-uninstall) before running the app.

### First run

1. Open CodexBar from the Start menu or extracted folder. Click its icon near the Windows clock; it may be under the hidden-icons arrow.
2. Open Settings and check the providers you want to track. Use search to find one.
3. Open a provider's settings. Leave **WSL distro** on **Automatic**, or choose your Linux distribution.
4. Under **Credentials**, try **Automatic** if you already signed in through that provider's tool or OpenCode in WSL. If the provider offers another option, such as **API key**, you can choose it to enter the details yourself. Follow the instructions and click **Apply** to save.
5. Refresh to load usage. **Source** shows which Linux distribution and sign-in method worked.

### Credentials and support

- The labels under each provider tell you how you can connect it:
  - **Provider app/CLI:** CodexBar can use a sign-in or service from the provider's own app or command-line tool in WSL. Choose **Automatic** to try it.
  - **OpenCode:** CodexBar can use an account you connected to OpenCode in WSL. Choose **Automatic** to try it.
  - **API key**, **Browser session**, or **Session token:** choose that option in the provider's settings, then paste the requested value.
- **Automatic** checks OpenCode first where supported, then looks for an existing sign-in or CodexBar CLI configuration. You still need to sign in or supply a key yourself.
- If you save a key or browser session in CodexBar, the app uses it instead. If it stops working, replace it or click **Clear** before trying Automatic again.
- See the [credential methods and provider lists](docs/windows.md#credential-methods), [browser capture instructions](docs/windows.md#browser-sessions), and [troubleshooting](docs/windows.md#troubleshooting).

### Security

- Keys and browser sessions you save are encrypted for your Windows account. This does not protect them from malicious software running under the same account.
- The app reads the sign-in details from a pasted cURL request; it never runs the command. Those details are passed to WSL when needed, without keeping a second, unencrypted settings file there. See [storage and security](docs/windows.md#storage-and-security).

## For developers

- **How it works:** a native Windows app written in Swift calls the unchanged upstream CodexBar CLI in WSL. Shared provider definitions control the settings fields, instructions, and labels.
- **Build and test:** [Windows development guide](docs/windows-development.md).
- **Contribute:** create a feature branch and target PRs at `windows-native-app`; `main` mirrors upstream. See [branch and review rules](docs/windows-fork.md#branches-and-pull-requests).
- **Package and release:** [packaging](docs/windows-development.md#packaging) and [release process](docs/windows-fork.md#builds-and-releases).
- **Upstream references:** [CLI](docs/cli.md), [provider implementation](docs/provider.md), and [upstream repository](https://github.com/steipete/CodexBar). For features available in the Windows app, use the Windows user guide.

## Credits and license

- Based on [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger and contributors.
- Upstream cost tracking was inspired by [ccusage](https://github.com/ryoppippi/ccusage).
- [MIT license](LICENSE); upstream attribution is retained.
