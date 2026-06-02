# ADR-004: Manual Nix store size scans

**Status:** Accepted
**Date:** 2026-06-01
**Applies to:** `DankDiskUsageWidget.qml`

## Context

The Nix section has two useful but different questions to answer:

- How large is the whole `/nix/store`?
- How large is the current NixOS system generation closure?

The current generation closure is cheap to query with `nix path-info --closure-size --human-readable /run/current-system`, and its path count is cheap to query with `nix-store --query --requisites /run/current-system`.

The whole store size is different. `df /nix/store` is fast but incorrect for this purpose because it reports usage for the containing filesystem. `du -sh /nix/store` answers the user-facing question more directly, but it can walk many store paths and produce unwanted background I/O.

## Decision

Refresh current generation closure size and path count automatically with the normal widget refresh.

Do not run whole-store scans automatically. Show the last cached store total when available, show `Not scanned` when unavailable, and run `du -sh /nix/store` only when the user clicks the Nix section refresh button.

Cache the manual store total in plugin state alongside the current generation values.

## Alternatives Considered

**Use `df /nix/store`:** Rejected because it reports filesystem usage, not store size.

**Run `du -sh /nix/store` on every refresh:** Rejected because it can be expensive and surprising on large stores.

**Use Nix store metadata for all paths:** Rejected for now because it reports Nix object/NAR size semantics rather than the intuitive filesystem size users expect from a disk usage widget.

## Consequences

- The Nix section can show both whole-store and current-generation information.
- The widget avoids surprise background scans of `/nix/store`.
- Store total can be stale until the user manually refreshes it.
