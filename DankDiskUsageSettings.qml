import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "dankDiskUsage"

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Refresh interval (seconds)"
        description: "How often to poll disk usage data"
        minimum: 5
        maximum: 600
        defaultValue: 30
    }

    SliderSetting {
        settingKey: "warningThreshold"
        label: "Warning threshold (%)"
        description: "Usage percentage at which the indicator turns yellow"
        minimum: 50
        maximum: 99
        defaultValue: 80
    }

    SliderSetting {
        settingKey: "criticalThreshold"
        label: "Critical threshold (%)"
        description: "Usage percentage at which the indicator turns red"
        minimum: 70
        maximum: 99
        defaultValue: 95
    }

    ToggleSetting {
        settingKey: "showPartitions"
        label: "Show local filesystems"
        description: "Display remaining internal local filesystems and non-system Btrfs volumes"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showExternalDrives"
        label: "Show external drives"
        description: "Display USB and removable drives separately from local filesystems"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showZfs"
        label: "Show ZFS pools"
        description: "Display ZFS pool usage and health status"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showBtrfsVolumes"
        label: "Group Btrfs subvolumes"
        description: "Collapse subvolumes of one Btrfs filesystem into a single expandable volume instead of repeating its capacity per mountpoint"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showMergedStorage"
        label: "Show merged storage"
        description: "Display mergerfs pools with expandable member filesystem usage details"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showNetworkMounts"
        label: "Show network shares"
        description: "Display NFS, SMB, SSHFS, and rclone mounts as separate rows"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "dedupeByDevice"
        label: "Merge mountpoints sharing a device"
        description: "Show one row per block device for the remaining filesystems (bind mounts, volumes mounted twice); hidden mountpoints are counted in a badge"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showNixStore"
        label: "Show Nix info"
        description: "Display cached store size plus current generation closure details"
        defaultValue: true
    }

    ListSettingWithInput {
        settingKey: "excludeMounts"
        label: "Excluded mountpoints or datasets"
        description: "Hide matching mountpoints or ZFS datasets. Supports * wildcards."
        fields: [
            {id: "value", label: "Pattern", placeholder: "e.g., /boot, /run/user/1000/*, zroot/persist", width: 300, required: true}
        ]
    }
}
