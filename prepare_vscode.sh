#!/usr/bin/env bash
# shellcheck disable=SC1091,2154

set -e

# include common functions
. ./utils.sh

# Void - disable icon copying, we already handled icons
# if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
#   cp -rp src/insider/* vscode/
# else
#   cp -rp src/stable/* vscode/
# fi

# Void - keep our license...
# cp -f LICENSE vscode/LICENSE.txt

# When `vscode` is a symlink to a monorepo `ide/` checkout, `..` is not spud-builder.
# Resolve builder root so scripts and patches always load from this repo.
BUILDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${BUILDER_ROOT}/vscode" || { echo "'vscode' dir not found"; exit 1; }

"${BUILDER_ROOT}/update_settings.sh"

# apply patches
{ set +x; } 2>/dev/null

echo "APP_NAME=\"${APP_NAME}\""
echo "APP_NAME_LC=\"${APP_NAME_LC}\""
echo "BINARY_NAME=\"${BINARY_NAME}\""
echo "GH_REPO_PATH=\"${GH_REPO_PATH}\""
echo "ORG_NAME=\"${ORG_NAME}\""

echo "Applying patches at ${BUILDER_ROOT}/patches/*.patch..." # Void comment
for file in "${BUILDER_ROOT}/patches"/*.patch; do
  if [[ -f "${file}" ]]; then
    apply_patch "${file}"
  fi
done

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  echo "Applying insider patches..." # Void comment
  for file in "${BUILDER_ROOT}/patches/insider"/*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

if [[ -d "${BUILDER_ROOT}/patches/${OS_NAME}/" ]]; then
  echo "Applying OS patches (${OS_NAME})..." # Void comment
  for file in "${BUILDER_ROOT}/patches/${OS_NAME}/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

echo "Applying user patches..." # Void comment
for file in "${BUILDER_ROOT}/patches/user"/*.patch; do
  if [[ -f "${file}" ]]; then
    apply_patch "${file}"
  fi
done

set -x

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

if [[ "${OS_NAME}" == "linux" ]]; then
  export VSCODE_SKIP_NODE_VERSION_CHECK=1

   if [[ "${npm_config_arch}" == "arm" ]]; then
    export npm_config_arm_version=7
  fi
elif [[ "${OS_NAME}" == "windows" ]]; then
  if [[ "${npm_config_arch}" == "arm" ]]; then
    export npm_config_arm_version=7
  fi
else
  if [[ "${CI_BUILD}" != "no" ]]; then
    clang++ --version
  fi
fi

mv .npmrc .npmrc.bak
cp "${BUILDER_ROOT}/npmrc" .npmrc

# Spud IDE (fork) uses bun: root package.json declares `packageManager: bun@*`, and
# extensions ship `bun.lock` instead of `package-lock.json`. Fall back to npm when bun
# is not available or the tree lacks a root `bun.lock` (upstream Code-OSS path).
SPUD_INSTALL_TOOL=""
if [[ -f "bun.lock" ]] && command -v bun >/dev/null 2>&1; then
  SPUD_INSTALL_TOOL="bun"
fi

for i in {1..5}; do # try 5 times
  if [[ "${SPUD_INSTALL_TOOL}" == "bun" ]]; then
    # `bun install` (no --frozen-lockfile) on purpose: spud-builder patches mutate
    # package.json (e.g. policies.patch swaps @vscode/policy-watcher ->
    # @vscodium/policy-watcher), so the committed bun.lock is intentionally stale
    # after patching. Allow bun to rewrite it in place.
    bun install && break
  elif [[ "${CI_BUILD}" != "no" && "${OS_NAME}" == "osx" ]]; then
    CXX=clang++ npm ci && break
  else
    npm ci && break
  fi

  if [[ $i == 3 ]]; then
    echo "Install failed too many times (tool=${SPUD_INSTALL_TOOL:-npm})" >&2
    exit 1
  fi
  echo "Install failed $i (tool=${SPUD_INSTALL_TOOL:-npm}), trying again..."

  sleep $(( 15 * (i + 1)))
done

# Native addons for the Electron main process MUST be compiled against Electron's
# Node ABI (see ide/.npmrc: disturl/target/runtime). Bun does not honor npm-style
# `.npmrc` and silently skips install scripts for patched/renamed packages
# (e.g. @vscodium/policy-watcher, which our policies.patch swaps in, is not in
# the root's `trustedDependencies`). Result: node_modules/**/build/Release/*.node
# is empty, the .app silently fails its first `dlopen` on launch, and macOS shows
# no window. Force a full native rebuild with npm, which reads .npmrc here and
# drives node-gyp to produce arm64/Electron-ABI .node files for every package
# with a binding.gyp. No-op for pure JS dependencies.
if [[ "${SPUD_INSTALL_TOOL}" == "bun" ]] && command -v npm >/dev/null 2>&1; then
  echo "Rebuilding native node addons against Electron headers (.npmrc target=$(grep '^target=' .npmrc | cut -d= -f2 | tr -d '\"'))..."
  npm rebuild --build-from-source
fi

# open-remote-ssh depends on a git-source `simple-socks` whose published `main`
# (`dist/socks5.js`) is produced by a `prepare` script (`gulp build`). That
# script needs the package's devDeps, which are not installed for transitive
# deps under any package manager, so it fails under `bun pm trust --all` too.
# Workaround: repoint `main` to the bundled `src/socks5.js`; it uses ESM import
# syntax which webpack resolves natively when bundling the extension.
fix_missing_dist_main() {
  local pkg_path="$1"        # e.g. extensions/open-remote-ssh/node_modules/simple-socks/package.json
  local replacement_main="$2" # e.g. src/socks5.js
  if [[ ! -f "${pkg_path}" ]]; then
    return
  fi
  local pkg_dir
  pkg_dir="$(dirname "${pkg_path}")"
  local current_main
  current_main=$(node -e 'try{const p=require(process.argv[1]);process.stdout.write(p.main||"")}catch(e){process.exit(0)}' "${pkg_path}")
  if [[ -n "${current_main}" && -f "${pkg_dir}/${current_main}" ]]; then
    return
  fi
  if [[ ! -f "${pkg_dir}/${replacement_main}" ]]; then
    echo "fix_missing_dist_main: no replacement '${replacement_main}' in ${pkg_dir}, skipping" >&2
    return
  fi
  echo "fix_missing_dist_main: ${pkg_path} main='${current_main}' -> '${replacement_main}'"
  local jsonTmp
  jsonTmp=$(jq --arg m "${replacement_main}" '.main = $m' "${pkg_path}")
  echo "${jsonTmp}" > "${pkg_path}"
}

fix_missing_dist_main "extensions/open-remote-ssh/node_modules/simple-socks/package.json" "src/socks5.js"

mv .npmrc.bak .npmrc

setpath() {
  local jsonTmp
  { set +x; } 2>/dev/null
  jsonTmp=$( jq --arg 'path' "${2}" --arg 'value' "${3}" 'setpath([$path]; $value)' "${1}.json" )
  echo "${jsonTmp}" > "${1}.json"
  set -x
}

setpath_json() {
  local jsonTmp
  { set +x; } 2>/dev/null
  jsonTmp=$( jq --arg 'path' "${2}" --argjson 'value' "${3}" 'setpath([$path]; $value)' "${1}.json" )
  echo "${jsonTmp}" > "${1}.json"
  set -x
}

# product.json
cp product.json{,.bak}

setpath "product" "checksumFailMoreInfoUrl" "https://go.microsoft.com/fwlink/?LinkId=828886"
setpath "product" "documentationUrl" "https://spud.dev"
# setpath_json "product" "extensionsGallery" '{"serviceUrl": "https://open-vsx.org/vscode/gallery", "itemUrl": "https://open-vsx.org/vscode/item"}'
setpath "product" "introductoryVideosUrl" "https://go.microsoft.com/fwlink/?linkid=832146"
setpath "product" "keyboardShortcutsUrlLinux" "https://go.microsoft.com/fwlink/?linkid=832144"
setpath "product" "keyboardShortcutsUrlMac" "https://go.microsoft.com/fwlink/?linkid=832143"
setpath "product" "keyboardShortcutsUrlWin" "https://go.microsoft.com/fwlink/?linkid=832145"
setpath "product" "licenseUrl" "https://github.com/spud-dev-ai/spud-ide/blob/main/LICENSE.txt"
# setpath_json "product" "linkProtectionTrustedDomains" '["https://open-vsx.org"]'
# setpath "product" "releaseNotesUrl" "https://go.microsoft.com/fwlink/?LinkID=533483#vscode"
setpath "product" "reportIssueUrl" "https://spud.dev"
setpath "product" "requestFeatureUrl" "https://spud.dev"
setpath "product" "tipsAndTricksUrl" "https://go.microsoft.com/fwlink/?linkid=852118"
setpath "product" "twitterUrl" "https://spud.dev"

if [[ "${DISABLE_UPDATE}" != "yes" ]]; then
  # Cloud update API (Next.js). Override with SPUD_UPDATE_URL for staging (e.g. Vercel preview URL).
  setpath "product" "updateUrl" "${SPUD_UPDATE_URL:-https://updates.spud.dev}"
  setpath "product" "downloadUrl" "https://github.com/spud-dev-ai/binaries/releases"
fi

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  setpath "product" "nameShort" "Spud - Insiders"
  setpath "product" "nameLong" "Spud - Insiders"
  setpath "product" "applicationName" "spud-insiders"
  setpath "product" "dataFolderName" ".spud-insiders"
  setpath "product" "linuxIconName" "spud-insiders"
  setpath "product" "quality" "insider"
  setpath "product" "urlProtocol" "spud-insiders"
  setpath "product" "serverApplicationName" "spud-server-insiders"
  setpath "product" "serverDataFolderName" ".spud-server-insiders"
  setpath "product" "darwinBundleIdentifier" "dev.spud.ide.insiders"
  setpath "product" "win32AppUserModelId" "Spud.SpudInsiders"
  setpath "product" "win32DirName" "Spud Insiders"
  setpath "product" "win32MutexName" "spudinsiders"
  setpath "product" "win32NameVersion" "Spud Insiders"
  setpath "product" "win32RegValueName" "SpudInsiders"
  setpath "product" "win32ShellNameShort" "Spud Insiders"
  setpath "product" "win32AppId" "{{5893CE20-77AA-4856-A655-ECE65CBCF1C7}"
  setpath "product" "win32x64AppId" "{{7A261980-5847-44B6-B554-31DF0F5CDFC9}"
  setpath "product" "win32arm64AppId" "{{EE4FF7AA-A874-419D-BAE0-168C9DBCE211}"
  setpath "product" "win32UserAppId" "{{FA3AE0C7-888E-45DA-AB58-B8E33DE0CB2E}"
  setpath "product" "win32x64UserAppId" "{{5B1813E3-1D97-4E00-AF59-C59A39CF066A}"
  setpath "product" "win32arm64UserAppId" "{{C2FA90D8-B265-41B1-B909-3BAEB21CAA9D}"
else
  setpath "product" "nameShort" "Spud"
  setpath "product" "nameLong" "Spud"
  setpath "product" "applicationName" "spud"
  setpath "product" "linuxIconName" "spud-editor"
  setpath "product" "quality" "stable"
  setpath "product" "urlProtocol" "spud"
  setpath "product" "serverApplicationName" "spud-server"
  setpath "product" "serverDataFolderName" ".spud-server"
  setpath "product" "darwinBundleIdentifier" "dev.spud.ide"
  setpath "product" "win32AppUserModelId" "Spud.Editor"
  setpath "product" "win32DirName" "Spud"
  setpath "product" "win32MutexName" "spudide"
  setpath "product" "win32NameVersion" "Spud"
  setpath "product" "win32RegValueName" "SpudEditor"
  setpath "product" "win32ShellNameShort" "&Spud"
  # Remaining win32 app IDs come from merged product.json
  # setpath "product" "win32AppId" "{{88DA3577-054F-4CA1-8122-7D820494CFFB}"
  # setpath "product" "win32x64AppId" "{{9D394D01-1728-45A7-B997-A6C82C5452C3}"
  # setpath "product" "win32arm64AppId" "{{0668DD58-2BDE-4101-8CDA-40252DF8875D}"
  # setpath "product" "win32UserAppId" "{{0FD05EB4-651E-4E78-A062-515204B47A3A}"
  # setpath "product" "win32x64UserAppId" "{{8BED5DC1-6C55-46E6-9FE6-18F7E6F7C7F1}"
  # setpath "product" "win32arm64UserAppId" "{{F6C87466-BC82-4A8F-B0FF-18CA366BA4D8}"
fi

jsonTmp=$( jq -s '.[0] * .[1]' product.json "${BUILDER_ROOT}/product.json" )
echo "${jsonTmp}" > product.json && unset jsonTmp

cat product.json

# package.json
cp package.json{,.bak}

setpath "package" "version" "${RELEASE_VERSION%-insider}"

replace 's|Microsoft Corporation|Spud|' package.json

cp resources/server/manifest.json{,.bak}

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  setpath "resources/server/manifest" "name" "Spud - Insiders"
  setpath "resources/server/manifest" "short_name" "Spud - Insiders"
else
  setpath "resources/server/manifest" "name" "Spud"
  setpath "resources/server/manifest" "short_name" "Spud"
fi

cp resources/server/manifest.json{,.bak}

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  setpath "resources/server/manifest" "name" "Spud - Insiders"
  setpath "resources/server/manifest" "short_name" "Spud - Insiders"
else
  setpath "resources/server/manifest" "name" "Spud"
  setpath "resources/server/manifest" "short_name" "Spud"
fi

# announcements
# replace "s|\\[\\/\\* BUILTIN_ANNOUNCEMENTS \\*\\/\\]|$( tr -d '\n' < ../announcements-builtin.json )|" src/vs/workbench/contrib/welcomeGettingStarted/browser/gettingStarted.ts

"${BUILDER_ROOT}/undo_telemetry.sh"

replace 's|Microsoft Corporation|Spud|' build/lib/electron.js
replace 's|Microsoft Corporation|Spud|' build/lib/electron.ts
replace 's|([0-9]) Microsoft|\1 Spud|' build/lib/electron.js
replace 's|([0-9]) Microsoft|\1 Spud|' build/lib/electron.ts

if [[ "${OS_NAME}" == "linux" ]]; then
  # microsoft adds their apt repo to sources
  # unless the app name is code-oss
  # as we are renaming the application to void
  # we need to edit a line in the post install template
  if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
    sed -i "s/code-oss/spud-insiders/" resources/linux/debian/postinst.template
  else
    sed -i "s/code-oss/spud/" resources/linux/debian/postinst.template
  fi

  # fix the packages metadata
  # code.appdata.xml
  sed -i 's|Visual Studio Code|Spud|g' resources/linux/code.appdata.xml
  sed -i 's|https://code.visualstudio.com/docs/setup/linux|https://spud.dev|' resources/linux/code.appdata.xml
  sed -i 's|https://code.visualstudio.com/home/home-screenshot-linux-lg.png|https://vscodium.com/img/vscodium.png|' resources/linux/code.appdata.xml
  sed -i 's|https://code.visualstudio.com|https://spud.dev|' resources/linux/code.appdata.xml

  # control.template
  sed -i 's|Microsoft Corporation <vscode-linux@microsoft.com>|Spud <hello@spud.dev>|'  resources/linux/debian/control.template
  sed -i 's|Visual Studio Code|Spud|g' resources/linux/debian/control.template
  sed -i 's|https://code.visualstudio.com/docs/setup/linux|https://spud.dev|' resources/linux/debian/control.template
  sed -i 's|https://code.visualstudio.com|https://spud.dev|' resources/linux/debian/control.template

  # code.spec.template
  sed -i 's|Microsoft Corporation|Spud|' resources/linux/rpm/code.spec.template
  sed -i 's|Visual Studio Code Team <vscode-linux@microsoft.com>|Spud <hello@spud.dev>|' resources/linux/rpm/code.spec.template
  sed -i 's|Visual Studio Code|Spud|' resources/linux/rpm/code.spec.template
  sed -i 's|https://code.visualstudio.com/docs/setup/linux|https://spud.dev|' resources/linux/rpm/code.spec.template
  sed -i 's|https://code.visualstudio.com|https://spud.dev|' resources/linux/rpm/code.spec.template

  # snapcraft.yaml
  sed -i 's|Visual Studio Code|Spud|'  resources/linux/rpm/code.spec.template
elif [[ "${OS_NAME}" == "windows" ]]; then
  # code.iss
  sed -i 's|https://code.visualstudio.com|https://spud.dev|' build/win32/code.iss
  sed -i 's|Microsoft Corporation|Spud|' build/win32/code.iss
fi

cd "${BUILDER_ROOT}"
