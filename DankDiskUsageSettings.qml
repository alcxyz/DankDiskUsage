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
        label: "Show partitions"
        description: "Display standard filesystem partitions (ext4, btrfs, xfs, etc.)"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showZfs"
        label: "Show ZFS pools"
        description: "Display ZFS pool usage and health status"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showNixStore"
        label: "Show Nix store"
        description: "Display /nix/store size and path count"
        defaultValue: true
    }

    ListSettingWithInput {
        settingKey: "excludeMounts"
        label: "Excluded mountpoints"
        description: "Mountpoints to hide from the partitions list (e.g. /boot, /mnt/backup)"
        fields: [
            {id: "value", label: "Mountpoint", placeholder: "e.g., /boot", width: 300, required: true}
        ]
    }
}
