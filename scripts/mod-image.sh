#!/usr/bin/env bash
# Patch one dArkOS RK2023 image copy for X35H or X35S (uboot, boot, rootfs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config.env
source "${REPO_ROOT}/config.env"

part_path() {
  local disk="$1" part="$2"

  if [[ "${disk}" == /dev/loop* ]]; then
    echo "${disk}p${part}"
    return 0
  fi

  if [[ -b "${disk}p${part}" ]]; then
    echo "${disk}p${part}"
  elif [[ -b "${disk}${part}" ]]; then
    echo "${disk}${part}"
  else
    echo "${disk}p${part}"
  fi
}

wait_for_block() {
  local dev="$1" disk="${2:-}"
  local i

  for ((i = 1; i <= 50; i++)); do
    [[ -b "${dev}" ]] && return 0
    [[ -n "${disk}" ]] && partprobe "${disk}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 0.2
  done

  echo "Error: block device not ready: ${dev}" >&2
  return 1
}

setup_loop_image() {
  local image="$1"
  local loop_dev

  loop_dev="$(losetup -Pf --show "${image}")"
  partprobe "${loop_dev}" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  echo "${loop_dev}"
}

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
  local device_file="${root_mnt}/home/ark/.config/.DEVICE"
  local cron_file="${root_mnt}/var/spool/cron/crontabs/root"
  local ark_uid ark_gid

  [[ -d "${overlay}" ]] || return 0

  echo "[mod] applying rootfs overlay from overlay/rootfs/"
  cp -a "${overlay}/." "${root_mnt}/"

  # Variant-specific device id (overlay ships X35H as placeholder)
  mkdir -p "$(dirname "${device_file}")"
  printf '%s\n' "${VARIANT_NAME}" > "${device_file}"
  if ark_uid="$(stat -c '%u' "${root_mnt}/home/ark" 2>/dev/null)" \
    && ark_gid="$(stat -c '%g' "${root_mnt}/home/ark" 2>/dev/null)"; then
    chown "${ark_uid}:${ark_gid}" "${device_file}" 2>/dev/null || true
  fi
  echo "[mod] set .DEVICE=${VARIANT_NAME}"

  # Upstream @reboot spktoggle.sh toggles SPK→HP when path is already SPK.
  # On X35 that mutes the speaker amp; headphone-audio-switch.sh is enough at boot.
  if [[ -f "${cron_file}" ]]; then
    if grep -q 'spktoggle\.sh' "${cron_file}"; then
      echo "[mod] removing @reboot spktoggle.sh from root crontab"
      sed -i '/spktoggle\.sh/d' "${cron_file}"
    fi
  else
    echo "[mod] warning: root crontab not found at ${cron_file}" >&2
  fi
}

verify_rootfs_overlay() {
  local root_mnt="$1"
  local sleep_conf="${root_mnt}/etc/systemd/sleep.conf.d/s2idle.conf"
  local device_file="${root_mnt}/home/ark/.config/.DEVICE"
  local fix_audio="${root_mnt}/usr/local/bin/Fix Audio.sh"
  local spktoggle="${root_mnt}/usr/local/bin/spktoggle.sh"
  local cron_file="${root_mnt}/var/spool/cron/crontabs/root"
  local device_id

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

  [[ -f "${device_file}" ]] || {
    echo "Error: missing ${device_file}" >&2
    exit 1
  }
  device_id="$(tr -d '\r\n' < "${device_file}")"
  [[ "${device_id}" == "${VARIANT_NAME}" ]] || {
    echo "Error: .DEVICE is '${device_id}', expected '${VARIANT_NAME}'" >&2
    exit 1
  }

  [[ -f "${fix_audio}" ]] || {
    echo "Error: missing ${fix_audio}" >&2
    exit 1
  }
  grep -q 'X35H' "${fix_audio}" || {
    echo "Error: Fix Audio.sh missing X35H support" >&2
    exit 1
  }

  [[ -f "${spktoggle}" ]] || {
    echo "Error: missing ${spktoggle}" >&2
    exit 1
  }
  grep -q 'X35H' "${spktoggle}" || {
    echo "Error: spktoggle.sh missing X35H support" >&2
    exit 1
  }
  grep -q 'unmute_path="SPK"' "${spktoggle}" || {
    echo "Error: spktoggle.sh missing X35 unmute_path=SPK" >&2
    exit 1
  }

  if [[ -f "${cron_file}" ]] && grep -q 'spktoggle\.sh' "${cron_file}"; then
    echo "Error: root crontab still contains spktoggle.sh @reboot" >&2
    exit 1
  fi
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
  loop_dev="$(setup_loop_image "${output}")"
  disk="${loop_dev}"

  local boot_dev root_dev
  boot_dev="$(part_path "${disk}" "${BOOT_PART}")"
  root_dev="$(part_path "${disk}" "${ROOTFS_PART}")"
  wait_for_block "${boot_dev}" "${disk}" || exit 1
  wait_for_block "${root_dev}" "${disk}" || exit 1

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
