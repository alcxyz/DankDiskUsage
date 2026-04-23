# ADR-003: Cache Nix Store info via plugin state

**Status:** Accepted
**Date:** 2026-04-23
**Applies to:** `DankDiskUsageWidget.qml`

## Context

The Nix Store section runs `nix-store --query --requisites /run/current-system | wc -l` to count paths and `df /nix/store` for size. While both are fast (~0.1s), the section showed `?` until the process completed because there was no cached data to display on initial load.

The original implementation used `du -sh /nix/store` for size, which walked all store paths and took minutes. This was replaced with `df /nix/store` (instant, queries filesystem metadata). The size was also initially derived from the main df process's parsed mount data, but this broke on systems where `/nix` is not a separate mount (e.g. NixOS with ZFS root where `/nix/store` lives under `/`).

## Decision

Use `pluginService.savePluginState` / `loadPluginState` to persist the last known Nix Store values (path count and size) across sessions. On load, display cached data immediately, then refresh in the background.

## Alternatives Considered

**No caching, just show a spinner:** Acceptable for a 0.1s delay but provides a worse experience on first open — the user sees incomplete data.

**Cache in plugin settings (savePluginData):** Settings are meant for user-configured values. Plugin state is the correct API for transient runtime data that should persist across restarts.

## Consequences

- Nix Store info appears instantly on plugin load using the last known values.
- Stale data is visible briefly until the background refresh completes (at most `refreshInterval` seconds, default 30s).
- State file is written to `~/.local/state/DankMaterialShell/plugins/dankDiskUsage_state.json`.
