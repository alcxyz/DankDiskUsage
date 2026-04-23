# ADR-001: Priority-based mount classification over flat listing

**Status:** Accepted
**Date:** 2026-04-23
**Applies to:** `DankDiskUsageWidget.qml`

## Context

The initial widget listed all partitions in one flat section and ZFS pools in another, with ZFS mounts completely filtered from the partitions view. On systems where important paths like `/`, `/home`, and `/nix` live on ZFS, these mounts were invisible. The bar pill showed the worst usage percentage across all volumes, which often surfaced irrelevant storage (e.g. a torrent pool at 84%) instead of the system disk the user cares about.

## Decision

Classify mounts into three buckets using a priority map of well-known system paths (`/`, `/home`, `/nix`, `/var`, `/boot`, etc.):

- **System Storage** — mounts at priority paths, shown prominently regardless of filesystem type. The highest-priority mount drives the bar pill percentage.
- **ZFS Pools** — remaining ZFS datasets grouped by pool name, with expandable detail.
- **Other** — everything else (non-ZFS, non-priority).

## Alternatives Considered

**User-configurable "pinned" mount:** Lets the user pick which mount to highlight. Rejected because it requires manual setup and the priority map covers the common case for all Linux systems.

**Keep flat listing, just stop filtering ZFS:** Would show ZFS mounts but still surface the wrong percentage in the bar pill and provide no grouping.

## Consequences

- The bar pill shows a meaningful system disk percentage on any Linux system without configuration.
- ZFS-backed system paths are visible alongside non-ZFS ones.
- The priority map is hardcoded; uncommon system layouts (e.g. `/data` as the primary mount) won't be prioritized without adding entries to the map.
