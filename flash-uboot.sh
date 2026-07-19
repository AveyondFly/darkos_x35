#!/usr/bin/env bash
# RK3566-Specific U-Boot for dArkOS SD/img (verified Plan B).
#
# flash: dd RK3566-Specific_uboot.bin @ sector 64 (notrunc, no GPT write)
#        + bootable flag on boot FAT partition (default p3)
# restore: rollback from backup created by flash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBOOT_BIN="${SCRIPT_DIR}/RK3566-Specific_uboot.bin"

SECTOR_SIZE=512
UBOOT_SEEK=64
BOOT_SECTOR_COUNT=32704
BOOT_PART=3

usage() {
  cat <<EOF
Usage:
  sudo $(basename "$0") [options] <target>
  sudo $(basename "$0") restore <backup-dir> <target>

  <target>   Block device (/dev/sdb) or raw image (darkos.img)

Flash options:
  -n, --no-backup       Skip backup
  -b, --backup-dir DIR  Backup directory
  -p, --boot-part N     Boot FAT partition (default: ${BOOT_PART})
      --no-bootable     Skip bootable flag on boot partition

Examples:
  sudo $(basename "$0") /dev/sdb
  sudo $(basename "$0") restore ./backup-sdb-20260717 /dev/sdb
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Error: run as root (sudo)." >&2; exit 1; }
}

loop_dev=""

open_disk() {
  local t="$1"
  loop_dev=""
  if [[ -b "${t}" ]]; then
    disk="${t}"
  elif [[ -f "${t}" ]]; then
    loop_dev=$(losetup -Pf --show "${t}")
    disk="${loop_dev}"
    partprobe "${loop_dev}" 2>/dev/null || true
  else
    echo "Error: target not found: ${t}" >&2
    exit 1
  fi
}

boot_part_path() {
  local d="$1" n="$2"
  [[ -b "${d}p${n}" ]] && echo "${d}p${n}" || echo "${d}${n}"
}

cmd_restore() {
  local backup_dir="$1" target="$2"
  require_root
  open_disk "${target}"

  if [[ -f "${backup_dir}/boot-sector64.bin" ]]; then
    echo "Restoring boot-sector64.bin @ sector 64"
    dd if="${backup_dir}/boot-sector64.bin" of="${disk}" bs=512 seek=64 conv=fsync,notrunc status=progress
  else
    echo "Error: missing ${backup_dir}/boot-sector64.bin" >&2
    exit 1
  fi

  if [[ -f "${backup_dir}/partition-table.bin" ]]; then
    echo "Restoring partition table"
    sgdisk --load-backup="${backup_dir}/partition-table.bin" "${disk}"
  fi

  sync
  sgdisk -p "${disk}" | tail -8
  echo "Done."
}

cmd_flash() {
  local do_backup=1 set_bootable=1 backup_dir="" target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--no-backup) do_backup=0; shift ;;
      -b|--backup-dir) backup_dir="$2"; shift 2 ;;
      -p|--boot-part) BOOT_PART="$2"; shift 2 ;;
      --no-bootable) set_bootable=0; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
      *) target="$1"; shift ;;
    esac
  done

  [[ -n "${target}" ]] || { usage >&2; exit 1; }
  [[ -f "${UBOOT_BIN}" ]] || { echo "Error: missing ${UBOOT_BIN}" >&2; exit 1; }
  require_root
  open_disk "${target}"

  local boot_part_dev mnt=""
  boot_part_dev=$(boot_part_path "${disk}" "${BOOT_PART}")

  cleanup() {
    umount "${mnt}" 2>/dev/null || true
    [[ -n "${mnt}" ]] && rmdir "${mnt}" 2>/dev/null || true
    [[ -n "${loop_dev}" ]] && losetup -d "${loop_dev}" 2>/dev/null || true
  }
  trap cleanup EXIT

  local target_base timestamp
  target_base="$(basename "${target}")"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  [[ -n "${backup_dir}" ]] || backup_dir="${SCRIPT_DIR}/backup-${target_base}-${timestamp}"

  echo "Target:       ${target}"
  echo "U-Boot:       ${UBOOT_BIN}"
  echo "Boot part:    ${boot_part_dev} (GPT #${BOOT_PART})"

  if [[ ${do_backup} -eq 1 ]]; then
    mkdir -p "${backup_dir}"
    echo "Backup:       ${backup_dir}"
    sgdisk -p "${disk}" > "${backup_dir}/partitions-before.txt"
    sgdisk --backup="${backup_dir}/partition-table.bin" "${disk}"
    dd if="${disk}" of="${backup_dir}/boot-sector64.bin" bs=512 skip=${UBOOT_SEEK} count=${BOOT_SECTOR_COUNT} status=none conv=fsync
    if [[ -b "${boot_part_dev}" ]]; then
      mnt=$(mktemp -d)
      mount "${boot_part_dev}" "${mnt}"
      cp -a "${mnt}/extlinux/extlinux.conf" "${backup_dir}/extlinux.conf"
      umount "${mnt}"; rmdir "${mnt}"; mnt=""
    fi
  fi

  echo "[flash] dd @ sector ${UBOOT_SEEK}"
  dd if="${UBOOT_BIN}" of="${disk}" bs=${SECTOR_SIZE} seek=${UBOOT_SEEK} conv=fsync,notrunc status=progress

  if [[ ${set_bootable} -eq 1 ]]; then
    echo "[flash] bootable flag on partition ${BOOT_PART}"
    sgdisk -A ${BOOT_PART}:set:2 "${disk}"
  fi

  if [[ ${do_backup} -eq 1 ]]; then
    sgdisk -p "${disk}" > "${backup_dir}/partitions-after.txt"
    local before after
    before=$(grep -cE '^[[:space:]]+[0-9]+' "${backup_dir}/partitions-before.txt" || true)
    after=$(grep -cE '^[[:space:]]+[0-9]+' "${backup_dir}/partitions-after.txt" || true)
    [[ "${before}" == "${after}" ]] || { echo "ERROR: partition count changed" >&2; exit 1; }
    echo "Partitions:   ${after} (unchanged)"
  else
    sgdisk -p "${disk}" | tail -8
  fi

  dd if="${disk}" bs=512 skip=16384 count=8192 status=none | strings | grep -m1 "U-Boot 20" || true
  sync
  echo "Done."
  [[ ${do_backup} -eq 1 ]] && echo "Rollback: sudo $0 restore ${backup_dir} ${target}"
}

# main
if [[ "${1:-}" == "restore" ]]; then
  shift
  [[ $# -eq 2 ]] || { usage >&2; exit 1; }
  cmd_restore "$1" "$2"
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
elif [[ "${1:-}" == "flash" ]]; then
  shift
  cmd_flash "$@"
else
  cmd_flash "$@"
fi
