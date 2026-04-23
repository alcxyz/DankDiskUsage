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

    // ── Mount priority (lower = more important) ─────────────────────
    readonly property var mountPriority: ({
        "/": 1, "/home": 2, "/nix": 3, "/var": 4, "/boot": 5,
        "/root": 6, "/opt": 7, "/srv": 8, "/usr": 9, "/mnt": 10
    })

    // ── Runtime state ───────────────────────────────────────────────
    property bool isLoading: true
    property var importantMounts: []
    property var zfsPoolGroups: []
    property var otherMounts: []
    property var nixStoreInfo: null
    property int primaryUsagePercent: 0
    property var expandedPools: ({})

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
        loadCachedNixStore()
        refreshAll()
    }

    function loadCachedNixStore() {
        if (!pluginService) return
        var cached = pluginService.loadPluginState("dankDiskUsage", "nixStoreCache", null)
        if (cached && cached.paths !== undefined) {
            nixStoreInfo = cached
        }
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
        if (!dfProcess.running) dfProcess.running = true
        if (root.showNixStore && !nixPathCountProcess.running) nixPathCountProcess.running = true
    }

    // ── df: all filesystems ─────────────────────────────────────────
    property Process dfProcess: Process {
        running: false
        command: ["sh", "-c", "df -h --output=source,fstype,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x efivarfs -x overlay -x fuse 2>/dev/null | tail -n +2"]

        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                var all = []
                for (var i = 0; i < lines.length; i++) {
                    var parts = lines[i].trim().split(/\s+/)
                    if (parts.length < 7) continue
                    var mount = parts.slice(6).join(" ")
                    if (root.isExcluded(mount)) continue
                    all.push({
                        device: parts[0],
                        fstype: parts[1],
                        size: parts[2],
                        used: parts[3],
                        avail: parts[4],
                        percent: parseInt(parts[5].replace("%", "")) || 0,
                        mount: mount
                    })
                }

                var important = []
                var pools = {}
                var other = []

                for (var j = 0; j < all.length; j++) {
                    var entry = all[j]
                    var prio = root.mountPriority[entry.mount]
                    if (prio !== undefined) {
                        entry.priority = prio
                        important.push(entry)
                    } else if (entry.fstype === "zfs" && root.showZfs) {
                        var poolName = entry.device.indexOf("/") > 0
                            ? entry.device.substring(0, entry.device.indexOf("/"))
                            : entry.device
                        // Skip bare pool root datasets (e.g. zpool mounted at /zpool, ~0% used)
                        if (entry.device === poolName && entry.percent <= 1) continue
                        if (!pools[poolName]) pools[poolName] = { poolName: poolName, datasets: [], freeSpace: entry.avail }
                        pools[poolName].datasets.push(entry)
                    } else if (root.showPartitions) {
                        other.push(entry)
                    }
                }

                important.sort(function(a, b) { return a.priority - b.priority })
                root.importantMounts = important

                var poolList = []
                for (var pn in pools) {
                    pools[pn].datasets.sort(function(a, b) { return b.percent - a.percent })
                    poolList.push(pools[pn])
                }
                poolList.sort(function(a, b) { return a.poolName.localeCompare(b.poolName) })
                root.zfsPoolGroups = poolList

                root.otherMounts = other
                root.updatePrimaryUsage()
                root.isLoading = false
            }
        }
    }

    // ── Nix store info ────────────────────────────────────────────────
    property Process nixPathCountProcess: Process {
        running: false
        command: ["sh", "-c", "nix-store --query --requisites /run/current-system 2>/dev/null | wc -l | tr -d ' '; df -h --output=used /nix/store 2>/dev/null | tail -1 | tr -d ' '"]

        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                var count = parseInt(lines[0]) || 0
                var size = (lines.length >= 2 && lines[1]) ? lines[1] : "?"
                var info = { paths: count, size: size }
                root.nixStoreInfo = info
                if (root.pluginService)
                    root.pluginService.savePluginState("dankDiskUsage", "nixStoreCache", info)
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

    function updatePrimaryUsage() {
        // Use the highest-priority important mount for the bar pill
        if (importantMounts.length > 0) {
            primaryUsagePercent = importantMounts[0].percent
        } else {
            // Fallback: worst across everything
            var worst = 0
            for (var i = 0; i < otherMounts.length; i++) {
                if (otherMounts[i].percent > worst) worst = otherMounts[i].percent
            }
            for (var j = 0; j < zfsPoolGroups.length; j++) {
                for (var k = 0; k < zfsPoolGroups[j].datasets.length; k++) {
                    if (zfsPoolGroups[j].datasets[k].percent > worst) worst = zfsPoolGroups[j].datasets[k].percent
                }
            }
            primaryUsagePercent = worst
        }
    }

    function usageColor(percent) {
        if (percent >= criticalThreshold) return "#ff4444"
        if (percent >= warningThreshold) return "#ffaa00"
        return Theme.primary
    }

    function barLabel() {
        if (isLoading) return "..."
        return primaryUsagePercent + "%"
    }

    function togglePool(poolName) {
        var exp = {}
        for (var k in expandedPools) exp[k] = expandedPools[k]
        exp[poolName] = !exp[poolName]
        expandedPools = exp
    }

    // ── Horizontal bar pill ─────────────────────────────────────────
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "hard_drive"
                size: Theme.fontSizeLarge
                color: root.usageColor(root.primaryUsagePercent)
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.barLabel()
                font.pixelSize: Theme.fontSizeMedium
                color: root.usageColor(root.primaryUsagePercent)
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
                color: root.usageColor(root.primaryUsagePercent)
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.barLabel()
                font.pixelSize: Theme.fontSizeSmall
                color: root.usageColor(root.primaryUsagePercent)
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

            // ── System Storage (important mounts) ───────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.importantMounts.length > 0

                StyledText {
                    text: "System Storage"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.importantMounts

                    StyledRect {
                        width: parent.width
                        height: 56
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingXS

                            Item {
                                width: parent.width
                                height: sysMountText.implicitHeight

                                Row {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS

                                    DankIcon {
                                        name: modelData.fstype === "zfs" ? "database" : "hard_drive"
                                        size: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: modelData.fstype === "zfs"
                                    }

                                    StyledText {
                                        id: sysMountText
                                        text: modelData.mount
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }
                                }

                                StyledText {
                                    text: modelData.used + " / " + modelData.size
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.right: sysPercentText.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    id: sysPercentText
                                    text: modelData.percent + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.usageColor(modelData.percent)
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

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

            // ── ZFS Pools (expandable) ──────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showZfs && root.zfsPoolGroups.length > 0

                StyledText {
                    text: "ZFS Pools"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.zfsPoolGroups

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        // Pool header (clickable)
                        StyledRect {
                            width: parent.width
                            height: 44
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.togglePool(modelData.poolName)
                            }

                            Item {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS

                                Row {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "database"
                                        size: Theme.fontSizeMedium
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        text: modelData.poolName
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        text: modelData.datasets.length + " datasets"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: modelData.freeSpace + " free"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    DankIcon {
                                        name: "chevron_right"
                                        size: Theme.fontSizeMedium
                                        color: Theme.surfaceVariantText
                                        rotation: !!root.expandedPools[modelData.poolName] ? 90 : 0
                                        Behavior on rotation { NumberAnimation { duration: 150 } }
                                    }
                                }
                            }
                        }

                        // Expanded datasets
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: !!root.expandedPools[modelData.poolName]

                            Repeater {
                                model: modelData.datasets

                                StyledRect {
                                    width: parent.width
                                    height: 48
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainer

                                    Column {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacingL
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.topMargin: Theme.spacingXS
                                        anchors.bottomMargin: Theme.spacingXS
                                        spacing: Theme.spacingXS

                                        Item {
                                            width: parent.width
                                            height: dsNameText.implicitHeight

                                            StyledText {
                                                id: dsNameText
                                                text: modelData.mount
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                elide: Text.ElideMiddle
                                                anchors.left: parent.left
                                                anchors.right: dsUsedText.left
                                                anchors.rightMargin: Theme.spacingS
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            StyledText {
                                                id: dsUsedText
                                                text: modelData.used + " / " + modelData.size
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                anchors.right: dsPercentText.left
                                                anchors.rightMargin: Theme.spacingS
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            StyledText {
                                                id: dsPercentText
                                                text: modelData.percent + "%"
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Bold
                                                color: root.usageColor(modelData.percent)
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Rectangle {
                                            width: parent.width
                                            height: 3
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
                    }
                }
            }

            // ── Other filesystems ───────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showPartitions && root.otherMounts.length > 0

                StyledText {
                    text: "Other"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.otherMounts

                    StyledRect {
                        width: parent.width
                        height: 56
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingXS

                            Item {
                                width: parent.width
                                height: otherMountText.implicitHeight

                                StyledText {
                                    id: otherMountText
                                    text: modelData.mount
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideMiddle
                                    anchors.left: parent.left
                                    anchors.right: otherUsedText.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    id: otherUsedText
                                    text: modelData.used + " / " + modelData.size
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.right: otherPercentText.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    id: otherPercentText
                                    text: modelData.percent + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.usageColor(modelData.percent)
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

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

                    Item {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS

                        Row {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
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
                            }
                        }

                        StyledText {
                            text: root.nixStoreInfo ? (root.nixStoreInfo.paths + " paths") : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.right: nixSizeText.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            id: nixSizeText
                            text: root.nixStoreInfo ? root.nixStoreInfo.size : ""
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.primary
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
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
                         && root.importantMounts.length === 0
                         && root.zfsPoolGroups.length === 0
                         && root.otherMounts.length === 0
                         && root.nixStoreInfo === null
            }
        }
    }

    popoutWidth: 400
    popoutHeight: 520
}
