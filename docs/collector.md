# Optional Nix store collector

The collector is an optional helper for keeping Nix measurements in one shared cache. It runs once per invocation and exits. The first release covers the current system closure's logical size and path count, plus registered NAR logical sizes for the whole store. Once the user opts in by enabling the timer, the aggregate refreshes on each timer run. It does not collect all filesystem usage or topology.

The whole-store NAR total is the sum of Nix's registered logical object sizes. It is not allocated disk usage: compression, deduplication, filesystem metadata, and unregistered files are outside that number. The collector never starts a `du` scan automatically.

## Snapshot and refresh

The helper is named `dankdiskusage-collector`; it supports the `version` subcommand and a one-shot default invocation. It writes a schema version 1 JSON snapshot to:

- `$XDG_CACHE_HOME/dankDiskUsage/snapshot.json`, when `XDG_CACHE_HOME` is an absolute path;
- otherwise `~/.cache/dankDiskUsage/snapshot.json`.

The cache directory and file are private to the user. Updates use an atomic replacement, so readers see either the previous complete snapshot or the new one. Each measurement carries its own last-success timestamp (`updatedAt`), last check timestamp (`checkedAt`), and error state; a failed query does not erase unrelated successful results.

For registered store sizes, the helper opens the local Nix database read-only, verifies the expected `ValidPaths` schema, and aggregates `narSize`. If `sqlite3` is missing or the database cannot be queried with a compatible schema, it uses a bounded public Nix CLI query when available. A CLI fallback can take longer. Missing tools, database access, or Nix permissions are reported in the relevant measurement error.

Closure information refreshes when the target of `/run/current-system` changes. When enabled, the user systemd timer uses `OnStartupSec=2min` and `OnUnitInactiveSec=15min`, with up to one minute of randomized delay. Each run refreshes the whole-store NAR aggregate as well. Values may therefore be up to one timer interval old; consult their timestamps.

## Explicit installation

The repository supplies the unit files at `systemd/dankdiskusage-collector.service` and `systemd/dankdiskusage-collector.timer`. For a manual install, install the helper binary at `~/.local/bin/dankdiskusage-collector` and copy both unit files into `~/.config/systemd/user/`. The service searches common user and system Nix/Linux binary directories for `sqlite3` and Nix commands and has a 120-second timeout. The Nix package installs the units under `lib/systemd/user`, adjusts `ExecStart` to its packaged helper path, and supplies `sqlite3` through the package wrapper. Package installation does not enable the timer. For a manual build from this checkout:

```sh
python3 scripts/package.py --output dist/collector
install -Dm755 dist/collector/bin/dankdiskusage-collector ~/.local/bin/dankdiskusage-collector
mkdir -p ~/.config/systemd/user
cp systemd/dankdiskusage-collector.{service,timer} ~/.config/systemd/user/
```

For Nix/Home Manager, make the packaged units available through your user service configuration (for example, `systemd.user.packages = [ collectorPackage ];` on NixOS) before enabling the timer. Merely installing the binary into a profile may not expose its units.

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
