# Changelog

All notable changes to this plugin are documented here. The format follows
Keep a Changelog, and the release workflow publishes each version's section
as its GitHub release notes.

## [Unreleased]

## [0.3.2] - 2026-09-20

- Development installs (built from a checkout that isn't a clean release tag) now stamp themselves with an identifiable version such as `X.Y.Z-dev.<commit>`, with a `.dirty` suffix when the working tree has local changes, so it's obvious at a glance when you're not running an official release. Official releases are unaffected and continue to use the plain `plugin.json` version; a new packaging script (`scripts/package.py`) produces these development builds without changing the tracked source.

## [0.3.1] - 2026-07-03

- Fixed excluded mountpoint settings so entries configured through the DMS settings UI actually take effect again.
- Exclusions now match more reliably: exact mount targets, trailing-slash variations, ZFS dataset/device names, and `*` wildcard patterns for dynamic mount paths (for example `/run/user/1000/*`) are all supported.

## [0.3.0] - 2026-06-02

- Added an on-demand full `/nix/store` size scan, triggered manually from the widget, with the result cached so it doesn't need to be recomputed on every refresh.
- The current NixOS generation's closure size and path count still update automatically on each poll, independent of the manual store scan.

## [0.2.1] - 2026-06-01

Initial release. DankDiskUsage is a bar widget for DankMaterialShell that monitors disk, ZFS pool, and Nix closure usage:

- Smart mount classification groups important system paths (`/`, `/home`, `/nix`, `/var`, `/boot`) into a "System Storage" section so they're always visible, and the bar pill shows the usage percentage of the most important mount rather than the worst across all volumes.
- ZFS datasets are grouped by pool with expandable/collapsible detail views.
- The Nix section shows the current system generation's closure size and path count.
- Usage bars are color-coded against configurable warning (80%) and critical (95%) thresholds, and tmpfs, devtmpfs, overlay, and fuse mounts are excluded automatically to reduce noise.
- Nix Store info is cached so it displays instantly on load instead of being recomputed on every refresh, and overlapping background scans are guarded against so a slow run can't stack with the next poll.
- Includes documentation, license, and screenshots for the plugin.

Early post-release fixes (rolled into this first tagged version) corrected a QML parse error that could prevent the plugin from loading at all, restored text visibility in partition and ZFS entries, and fixed the Nix Store size display to read `/nix/store` directly instead of an unreliable mount-path search.
