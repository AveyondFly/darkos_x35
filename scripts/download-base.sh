#!/usr/bin/env bash
# Download and extract the upstream dArkOS RK2023 base image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config.env
source "${REPO_ROOT}/config.env"

CACHE_DIR="${REPO_ROOT}/.cache"
mkdir -p "${CACHE_DIR}"

BASE_IMG="${CACHE_DIR}/${BASE_IMAGE_BASENAME}.img"
ARCHIVE_PREFIX="${CACHE_DIR}/${BASE_IMAGE_BASENAME}.img.7z"

if [[ -f "${BASE_IMG}" ]]; then
  echo "[download] Base image already present: ${BASE_IMG}"
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd 7z

part=1
while true; do
  part_file="${ARCHIVE_PREFIX}.$(printf '%03d' "${part}")"
  url="${DARKOS_DOWNLOAD_BASE}/${BASE_IMAGE_BASENAME}.img.7z.$(printf '%03d' "${part}")"
  if [[ -f "${part_file}" ]]; then
    echo "[download] Skip existing part: ${part_file}"
  else
    echo "[download] Fetching ${url}"
    if ! curl -fL --retry 5 --retry-delay 10 -C - -o "${part_file}" "${url}"; then
      if [[ "${part}" -eq 1 ]]; then
        echo "Error: failed to download first archive part" >&2
        exit 1
      fi
      rm -f "${part_file}"
      break
    fi
  fi
  part=$((part + 1))
done

first_part="${ARCHIVE_PREFIX}.001"
[[ -f "${first_part}" ]] || {
  echo "Error: missing ${first_part}" >&2
  exit 1
}

echo "[extract] ${first_part} -> ${BASE_IMG}"
7z x -y "-o${CACHE_DIR}" "${first_part}"

[[ -f "${BASE_IMG}" ]] || {
  echo "Error: extraction did not produce ${BASE_IMG}" >&2
  exit 1
}

echo "[download] Ready: ${BASE_IMG}"
