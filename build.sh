#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

# When `vscode/` is a symlink into a monorepo `ide/` checkout, `..` from inside
# `vscode/` resolves to the monorepo root (the symlink target's parent), not to
# spud-builder/. The artifact outputs (VSCode-darwin-${ARCH}) intentionally
# land there via the same `..` resolution, but sourcing helper scripts that
# live in spud-builder must use an absolute path.
BUILDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. version.sh

if [[ "${SHOULD_BUILD}" == "yes" ]]; then
  echo "MS_COMMIT=\"${MS_COMMIT}\""

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  export NODE_OPTIONS="--max-old-space-size=8192"

  # Skip monaco-compile-check as it's failing due to searchUrl property
  # Skip valid-layers-check as well since it might depend on monaco
  # Void commented these out
  # npm run monaco-compile-check
  # npm run valid-layers-check

  npm run buildreact
  npm run gulp compile-build-without-mangling
  npm run gulp compile-extension-media
  npm run gulp compile-extensions-build
  npm run gulp minify-vscode

  if [[ "${OS_NAME}" == "osx" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies darwin # Void commented this out

    npm run gulp "vscode-darwin-${VSCODE_ARCH}-min-ci"

    find "../VSCode-darwin-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

    # CLI (Rust) build is optional for local DMGs; skip cleanly when cargo is
    # not installed instead of aborting the DMG pipeline. Set SPUD_SKIP_CLI=no
    # to force the CLI build and surface missing-toolchain errors.
    if [[ "${SPUD_SKIP_CLI:-auto}" == "auto" ]]; then
      if command -v cargo >/dev/null 2>&1; then
        . "${BUILDER_ROOT}/build_cli.sh"
      else
        echo "build.sh: cargo not found on PATH; skipping CLI ('code') build. App will lack the 'code' shell command." >&2
      fi
    elif [[ "${SPUD_SKIP_CLI}" != "yes" ]]; then
      . "${BUILDER_ROOT}/build_cli.sh"
    fi

    # With a symlinked `vscode/`, gulp and build_cli.sh resolve `..` physically,
    # so `VSCode-darwin-${VSCODE_ARCH}` is produced next to `ide/` (the real
    # target of the spud-builder/vscode symlink) rather than inside spud-builder/.
    # Move it to where prepare_assets.sh expects it (and INTEGRATION.md documents).
    # Check the known possible landing sites in order.
    for _candidate in \
      "../VSCode-darwin-${VSCODE_ARCH}" \
      "../../VSCode-darwin-${VSCODE_ARCH}" \
      "${BUILDER_ROOT}/../VSCode-darwin-${VSCODE_ARCH}"; do
      if [[ -d "${_candidate}" && ! -e "${BUILDER_ROOT}/VSCode-darwin-${VSCODE_ARCH}" ]]; then
        mv "${_candidate}" "${BUILDER_ROOT}/VSCode-darwin-${VSCODE_ARCH}"
        break
      fi
    done
    unset _candidate

    VSCODE_PLATFORM="darwin"
  elif [[ "${OS_NAME}" == "windows" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies win32 # Void commented this out

    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      . "${BUILDER_ROOT}/build/windows/rtf/make.sh"

      npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"

      if [[ "${VSCODE_ARCH}" != "x64" ]]; then
        SHOULD_BUILD_REH="no"
        SHOULD_BUILD_REH_WEB="no"
      fi

      . "${BUILDER_ROOT}/build_cli.sh"
    fi

    VSCODE_PLATFORM="win32"
  else # linux
    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

      find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

      . "${BUILDER_ROOT}/build_cli.sh"
    fi

    VSCODE_PLATFORM="linux"
  fi

  if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
    npm run gulp minify-vscode-reh
    npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    npm run gulp minify-vscode-reh-web
    npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  cd ..
fi
