# Optional Nix store collector

The collector is an optional helper for keeping Nix measurements in one shared cache. It runs once per invocation and exits. The first release covers the current system closure's logical size and path count, plus registered NAR logical sizes for the whole store. Once the user opts in by enabling the timer, the aggregate refreshes on each timer run. It does not collect all filesystem usage or topology.

The whole-store NAR total is the sum of Nix's registered logical object sizes. It is not allocated disk usage: compression, deduplication, filesystem metadata, and unregistered files are outside that number. The collector never starts a `du` scan automatically.

## Snapshot and refresh

The helper is named `dankdiskusage-collector`; it supports the `version` subcommand and a one-shot default invocation. It writes a schema version 1 JSON snapshot to:

- `$XDG_CACHE_HOME/dankDiskUsage/snapshot.json`, when `XDG_CACHE_HOME` is an absolute path;
- otherwise `~/.cache/dankDiskUsage/snapshot.json`.

The cache directory and file are private to the user. Updates use an atomic replacement, so readers see either the previous complete snapshot or the new one. Each measurement carries its own last-success timestamp (`updatedAt`), last check timestamp (`checkedAt`), and error state; top-level metadata also records generation time and collector version. A failed query does not erase unrelated successful results.

For registered store sizes, the helper opens the local Nix database read-only, validates the required query result and nonnegative integer `narSize` values, and aggregates `narSize`. SQLite waits up to 250 ms for a lock. A busy database or timed-out query preserves the last good result without invoking the CLI. If `sqlite3` is missing, metadata is inaccessible, or the query result is incompatible, a bounded public Nix CLI query may be used. This potentially expensive fallback is attempted at most once per hour, even after success; SQLite is retried every scheduled run. Deferred fallback attempts retain the previous measurement timestamps and explicitly report the deferral. Sanitized error categories appear in the journal, and source provenance appears in the snapshot and widget.

Closure information refreshes when the target of `/run/current-system` changes. When enabled, the user systemd timer uses `OnStartupSec=2min` and `OnUnitInactiveSec=15min`, with up to one minute of randomized delay. Each run attempts the whole-store NAR aggregate as well. SQLite data normally follows the timer cadence; CLI fallback data can be an hour old or older after failures. Consult the timestamps and error state. Closure collection has its own 30-second budget and registered-store collection a separate 60-second budget, so one cannot consume the other’s allowance.

## Explicit installation

The repository supplies the unit files at `systemd/dankdiskusage-collector.service` and `systemd/dankdiskusage-collector.timer`. For a manual install, install the helper binary at `~/.local/bin/dankdiskusage-collector` and copy both unit files into `$XDG_CONFIG_HOME/systemd/user/` (default `~/.config/systemd/user/`). The service searches conventional, XDG-profile, NixOS per-user, multi-user Nix, and FHS binary directories for `sqlite3` and Nix commands and has a 120-second timeout. The Nix package installs the units under `lib/systemd/user`, adjusts `ExecStart` to its packaged helper path, and supplies `sqlite3` through the package wrapper. Package installation does not enable the timer. For manual installs, provide `sqlite3` and Nix commands in one of those profiles; building the helper requires Go 1.23+ and Python. For a manual build from this checkout:

```sh
python3 scripts/package.py --output dist/collector
install -Dm755 dist/collector/bin/dankdiskusage-collector ~/.local/bin/dankdiskusage-collector
case "$XDG_CONFIG_HOME" in
  /*) unit_dir="$XDG_CONFIG_HOME/systemd/user" ;;
  *) unit_dir="$HOME/.config/systemd/user" ;;
esac
mkdir -p "$unit_dir"
cp systemd/dankdiskusage-collector.service systemd/dankdiskusage-collector.timer "$unit_dir/"
```

For NixOS, make the packaged units available through your user service configuration (for example, `systemd.packages = [ collectorPackage ];` on NixOS) before enabling the timer. Merely installing the binary into a profile may not expose its units.

To enable the installed timer, run:

```sh
systemctl --user daemon-reload
systemctl --user enable --now dankdiskusage-collector.timer
```

To stop and disable scheduled collection:

```sh
systemctl --user disable --now dankdiskusage-collector.timer
```

The collector can also be run directly with `dankdiskusage-collector`; `dankdiskusage-collector version` prints its build version. Direct invocation updates the same snapshot.

## Widget integration

`useCollector` defaults to `false`. Turning it on makes the widget read the snapshot during its normal refresh. It does not install a package, copy unit files, or start or enable the timer. Manual disk scanning remains available in either mode. With collector mode off, the widget continues its existing automatic closure queries. If no snapshot exists yet or a measurement has failed, the widget can continue to show unavailable or previously cached information according to that measurement's status.

## Scope and follow-up

This initial slice migrates only the specified Nix measurements. Future phases can consider local filesystem usage and topology with a chosen cadence, network measurements with isolated timeouts, and an opt-in low-priority physical scan. These phases remain part of the broader shared storage collector effort tracked in [issue #22](https://github.com/alcxyz/DankDiskUsage/issues/22). Physical scans must remain separately opt-in and low priority.

The collector checks only the local Nix store. It does not query a configured remote store. The current-system closure is unavailable on hosts without `/run/current-system`; registered store data can still be displayed.

Disable the timer separately when turning off the widget setting. For a nondefault XDG cache directory, ensure the user service manager receives the same `XDG_CACHE_HOME` as the desktop session. An incompatible or malformed existing snapshot is preserved; move it aside before collecting again.

## XDG ownership and diagnostics

Widget preferences remain in DMS's settings API, under its XDG configuration directory. The existing manual-scan result remains in DMS plugin state, under its XDG state directory. The plugin does not create a second settings file. The helper has no standalone settings file: its small command-line interface and systemd overrides configure execution.

The rebuildable snapshot belongs in `XDG_CACHE_HOME`. Relative XDG paths are ignored, following the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/). The snapshot lock stays beside the output, so scheduled and manual runs targeting the same file synchronize even with different runtime environments; the persistent lock file contains no data and is not removed while another process may hold it.

Sanitized collector diagnostics go to stderr. The user service journal handles retention; inspect it with `journalctl --user -u dankdiskusage-collector.service`. Raw command output, store paths, and database error messages are not copied to logs. No separate log files or log-directory setting are introduced. If persistent file logging becomes necessary later, it belongs under `XDG_STATE_HOME`, not the cache or configuration directory.

For custom cache locations, set `XDG_CACHE_HOME` in a service drop-in using `systemctl --user edit dankdiskusage-collector.service`, matching the value in the DMS session. The unit's PATH covers default Nix profile locations; installations using a custom `XDG_STATE_HOME` profile may also need a PATH override. The widget marks measurements stale after 45 minutes; changing the timer interval does not automatically change this threshold.
