#!/usr/bin/env bash
# Configure a one-time, post-reboot memory-offline pass for a NUMA node.
#
# Example:
#   sudo ./node-kernelcore-offline.sh --node 1 --online-gib 11 --reboot
#   sudo ./node-kernelcore-offline.sh --node 1 --kernel /boot/vmlinuz-5.15.95-uts+ --kernelcore-gib 15 --reboot
#
# The requested online size is a per-memory-node ZONE_NORMAL target.  Linux
# distributes kernelcore across memory nodes, and a memory-hotplug block cannot
# be split, so the final online size can be larger than requested.

set -Eeuo pipefail

readonly INSTALL_PATH=/usr/local/sbin/node-kernelcore-offline
readonly STATE_DIR=/var/lib/node-kernelcore-offline
readonly STATE_FILE="$STATE_DIR/pending.env"
readonly UNIT_NAME=node-kernelcore-offline.service
readonly UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

require_root() {
  [[ $EUID -eq 0 ]] || die 'run this script with sudo or as root'
}

current_kernel_path() {
  printf '/boot/vmlinuz-%s\n' "$(uname -r)"
}

has_current_kernelcore() {
  [[ " $(< /proc/cmdline) " =~ [[:space:]]kernelcore=[^[:space:]]+ ]]
}

memory_node_count() {
  local node mem_kib count=0
  for node in /sys/devices/system/node/node[0-9]*; do
    [[ -r "$node/meminfo" ]] || continue
    mem_kib=$(awk '/MemTotal:/ { print $4; exit }' "$node/meminfo")
    [[ ${mem_kib:-0} -gt 0 ]] && ((count += 1))
  done
  printf '%s\n' "$count"
}

