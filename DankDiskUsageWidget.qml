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
    property bool showBtrfsVolumes: true
    property bool dedupeByDevice: false
    property bool showNixStore: true
    property var excludeMounts: []

    // ── Mount priority (lower = more important) ─────────────────────
    readonly property var mountPriority: ({
        "/": 1, "/home": 2, "/nix": 3, "/var": 4, "/boot": 5,
        "/root": 6, "/opt": 7, "/srv": 8, "/usr": 9, "/mnt": 10
    })

    // ── Runtime state ───────────────────────────────────────────────
    property bool isLoading: true
    property var lastDfOutput: null
    property var importantMounts: []
    property var zfsPoolGroups: []
    property var btrfsVolumeGroups: []
    property var otherMounts: []
    property var nixStoreInfo: null
    property bool isScanningNixStore: false
    property int primaryUsagePercent: 0
    property var expandedPools: ({})

    function loadSettings() {
        if (!pluginService || !pluginService.loadPluginData) return
        var previousMountSettings = JSON.stringify([showPartitions, showZfs, showBtrfsVolumes, dedupeByDevice, excludeMounts])
        refreshInterval = pluginService.loadPluginData("dankDiskUsage", "refreshInterval", 30) || 30
        warningThreshold = pluginService.loadPluginData("dankDiskUsage", "warningThreshold", 80) || 80
        criticalThreshold = pluginService.loadPluginData("dankDiskUsage", "criticalThreshold", 95) || 95
        showPartitions = pluginService.loadPluginData("dankDiskUsage", "showPartitions", true) !== false
        showZfs = pluginService.loadPluginData("dankDiskUsage", "showZfs", true) !== false
        showBtrfsVolumes = pluginService.loadPluginData("dankDiskUsage", "showBtrfsVolumes", true) !== false
        dedupeByDevice = pluginService.loadPluginData("dankDiskUsage", "dedupeByDevice", false) === true
        showNixStore = pluginService.loadPluginData("dankDiskUsage", "showNixStore", true) !== false
        var saved = pluginService.loadPluginData("dankDiskUsage", "excludeMounts", [])
        excludeMounts = root.normalizeExcludeMounts(saved)
        var mountSettings = JSON.stringify([showPartitions, showZfs, showBtrfsVolumes, dedupeByDevice, excludeMounts])
        if (lastDfOutput !== null && mountSettings !== previousMountSettings)
            root.updateMounts(lastDfOutput)
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
            if (cached.closureSize === undefined && cached.size !== undefined)
                cached.closureSize = cached.size
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

    function scanNixStoreSize() {
        if (!root.showNixStore || nixStoreSizeProcess.running) return
        root.isScanningNixStore = true
        nixStoreSizeProcess.running = true
    }

    // ── df: all filesystems ─────────────────────────────────────────
    property Process dfProcess: Process {
        running: false
        command: ["sh", "-c", "df -h --output=source,fstype,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x efivarfs -x overlay -x fuse 2>/dev/null | tail -n +2"]

        stdout: StdioCollector {
            onStreamFinished: {
                root.lastDfOutput = text
                root.updateMounts(text)
            }
        }
    }

    // Reparse the cached df snapshot when display settings change. Fresh entries
    // keep dedupe metadata from leaking into subsequent ungrouped views.
    function updateMounts(text) {
        var lines = text.trim().split("\n")
        var all = []
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].trim().split(/\s+/)
            if (parts.length < 7) continue
            var entry = {
                device: parts[0],
                fstype: parts[1],
                size: parts[2],
                used: parts[3],
                avail: parts[4],
                percent: parseInt(parts[5].replace("%", "")) || 0,
                mount: parts.slice(6).join(" ")
            }
            if (root.isExcluded(entry)) continue
            all.push(entry)
        }

        var important = []
        var pools = {}
        var other = []

        // Collapse shared-device mounts before classification when enabled.
        var volumes = root.groupBtrfsVolumes(all)
        all = root.dedupeSameDevice(volumes.remaining)
        var visibleVolumes = []
        for (var v = 0; v < volumes.groups.length; v++) {
            var volume = volumes.groups[v]
            // System mounts remain visible even when ordinary partitions are hidden.
            if (root.showPartitions || volume.priority < 100) visibleVolumes.push(volume)
        }
        root.btrfsVolumeGroups = visibleVolumes

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

    // ── Nix current-system closure info ───────────────────────────────
    property Process nixPathCountProcess: Process {
        running: false
        command: ["sh", "-c", "reqs=$(nix-store --query --requisites /run/current-system 2>/dev/null); count=$(printf '%s\\n' \"$reqs\" | sed '/^$/d' | wc -l | tr -d ' '); size=$(nix path-info --closure-size --human-readable /run/current-system 2>/dev/null | awk '{print $(NF-1) \" \" $NF}'); if [ -z \"$size\" ]; then size=$(printf '%s\\n' \"$reqs\" | xargs nix-store --query --size 2>/dev/null | awk 'function human(b){split(\"B KiB MiB GiB TiB\",u); i=1; while (b>=1024 && i<5){b/=1024; i++} return sprintf(b>=10 || i==1 ? \"%.0f %s\" : \"%.1f %s\", b, u[i])} {s += $1} END {if (s > 0) print human(s); else print \"?\"}'); fi; printf '%s\\n%s\\n' \"$count\" \"${size:-?}\""]

        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                var count = parseInt(lines[0]) || 0
                var size = (lines.length >= 2 && lines[1]) ? lines[1] : "?"
                var current = root.nixStoreInfo || {}
                var info = {
                    paths: count,
                    closureSize: size,
                    storeSize: current.storeSize || "",
                    storeSizeScannedAt: current.storeSizeScannedAt || ""
                }
                root.nixStoreInfo = info
                if (root.pluginService)
                    root.pluginService.savePluginState("dankDiskUsage", "nixStoreCache", info)
            }
        }
    }

    // ── Nix total store size: manual only to avoid background store walks ──
    property Process nixStoreSizeProcess: Process {
        running: false
        command: ["sh", "-c", "du -sh /nix/store 2>/dev/null | cut -f1"]

        stdout: StdioCollector {
            onStreamFinished: {
                var size = text.trim() || "?"
                var current = root.nixStoreInfo || {}
                var info = {
                    paths: current.paths || 0,
                    closureSize: current.closureSize || current.size || "?",
                    storeSize: size,
                    storeSizeScannedAt: new Date().toISOString()
                }
                root.nixStoreInfo = info
                root.isScanningNixStore = false
                if (root.pluginService)
                    root.pluginService.savePluginState("dankDiskUsage", "nixStoreCache", info)
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────
    function normalizeExcludeMounts(saved) {
        if (!saved || !Array.isArray(saved)) return []
        var normalized = []
        for (var i = 0; i < saved.length; i++) {
            var entry = saved[i]
            var value = ""
            if (typeof entry === "string") {
                value = entry
            } else if (entry && typeof entry.value === "string") {
                value = entry.value
            } else if (entry && typeof entry.mount === "string") {
                value = entry.mount
            } else if (entry && typeof entry.pattern === "string") {
                value = entry.pattern
            }
            value = root.normalizeExcludeValue(value)
            if (value.length > 0 && normalized.indexOf(value) < 0)
                normalized.push(value)
        }
        return normalized
    }

    function normalizeExcludeValue(value) {
        if (typeof value !== "string") return ""
        var normalized = value.trim()
        while (normalized.length > 1 && normalized.charAt(normalized.length - 1) === "/")
            normalized = normalized.substring(0, normalized.length - 1)
        return normalized
    }

    function wildcardMatches(pattern, value) {
        if (pattern.indexOf("*") < 0) return pattern === value

        var parts = pattern.split("*")
        var pos = 0
        if (parts[0] && value.indexOf(parts[0]) !== 0) return false
        pos = parts[0].length

        for (var i = 1; i < parts.length; i++) {
            var part = parts[i]
            if (!part) continue
            var idx = value.indexOf(part, pos)
            if (idx < 0) return false
            pos = idx + part.length
        }

        var last = parts[parts.length - 1]
        return !last || value.substring(value.length - last.length) === last
    }

    function isExcludedValue(value) {
        var normalized = root.normalizeExcludeValue(value)
        if (!normalized) return false
        for (var i = 0; i < excludeMounts.length; i++) {
            if (root.wildcardMatches(excludeMounts[i], normalized)) return true
        }
        return false
    }

    function isExcluded(entry) {
        if (typeof entry === "string")
            return root.isExcludedValue(entry)
        return root.isExcludedValue(entry.mount) || root.isExcludedValue(entry.device)
    }

    // Rank used to pick the representative mountpoint of a shared device.
    // Priority mounts win; everything else is ordered shallowest path first.
    function mountRank(mount) {
        var prio = root.mountPriority[mount]
        if (prio !== undefined) return prio
        return 100 + mount.split("/").length
    }

    function compareByRank(a, b) {
        var rankA = root.mountRank(a.mount)
        var rankB = root.mountRank(b.mount)
        if (rankA !== rankB) return rankA - rankB
        return a.mount.localeCompare(b.mount)
    }

    // Conservatively recognize Linux device paths from df without another
    // subprocess. Absolute paths alone are insufficient: SMB sources start //.
    // Sources outside /dev/ remain separate, even if they alias a local device.
    function isBlockDevice(device) {
        return typeof device === "string" && device.indexOf("/dev/") === 0 && device.length > 5
    }

    // Btrfs subvolumes of one filesystem each report the whole filesystem in
    // df, so listing them flat multiplies the same capacity N times. Collapse
    // them into one expandable volume, mirroring the ZFS pool grouping.
    // Returns { groups, remaining }.
    function groupBtrfsVolumes(entries) {
        if (!root.showBtrfsVolumes) return { groups: [], remaining: entries }

        var byDevice = {}
        var deviceOrder = []
        var remaining = []

        for (var i = 0; i < entries.length; i++) {
            var entry = entries[i]
            if (entry.fstype !== "btrfs" || !root.isBlockDevice(entry.device)) {
                remaining.push(entry)
                continue
            }
            if (!byDevice[entry.device]) {
                byDevice[entry.device] = []
                deviceOrder.push(entry.device)
            }
            byDevice[entry.device].push(entry)
        }

        var groups = []
        for (var d = 0; d < deviceOrder.length; d++) {
            var device = deviceOrder[d]
            var members = byDevice[device]

            // A single-subvolume filesystem is just an ordinary mount.
            if (members.length < 2) {
                remaining.push(members[0])
                continue
            }

            members.sort(root.compareByRank)
            var head = members[0]
            groups.push({
                key: "btrfs:" + device,
                poolName: head.mount,
                device: device,
                priority: root.mountRank(head.mount),
                size: head.size,
                used: head.used,
                freeSpace: head.avail,
                percent: head.percent,
                datasets: members
            })
        }

        groups.sort(function(a, b) { return a.priority - b.priority })
        return { groups: groups, remaining: remaining }
    }

    // Generic same-device collapse for filesystems without dedicated grouping
    // (bind mounts, an LVM volume mounted twice, ...). Keeps the best-ranked
    // mountpoint and records the others in `sharedMounts`.
    function dedupeSameDevice(entries) {
        if (!root.dedupeByDevice) return entries

        var indexByDevice = {}
        var result = []

        for (var i = 0; i < entries.length; i++) {
            var entry = entries[i]
            if (!root.isBlockDevice(entry.device)) {
                result.push(entry)
                continue
            }

            var seen = indexByDevice[entry.device]
            if (seen === undefined) {
                entry.sharedMounts = []
                indexByDevice[entry.device] = result.length
                result.push(entry)
                continue
            }

            var kept = result[seen]
            if (root.compareByRank(entry, kept) < 0) {
                entry.sharedMounts = kept.sharedMounts.concat([kept.mount])
                result[seen] = entry
            } else {
                kept.sharedMounts.push(entry.mount)
            }
        }

        return result
    }

    function sharedMountLabel(entry) {
        if (!entry || !entry.sharedMounts || entry.sharedMounts.length === 0) return ""
        return "+" + entry.sharedMounts.length + (entry.sharedMounts.length === 1 ? " mount" : " mounts")
    }

    function updatePrimaryUsage() {
        // Use the highest-priority system mount for the bar pill. A btrfs
        // volume can hold that mount, so groups compete on the same rank.
        var best = null
        for (var i = 0; i < importantMounts.length; i++) {
            if (best === null || importantMounts[i].priority < best.priority) best = importantMounts[i]
        }
        for (var g = 0; g < btrfsVolumeGroups.length; g++) {
            var group = btrfsVolumeGroups[g]
            if (group.priority >= 100) continue
            if (best === null || group.priority < best.priority) best = group
        }

        if (best !== null) {
            primaryUsagePercent = best.percent
            return
        }

        // Fallback: worst across everything
        var worst = 0
        for (var m = 0; m < otherMounts.length; m++) {
            if (otherMounts[m].percent > worst) worst = otherMounts[m].percent
        }
        for (var j = 0; j < zfsPoolGroups.length; j++) {
            for (var k = 0; k < zfsPoolGroups[j].datasets.length; k++) {
                if (zfsPoolGroups[j].datasets[k].percent > worst) worst = zfsPoolGroups[j].datasets[k].percent
            }
        }
        for (var b = 0; b < btrfsVolumeGroups.length; b++) {
            if (btrfsVolumeGroups[b].percent > worst) worst = btrfsVolumeGroups[b].percent
        }
        primaryUsagePercent = worst
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
            Item {
                width: parent.width
                height: Math.max(diskHeader.implicitHeight, 28)

                StyledText {
                    id: diskHeader
                    text: "Disk Usage"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    anchors.left: parent.left
                    anchors.right: diskRefresh.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                DankActionButton {
                    id: diskRefresh
                    buttonSize: 28
                    iconName: "refresh"
                    iconColor: Theme.surfaceVariantText
                    anchors.right: parent.right
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
                                    anchors.right: sysUsedText.left
                                    anchors.rightMargin: Theme.spacingS
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
                                        width: parent.width
                                               - (modelData.fstype === "zfs" ? Theme.fontSizeSmall + Theme.spacingXS : 0)
                                               - (sysSharedBadge.visible ? sysSharedBadge.implicitWidth + Theme.spacingXS : 0)
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideMiddle
                                        maximumLineCount: 1
                                    }

                                    StyledText {
                                        id: sysSharedBadge
                                        text: root.sharedMountLabel(modelData)
                                        visible: text.length > 0
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                StyledText {
                                    id: sysUsedText
                                    text: modelData.used + " / " + modelData.size
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.right: sysPercentText.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                StyledText {
                                    id: sysPercentText
                                    text: modelData.percent + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.usageColor(modelData.percent)
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
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
                                    anchors.right: poolRightRow.left
                                    anchors.rightMargin: Theme.spacingS
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
                                        width: parent.width - Theme.fontSizeMedium - Theme.spacingS
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideMiddle
                                        maximumLineCount: 1
                                    }

                                    StyledText {
                                        text: modelData.datasets.length + " datasets"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        visible: false
                                    }
                                }

                                Row {
                                    id: poolRightRow
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: modelData.freeSpace + " free"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
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
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }

                                            StyledText {
                                                id: dsPercentText
                                                text: modelData.percent + "%"
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Bold
                                                color: root.usageColor(modelData.percent)
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
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

            // ── Btrfs volumes (expandable) ──────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.btrfsVolumeGroups.length > 0

                StyledText {
                    text: "Btrfs Volumes"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.btrfsVolumeGroups

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        // Volume header (clickable)
                        StyledRect {
                            width: parent.width
                            height: 68
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.togglePool(modelData.key)
                            }

                            Column {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingXS

                                Item {
                                    width: parent.width
                                    height: btrfsNameText.implicitHeight

                                    Row {
                                        anchors.left: parent.left
                                        anchors.right: btrfsUsedText.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS

                                        DankIcon {
                                            name: "hard_drive"
                                            size: Theme.fontSizeSmall
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            id: btrfsNameText
                                            text: modelData.poolName
                                            width: parent.width - Theme.fontSizeSmall - Theme.spacingXS
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                            elide: Text.ElideMiddle
                                            maximumLineCount: 1
                                        }
                                    }

                                    StyledText {
                                        id: btrfsUsedText
                                        text: modelData.used + " / " + modelData.size
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.right: btrfsPercentText.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }

                                    StyledText {
                                        id: btrfsPercentText
                                        text: modelData.percent + "%"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: root.usageColor(modelData.percent)
                                        anchors.right: btrfsChevron.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }

                                    DankIcon {
                                        id: btrfsChevron
                                        name: "chevron_right"
                                        size: Theme.fontSizeMedium
                                        color: Theme.surfaceVariantText
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        rotation: !!root.expandedPools[modelData.key] ? 90 : 0
                                        Behavior on rotation { NumberAnimation { duration: 150 } }
                                    }
                                }

                                Item {
                                    width: parent.width
                                    height: btrfsSubtitle.implicitHeight

                                    StyledText {
                                        id: btrfsSubtitle
                                        text: modelData.datasets.length + " subvolumes \u00b7 " + modelData.device
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        elide: Text.ElideMiddle
                                        maximumLineCount: 1
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

                        // Expanded subvolumes. Capacity belongs to the volume,
                        // not to each mountpoint, so only the mountpoints are
                        // listed here.
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: !!root.expandedPools[modelData.key]

                            Repeater {
                                model: modelData.datasets

                                StyledRect {
                                    width: parent.width
                                    height: 28
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainer

                                    StyledText {
                                        text: modelData.mount
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingL
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideMiddle
                                        maximumLineCount: 1
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
                                    anchors.right: otherSharedBadge.left
                                    anchors.rightMargin: otherSharedBadge.visible ? Theme.spacingXS : 0
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    id: otherSharedBadge
                                    text: root.sharedMountLabel(modelData)
                                    visible: text.length > 0
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
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
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                StyledText {
                                    id: otherPercentText
                                    text: modelData.percent + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.usageColor(modelData.percent)
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
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

            // ── Nix section ─────────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showNixStore && root.nixStoreInfo !== null

                Item {
                    width: parent.width
                    height: Math.max(nixHeader.implicitHeight, 24)

                    StyledText {
                        id: nixHeader
                        text: "Nix"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                        anchors.left: parent.left
                        anchors.right: nixStoreScan.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    DankActionButton {
                        id: nixStoreScan
                        buttonSize: 24
                        iconName: "refresh"
                        iconColor: root.isScanningNixStore ? Theme.primary : Theme.surfaceVariantText
                        opacity: root.isScanningNixStore ? 0.5 : 1.0
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.scanNixStoreSize()
                    }
                }

                StyledRect {
                    width: parent.width
                    height: 104
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingXS

                        Item {
                            width: parent.width
                            height: 26

                            StyledText {
                                text: "Store total"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                anchors.left: parent.left
                                anchors.right: nixStoreSizeText.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            StyledText {
                                id: nixStoreSizeText
                                text: root.isScanningNixStore
                                      ? "Scanning..."
                                      : (root.nixStoreInfo && root.nixStoreInfo.storeSize ? root.nixStoreInfo.storeSize : "Not scanned")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: root.nixStoreInfo && root.nixStoreInfo.storeSize ? Theme.primary : Theme.surfaceVariantText
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        Item {
                            width: parent.width
                            height: 24

                            StyledText {
                                text: "Current generation"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.left: parent.left
                                anchors.right: nixClosureSizeText.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            StyledText {
                                id: nixClosureSizeText
                                text: root.nixStoreInfo ? (root.nixStoreInfo.closureSize || root.nixStoreInfo.size || "?") : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        Item {
                            width: parent.width
                            height: 24

                            StyledText {
                                text: "Current paths"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.left: parent.left
                                anchors.right: nixPathsText.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            StyledText {
                                id: nixPathsText
                                text: root.nixStoreInfo ? (root.nixStoreInfo.paths + " paths") : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
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
                         && root.btrfsVolumeGroups.length === 0
                         && root.otherMounts.length === 0
                         && root.nixStoreInfo === null
            }
        }
    }

    popoutWidth: 400
    popoutHeight: 520
}
