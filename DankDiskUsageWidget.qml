import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ── Persisted settings ──────────────────────────────────────────
    property var pluginService: null
    property int refreshInterval: 30
    property int warningThreshold: 80
    property int criticalThreshold: 95
    property bool showPartitions: true
    property bool showZfs: true
    property bool showNixStore: true
    property var excludeMounts: []

    // ── Runtime state ───────────────────────────────────────────────
    property bool isLoading: true
    property var partitions: []
    property var zfsPools: []
    property var nixStoreInfo: null
    property int worstUsagePercent: 0

    function loadSettings() {
        if (!pluginService || !pluginService.loadPluginData) return
        refreshInterval = pluginService.loadPluginData("dankDiskUsage", "refreshInterval", 30) || 30
        warningThreshold = pluginService.loadPluginData("dankDiskUsage", "warningThreshold", 80) || 80
        criticalThreshold = pluginService.loadPluginData("dankDiskUsage", "criticalThreshold", 95) || 95
        showPartitions = pluginService.loadPluginData("dankDiskUsage", "showPartitions", true) !== false
        showZfs = pluginService.loadPluginData("dankDiskUsage", "showZfs", true) !== false
        showNixStore = pluginService.loadPluginData("dankDiskUsage", "showNixStore", true) !== false
        var saved = pluginService.loadPluginData("dankDiskUsage", "excludeMounts", [])
        excludeMounts = (saved && Array.isArray(saved)) ? saved : []
    }

    Component.onCompleted: {
        loadSettings()
        refreshAll()
    }

    Timer {
        id: settingsReloadTimer
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.loadSettings()
    }

    Timer {
        id: dataRefreshTimer
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        onTriggered: root.refreshAll()
    }

    // ── Data refresh ────────────────────────────────────────────────
    function refreshAll() {
        if (root.showPartitions) dfProcess.running = true
        if (root.showZfs) zpoolProcess.running = true
        if (root.showNixStore) nixStoreProcess.running = true
    }

    // ── df: standard partitions ─────────────────────────────────────
    property Process dfProcess: Process {
        running: false
        command: ["sh", "-c", "df -h --output=source,fstype,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x efivarfs -x overlay 2>/dev/null | tail -n +2"]

        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                var results = []
                for (var i = 0; i < lines.length; i++) {
                    var parts = lines[i].trim().split(/\s+/)
                    if (parts.length < 7) continue
                    var mount = parts.slice(6).join(" ")
                    if (root.isExcluded(mount)) continue
                    // Skip ZFS mounts if showZfs is on (handled separately)
                    if (root.showZfs && parts[1] === "zfs") continue
                    results.push({
                        device: parts[0],
                        fstype: parts[1],
                        size: parts[2],
                        used: parts[3],
                        avail: parts[4],
                        percent: parseInt(parts[5].replace("%", "")) || 0,
                        mount: mount
                    })
                }
                root.partitions = results
                root.updateWorstUsage()
                root.isLoading = false
            }
        }
    }

    // ── ZFS pools ───────────────────────────────────────────────────
    property Process zpoolProcess: Process {
        running: false
        command: ["sh", "-c", "zpool list -Hp -o name,size,alloc,free,capacity,health 2>/dev/null"]

        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                var results = []
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i].trim()) continue
                    var parts = lines[i].trim().split("\t")
                    if (parts.length < 6) continue
                    results.push({
                        name: parts[0],
                        size: root.humanSize(parseInt(parts[1]) || 0),
                        alloc: root.humanSize(parseInt(parts[2]) || 0),
                        free: root.humanSize(parseInt(parts[3]) || 0),
                        percent: parseInt(parts[4]) || 0,
                        health: parts[5]
                    })
                }
                root.zfsPools = results
                root.updateWorstUsage()
                root.isLoading = false
            }
        }
    }

    // ── Nix store ───────────────────────────────────────────────────
    property Process nixStoreProcess: Process {
        running: false
        command: ["sh", "-c", "nix-store --query --requisites /run/current-system 2>/dev/null | wc -l | tr -d ' '; du -sh /nix/store 2>/dev/null | cut -f1"]

        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                if (lines.length >= 2) {
                    root.nixStoreInfo = {
                        paths: parseInt(lines[0]) || 0,
                        size: lines[1] || "?"
                    }
                } else if (lines.length === 1 && lines[0]) {
                    root.nixStoreInfo = {
                        paths: 0,
                        size: lines[0]
                    }
                }
                root.isLoading = false
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────
    function isExcluded(mount) {
        for (var i = 0; i < excludeMounts.length; i++) {
            if (mount === excludeMounts[i]) return true
        }
        return false
    }

    function humanSize(bytes) {
        var units = ["B", "K", "M", "G", "T", "P"]
        var idx = 0
        var val = bytes
        while (val >= 1024 && idx < units.length - 1) {
            val /= 1024
            idx++
        }
        return val.toFixed(idx > 0 ? 1 : 0) + units[idx]
    }

    function updateWorstUsage() {
        var worst = 0
        for (var i = 0; i < partitions.length; i++) {
            if (partitions[i].percent > worst) worst = partitions[i].percent
        }
        for (var j = 0; j < zfsPools.length; j++) {
            if (zfsPools[j].percent > worst) worst = zfsPools[j].percent
        }
        worstUsagePercent = worst
    }

    function usageColor(percent) {
        if (percent >= criticalThreshold) return "#ff4444"
        if (percent >= warningThreshold) return "#ffaa00"
        return Theme.primary
    }

    function barLabel() {
        if (isLoading) return "..."
        return worstUsagePercent + "%"
    }

    // ── Horizontal bar pill ─────────────────────────────────────────
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "hard_drive"
                size: Theme.fontSizeLarge
                color: root.usageColor(root.worstUsagePercent)
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.barLabel()
                font.pixelSize: Theme.fontSizeMedium
                color: root.usageColor(root.worstUsagePercent)
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // ── Vertical bar pill ───────────────────────────────────────────
    verticalBarPill: Component {
        Column {
            spacing: 1

            DankIcon {
                name: "hard_drive"
                size: Theme.fontSizeLarge
                color: root.usageColor(root.worstUsagePercent)
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.barLabel()
                font.pixelSize: Theme.fontSizeSmall
                color: root.usageColor(root.worstUsagePercent)
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ── Popout panel ────────────────────────────────────────────────
    popoutContent: Component {
        Column {
            spacing: Theme.spacingL

            // ── Header ──────────────────────────────────────────────
            Row {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    text: "Disk Usage"
                    font.pixelSize: Theme.fontSizeXLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item { width: 1; height: 1; Layout ? undefined : undefined }

                DankActionButton {
                    buttonSize: 28
                    iconName: "refresh"
                    iconColor: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.refreshAll()
                }
            }

            // ── Loading state ───────────────────────────────────────
            StyledText {
                text: "Loading..."
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeMedium
                visible: root.isLoading
            }

            // ── Partitions section ──────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showPartitions && root.partitions.length > 0

                StyledText {
                    text: "Partitions"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.partitions

                    StyledRect {
                        width: parent.width
                        height: 56
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingXS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                StyledText {
                                    text: modelData.mount
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideMiddle
                                    width: parent.width * 0.5
                                }

                                Item { width: 1; height: 1 }

                                StyledText {
                                    text: modelData.used + " / " + modelData.size
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.right: percentText.left
                                    anchors.rightMargin: Theme.spacingS
                                }

                                StyledText {
                                    id: percentText
                                    text: modelData.percent + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.usageColor(modelData.percent)
                                    anchors.right: parent.right
                                }
                            }

                            // Usage bar
                            Rectangle {
                                width: parent.width
                                height: 4
                                radius: 2
                                color: Theme.withAlpha(Theme.surfaceText, 0.1)

                                Rectangle {
                                    width: parent.width * (modelData.percent / 100)
                                    height: parent.height
                                    radius: 2
                                    color: root.usageColor(modelData.percent)
                                }
                            }
                        }
                    }
                }
            }

            // ── ZFS pools section ───────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showZfs && root.zfsPools.length > 0

                StyledText {
                    text: "ZFS Pools"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.zfsPools

                    StyledRect {
                        width: parent.width
                        height: 56
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingXS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "database"
                                    size: Theme.fontSizeMedium
                                    color: modelData.health === "ONLINE" ? Theme.primary : "#ff4444"
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: modelData.name
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    text: modelData.health
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: modelData.health === "ONLINE" ? Theme.primary : "#ff4444"
                                    font.weight: Font.Medium
                                }

                                Item { width: 1; height: 1 }

                                StyledText {
                                    text: modelData.alloc + " / " + modelData.size
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.right: zpoolPercentText.left
                                    anchors.rightMargin: Theme.spacingS
                                }

                                StyledText {
                                    id: zpoolPercentText
                                    text: modelData.percent + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.usageColor(modelData.percent)
                                    anchors.right: parent.right
                                }
                            }

                            // Usage bar
                            Rectangle {
                                width: parent.width
                                height: 4
                                radius: 2
                                color: Theme.withAlpha(Theme.surfaceText, 0.1)

                                Rectangle {
                                    width: parent.width * (modelData.percent / 100)
                                    height: parent.height
                                    radius: 2
                                    color: root.usageColor(modelData.percent)
                                }
                            }
                        }
                    }
                }
            }

            // ── Nix store section ───────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showNixStore && root.nixStoreInfo !== null

                StyledText {
                    text: "Nix Store"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                StyledRect {
                    width: parent.width
                    height: 48
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Row {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "snowflake"
                            size: Theme.fontSizeMedium
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "/nix/store"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Item { width: 1; height: 1 }

                        StyledText {
                            text: root.nixStoreInfo ? (root.nixStoreInfo.paths + " paths") : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.nixStoreInfo ? root.nixStoreInfo.size : ""
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                        }
                    }
                }
            }

            // ── Empty state ─────────────────────────────────────────
            StyledText {
                text: "No disk information available.\nCheck plugin settings."
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeMedium
                visible: !root.isLoading
                         && root.partitions.length === 0
                         && root.zfsPools.length === 0
                         && root.nixStoreInfo === null
            }
        }
    }

    popoutWidth: 400
    popoutHeight: 480
}
