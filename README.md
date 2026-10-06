# NUMA `kernelcore` memory-offline helper

This project automates a two-stage Linux memory-hotplug workflow for a NUMA node:

1. Add a calculated `kernelcore=` boot parameter to the **currently running kernel's** GRUB entry.
2. Reboot that kernel once, then offline only the target node's blocks whose zone is `Movable`.

It is for machines where an entire NUMA node cannot be offlined because its normal memory contains unmovable kernel pages.

## What it does

`kernelcore=` reserves a global amount of `ZONE_NORMAL` memory for allocations that cannot move, such as page tables, slab allocations, and many driver allocations. The remaining memory becomes `ZONE_MOVABLE`, where user memory and page cache can be evacuated during memory offlining.

The script takes a requested normal-memory target for a node and estimates the global kernel-core budget as:

```text
kernelcore = requested normal GiB × number of memory-bearing NUMA nodes
```

The kernel distributes this budget between nodes. The result is approximate, not an exact node-size guarantee: memory-hotplug blocks cannot be split, so mixed boundary blocks remain online.

## Requirements

- Linux with NUMA and memory hot-remove support
- `bash`, `systemd`, and `grubby`
- Root access
- A GRUB entry at `/boot/vmlinuz-$(uname -r)` for the currently running kernel

## Usage

Review the script first, then run it as root. For example, to aim for about 11 GiB of normal memory on node 1 and reboot immediately:

```bash
sudo ./node-kernelcore-offline.sh --node 1 --online-gib 11 --reboot
```

Without `--reboot`, it configures the one-shot post-boot service and prints a reminder to reboot manually:

```bash
sudo ./node-kernelcore-offline.sh --node 1 --online-gib 11
```

On the next boot it temporarily selects the edited current-kernel entry, runs the one-shot offlining pass, and restores the previous GRUB default after success.

## Safety behavior

- If the **running** kernel already has `kernelcore=`, the script makes no changes.
- It only offlines blocks whose current `valid_zones` value is exactly `Movable`.
- It never tries to offline `Normal` or mixed (`none`) blocks.
- A failed block remains online. The pending state remains so the `--resume` stage can be retried after investigating the failure.
- The normal GRUB default is restored after a successful one-shot run.

## Verify the result

After the reboot and offlining pass:

```bash
numactl -H
lsmem -o RANGE,SIZE,STATE,REMOVABLE,NODE,BLOCK
```

To inspect zone placement:

```bash
awk '
/^Node [0-9]+, zone/ { zone=$0 }
/^[[:space:]]+managed / { print zone "  " $1 " " $2 }
' /proc/zoneinfo
```

## Limitations

`kernelcore=` is global, not a per-node control. It can make most of a node removable, but cannot guarantee that a node has zero normal memory. If the goal is to permanently hide a node entirely from Linux, use a firmware/BMC or hypervisor setting instead.

The script changes kernel boot configuration and can reboot the system. Test it during a maintenance window and ensure you have console access.
