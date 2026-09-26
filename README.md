# DankDiskUsage

A bar widget plugin for [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) that monitors disk, ZFS pool, and Nix store usage with smart mount classification and expandable detail.

![Screenshot](docs/screenshot.png)

## Features

- Smart mount priority: system paths (/, /home, /nix, /var, /boot) are shown prominently in "System Storage"
- Bar pill shows the most important mount's usage percentage
- ZFS datasets grouped by pool with expandable detail views
- Btrfs subvolumes of one filesystem grouped into a single expandable volume, so shared capacity is counted once instead of once per mountpoint
- Optional same-device merging for the remaining filesystems (bind mounts, volumes mounted twice)
- Nix store total size on demand, plus current NixOS generation path count and closure size
- Color-coded usage bars with configurable warning/critical thresholds
- Excludes tmpfs, devtmpfs, overlay, and fuse mounts automatically
- User-defined exclusions for mountpoints and ZFS datasets, with `*` wildcard support

## Installation

### Nix (flake)

Add as a `flake = false` input and include in your DMS plugin configuration:

```nix
inputs.dms-plugin-diskusage = {
  url = "github:alcxyz/DankDiskUsage";
  flake = false;
};
```

```nix
programs.dank-material-shell.plugins.dankDiskUsage = {
  enable = true;
  src = inputs.dms-plugin-diskusage;
};
```

### Manual

Copy the plugin directory to `~/.config/DankMaterialShell/plugins/DankDiskUsage/`.
For an identifiable development build, stage `dist/dev` first and copy
`dist/dev/share/dms-plugins/DankDiskUsage/` instead of the raw checkout.

## Settings

The Nix section refreshes current generation closure details automatically. The full `/nix/store` size is cached and only rescanned when you click the Nix section refresh button, because walking the whole store can be expensive.

`df` can report several Btrfs mountpoints with the same filesystem-wide usage.
**Group Btrfs subvolumes** presents that capacity once and keeps the mountpoint list
expandable. **Merge mountpoints sharing a device** optionally collapses other repeated
device rows; GNU `df` already omits ordinary duplicate bind mounts in many cases.
Grouping conservatively recognizes sources under `/dev/`; pseudo sources, ZFS datasets,
network shares, and paths outside `/dev/` remain separate. See
[ADR-006](docs/adr/ADR-006-device-aware-mount-grouping.md).

**Show partitions** also controls Btrfs groups without system mounts. Groups containing
priority mounts such as `/` or `/home` stay visible. Changes to grouping, visibility,
and exclusions apply to the latest disk snapshot as soon as settings reload, without
waiting for the next disk poll.

| Setting | Default | Description |
|---------|---------|-------------|
| Refresh interval | 30s | How often to poll disk usage data |
| Warning threshold | 80% | Usage percentage for yellow indicator |
| Critical threshold | 95% | Usage percentage for red indicator |
| Show partitions | true | Display non-ZFS, non-system filesystems |
| Show ZFS pools | true | Group ZFS datasets by pool with expandable detail |
| Group Btrfs subvolumes | true | Merge subvolumes of one Btrfs filesystem into a single expandable volume |
| Merge mountpoints sharing a device | false | Collapse the remaining same-device mountpoints into one row with a `+N mounts` badge |
| Show Nix info | true | Display cached store size plus current generation closure details |
| Excluded mountpoints or datasets | [] | Mountpoints or ZFS datasets to hide; supports `*` wildcards such as `/run/user/1000/*` |

+## Development builds

The tracked manifest keeps the release version. To stage an identifiable
development package, run:

```bash
python3 scripts/package.py --output dist/dev
```

This produces a manifest version like `X.Y.Z-dev.<commit>`; a dirty checkout
adds `.dirty`. For Nix, use `pkgs.callPackage ./default.nix { revision = ...; }`.
Release packaging is guarded and requires a clean checkout at the exact
`vX.Y.Z` tag.

## License

MIT

<details>
<summary>Support</summary>

- **BTC:** `bc1pzdt3rjhnme90ev577n0cnxvlwvclf4ys84t2kfeu9rd3rqpaaafsgmxrfa`
- **ETH / ERC-20:** `0x2122c7817381B74762318b506c19600fF8B8372c`
</details>