write_unit() {
  cat > "$UNIT_PATH" <<'EOF'
[Unit]
Description=Offline movable memory blocks after a kernelcore reboot
After=local-fs.target systemd-udev-settle.service
Before=multi-user.target
ConditionPathExists=/var/lib/node-kernelcore-offline/pending.env

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/node-kernelcore-offline --resume
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

restore_previous_default() {
  # The old default is saved solely so this one-shot operation does not
  # permanently change the user's normal GRUB default kernel.
  [[ -n ${OLD_DEFAULT_KERNEL:-} ]] || return 0
  grubby --set-default "$OLD_DEFAULT_KERNEL"
}

resume() {
  require_root
  [[ -r "$STATE_FILE" ]] || die "no pending operation at $STATE_FILE"
  # This file is created by this script with validated numeric inputs.
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  [[ ${NODE:-} =~ ^[0-9]+$ ]] || die 'invalid pending node number'
  [[ ${KERNELCORE:-} =~ ^[0-9]+G$ ]] || die 'invalid pending kernelcore value'
  [[ ${TARGET_RELEASE:-} =~ ^[[:alnum:].+_-]+$ ]] || die 'invalid pending target kernel release'
  [[ -d "/sys/devices/system/node/node$NODE" ]] || die "NUMA node $NODE is absent"
  [[ $(uname -r) == "$TARGET_RELEASE" ]] || die "this boot is $(uname -r), but pending operation targets $TARGET_RELEASE"
  [[ " $(< /proc/cmdline) " == *" kernelcore=$KERNELCORE "* ]] ||
    die "this boot does not have the expected kernelcore=$KERNELCORE parameter"

  local block state zones total=0 offlined=0 failures=0
  note "Post-boot stage: node $NODE, offlining only blocks whose current zone is Movable."
  for block in /sys/devices/system/node/node"$NODE"/memory*; do
    [[ -e "$block/valid_zones" ]] || continue
    zones=$(< "$block/valid_zones")
    [[ "$zones" == "Movable" ]] || continue
    ((total += 1))
    if printf 'offline\n' > "$block/state"; then
      note "$(basename "$block"): offlined"
      ((offlined += 1))
    else
      note "$(basename "$block"): FAILED (left online)"
      ((failures += 1))
    fi
  done

  note "Movable blocks considered: $total; offlined: $offlined; failures: $failures."
  if ((failures > 0)); then
    die 'some blocks could not be offlined; state was retained so --resume can be retried'
  fi

  restore_previous_default
  rm -f "$STATE_FILE"
  systemctl disable "$UNIT_NAME" >/dev/null || true
  systemctl daemon-reload
  note 'Completed. Check with: lsmem -o RANGE,SIZE,STATE,REMOVABLE,NODE,BLOCK'
}

configure() {
  local node='' online_gib='' kernelcore_override='' kernel='' do_reboot=0 arg
  while (($#)); do
    arg=$1
    case "$arg" in
      --node) node=${2:-}; shift 2 ;;
      --online-gib) online_gib=${2:-}; shift 2 ;;
      --kernelcore-gib) kernelcore_override=${2:-}; shift 2 ;;
      --kernel) kernel=${2:-}; shift 2 ;;
      --reboot) do_reboot=1; shift ;;
      --help|-h)
        sed -n '2,12p' "$0"
        exit 0
        ;;
      *) die "unknown argument: $arg" ;;
    esac
  done

  require_root
  [[ $node =~ ^[0-9]+$ ]] || die '--node must be a non-negative integer'
  [[ -z $online_gib || $online_gib =~ ^[1-9][0-9]*$ ]] || die '--online-gib must be a positive whole number'
  [[ -z $kernelcore_override || $kernelcore_override =~ ^[1-9][0-9]*$ ]] || die '--kernelcore-gib must be a positive whole number'
  [[ -n $online_gib || -n $kernelcore_override ]] || die 'provide --online-gib or --kernelcore-gib'
  [[ -z $online_gib || -z $kernelcore_override ]] || die 'use only one of --online-gib and --kernelcore-gib'
  [[ -d "/sys/devices/system/node/node$node" ]] || die "NUMA node $node is absent"

  [[ -n $kernel ]] || kernel=$(current_kernel_path)
  [[ -f $kernel ]] || die "kernel image does not exist: $kernel"
  if [[ $kernel == "$(current_kernel_path)" ]] && has_current_kernelcore; then
    note 'The running kernel already has a kernelcore= parameter. No changes made.'
    return 0
  fi

  command -v grubby >/dev/null || die 'grubby is required'
  command -v systemctl >/dev/null || die 'systemd is required'
  [[ ! -e "$STATE_FILE" ]] || die "a pending operation exists at $STATE_FILE"

  local old_default nodes kernelcore_gib target_release entry
  grubby --info "$kernel" >/dev/null || die "GRUB has no entry for $kernel"
  entry=$(grubby --info "$kernel")
  if [[ " $entry " =~ [[:space:]]kernelcore=[^[:space:]]+ ]]; then
    note 'The selected kernel already has a kernelcore= parameter. No changes made.'
    return 0
  fi
  old_default=$(grubby --default-kernel)
  target_release=$(basename "$kernel")
  target_release=${target_release#vmlinuz-}
  if [[ -n $online_gib ]]; then
    nodes=$(memory_node_count)
    ((nodes > 0)) || die 'could not find any memory-bearing NUMA nodes'
    kernelcore_gib=$((online_gib * nodes))
    note "Memory-bearing NUMA nodes: $nodes"
    note "Requested node-$node normal-memory target: about ${online_gib} GiB"
  else
    kernelcore_gib=$kernelcore_override
    note "Requested global kernelcore budget: ${kernelcore_gib} GiB"
  fi
  note "Adding kernelcore=${kernelcore_gib}G to $kernel"
  note 'The final online size can be higher because mixed hotplug blocks cannot be split.'

  install -D -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$INSTALL_PATH"
  install -d -m 0700 "$STATE_DIR"
  printf 'NODE=%q\nKERNELCORE=%q\nTARGET_RELEASE=%q\nOLD_DEFAULT_KERNEL=%q\n' \
    "$node" "${kernelcore_gib}G" "$target_release" "$old_default" > "$STATE_FILE"
  write_unit

  grubby --update-kernel="$kernel" --args="kernelcore=${kernelcore_gib}G"
  grubby --set-default "$kernel"
  systemctl enable "$UNIT_NAME" >/dev/null

  note 'Configured successfully.'
  note "The next boot will use $kernel once, run the movable-block offlining pass, and restore the prior GRUB default."
  if ((do_reboot)); then
    note 'Rebooting now.'
    systemctl reboot
  else
    note 'Reboot when ready, or rerun with --reboot to reboot now.'
  fi
}

if [[ ${1:-} == --resume ]]; then
  shift
  (($# == 0)) || die '--resume does not accept other arguments'
  resume
else
  configure "$@"
fi
