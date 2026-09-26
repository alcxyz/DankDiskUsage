# ADR-009: Shared cached storage collector

**Status:** Accepted
**Date:** 2026-09-26
**Applies to:** collector helper, packaged service files, `DankDiskUsageWidget.qml`

## Context

The widget currently obtains Nix information itself and keeps transient values in plugin state. A reusable collector can refresh useful Nix metadata outside the widget and expose one cached snapshot to multiple consumers. The first implementation slice covers current system closure logical size and path count, plus the whole-store aggregate of registered NAR logical sizes. With the optional user timer enabled, the aggregate is queried on each run, with rate-limited CLI fallback. The broader shared storage collector remains an umbrella effort for later storage measurements.

Whole-store size must not silently trigger a filesystem walk. Nix's registered NAR sizes are logical object sizes, not physical allocated bytes on disk; they are suitable as a quick, clearly labeled measure but cannot answer the physical disk usage question. A SQLite query can aggregate registered path sizes quickly when the local database has a compatible schema. A bounded public `nix` CLI fallback supports installations where that query is unavailable or incompatible. No automatic `du` scan is introduced.

## Decision

Add `dankdiskusage-collector`, a standard-library-only Go helper that runs once and exits. It writes a version 1 JSON snapshot at `$XDG_CACHE_HOME/dankDiskUsage/snapshot.json`, falling back to `~/.cache/dankDiskUsage/snapshot.json`. Writes use private permissions and atomic replacement. The snapshot records a timestamp and errors per measurement so one failed query does not invalidate successful measurements.

The helper reads Nix's SQLite database read-only, validates the required query result and integer sizes, and aggregates registered `ValidPaths.narSize`. If the database is absent, inaccessible, or incompatible, it uses a bounded public Nix CLI query. Closure measurements refresh when the current-system symlink target changes. Whole-store SQLite aggregation runs each time the opted-in oneshot runs; expensive CLI fallback is rate-limited as described below. The widget setting controls whether it reads the shared snapshot; it does not control or enable the timer.

The repository supplies a user systemd service and 15-minute timer. Manual installs require copying the source unit files; the Nix package installs the units but does not enable the timer. The widget has a `useCollector` setting that defaults to false. When enabled, it reads the existing snapshot only; it does not install, start, or enable services. The existing manual disk scan remains available in either mode; collector mode replaces only automatic Nix metadata queries.

The shared cached snapshot is the initial storage boundary. The umbrella effort includes later phases for local filesystem usage and topology with a suitable cadence, isolated network measurements with timeouts, and a separate opt-in, low-priority physical scan. Each phase should have its own implementation checklist and preserve explicit control of potentially expensive work. The phased work is tracked in [issue #22](https://github.com/alcxyz/DankDiskUsage/issues/22).

## Alternatives considered

**Long-running daemon:** Rejected for the initial slice. A oneshot process has a smaller runtime footprint and systemd timer supplies cadence without adding a persistent process or protocol.

**CLI-only/manual refresh:** Rejected because it leaves repeated work to each consumer and does not provide a shared refreshed snapshot. The oneshot remains explicitly installable and opt-in.

**Embed SQLite in Go:** Not chosen for this slice because a pure-Go SQLite library adds a Go dependency and increases build size. Calling the `sqlite3` CLI read-only keeps the helper on the standard library; the bounded public Nix CLI fallback handles missing or incompatible SQLite access at the cost of slower refresh.

**Have the widget poll the collector:** Rejected. The widget reads the snapshot on its normal refresh and does not manage service lifecycle, preventing duplicate polling or implicit installation.

**Use `du` for whole-store size:** Rejected because it can walk many paths and cause substantial I/O. NAR size is a different, logical registered-size measure and is labeled accordingly.

## Consequences

- Multiple consumers can use one atomic, versioned snapshot without implementing Nix queries independently.
- The helper is cheap to package and has no Go module dependencies. Missing `sqlite3` or an incompatible schema can make refresh slower through the CLI fallback; unavailable Nix tooling or permissions are recorded per measurement.
- Cached values can be stale between timer runs, and the timestamp makes freshness visible.
- NAR totals do not represent allocated filesystem blocks, compression, deduplication, or unregistered files.
- The Nix package installs the supplied unit files but does not enable the user timer. Manual installs require copying the units and placing the helper at the documented path; the helper and required commands must be visible on the service `PATH`.
- This first slice does not claim that all storage collection has moved to the collector.

## Hardening and XDG ownership

Keep settings in DMS's existing XDG-aware settings API, and manual-scan state in its state API. Keep only rebuildable collector data under `XDG_CACHE_HOME`; do not add an independent settings file. Send sanitized diagnostics to stderr/the user journal rather than maintaining and rotating plugin log files. Future persistent file logs would use `XDG_STATE_HOME`.

Retain a nonblocking lock beside the selected snapshot: an overlapping invocation skips successfully, while genuine locking failures remain errors. Never unlink a live lock, which could let two processes lock different inodes. Unknown snapshot versions remain protected from overwrite.

Collection budgets are independent per measurement. SQLite lock contention or timeout keeps the last good value without starting an expensive CLI fallback. Missing tools, inaccessible metadata or incompatible query results may use the public CLI, with at most one fallback attempt per hour. SQLite is checked on every scheduled run so its recovery is immediate. Deferred fallback attempts must not advance measurement freshness.

The next phases prioritize isolation of slow network sources. Local capacity and topology need their own cadence; moving them into a shared snapshot must preserve responsiveness and existing QML grouping behavior, not impose the Nix timer interval on them.
