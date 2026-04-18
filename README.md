# Spud Builder

Fork of [voideditor/void-builder](https://github.com/voideditor/void-builder) (itself a VSCodium fork) used to ship **Spud IDE** binaries. Upstream Void’s pipeline is described in the [Void Builder README](https://github.com/voideditor/void-builder/blob/main/README.md); this tree is rebranded for Spud (`spud.dev`, `spud-dev-ai/*` GitHub repos).

GitHub Actions build Spud artifacts (`.dmg`, `.zip`, installers, etc.), publish them to releases on **`${{ github.repository_owner }}/binaries`**, and update **`${{ github.repository_owner }}/versions`** so the desktop app can resolve updates (see `prepare_vscode.sh` `updateUrl` / `downloadUrl`).

## Repos you need

| Role | Default org (replace with yours when forking) |
|------|--------------------------------------------------|
| IDE source (cloned in CI) | [`spud-dev-ai/spud-ide`](https://github.com/spud-dev-ai/spud-ide) |
| This build repo | e.g. `spud-dev-ai/spud-builder` |
| Binary releases | `your-org/binaries` |
| Version manifest (`main` branch JSON) | `your-org/versions` |

Workflow env already uses `ASSETS_REPOSITORY: ${{ github.repository_owner }}/binaries` and `VERSIONS_REPOSITORY: ${{ github.repository_owner }}/versions`.

## Notes

- Workflow inputs: **spud_commit** / **spud_release** (optional) map to `get_repo.sh` (`SPUD_COMMIT`, `SPUD_RELEASE`).
- Patches under `patches/` use placeholders (`!!APP_NAME!!`, etc.); defaults in `utils.sh` are **Spud** / **spud** / **spud-dev-ai/spud-ide**.
- Rebasing onto new VSCodium/Void upstream: keep Void’s “search for upstream markers” workflow, then re-apply Spud-specific URLs and names.

## Upstream

- [void-builder](https://github.com/voideditor/void-builder) — original pipeline this fork was cloned from.
