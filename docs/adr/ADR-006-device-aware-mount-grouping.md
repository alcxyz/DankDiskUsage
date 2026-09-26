# ADR-006: Device-aware mount grouping

**Status:** Accepted
**Date:** 2026-09-20
**Applies to:** `DankDiskUsageWidget.qml`

## Context

Since [ADR-002](ADR-002-df-only-data-source.md), `df` is the sole data source and every
row it returns becomes one widget row. Btrfs subvolumes can appear as separate
mountpoints with identical filesystem-wide `size`, `used`, `avail`, and `pcent`.
GNU `df` already suppresses many ordinary duplicate bind mounts, so not every repeated
mount produces duplicate rows.

The common case is Btrfs. A subvolume layout such as `@`, `@home`, `@log`, `@pkg`, `@swap`
produces five `df` rows that all describe the same 931G filesystem:

```
/dev/nvme0n1p2  btrfs  931G  447G  479G  49%  /
/dev/nvme0n1p2  btrfs  931G  447G  479G  49%  /home
/dev/nvme0n1p2  btrfs  931G  447G  479G  49%  /swap
/dev/nvme0n1p2  btrfs  931G  447G  479G  49%  /var/log
/dev/nvme0n1p2  btrfs  931G  447G  479G  49%  /var/cache/pacman/pkg
```

Rendered flat, the popout shows five identical 931G bars. Each number is correct, but the
panel implies roughly 4.6T of storage where 931G exists. Any remaining repeated-device
rows can produce the same visual duplication.

ZFS already avoids this: datasets are grouped by pool and rendered as one expandable card.
No equivalent existed for anything else.

## Decision

Collapse mountpoints that describe one filesystem before classification, in two ordered
passes, each behind its own setting:

1. **`showBtrfsVolumes` (default `true`)** — Btrfs mountpoints sharing a block device are
   merged into one expandable volume card, mirroring the ZFS pool grouping. The card
   reports the filesystem capacity once; expanding lists the mountpoints. A device with a
   single mountpoint is left as an ordinary row.
2. **`dedupeByDevice` (default `false`)** — of the rows that remain, those sharing a block
   device collapse to one representative row carrying a `+N mounts` badge. This is
   filesystem-agnostic and covers bind mounts and repeated LVM mounts.

Supporting rules:

- **Representative selection.** `mountRank()` orders candidates by the existing
  `mountPriority` table, falling back to shallowest path for unranked mounts. `/` wins over
  `/home`, which wins over `/var/cache/pacman/pkg`. The group inherits that rank, so the bar
  pill keeps tracking the highest-priority system mount even when it now lives inside a group.
- **Conservative device identity.** Grouping keys on the `df` source column and recognizes
  paths under `/dev/`. This is a naming heuristic, not a filesystem identity query. A leading
  slash alone is insufficient because SMB sources use `//server/share`. Pseudo sources,
  ZFS datasets and network shares remain separate; aliases outside `/dev/` do too.
- **No per-mountpoint capacity when expanded.** Expanded subvolume rows list mountpoints
  only, with no size or usage bar. Capacity belongs to the volume; repeating it per child
  would reintroduce the problem the card exists to fix.
- **Exclusions run first.** `excludeMounts` is applied while parsing `df`, so an excluded
  mountpoint never reaches grouping and never becomes a group representative.
- **Visibility.** `showPartitions` controls groups with only non-priority mounts. A group
  containing a system mount remains visible, preserving ADR-001's system-storage rule.
- **Settings changes.** Reparse the latest `df` output when grouping, visibility or exclusion
  settings change. This rebuilds entries without stale dedupe metadata and restores plain
  rows immediately when grouping is disabled, without another subprocess.

## Alternatives Considered

**Collect per-subvolume usage with Btrfs tools.** `btrfs filesystem usage` still describes
filesystem-wide space. Quota-group accounting can provide subvolume-specific figures, but
requires additional tooling, permissions and quota configuration. Rejected to preserve
the unprivileged, single-`df` approach in ADR-002.

**Deduplicate unconditionally, with no setting.** Smaller surface, but it silently hides
mountpoints some users watch deliberately, and it removes the ability to inspect the raw
`df` view. Rejected in favour of defaults that stay closest to current behaviour for
non-Btrfs setups.

**One generic `dedupeByDevice` toggle with no Btrfs case.** Fixes the arithmetic but throws
away the mountpoint list, which on a subvolume layout is the interesting part. Kept as the
second pass rather than the only one.

**Key grouping on `findmnt` subvolume identity instead of the device.** More precise for
exotic layouts (multi-device Btrfs), but adds a second subprocess per refresh and breaks the
single-`df` invariant from ADR-002.

## Consequences

- Grouped Btrfs capacity is displayed once per source device, avoiding repeated capacity
  bars. The widget does not calculate a physical-disk total.
- On a multi-subvolume Btrfs system the default view changes: `/` and `/home` move from
  "System Storage" into a "Btrfs Volumes" card. Mountpoint detail is one click away.
- Systems with one mountpoint per filesystem see no change at any setting.
- `updatePrimaryUsage()` now ranks volume groups alongside plain mounts, so the bar pill is
  unaffected by whether the highest-priority mount ended up in a group.
- Multi-device Btrfs filesystems (RAID) are grouped per `df` source device, so one logical
  filesystem can still appear as more than one card. Acceptable until a case is reported.
