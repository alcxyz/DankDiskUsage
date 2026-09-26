# ADR-007: Merged and network storage

**Status:** Accepted
**Date:** 2026-09-26
**Applies to:** `DankDiskUsageWidget.qml`

## Context

Mergerfs exposes a pooled mount whose available capacity is useful to monitor,
while its underlying filesystems may also appear in `df`. Showing both without
context can make the pool's constituent capacity look like unrelated storage.
Network filesystems likewise need a clear classification so they can be shown
as their own mounts rather than merged with local storage.

## Decision

- Recognize mergerfs only by the `fuse.mergerfs` or `mergerfs` filesystem type.
  Show each pool as an expandable **Merged Storage** card using its mount's `df`
  capacity and usage.
- Optionally read `user.mergerfs.branches` from `<mount>/.mergerfs` with
  `getfattr --only-values`; bound the lookup with `timeout` at three seconds and
  a one-second kill grace period. Treat `attr` and coreutils `timeout` as
  optional dependencies. Parse branch paths and their `RW`, `RO`, or `NC` mode.
  Metadata is cached in memory and refreshed on disk polls and display-setting changes.
  Keep pending requests in order so slow lookups do not starve later pools.
- Use the longest matching non-root `df` mountpoint for each branch path, with
  path-boundary matching. Use the root mount only when the branch path itself
  is `/`. If no member filesystem can be mapped, do not infer that the root
  filesystem is the branch. Show member filesystem `df` usage, never per-file
  scans. If attribute lookup or mapping fails, keep pool capacity visible and
  leave member rows visible in the ordinary list.
- When member filesystems are represented in a mergerfs card, remove their
  ordinary rows from **Other**. Multiple branches mapped to one mount share a
  single member card, so its capacity is not repeated. Keep priority system mounts visible under the
  system classification regardless of this suppression or the card's
  visibility setting.
- Classify NFS/nfs4, CIFS/smb3, `fuse.sshfs`/sshfs, and `fuse.rclone`/rclone as
  network mounts. Keep each mount as an independent row with its protocol and
  source; do not combine their capacities into an aggregate. Do not classify
  arbitrary FUSE filesystems as network mounts.
- `showMergedStorage` and `showNetworkMounts` independently control their
  dedicated sections. Priority system mounts remain visible regardless of
  either setting.

## Alternatives Considered

**Use per-file scans to estimate mergerfs member usage.** This is expensive and
would not reliably represent filesystem capacity. Rejected; `df` remains the
usage source.

**Treat every FUSE mount as a network share.** FUSE includes local filesystems
and other virtual mounts. Rejected in favour of an explicit supported type
list.

**Infer missing mergerfs members from `/`.** The root filesystem is not
necessarily a pool member. Rejected; only a branch path of `/` may map to the
root mount.

## Consequences

- A mergerfs card reports the pooled capacity once and can show mapped member
  filesystem usage without scanning files.
- Optional attribute tooling affects only member detail. Missing tools,
  timeout, or unavailable attributes do not hide pool capacity.
- Network mounts remain individually inspectable and are not presented as a
  combined capacity total.
- Members mapped into a pool are omitted from **Other**, while priority system
  mounts keep their existing visibility.
- The `df`-only data source decision is amended only for branch-path metadata;
  see [ADR-002](ADR-002-df-only-data-source.md).
