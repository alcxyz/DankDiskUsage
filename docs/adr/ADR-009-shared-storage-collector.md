# ADR-009: Shared cached storage collector

**Status:** Accepted
**Date:** 2026-09-26 (revised 2026-09-28)
**Applies to:** collector helper, packaged service files, `DankDiskUsageWidget.qml`

## Context

The widget currently obtains Nix information itself and keeps transient values in plugin state. A reusable collector can refresh useful Nix metadata and expose one cached snapshot to multiple consumers. The first implementation slice covers current system closure logical size and path count, plus the whole-store aggregate of registered NAR logical sizes. The broader shared storage collector remains an umbrella effort for later storage measurements.

Whole-store size must not silently trigger a filesystem walk. Nix's registered NAR sizes are logical object sizes, not physical allocated bytes on disk; they are suitable as a quick, clearly labeled measure but cannot answer the physical disk usage question. A SQLite query can aggregate registered path sizes quickly when the local database has a compatible schema. A bounded public `nix` CLI fallback supports installations where that query is unavailable or incompatible. No automatic `du` scan is introduced.

## Decision

Add `dankdiskusage-collector`, a standard-library-only Go helper that runs once and exits. It writes a version 1 JSON snapshot at `$XDG_CACHE_HOME/dankDiskUsage/snapshot.json`, falling back to `~/.cache/dankDiskUsage/snapshot.json`. Writes use private permissions and atomic replacement. The snapshot records a timestamp and errors per measurement so one failed query does not invalidate successful measurements.

When **Use cached Nix collector** is enabled, the widget invokes the helper asynchronously during its normal refresh, at most once per minute, while the DMS widget runs, including when its dropdown is closed. The helper checks a shared 15-minute refresh interval under the snapshot lock, so repeated widget polls and an optional systemd timer do not cause duplicate collection. `--refresh-interval` configures this guard; zero forces a normal refresh, while the separate one-hour limit on CLI fallback remains in effect. The helper reads Nix's SQLite database read-only, validates the required query result and integer sizes, and aggregates registered `ValidPaths.narSize`. If the database is absent, inaccessible, or incompatible, it uses a bounded public Nix CLI query. Closure measurements refresh when the current-system symlink target changes.

The plugin package contains the helper; the package must be installed in an environment available on DMS's `PATH`. Manual installs must also make the helper available there. The widget does not install the helper or enable services. The repository supplies an optional user systemd service and timer for users who want collection to continue independently of DMS. The Nix package installs the units but does not enable the timer. The existing manual disk scan remains available in either mode; collector mode replaces only automatic Nix metadata queries.

The shared cached snapshot is the initial storage boundary. The umbrella effort includes later phases for local filesystem usage and topology with a suitable cadence, isolated network measurements with timeouts, and a separate opt-in, low-priority physical scan. Each phase should have its own implementation checklist and preserve explicit control of potentially expensive work. The phased work is tracked in [issue #22](https://github.com/alcxyz/DankDiskUsage/issues/22).

## Alternatives considered

**Long-running daemon:** Rejected for the initial slice. A oneshot process has a smaller runtime footprint and systemd timer supplies cadence without adding a persistent process or protocol.

**Manual-only refresh:** Rejected because it leaves repeated work to each consumer and does not provide a shared refreshed snapshot. The helper remains a oneshot; the widget starts it automatically when the user opts in.

**Embed SQLite in Go:** Not chosen for this slice because a pure-Go SQLite library adds a Go dependency and increases build size. Calling the `sqlite3` CLI read-only keeps the helper on the standard library; the bounded public Nix CLI fallback handles missing or incompatible SQLite access at the cost of slower refresh.

**Require users to install and enable a timer for widget updates:** Initially chosen to keep the widget a snapshot-only reader. Revisited after comparing the setup experience with sibling plugins that bundle and invoke their Go helpers directly. Repeated widget invocations are bounded by the helper's shared refresh guard and lock, so this extra setup is unnecessary. The widget invokes the helper when opted in, but still does not install it or manage service lifecycle. The optional timer only covers collection while DMS is not running.

**Use `du` for whole-store size:** Rejected because it can walk many paths and cause substantial I/O. NAR size is a different, logical registered-size measure and is labeled accordingly.

## Consequences

- Multiple consumers can use one atomic, versioned snapshot without implementing Nix queries independently.
- The helper is cheap to package and has no Go module dependencies. Missing `sqlite3` or an incompatible schema can make refresh slower through the CLI fallback; unavailable Nix tooling or permissions are recorded per measurement.
- With the setting enabled, the helper refreshes at most once per 15 minutes by default while DMS is running. The optional timer can keep data fresh while DMS is not running; timestamps make freshness visible.
- NAR totals do not represent allocated filesystem blocks, compression, deduplication, or unregistered files.
- The plugin package contains the helper and must be installed in an environment available on DMS's `PATH`; manual installs must make it available there as well. The Nix package installs optional unit files but does not enable the user timer. The helper and required commands must be visible on the service `PATH`.
- This first slice does not claim that all storage collection has moved to the collector.

## Hardening and XDG ownership

Keep settings in DMS's existing XDG-aware settings API, and manual-scan state in its state API. Keep only rebuildable collector data under `XDG_CACHE_HOME`; do not add an independent settings file. Send sanitized diagnostics to stderr/the user journal rather than maintaining and rotating plugin log files. Future persistent file logs would use `XDG_STATE_HOME`.

Retain a nonblocking lock beside the selected snapshot: an overlapping invocation skips successfully, while genuine locking failures remain errors. Never unlink a live lock, which could let two processes lock different inodes. Unknown snapshot versions remain protected from overwrite.

Collection budgets are independent per measurement. SQLite lock contention or timeout keeps the last good value without starting an expensive CLI fallback. Missing tools, inaccessible metadata or incompatible query results may use the public CLI, with at most one fallback attempt per hour. SQLite is checked on every due collection so its recovery is immediate. Deferred fallback attempts must not advance measurement freshness. Widget-triggered diagnostics go to stderr and appear in DMS/Quickshell logs; timer-triggered diagnostics go to stderr and the user journal.

The next phases prioritize isolation of slow network sources. Local capacity and topology need their own cadence; moving them into a shared snapshot must preserve responsiveness and existing QML grouping behavior, not impose the Nix timer interval on them.
