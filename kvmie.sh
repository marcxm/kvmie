#!/bin/bash

set -e

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root or with sudo"
  exit 1
fi

usage() {
  echo "Usage:"
  echo "  $0 export <vm_name> <export_dir>"
  echo "  $0 import <vm_name> <export_dir> [<new_disk_dir>]"
  exit 1
}

parse_paths() {
  local xmlfile="$1"
  # Extract all disk file paths
  mapfile -t disk_files < <(xmllint --xpath "//devices/disk/source/@file" "$xmlfile" 2>/dev/null | \
    sed -e 's/ file="/\n/g' -e 's/"//g' | grep -v '^$')
  # Extract nvram file path (element content of <nvram>)
  nvram_file=$(xmllint --xpath "string(//os/nvram)" "$xmlfile" 2>/dev/null || echo "")
}

# Recursively copy qcow2/raw disk and all its backing files
copy_disk_with_backing() {
  local src="$1"
  local dest_dir="$2"

  local abs_src
  abs_src=$(readlink -f "$src")

  local dest="$dest_dir/$abs_src"

  # Avoid copying same file twice
  if [[ -f "$dest" ]]; then
    return
  fi

  echo "Copying disk image: $abs_src"
  mkdir -p "$(dirname "$dest")"
  cp -a "$abs_src" "$dest"

  # Check for backing file recursively
  local backing_file
  backing_file=$(qemu-img info --output=json "$abs_src" 2>/dev/null | jq -r '.["backing-filename"]')

  if [[ "$backing_file" != "null" && -n "$backing_file" ]]; then
    # If relative path, resolve to absolute
    if [[ "$backing_file" != /* ]]; then
      backing_file="$(dirname "$abs_src")/$backing_file"
      backing_file=$(readlink -f "$backing_file")
    fi
    copy_disk_with_backing "$backing_file" "$dest_dir"
  fi
}

export_vm() {
  local vm="$1"
  local export_dir="$2"

  if ! virsh dominfo "$vm" &>/dev/null; then
    echo "VM '$vm' does not exist."
    exit 1
  fi

  mkdir -p "$export_dir/snapshots"

  # Dump XML
  local xmlfile="$export_dir/${vm}.xml"
  virsh dumpxml "$vm" > "$xmlfile"

  # Parse disk and nvram paths
  parse_paths "$xmlfile"

  echo "Exporting VM '$vm' to '$export_dir'..."

  # Copy all disk images and their backing files recursively
  for disk in "${disk_files[@]}"; do
    if [[ -f "$disk" ]]; then
      copy_disk_with_backing "$disk" "$export_dir"
    else
      echo "Warning: Disk image file '$disk' not found!"
    fi
  done

  # Copy nvram file if exists
  if [[ -n "$nvram_file" ]]; then
    if [[ -f "$nvram_file" ]]; then
      echo "Copying NVRAM file: $nvram_file"
      mkdir -p "$export_dir/$(dirname "$nvram_file")"
      cp -a "$nvram_file" "$export_dir/$nvram_file"
    else
      echo "Warning: NVRAM file '$nvram_file' not found!"
    fi
  fi

  # Export all snapshot XMLs
  echo "Exporting snapshot definitions..."
  mapfile -t snapshots < <(virsh snapshot-list --domain "$vm" --name)
  for snap in "${snapshots[@]}"; do
    if [[ -n "$snap" ]]; then
      echo "  Exporting snapshot: $snap"
      virsh snapshot-dumpxml "$vm" "$snap" > "$export_dir/snapshots/${snap}.xml"
    fi
  done

  echo "Export completed."
}

# Global associative array to track copied files during import
declare -A copied_files

import_disk_with_backing() {
  local disk="$1"
  local export_dir="$2"
  local new_disk_dir="$3"

  local abs_disk
  abs_disk=$(readlink -f "$disk")
  local export_disk_path="$export_dir/$abs_disk"

  # Avoid copying same file twice
  if [[ -n "${copied_files[$abs_disk]}" ]]; then
    return
  fi
  copied_files[$abs_disk]=1

  local target_disk_path="$abs_disk"
  if [[ -n "$new_disk_dir" ]]; then
    target_disk_path="$new_disk_dir/$(basename "$abs_disk")"
  fi

  if [[ ! -f "$export_disk_path" ]]; then
    echo "Warning: Disk image '$export_disk_path' not found in export directory!"
    return
  fi

  echo "Copying disk image to $target_disk_path"
  mkdir -p "$(dirname "$target_disk_path")"
  cp -a "$export_disk_path" "$target_disk_path"

  # Update VM XML disk source path if new_disk_dir is specified
  if [[ -n "$new_disk_dir" ]]; then
    sed -i "s|<source file=\"$abs_disk\"|<source file=\"$target_disk_path\"|g" "$export_dir/${vm_name}.xml"
  fi

  # Recursively handle backing file
  local backing_file
  backing_file=$(qemu-img info --output=json "$export_disk_path" 2>/dev/null | jq -r '.["backing-filename"]')

  if [[ "$backing_file" != "null" && -n "$backing_file" ]]; then
    if [[ "$backing_file" != /* ]]; then
      backing_file="$(dirname "$abs_disk")/$backing_file"
      backing_file=$(readlink -f "$backing_file")
    fi
    import_disk_with_backing "$backing_file" "$export_dir" "$new_disk_dir"
  fi
}

import_vm() {
  local vm="$1"
  local export_dir="$2"
  local new_disk_dir="$3"

  local xmlfile="$export_dir/${vm}.xml"
  if [[ ! -f "$xmlfile" ]]; then
    echo "Export XML file '$xmlfile' not found."
    exit 1
  fi

  # Parse disk and nvram paths from the exported XML
  parse_paths "$xmlfile"

  echo "Importing VM '$vm' from '$export_dir'..."

  # Clear global copied_files associative array
  copied_files=()

  # Copy all disk images and their backing files recursively
  for disk in "${disk_files[@]}"; do
    import_disk_with_backing "$disk" "$export_dir" "$new_disk_dir"
  done

  # Copy NVRAM file always to original location
  if [[ -n "$nvram_file" ]]; then
    local export_nvram_path="$export_dir/$nvram_file"
    if [[ ! -f "$export_nvram_path" ]]; then
      echo "Warning: NVRAM file '$export_nvram_path' not found in export directory!"
    else
      echo "Copying NVRAM file to $nvram_file"
      mkdir -p "$(dirname "$nvram_file")"
      cp -a "$export_nvram_path" "$nvram_file"
    fi
  fi

  # Copy XML definition to /etc/libvirt/qemu/
  local target_xml="/etc/libvirt/qemu/${vm}.xml"
  echo "Copying VM XML definition to $target_xml"
  cp -a "$xmlfile" "$target_xml"

  echo "Defining VM with virsh..."
  virsh define "$target_xml"

  # Import all snapshot XMLs
  if [[ -d "$export_dir/snapshots" ]]; then
    echo "Importing snapshot definitions..."
    for snapxml in "$export_dir"/snapshots/*.xml; do
      if [[ -f "$snapxml" ]]; then
        echo "  Importing snapshot: $(basename "$snapxml" .xml)"
        virsh snapshot-create "$vm" --redefine --xmlfile "$snapxml"
      fi
    done
  fi

  echo "Import completed. VM '$vm' is defined."
}

if [[ $# -lt 3 ]]; then
  usage
fi

cmd="$1"
vm_name="$2"
dir="$3"
alt_disk_dir="$4"

case "$cmd" in
  export)
    export_vm "$vm_name" "$dir"
    ;;
  import)
    import_vm "$vm_name" "$dir" "$alt_disk_dir"
    ;;
  *)
    usage
    ;;
esac

