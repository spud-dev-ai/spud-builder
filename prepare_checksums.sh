#!/usr/bin/env bash

set -e

sum_file() {
  if [[ -f "${1}" ]]; then
    echo "Calculating checksum for ${1}"
    shasum -a 256 "${1}" > "${1}.sha256"
    shasum -a 1 "${1}" > "${1}.sha1"
  fi
}

cd assets

for FILE in *; do
  if [[ ! -f "${FILE}" ]]; then
    continue
  fi
  case "${FILE}" in
    *.sha256 | *.sha1) continue ;;
  esac
  sum_file "${FILE}"
done

cd ..
