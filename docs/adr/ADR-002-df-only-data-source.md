# ADR-002: Use df as sole data source, remove zpool list

**Status:** Accepted
**Date:** 2026-04-23
**Applies to:** `DankDiskUsageWidget.qml`

## Context

The initial widget ran two separate processes: `df` for standard partitions and `zpool list -Hp` for ZFS pools. On many systems `zpool list` requires root privileges and silently returns no data. Meanwhile, `df` already reports all mounted ZFS datasets with per-mount usage, size, and filesystem type — the same information needed for the UI.

## Decision

Use a single `df` call as the sole data source. Derive ZFS pool groupings by parsing the device column (e.g. `zpool/stash` → pool `zpool`). Remove the `zpoolProcess` entirely.

## Alternatives Considered

**Keep zpool list as optional enrichment:** Would add pool health status (ONLINE/DEGRADED) but requires privilege escalation or special permissions. The complexity isn't worth it for a status that rarely changes.

**Run zpool list via sudo/polkit:** Adds a permission prompt or system configuration requirement. Too intrusive for a desktop widget.

## Consequences

- The widget works without root privileges on all systems.
- Pool health status (ONLINE/DEGRADED) is no longer displayed. This is acceptable because health changes are rare and typically surfaced through other monitoring.
- One fewer subprocess per refresh cycle.
- Fuse mounts are excluded via `-x fuse` in the df command to avoid duplicating ZFS datasets that have fuse bind mounts.
