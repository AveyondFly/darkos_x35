#!/usr/bin/env bash
# Patch one dArkOS RK2023 image copy for X35H or X35S (uboot, boot, rootfs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config.env
source "${REPO_ROOT}/config.env"

usage() {
  cat <<EOF
Usage: $(basename "$0") <variant> <input.img> <output.img>

  variant   X35H or X35S (must match MOD_VARIANTS in config.env)
  input     Upstream dArkOS RK2023 raw image
  output    Modified image path (should differ from input)

Environment:
  SKIP_UBOOT=1     Skip U-Boot flash (for testing kernel/dtb only)
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    echo "Error: run as root (sudo) for loop mount / dd." >&2
    exit 1
  }
}

resolve_variant() {
  local want="$1"
  want="${want^^}"
  local entry name dtb
  for entry in "${MOD_VARIANTS[@]}"; do
    IFS=':' read -r name dtb <<< "${entry}"
    if [[ "${name}" == "${want}" ]]; then
      VARIANT_NAME="${name}"
      VARIANT_DTB="${dtb}"
      return 0
    fi
  done
  echo "Error: unknown variant '${want}'. Valid: $(variants_list)" >&2
  exit 1
}

variants_list() {
  local entry name dtb out=""
  for entry in "${MOD_VARIANTS[@]}"; do
    IFS=':' read -r name dtb <<< "${entry}"
    out+="${name} "
  done
  echo "${out}"
}

patch_extlinux() {
  local conf="$1"
  local template="${REPO_ROOT}/overlay/extlinux/${VARIANT_NAME}.extlinux.conf"

  [[ -f "${template}" ]] || {
    echo "Error: missing extlinux template: ${template}" >&2
    exit 1
  }

  cp -f "${template}" "${conf}"
}

verify_extlinux() {
  local conf="$1"

  if grep -qE '(^|[[:space:]])console=tty1([[:space:]]|$)' "${conf}"; then
    echo "Error: extlinux.conf still contains console=tty1" >&2
    exit 1
  fi
  if grep -qE '(^|[[:space:]])loglevel=' "${conf}"; then
    echo "Error: extlinux.conf still contains loglevel=" >&2
    exit 1
  fi
  if ! grep -q 'console=ttyS2,1500000n8' "${conf}"; then
    echo "Error: extlinux.conf missing console=ttyS2,1500000n8" >&2
    exit 1
  fi
}

boot_part_path() {
  local disk="$1" part="$2"
  [[ -b "${disk}p${part}" ]] && echo "${disk}p${part}" || echo "${disk}${part}"
}

mount_rootfs() {
  local dev="$1" mnt="$2"
  local fstype

  fstype="$(blkid -o value -s TYPE "${dev}" 2>/dev/null || true)"
  case "${fstype}" in
    btrfs)
      mount -t btrfs -o subvol=/ "${dev}" "${mnt}"
      ;;
    ext4)
      mount "${dev}" "${mnt}"
      ;;
    "")
      echo "Error: could not detect filesystem on ${dev}" >&2
      exit 1
      ;;
    *)
      echo "Error: unsupported rootfs type '${fstype}' on ${dev}" >&2
      exit 1
      ;;
  esac
}

apply_rootfs_overlay() {
  local root_mnt="$1"
  local overlay="${REPO_ROOT}/overlay/rootfs"

  [[ -d "${overlay}" ]] || return 0

  echo "[mod] applying rootfs overlay from overlay/rootfs/"
  cp -a "${overlay}/." "${root_mnt}/"
}

verify_rootfs_overlay() {
  local root_mnt="$1"
  local sleep_conf="${root_mnt}/etc/systemd/sleep.conf.d/s2idle.conf"

  [[ -f "${sleep_conf}" ]] || {
    echo "Error: missing ${sleep_conf}" >&2
    exit 1
  }
  grep -q '^MemorySleepMode=s2idle$' "${sleep_conf}" || {
    echo "Error: s2idle.conf missing MemorySleepMode=s2idle" >&2
    exit 1
  }
  grep -q '^SuspendState=mem$' "${sleep_conf}" || {
    echo "Error: s2idle.conf missing SuspendState=mem" >&2
    exit 1
  }
}

