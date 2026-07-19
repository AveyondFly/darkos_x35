#!/usr/bin/env bash
# Build modded X35H/X35S images from upstream dArkOS RK2023 release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config.env
source "${REPO_ROOT}/config.env"

OUTPUT_DIR="${REPO_ROOT}/dist"
CACHE_DIR="${REPO_ROOT}/.cache"
BASE_IMG="${CACHE_DIR}/${BASE_IMAGE_BASENAME}.img"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build modded images for all variants listed in config.env.

Options:
  -o, --output-dir DIR   Output directory (default: ./dist)
  --variant NAME         Build only one variant (X35H or X35S)
  --skip-compress        Keep raw .img only, skip 7z split
  -h, --help             Show help

Requires root for loop mounts (use sudo).
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    echo "Error: run as root (sudo)." >&2
    exit 1
  }
}

compress_image() {
  local img="$1"
  local archive_base="$2"
  local out_dir="$3"

  echo "[compress] ${img}"
  rm -f "${out_dir}/${archive_base}.7z".*
  (
    cd "${out_dir}"
    7z a -t7z -mx=5 "-v${SPLIT_SIZE}" "${archive_base}.7z" "$(basename "${img}")"
  )
}

main() {
  local only_variant="" skip_compress=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --variant) only_variant="$2"; shift 2 ;;
      --skip-compress) skip_compress=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  require_root

  command -v 7z >/dev/null 2>&1 || {
    echo "Error: 7z not found" >&2
    exit 1
  }

  "${SCRIPT_DIR}/download-base.sh"

  [[ -f "${BASE_IMG}" ]] || {
    echo "Error: base image missing after download" >&2
    exit 1
  }

  mkdir -p "${OUTPUT_DIR}"

  local entry name dtb out_img archive_base
  for entry in "${MOD_VARIANTS[@]}"; do
    IFS=':' read -r name dtb <<< "${entry}"
    if [[ -n "${only_variant}" && "${name}" != "${only_variant^^}" ]]; then
      continue
    fi

    out_img="${OUTPUT_DIR}/${MOD_PREFIX}${name}_${MOD_SUFFIX}.img"
    archive_base="${MOD_PREFIX}${name}_${MOD_SUFFIX}.img"

    "${SCRIPT_DIR}/mod-image.sh" "${name}" "${BASE_IMG}" "${out_img}"

    if [[ "${skip_compress}" -eq 0 ]]; then
      compress_image "${out_img}" "${archive_base}" "${OUTPUT_DIR}"
    fi
  done

  echo "[build] Artifacts in ${OUTPUT_DIR}:"
  ls -lh "${OUTPUT_DIR}"
}

main "$@"
