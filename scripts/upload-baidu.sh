#!/usr/bin/env bash
# Upload dist/*.7z.* to Baidu Netdisk via BaiduPCS-Go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
REMOTE_DIR="${BAIDU_REMOTE_DIR:-/Apps/dArkOS-X35/}"
BAIDUPCS_VERSION="${BAIDUPCS_VERSION:-v4.0.1}"
BAIDUPCS_BIN="${BAIDUPCS_BIN:-${REPO_ROOT}/.cache/BaiduPCS-Go}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Upload split 7z archives from dist/ to Baidu Netdisk.

Required environment / secrets:
  BDUSS          Baidu account BDUSS cookie
  STOKEN         Baidu account STOKEN cookie

Optional:
  DIST_DIR           Local directory (default: ./dist)
  BAIDU_REMOTE_DIR   Remote folder (default: /Apps/dArkOS-X35/)
  BAIDUPCS_VERSION   Release tag (default: v4.0.1)
EOF
}

install_baidupcs() {
  if [[ -x "${BAIDUPCS_BIN}" ]]; then
    return 0
  fi

  local cache_dir tmp_dir asset_url
  cache_dir="${REPO_ROOT}/.cache"
  tmp_dir="$(mktemp -d)"
  mkdir -p "${cache_dir}"

  asset_url="https://github.com/qjfoidnh/BaiduPCS-Go/releases/download/${BAIDUPCS_VERSION}/BaiduPCS-Go-${BAIDUPCS_VERSION}-linux-amd64.zip"

  echo "[baidu] downloading BaiduPCS-Go ${BAIDUPCS_VERSION}"
  curl -fL --retry 3 -o "${tmp_dir}/baidupcs.zip" "${asset_url}"
  unzip -q -j "${tmp_dir}/baidupcs.zip" "BaiduPCS-Go-${BAIDUPCS_VERSION}-linux-amd64/BaiduPCS-Go" -d "${cache_dir}"
  mv "${cache_dir}/BaiduPCS-Go" "${BAIDUPCS_BIN}"
  chmod +x "${BAIDUPCS_BIN}"
  rm -rf "${tmp_dir}"
}

main() {
  [[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || {
    usage
    exit 0
  }

  [[ -n "${BDUSS:-}" && -n "${STOKEN:-}" ]] || {
    echo "Error: BDUSS and STOKEN must be set" >&2
    exit 1
  }

  shopt -s nullglob
  local files=( "${DIST_DIR}"/*.7z.* )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Error: no *.7z.* files in ${DIST_DIR}" >&2
    exit 1
  fi

  install_baidupcs

  echo "[baidu] login"
  "${BAIDUPCS_BIN}" login -bduss="${BDUSS}" -stoken="${STOKEN}"

  echo "[baidu] mkdir ${REMOTE_DIR}"
  "${BAIDUPCS_BIN}" mkdir "${REMOTE_DIR}" 2>/dev/null || true

  echo "[baidu] uploading ${#files[@]} file(s) -> ${REMOTE_DIR}"
  "${BAIDUPCS_BIN}" upload "${files[@]}" "${REMOTE_DIR}"

  echo "[baidu] done"
}

main "$@"