main() {
  local variant="${1:-}"
  local input="${2:-}"
  local output="${3:-}"

  [[ -n "${variant}" && -n "${input}" && -n "${output}" ]] || {
    usage >&2
    exit 1
  }

  resolve_variant "${variant}"

  [[ -f "${input}" ]] || {
    echo "Error: input image not found: ${input}" >&2
    exit 1
  }

  local uboot_path="${REPO_ROOT}/${UBOOT_BIN}"
  local kernel_path="${REPO_ROOT}/${KERNEL_IMAGE}"
  local dtb_path="${REPO_ROOT}/${VARIANT_DTB}"

  for f in "${uboot_path}" "${kernel_path}" "${dtb_path}"; do
    [[ -f "${f}" ]] || {
      echo "Error: missing mod asset: ${f}" >&2
      exit 1
    }
  done

  require_root

  echo "[mod] variant=${VARIANT_NAME} dtb=${VARIANT_DTB}"
  echo "[mod] ${input} -> ${output}"

  mkdir -p "$(dirname "${output}")"
  cp --reflink=auto "${input}" "${output}" 2>/dev/null || cp "${input}" "${output}"

  if [[ "${SKIP_UBOOT:-0}" != "1" ]]; then
    echo "[mod] flashing U-Boot"
    "${REPO_ROOT}/flash-uboot.sh" --no-backup -p "${BOOT_PART}" "${output}"
  else
    echo "[mod] SKIP_UBOOT=1, skipping U-Boot flash"
  fi

  local loop_dev disk boot_mnt="" root_mnt=""
  loop_dev="$(losetup -Pf --show "${output}")"
  disk="${loop_dev}"
  partprobe "${loop_dev}" 2>/dev/null || true

  local boot_dev root_dev
  boot_dev="$(boot_part_path "${disk}" "${BOOT_PART}")"
  root_dev="$(boot_part_path "${disk}" "${ROOTFS_PART}")"
  [[ -b "${boot_dev}" ]] || {
    echo "Error: boot partition not found: ${boot_dev}" >&2
    losetup -d "${loop_dev}" 2>/dev/null || true
    exit 1
  }
  [[ -b "${root_dev}" ]] || {
    echo "Error: rootfs partition not found: ${root_dev}" >&2
    losetup -d "${loop_dev}" 2>/dev/null || true
    exit 1
  }

  cleanup() {
    umount "${boot_mnt}" 2>/dev/null || true
    umount "${root_mnt}" 2>/dev/null || true
    [[ -n "${boot_mnt}" ]] && rmdir "${boot_mnt}" 2>/dev/null || true
    [[ -n "${root_mnt}" ]] && rmdir "${root_mnt}" 2>/dev/null || true
    [[ -n "${loop_dev}" ]] && losetup -d "${loop_dev}" 2>/dev/null || true
  }
  trap cleanup EXIT

  boot_mnt="$(mktemp -d)"
  root_mnt="$(mktemp -d)"
  mount "${boot_dev}" "${boot_mnt}"
  mount_rootfs "${root_dev}" "${root_mnt}"

  local extlinux_dir="${boot_mnt}/extlinux"
  local extlinux_conf="${extlinux_dir}/extlinux.conf"
  [[ -f "${extlinux_conf}" ]] || {
    echo "Error: missing ${extlinux_conf}" >&2
    exit 1
  }

  cp -a "${extlinux_conf}" "${extlinux_conf}.bak"

  echo "[mod] replacing kernel Image"
  cp -f "${kernel_path}" "${boot_mnt}/Image"

  echo "[mod] installing ${VARIANT_DTB}"
  cp -f "${dtb_path}" "${boot_mnt}/${VARIANT_DTB}"

  echo "[mod] installing extlinux.conf (from overlay/extlinux/${VARIANT_NAME}.extlinux.conf)"
  patch_extlinux "${extlinux_conf}"
  verify_extlinux "${extlinux_conf}"

  if [[ -f "${boot_mnt}/${UPSTREAM_DTB}" ]]; then
    echo "[mod] removing upstream ${UPSTREAM_DTB}"
    rm -f "${boot_mnt}/${UPSTREAM_DTB}"
  fi

  apply_rootfs_overlay "${root_mnt}"
  verify_rootfs_overlay "${root_mnt}"

  sync
  umount "${boot_mnt}"
  umount "${root_mnt}"
  rmdir "${boot_mnt}"
  rmdir "${root_mnt}"
  boot_mnt=""
  root_mnt=""
  losetup -d "${loop_dev}"
  loop_dev=""
  trap - EXIT

  sync
  echo "[mod] done: ${output}"
}

main "$@"
