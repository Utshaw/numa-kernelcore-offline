# NUMA `kernelcore` memory-offline helper

Automate a two-stage Linux memory-hotplug workflow for a NUMA node:

1. Add a `kernelcore=` boot parameter to a selected GRUB kernel entry.
2. Boot that kernel once.
3. Offline only the target node’s memory blocks currently in `ZONE_MOVABLE`.

This is useful when a NUMA node cannot be fully offlined because its normal memory contains unmovable kernel pages.

## How it works

Linux classifies RAM both by NUMA node and by memory zone:

- `ZONE_NORMAL` can contain unmovable kernel allocations such as slab objects, page tables, and driver memory.
- `ZONE_MOVABLE` is intended for movable pages such as process memory and page cache.

A memory-hotplug block can be offlined only when its pages can be migrated away. `kernelcore=` preserves a limited global pool of normal, kernel-capable memory and lets the rest become movable.

The script creates a one-time systemd service. After rebooting the selected kernel, that service offlines only the target node’s blocks whose `valid_zones` value is exactly `Movable`.

## Requirements

- Linux with NUMA and memory-hot-remove support
- `bash`
- `systemd`
- `grubby`
- Root access
- A GRUB entry for the selected kernel
- Console or out-of-band access during testing

## Basic usage

To target NUMA node 1 and aim for about 11 GiB of normal memory per memory-bearing NUMA node:

```bash
sudo ./node-kernelcore-offline.sh \
  --node 1 \
  --online-gib 11 \
  --reboot