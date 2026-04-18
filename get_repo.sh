#!/usr/bin/env bash
# shellcheck disable=SC2129

set -e

# Echo all environment variables used by this script
echo "----------- get_repo -----------"
echo "Environment variables:"
echo "CI_BUILD=${CI_BUILD}"
echo "GITHUB_REPOSITORY=${GITHUB_REPOSITORY}"
echo "RELEASE_VERSION=${RELEASE_VERSION}"
echo "VSCODE_LATEST=${VSCODE_LATEST}"
echo "VSCODE_QUALITY=${VSCODE_QUALITY}"
echo "GITHUB_ENV=${GITHUB_ENV}"

echo "SHOULD_DEPLOY=${SHOULD_DEPLOY}"
echo "SHOULD_BUILD=${SHOULD_BUILD}"
echo "-------------------------"

# git workaround
if [[ "${CI_BUILD}" != "no" ]]; then
  git config --global --add safe.directory "/__w/$( echo "${GITHUB_REPOSITORY}" | awk '{print tolower($0)}' )"
fi

SPUD_BRANCH="main"
echo "Cloning Spud IDE (${SPUD_BRANCH})..."

mkdir -p vscode
cd vscode || { echo "'vscode' dir not found"; exit 1; }

git init -q
git remote add origin https://github.com/spud-dev-ai/spud-ide.git

# Allow callers to specify a particular commit to checkout via the
# environment variable SPUD_COMMIT.  We still default to the tip of the
# ${SPUD_BRANCH} branch when the variable is not provided.
if [[ -n "${SPUD_COMMIT}" ]]; then
  echo "Using explicit commit ${SPUD_COMMIT}"
  # Fetch just that commit to keep the clone shallow.
  git fetch --depth 1 origin "${SPUD_COMMIT}"
  git checkout "${SPUD_COMMIT}"
else
  git fetch --depth 1 origin "${SPUD_BRANCH}"
  git checkout FETCH_HEAD
fi

MS_TAG=$( jq -r '.version' "package.json" )
MS_COMMIT=$SPUD_BRANCH
VOID_VERSION=$( jq -r '.voidVersion' "product.json" )

if [[ -n "${SPUD_RELEASE}" ]]; then
  RELEASE_VERSION="${MS_TAG}${SPUD_RELEASE}"
else
  SPUD_RELEASE=$( jq -r '.voidRelease // ""' "product.json" )
  RELEASE_VERSION="${MS_TAG}${SPUD_RELEASE}"
fi
# RELEASE_VERSION is later used as version (1.0.3+suffix); voidRelease should be numeric or empty for semver tooling.


echo "RELEASE_VERSION=\"${RELEASE_VERSION}\""
echo "MS_COMMIT=\"${MS_COMMIT}\""
echo "MS_TAG=\"${MS_TAG}\""

cd ..

# for GH actions
if [[ "${GITHUB_ENV}" ]]; then
  echo "MS_TAG=${MS_TAG}" >> "${GITHUB_ENV}"
  echo "MS_COMMIT=${MS_COMMIT}" >> "${GITHUB_ENV}"
  echo "RELEASE_VERSION=${RELEASE_VERSION}" >> "${GITHUB_ENV}"
  echo "VOID_VERSION=${VOID_VERSION}" >> "${GITHUB_ENV}"
fi



echo "----------- get_repo exports -----------"
echo "MS_TAG ${MS_TAG}"
echo "MS_COMMIT ${MS_COMMIT}"
echo "RELEASE_VERSION ${RELEASE_VERSION}"
echo "VOID_VERSION (marketing) ${VOID_VERSION}"
echo "----------------------"


export MS_TAG
export MS_COMMIT
export RELEASE_VERSION
export VOID_VERSION
