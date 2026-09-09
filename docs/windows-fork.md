---
summary: "Windows fork branches, upstream synchronization, and release gates."
read_when:
  - Contributing to the Windows fork or updating its upstream baseline
---

# Windows fork workflow

## Branches and pull requests

- `main` is an exact upstream-main mirror, with no fork-specific commits. The daily/manual
  **Sync upstream main** workflow fast-forwards it; divergence must fail, never force-reset.
- `windows-native-app` is the default, long-lived integration branch. Create short-lived
  `windows/<feature>` branches from it and target PRs at this fork's `windows-native-app`, not `main`
  or the upstream repository. Squash-merge one coherent change per PR after required checks pass.
- Protect both long-lived branches from deletion. Normal Windows changes require PRs and passing
  CI. The repository administrator may bypass protection only for coordinated upstream rebases or
  repository maintenance, not to label a failing build release-ready.

## Upstream updates

- The current Windows baseline is upstream `v0.56.8`. Prefer published upstream release tags;
  syncing mirror `main` does not automatically update the Windows branch.

1. Pause Windows merges and record open feature branches. Preserve the old integration tip with
   a `backup/windows-before-<date>` tag. Never move published Windows release tags.
2. Fetch upstream tags and rebase on a temporary integration branch against the chosen release tag.
   Review the resulting Windows patch series and verify the CLI/Core boundary remains unchanged.
3. Run the Windows tests, AMD64/ARM64 native CI, packaging gates, and a fresh debug visual smoke test.
   Resolve release-blocking failures before accepting the new baseline.
4. Update `windows-native-app` using an explicit expected-old-SHA `--force-with-lease`, only after
   confirming nobody has advanced it. Force pushes are reserved for this coordinated operation.
5. Rebase outstanding feature commits onto the new Windows tip; do not merge the obsolete Windows
   history back in. Update the baseline recorded in this document.

- The mirror sync workflow never rebases or pushes the Windows branch.

## Builds and releases

- CI runs on Windows-targeted PRs and pushes to the integration branch. Required native Windows
  checks and the `lint-build-test` gate must pass before ordinary PR merges.
- **Release artifacts** can be dispatched manually from `windows-native-app` to rehearse packaging
  without publishing. Its optional tag input labels the artifacts; it does not select the checkout.
- For publication, create an immutable fork-specific tag such as `v0.56.8-windows.1` on the tested
  Windows commit, then publish a GitHub release for that tag. Never reuse or move an upstream tag.
  The release event builds and uploads installers, portable ZIPs, and checksums for both architectures.
- The fork must not dispatch upstream Homebrew updates. Packages are currently unsigned; disclose
  that limitation and link the WSL requirements and setup instructions in the release notes.
- A successful build is not a complete release sign-off: require both installer lifecycle gates,
  fresh visual smoke evidence, and an explicit account of any untested live-provider behavior.

- Build commands, runtime architecture, test setup, and packaging inputs live in the
  [Windows development guide](windows-development.md).
- User requirements, installation, credentials, and troubleshooting live in the
  [Windows user guide](windows.md).
