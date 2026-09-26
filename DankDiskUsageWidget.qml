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
    property bool showMergedStorage: true
    property bool showNetworkMounts: true
    property bool showExternalDrives: true
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
    property var mergerfsGroups: []
    property var networkMounts: []
    property var externalMounts: []
    property var externalDevices: ({})
    property var mergerfsMetadata: ({})
    property var mergerfsQueue: []
    property var mergerfsRequests: []
    property var nixStoreInfo: null
    property bool isScanningNixStore: false
    property int primaryUsagePercent: 0
    property var expandedPools: ({})

    function loadSettings() {
        if (!pluginService || !pluginService.loadPluginData) return
        var previousMountSettings = JSON.stringify([showPartitions, showZfs, showBtrfsVolumes, dedupeByDevice, showMergedStorage, showNetworkMounts, showExternalDrives, excludeMounts])
        refreshInterval = pluginService.loadPluginData("dankDiskUsage", "refreshInterval", 30) || 30
        warningThreshold = pluginService.loadPluginData("dankDiskUsage", "warningThreshold", 80) || 80
        criticalThreshold = pluginService.loadPluginData("dankDiskUsage", "criticalThreshold", 95) || 95
        showPartitions = pluginService.loadPluginData("dankDiskUsage", "showPartitions", true) !== false
        showZfs = pluginService.loadPluginData("dankDiskUsage", "showZfs", true) !== false
        showBtrfsVolumes = pluginService.loadPluginData("dankDiskUsage", "showBtrfsVolumes", true) !== false
        dedupeByDevice = pluginService.loadPluginData("dankDiskUsage", "dedupeByDevice", false) === true
        showMergedStorage = pluginService.loadPluginData("dankDiskUsage", "showMergedStorage", true) !== false
        showNetworkMounts = pluginService.loadPluginData("dankDiskUsage", "showNetworkMounts", true) !== false
        showExternalDrives = pluginService.loadPluginData("dankDiskUsage", "showExternalDrives", true) !== false
        showNixStore = pluginService.loadPluginData("dankDiskUsage", "showNixStore", true) !== false
        var saved = pluginService.loadPluginData("dankDiskUsage", "excludeMounts", [])
        excludeMounts = root.normalizeExcludeMounts(saved)
        var mountSettings = JSON.stringify([showPartitions, showZfs, showBtrfsVolumes, dedupeByDevice, showMergedStorage, showNetworkMounts, showExternalDrives, excludeMounts])
        if (lastDfOutput !== null && mountSettings !== previousMountSettings) {
            root.updateMounts(lastDfOutput)
            root.refreshMergerfsMetadata()
        }
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
                root.refreshMergerfsMetadata()
                if (!root.blockDeviceProcess.running) root.blockDeviceProcess.running = true
            }
        }
    }

    // Read device transport/removability, not filesystem contents or identities.
    property Process blockDeviceProcess: Process {
        command: ["sh", "-c", "exec timeout -k 1s 3s lsblk --json --paths --tree --output NAME,KNAME,PATH,TRAN,RM 2>/dev/null"]
        stdout: StdioCollector { id: blockDeviceOutput }
        onExited: (exitCode, exitStatus) => root.acceptDeviceMetadata(exitCode === 0 ? blockDeviceOutput.text : "")
    }

    function acceptDeviceMetadata(text) {
        // Replace the snapshot even on failure: never keep stale USB classifications.
        externalDevices = root.parseExternalDevices(text)
        if (lastDfOutput !== null) root.updateMounts(lastDfOutput)
    }

    function parseExternalDevices(text) {
        var data
        try { data = JSON.parse(text) } catch (error) { return {} }
        if (!data || !Array.isArray(data.blockdevices)) return {}
        var devices = {}
        function visit(nodes, inheritedConnection) {
            for (var i = 0; i < nodes.length; i++) {
                var node = nodes[i]
                if (!node || typeof node !== "object") continue
                var removable = node.rm === true || node.rm === 1 || node.rm === "1" || node.rm === "true"
                var connection = node.tran === "usb" || inheritedConnection === "USB" ? "USB"
                               : removable || inheritedConnection ? "Removable" : ""
                if (connection) {
                    var aliases = [node.name, node.kname, node.path]
                    for (var a = 0; a < aliases.length; a++) {
                        var alias = aliases[a]
                        if (typeof alias !== "string" || alias.indexOf("/dev/") !== 0) continue
                        if (devices[alias] !== "USB") devices[alias] = connection
                    }
                }
                if (Array.isArray(node.children)) visit(node.children, connection)
            }
        }
        visit(data.blockdevices, "")
        return devices
    }

    function externalConnection(device) {
        return (root.externalDevices || {})[device] || ""
    }

    // Optional topology enrichment. No mount options, file scans or privilege escalation.
    property Process mergerfsProcess: Process {
        property string mountPoint: ""
        property string sourceDevice: ""
        command: ["sh", "-c", "exec timeout -k 1s 3s getfattr --only-values -n user.mergerfs.branches -- \"$1/.mergerfs\" 2>/dev/null", "dank-disk-usage", mountPoint]
        stdout: StdioCollector { id: mergerfsOutput }
        onExited: (exitCode, exitStatus) => {
            root.acceptMergerfsMetadata(mountPoint, sourceDevice, exitCode === 0 ? mergerfsOutput.text : "")
            mergerfsNextTimer.restart()
        }
    }

    Timer {
        id: mergerfsNextTimer
        interval: 1
        onTriggered: root.startNextMergerfsRequest()
    }

    function refreshMergerfsMetadata() {
        // Preserve queue order so slow pools cannot starve later pools on each poll.
        var wanted = {}
        for (var i = 0; i < mergerfsRequests.length; i++) {
            var request = mergerfsRequests[i]
            wanted[JSON.stringify([request.mount, request.device])] = request
        }
        var scheduled = {}
        if (mergerfsProcess.running)
            scheduled[JSON.stringify([mergerfsProcess.mountPoint, mergerfsProcess.sourceDevice])] = true
        var queue = []
        var candidates = mergerfsQueue.concat(mergerfsRequests)
        for (var j = 0; j < candidates.length; j++) {
            var candidate = candidates[j]
            var key = JSON.stringify([candidate.mount, candidate.device])
            if (!wanted[key] || scheduled[key]) continue
            scheduled[key] = true
            queue.push(candidate)
        }
        mergerfsQueue = queue
        root.startNextMergerfsRequest()
    }

    function startNextMergerfsRequest() {
        if (mergerfsQueue.length === 0 || mergerfsProcess.running) return
        var queue = mergerfsQueue.slice()
        var request = queue.shift()
        mergerfsQueue = queue
        mergerfsProcess.mountPoint = request.mount
        mergerfsProcess.sourceDevice = request.device
        mergerfsProcess.running = true
    }

    function acceptMergerfsMetadata(mount, device, text) {
        // Ignore results for an unmounted/replaced pool from an older snapshot.
        var current = false
        for (var i = 0; i < mergerfsRequests.length; i++) {
            if (mergerfsRequests[i].mount === mount && mergerfsRequests[i].device === device)
                current = true
        }
        if (!current) return
        var metadata = {}
        for (var key in mergerfsMetadata) metadata[key] = mergerfsMetadata[key]
        var branches = root.parseMergerfsBranches(text)
        metadata[mount] = { device: device, branches: branches, available: branches.length > 0 }
        mergerfsMetadata = metadata
        if (lastDfOutput !== null) root.updateMounts(lastDfOutput)
    }

    // Reparse the cached df snapshot when display settings change. Fresh entries
    // keep dedupe metadata from leaking into subsequent ungrouped views.
    function updateMounts(text) {
        var lines = text.trim().split("\n")
        var all = []
        var topologyEntries = []
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
            topologyEntries.push(entry)
            if (root.isExcluded(entry)) continue
            all.push(entry)
        }

        var important = []
        var pools = {}
        var other = []
        var external = []

        // Mergerfs topology must see physical rows before optional device deduplication.
        var requests = []
        for (var r = 0; r < all.length; r++) {
            if (root.showMergedStorage && root.isMergerfs(all[r])) requests.push({ mount: all[r].mount, device: all[r].device })
        }
        root.mergerfsRequests = requests
        if (!root.showMergedStorage) root.mergerfsQueue = []
        var merged = root.groupMergerfs(all, topologyEntries)
        root.mergerfsGroups = merged.groups
        var network = []
        var local = []
        for (var n = 0; n < merged.remaining.length; n++) {
            var candidate = merged.remaining[n]
            var protocol = root.networkProtocol(candidate.fstype)
            if (protocol && root.mountPriority[candidate.mount] === undefined) {
                if (root.showNetworkMounts) {
                    candidate.protocol = protocol
                    network.push(candidate)
                }
            } else {
                local.push(candidate)
            }
        }
        root.networkMounts = network
        // Collapse shared-device mounts before classification when enabled.
        var volumes = root.groupBtrfsVolumes(local)
        all = root.dedupeSameDevice(volumes.remaining)
        var visibleVolumes = []
        for (var v = 0; v < volumes.groups.length; v++) {
            var volume = volumes.groups[v]
            // System groups keep their established placement, even on USB media.
            var connection = root.externalConnection(volume.device)
            if (connection && volume.priority >= 100) {
                if (root.showExternalDrives) {
                    volume.mount = volume.poolName
                    volume.fstype = "btrfs"
                    volume.connection = connection
                    external.push(volume)
                }
            } else if (root.showPartitions || volume.priority < 100) {
                visibleVolumes.push(volume)
            }
        }
        root.btrfsVolumeGroups = visibleVolumes

        for (var j = 0; j < all.length; j++) {
            var entry = all[j]
            var prio = root.mountPriority[entry.mount]
            if (prio !== undefined) {
                entry.priority = prio
                important.push(entry)
            } else if (root.externalConnection(entry.device)) {
                if (root.showExternalDrives) {
                    entry.connection = root.externalConnection(entry.device)
                    external.push(entry)
                }
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
        external.sort(function(a, b) { return a.mount.localeCompare(b.mount) })
        root.externalMounts = external
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

    function isMergerfs(entry) {
        return entry.fstype === "fuse.mergerfs" || entry.fstype === "mergerfs"
    }

    function networkProtocol(fstype) {
        switch (fstype) {
        case "nfs": case "nfs4": return "NFS"
        case "cifs": case "smb3": return "SMB"
        case "sshfs": case "fuse.sshfs": return "SSHFS"
        case "rclone": case "fuse.rclone": return "Rclone"
        default: return ""
        }
    }

    function parseMergerfsBranches(text) {
        var branches = []
        var parts = text.trim().split(":")
        for (var i = 0; i < parts.length; i++) {
            var match = /^(\/.*)=(RW|RO|NC)$/.exec(parts[i])
            // Reject ambiguous/malformed metadata rather than invent member paths.
            if (!match) return []
            var path = match[1].replace(/\/+$/, "") || "/"
            branches.push({ path: path, mode: match[2] })
        }
        return branches
    }

    function memberFilesystem(path, entries) {
        var best = null
        for (var i = 0; i < entries.length; i++) {
            var entry = entries[i]
            if (root.isMergerfs(entry)) continue
            var mount = entry.mount.replace(/\/+$/, "") || "/"
            // A missing member disk must not silently turn into the root disk.
            if (mount === "/" && path !== "/") continue
            if (path !== mount && path.indexOf(mount + "/") !== 0) continue
            if (best === null || mount.length > best.mount.length) best = entry
        }
        return best
    }

    function groupMergerfs(entries, topologyEntries) {
        var groups = []
        var consumed = {}
        for (var i = 0; i < entries.length; i++) {
            var pool = entries[i]
            if (!root.isMergerfs(pool)) continue
            if (!root.showMergedStorage) {
                if (root.mountPriority[pool.mount] === undefined) consumed[pool.mount] = true
                continue
            }
            var metadata = (root.mergerfsMetadata || {})[pool.mount]
            if (metadata && metadata.device !== pool.device) metadata = null
            var members = []
            var memberIndexes = {}
            var branches = metadata && metadata.available ? metadata.branches : []
            for (var j = 0; j < branches.length; j++) {
                var branch = branches[j]
                if (root.isExcludedValue(branch.path)) continue
                var entry = root.memberFilesystem(branch.path, topologyEntries || entries)
                if (entry && root.isExcluded(entry)) continue
                var memberKey = entry ? "mount:" + entry.mount : "branch:" + branch.path
                var existing = memberIndexes[memberKey]
                if (existing !== undefined) {
                    members[existing].branch += ", " + branch.path
                    if (members[existing].mode.indexOf(branch.mode) === -1)
                        members[existing].mode += "/" + branch.mode
                    continue
                }
                memberIndexes[memberKey] = members.length
                members.push({
                    branch: branch.path, mode: branch.mode,
                    mount: entry ? entry.mount : branch.path,
                    fstype: entry ? entry.fstype : "",
                    size: entry ? entry.size : "?",
                    used: entry ? entry.used : "?",
                    avail: entry ? entry.avail : "?",
                    percent: entry ? entry.percent : null
                })
                // Preserve the system-storage rows even when also used by a pool.
                if (entry && root.mountPriority[entry.mount] === undefined) consumed[entry.mount] = true
            }
            groups.push({
                mount: pool.mount, device: pool.device, fstype: pool.fstype,
                size: pool.size, used: pool.used, avail: pool.avail, percent: pool.percent,
                priority: root.mountRank(pool.mount), members: members,
                detailsAvailable: !!metadata && metadata.available,
                detailsLoading: !metadata
            })
            consumed[pool.mount] = true
        }
        var remaining = []
        for (var k = 0; k < entries.length; k++) {
            if (!consumed[entries[k].mount]) remaining.push(entries[k])
        }
        groups.sort(function(a, b) { return a.priority - b.priority || a.mount.localeCompare(b.mount) })
        return { groups: groups, remaining: remaining }
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
            if (!root.isBlockDevice(entry.device) || root.networkProtocol(entry.fstype) || root.isMergerfs(entry)) {
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

        for (var v = 0; v < mergerfsGroups.length; v++) {
            var volume = mergerfsGroups[v]
            if (volume.priority < 100 && (best === null || volume.priority < best.priority)) best = volume
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
        for (var v = 0; v < mergerfsGroups.length; v++) {
            if (mergerfsGroups[v].percent > worst) worst = mergerfsGroups[v].percent
        }
        for (var n = 0; n < networkMounts.length; n++) {
            if (networkMounts[n].percent > worst) worst = networkMounts[n].percent
        }
        for (var e = 0; e < externalMounts.length; e++) {
            if (externalMounts[e].percent > worst) worst = externalMounts[e].percent
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

            // ── Merged storage ──────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.mergerfsGroups.length > 0

                StyledText {
                    text: "Merged Storage"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.mergerfsGroups

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        readonly property string expansionKey: "mergerfs:" + modelData.mount

                        Item {
                            width: parent.width
                            height: mergedCard.height

                            StorageUsageCard {
                                id: mergedCard
                                width: parent.width
                                entry: modelData
                                title: modelData.mount
                                subtitle: modelData.device + " · mergerfs"
                                          + (modelData.detailsAvailable ? " · " + modelData.members.length + (modelData.members.length === 1 ? " filesystem" : " filesystems") : "")
                                usageTint: root.usageColor(modelData.percent)
                                expandable: true
                                expanded: !!root.expandedPools[expansionKey]
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.togglePool(expansionKey)
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: !!root.expandedPools[expansionKey]

                            StyledText {
                                width: parent.width
                                visible: modelData.detailsLoading || !modelData.detailsAvailable
                                text: modelData.detailsLoading ? "Loading member details…" : "Member details unavailable"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }

                            Repeater {
                                model: modelData.detailsAvailable && !modelData.detailsLoading ? modelData.members : []

                                Item {
                                    width: parent.width
                                    height: memberCard.height

                                    StorageUsageCard {
                                        id: memberCard
                                        width: parent.width
                                        compact: true
                                        entry: modelData
                                        title: modelData.mount
                                        subtitle: "Branch: " + modelData.branch + (modelData.mode ? " · " + modelData.mode : "")
                                                  + (modelData.fstype ? " · " + modelData.fstype : "")
                                        usageTint: root.usageColor(modelData.percent)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── External drives ─────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.externalMounts.length > 0

                StyledText {
                    text: "External Drives"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.externalMounts

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        readonly property bool hasDatasets: !!modelData.datasets && modelData.datasets.length > 0
                        readonly property string expansionKey: "external:" + modelData.device

                        Item {
                            width: parent.width
                            height: externalCard.height

                            StorageUsageCard {
                                id: externalCard
                                width: parent.width
                                entry: modelData
                                title: modelData.mount
                                subtitle: modelData.fstype + " · " + modelData.connection + " · " + modelData.device
                                          + (root.sharedMountLabel(modelData) ? " · " + root.sharedMountLabel(modelData) : "")
                                usageTint: root.usageColor(modelData.percent)
                                expandable: hasDatasets
                                expanded: hasDatasets && !!root.expandedPools[expansionKey]
                            }

                            MouseArea {
                                anchors.fill: parent
                                visible: hasDatasets
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.togglePool(expansionKey)
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: hasDatasets && !!root.expandedPools[expansionKey]

                            Repeater {
                                model: hasDatasets ? modelData.datasets : []

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

            // ── Network shares ──────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.networkMounts.length > 0

                StyledText {
                    text: "Network Shares"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.networkMounts

                    Item {
                        width: parent.width
                        height: networkCard.height

                        StorageUsageCard {
                            id: networkCard
                            width: parent.width
                            entry: modelData
                            title: modelData.mount
                            subtitle: modelData.protocol + " · " + modelData.device
                            usageTint: root.usageColor(modelData.percent)
                        }
                    }
                }
            }

            // ── Local filesystems ───────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.otherMounts.length > 0

                StyledText {
                    text: "Local Filesystems"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.otherMounts

                    Item {
                        width: parent.width
                        height: localCard.height

                        StorageUsageCard {
                            id: localCard
                            width: parent.width
                            entry: modelData
                            title: modelData.mount
                            subtitle: modelData.fstype + " · " + modelData.device
                                      + (root.sharedMountLabel(modelData) ? " · " + root.sharedMountLabel(modelData) : "")
                            usageTint: root.usageColor(modelData.percent)
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
                         && root.mergerfsGroups.length === 0
                         && root.externalMounts.length === 0
                         && root.networkMounts.length === 0
                         && root.otherMounts.length === 0
                         && root.nixStoreInfo === null
            }
        }
    }

    popoutWidth: 400
    popoutHeight: 520
}
