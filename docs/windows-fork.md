---
summary: "How to contribute, update from upstream, and publish Windows releases."
read_when:
  - Contributing to the Windows fork or updating its upstream version
---

# Windows fork workflow

## Branches and pull requests

- `main` copies the original CodexBar repository's `main` branch. Do not add Windows changes there.
  **Sync upstream main** updates it daily and can also be run manually. If the histories have
  diverged, the workflow must stop rather than overwrite either history.
- `windows-native-app` is the default branch and contains the Windows app. Start a
  `windows/<feature>` branch from it, then open a PR back to this fork's `windows-native-app`.
  Do not target `main` or the original CodexBar repository.
- Keep each PR focused on one change. Squash-merge it after all required checks pass.
- Keep deletion protection enabled for `main` and `windows-native-app`. Administrator bypass is
  reserved for coordinated upstream rebases or repository maintenance, not ordinary PRs or failing builds.

## Upstream updates

- The Windows branch is currently based on upstream `v0.56.8`. Prefer published upstream releases
  when updating it. Syncing `main` alone does not update the Windows app.

1. Pause Windows PR merges and record open feature branches. Save the current Windows commit with
   a `backup/windows-before-<date>` tag. Never move published Windows release tags.
2. Fetch upstream tags. On a temporary branch, rebase the Windows changes onto the chosen release.
   Review the result and confirm that the Windows changes still leave `Sources/CodexBarCLI` and
   `Sources/CodexBarCore` unchanged from that upstream release.
3. Run the Windows tests and native x64/ARM64 CI, verify the packages, and visually check a fresh
   debug build. Fix any failures that would block a release before accepting the update.
4. Confirm that nobody has pushed new Windows commits. Update `windows-native-app` with
   `--force-with-lease`, supplying the exact previous commit SHA as the expected value.
   Do not use a plain force push.
5. Rebase open feature branches onto the updated Windows branch. Do not merge the old branch
   history back in. Record the new upstream version in this document.

- The mirror sync workflow never rebases or pushes the Windows branch.

## Builds and releases

- CI runs for PRs targeting `windows-native-app` and for pushes to that branch. The required native
  Windows checks and `lint-build-test` must pass before merging a PR.
- Run **Release artifacts** manually on `windows-native-app` to test packaging without publishing.
  The optional tag field names the output files; it does not choose which commit to build.
- Before publishing, require passing installer tests on both architectures and a visual check of
  the packaged app. Record any provider connections that have not been tested with a real account.
- Tag the tested Windows commit with a fork-specific version such as `v0.56.8-windows.1`, then
  publish a GitHub release for that tag. Publication starts the build that uploads installers,
  portable ZIPs, and checksums for both architectures. Never move a published tag or reuse an upstream tag.
- State in the release notes that packages are unsigned, and link to the WSL requirements and
  setup instructions. Do not trigger the original project's Homebrew update process.

- Build commands, code layout, tests, and packaging instructions are in the
  [Windows development guide](windows-development.md).
- User requirements, installation, credentials, and troubleshooting live in the
  [Windows user guide](windows.md).
