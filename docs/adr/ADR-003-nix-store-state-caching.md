# ADR-003: Cache Nix closure info via plugin state

**Status:** Accepted
**Date:** 2026-04-23
**Applies to:** `DankDiskUsageWidget.qml`

## Context

The Nix Closure section runs `nix-store --query --requisites /run/current-system | wc -l` to count paths and `nix path-info --closure-size --human-readable /run/current-system` for size. While both are fast (~0.1s), the section showed `?` until the process completed because there was no cached data to display on initial load.

The original implementation used `du -sh /nix/store` for size, which walked all store paths and took minutes. This was replaced with `df /nix/store` (instant, queries filesystem metadata), but that reported the usage of the filesystem containing `/nix/store` rather than the store or closure itself. The size was also initially derived from the main df process's parsed mount data, but this broke on systems where `/nix` is not a separate mount (e.g. NixOS with ZFS root where `/nix/store` lives under `/`).

## Decision

Use `pluginService.savePluginState` / `loadPluginState` to persist the last known Nix closure values (path count and size) across sessions. On load, display cached data immediately, then refresh in the background.

Measure the current system closure rather than the entire `/nix/store` directory. This matches the existing path count semantics and avoids expensive whole-store scans.

## Alternatives Considered

**No caching, just show a spinner:** Acceptable for a 0.1s delay but provides a worse experience on first open — the user sees incomplete data.

**Cache in plugin settings (savePluginData):** Settings are meant for user-configured values. Plugin state is the correct API for transient runtime data that should persist across restarts.

## Consequences

- Nix closure info appears instantly on plugin load using the last known values.
- Stale data is visible briefly until the background refresh completes (at most `refreshInterval` seconds, default 30s).
- State file is written to `~/.local/state/DankMaterialShell/plugins/dankDiskUsage_state.json`.
