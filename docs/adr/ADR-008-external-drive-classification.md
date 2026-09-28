# ADR-008: Optional external-drive classification

**Status:** Accepted
**Date:** 2026-09-26
**Applies to:** `DankDiskUsageWidget.qml`

## Context

The widget currently presents local filesystems together, but USB disks and
other removable devices can be useful to inspect separately. Mount names and
hotplug events alone do not reliably distinguish external storage from local
disks, and USB SSDs may not be marked removable by the kernel.

## Decision

- Use optional, unprivileged `lsblk --json --paths --tree --output NAME,KNAME,PATH,TRAN,RM`
  metadata solely to classify block devices. Continue to use `df` for capacity
  and usage. Run one `lsblk` query per disk poll, with a three-second timeout
  and one-second kill grace period. `lsblk` from util-linux and coreutils
  `timeout` are optional; they are not new runtime hard dependencies.
- Classify a block device as external when its transport is `usb` or its
  removable flag is true. A USB transport identifies a USB SSD as external even
  when `RM` is false. Hotplug presence alone does not imply external status,
  avoiding false positives for internal SATA devices.
- Inherit the external classification through partitions and encrypted or
  mapped child devices. Match `df` source aliases using `NAME`, `KNAME`, and
  `PATH` values from the metadata.
- If `lsblk` is missing, malformed, times out, or cannot classify a source,
  clear the metadata classification and leave that filesystem subject to the
  existing local-filesystem and Btrfs visibility rules. Metadata failure must
  not hide storage.
- Preserve priority system-mount visibility first. Keep merged-pool member
  ownership intact. A non-system Btrfs volume backed by USB is presented in
  **External Drives** as one expandable group with its subvolumes and capacity
  counted once. The external-drive setting independently controls this section.
- Reflect newly plugged and unmounted devices on the next disk poll or manual
  refresh, rather than subscribing to instantaneous hotplug events.

## Alternatives Considered

**Classify by mount path or device name.** These values do not reliably encode
whether storage is external, and aliases can refer to the same device. Rejected
in favor of block metadata and alias matching.

**Treat every hotplugged device as external.** Internal SATA devices can also
appear dynamically. Rejected because it can misclassify local storage.

**Require `lsblk` or use it for capacity.** A missing utility should not make
otherwise visible filesystems disappear, and `df` already provides the usage
data the widget displays. Rejected; `lsblk` is optional classification metadata.

## Consequences

- External USB and removable storage can be shown independently while local
  filesystems keep their existing visibility controls.
- Missing or unusable optional metadata degrades to ordinary local/Btrfs
  classification without hiding capacity or usage.
- External-device visibility follows the disk polling and manual refresh
  cadence, not kernel hotplug events.
- This amends the `df`-only data-source decision only for device classification;
  see [ADR-002](ADR-002-df-only-data-source.md).
