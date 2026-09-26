// Exercise the widget's own JavaScript without starting Quickshell or running df.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const qml = fs.readFileSync(path.join(__dirname, '..', 'DankDiskUsageWidget.qml'), 'utf8');
const functions = [...qml.matchAll(/^    function (\w+)\([^\n]*\) \{[\s\S]*?^    \}/gm)]
    .map(match => match[0].replace(/^    /gm, ''));
const prioritySource = qml.match(/readonly property var mountPriority:\s*(\(\{[\s\S]*?\}\))/);
assert.ok(prioritySource, 'mountPriority must be present in the widget');

function widget(settings = {}) {
    const root = {
        mountPriority: vm.runInNewContext(prioritySource[1]),
        showPartitions: true,
        showZfs: true,
        showBtrfsVolumes: true,
        showMergedStorage: true,
        showNetworkMounts: true,
        dedupeByDevice: false,
        excludeMounts: [],
        importantMounts: [],
        zfsPoolGroups: [],
        btrfsVolumeGroups: [],
        mergerfsGroups: [],
        networkMounts: [],
        mergerfsMetadata: {},
        mergerfsRequests: [],
        mergerfsQueue: [],
        mergerfsProcess: { running: false, mountPoint: '', sourceDevice: '' },
        otherMounts: [],
        lastDfOutput: null,
        isLoading: true,
        primaryUsagePercent: 0,
        pluginService: {
            loadPluginData(_plugin, key, fallback) {
                return Object.hasOwn(settings, key) ? settings[key] : fallback;
            },
        },
    };
    // QML properties are visible as globals inside methods as well as via root.
    root.root = root;
    const context = vm.createContext(root);
    for (const source of functions) {
        const name = source.match(/^function (\w+)/)[1];
        root[name] = vm.runInContext(`(${source})`, context, { filename: 'DankDiskUsageWidget.qml' });
    }
    for (const name of ['updateMounts', 'loadSettings', 'groupBtrfsVolumes', 'dedupeSameDevice',
        'updatePrimaryUsage', 'groupMergerfs', 'networkProtocol', 'parseMergerfsBranches',
        'acceptMergerfsMetadata']) {
        assert.equal(typeof root[name], 'function', `${name} must be an extractable top-level QML function`);
    }
    root.loadSettings();
    root.acceptDf = output => {
        root.lastDfOutput = output;
        root.updateMounts(output);
    };
    return root;
}

function row(device, fstype, percent, mount) {
    return `${device} ${fstype} 931G 447G 479G ${percent}% ${mount}`;
}

const btrfs = [
    row('/dev/nvme0n1p2', 'btrfs', 49, '/'),
    row('/dev/nvme0n1p2', 'btrfs', 49, '/home'),
    row('/dev/nvme0n1p2', 'btrfs', 49, '/swap'),
    row('/dev/nvme0n1p2', 'btrfs', 49, '/var/log'),
    row('/dev/nvme0n1p2', 'btrfs', 49, '/var/cache/pacman/pkg'),
    row('/dev/nvme0n1p1', 'vfat', 95, '/boot'),
].join('\n');

function mounts(entries) {
    return Array.from(entries, entry => entry.mount);
}

for (const grouped of [false, true]) {
    for (const deduped of [false, true]) {
        test(`five Btrfs mounts and /boot: group=${grouped}, dedupe=${deduped}`, () => {
            const root = widget({ showBtrfsVolumes: grouped, dedupeByDevice: deduped });
            root.acceptDf(btrfs);
            assert.equal(root.primaryUsagePercent, 49, 'root must win pill priority over /boot');
            assert.deepEqual(mounts(root.importantMounts).filter(mount => mount === '/boot'), ['/boot']);
            if (grouped) {
                assert.equal(root.btrfsVolumeGroups.length, 1);
                const group = root.btrfsVolumeGroups[0];
                assert.equal(group.device, '/dev/nvme0n1p2');
                assert.equal(group.poolName, '/');
                assert.equal(group.priority, root.mountPriority['/']);
                assert.equal(group.percent, 49);
                assert.deepEqual(mounts(group.datasets), ['/', '/home', '/swap', '/var/log', '/var/cache/pacman/pkg']);
                assert.deepEqual(mounts(root.importantMounts), ['/boot']);
                assert.equal(root.otherMounts.length, 0);
            } else if (deduped) {
                assert.equal(root.btrfsVolumeGroups.length, 0);
                assert.deepEqual(mounts(root.importantMounts), ['/', '/boot']);
                assert.equal(root.sharedMountLabel(root.importantMounts[0]), '+4 mounts');
                assert.deepEqual(Array.from(root.importantMounts[0].sharedMounts).sort(),
                    ['/home', '/swap', '/var/log', '/var/cache/pacman/pkg'].sort());
            } else {
                assert.equal(root.btrfsVolumeGroups.length, 0);
                assert.deepEqual(mounts(root.importantMounts), ['/', '/home', '/boot']);
                assert.deepEqual(mounts(root.otherMounts), ['/swap', '/var/log', '/var/cache/pacman/pkg']);
            }
        });
    }
}

test('one Btrfs mount stays a normal row with every grouping setting', () => {
    const data = row('/dev/sda2', 'btrfs', 37, '/');
    for (const grouped of [false, true]) {
        for (const deduped of [false, true]) {
            const root = widget({ showBtrfsVolumes: grouped, dedupeByDevice: deduped });
            root.acceptDf(data);
            assert.equal(root.btrfsVolumeGroups.length, 0);
            assert.deepEqual(mounts(root.importantMounts), ['/']);
            assert.equal(root.sharedMountLabel(root.importantMounts[0]), '');
            assert.equal(root.primaryUsagePercent, 37);
        }
    }
});

test('generic device representative changes to ranked mount and keeps badge', () => {
    const root = widget({ dedupeByDevice: true });
    root.acceptDf([
        row('/dev/mapper/data', 'ext4', 30, '/data/archive'),
        row('/dev/mapper/data', 'ext4', 30, '/srv'),
        row('/dev/mapper/data', 'ext4', 30, '/data/backup'),
    ].join('\n'));
    assert.deepEqual(mounts(root.importantMounts), ['/srv']);
    assert.equal(root.sharedMountLabel(root.importantMounts[0]), '+2 mounts');
    assert.deepEqual(Array.from(root.importantMounts[0].sharedMounts).sort(),
        ['/data/archive', '/data/backup']);
});

test('pseudo, ZFS, network, and absolute non-device sources never dedupe', () => {
    const root = widget({ dedupeByDevice: true, showZfs: false });
    const sources = [
        ['none', 'ext4'], ['tmpfs', 'ext4'], ['zpool/data', 'zfs'],
        ['host:/export', 'nfs'], ['//server/share', 'cifs'], ['/tmp/disk.img', 'ext4'],
    ];
    const data = sources.flatMap(([source, fstype], index) => [
        row(source, fstype, 10, `/volume${index}/a`),
        row(source, fstype, 20, `/volume${index}/b`),
    ]).join('\n');
    root.acceptDf(data);
    assert.equal(root.otherMounts.length, (sources.length - 2) * 2);
    assert.deepEqual(mounts(root.networkMounts), ['/volume3/a', '/volume3/b', '/volume4/a', '/volume4/b']);
    assert.ok(root.otherMounts.every(entry => root.sharedMountLabel(entry) === ''));
    assert.equal(root.btrfsVolumeGroups.length, 0);
});

test('showPartitions hides unranked Btrfs groups but keeps the root group', () => {
    const root = widget({ showPartitions: false });
    root.acceptDf([
        ...btrfs.split('\n'),
        row('/dev/sdb1', 'btrfs', 70, '/media/a'),
        row('/dev/sdb1', 'btrfs', 70, '/media/b'),
    ].join('\n'));
    assert.deepEqual(Array.from(root.btrfsVolumeGroups, group => group.device), ['/dev/nvme0n1p2']);
    assert.deepEqual(mounts(root.importantMounts), ['/boot']);
    assert.equal(root.primaryUsagePercent, 49);
});

test('loadSettings reclassifies cached df in both directions and clears stale badges', () => {
    const settings = { showBtrfsVolumes: true, dedupeByDevice: false };
    const root = widget(settings);
    root.acceptDf(btrfs);
    assert.equal(root.btrfsVolumeGroups.length, 1);
    settings.showBtrfsVolumes = false;
    settings.dedupeByDevice = true;
    root.loadSettings();
    assert.equal(root.btrfsVolumeGroups.length, 0);
    assert.deepEqual(mounts(root.importantMounts), ['/', '/boot']);
    assert.equal(root.sharedMountLabel(root.importantMounts[0]), '+4 mounts');
    settings.dedupeByDevice = false;
    root.loadSettings();
    assert.deepEqual(mounts(root.importantMounts), ['/', '/home', '/boot']);
    assert.equal(root.sharedMountLabel(root.importantMounts[0]), '');
    settings.showBtrfsVolumes = true;
    root.loadSettings();
    assert.equal(root.btrfsVolumeGroups.length, 1);
    assert.deepEqual(mounts(root.importantMounts), ['/boot']);
});

test('loadSettings applies changed exclusions to cached df before grouping', () => {
    const settings = { excludeMounts: [] };
    const root = widget(settings);
    root.acceptDf(btrfs);
    settings.excludeMounts = ['/'];
    root.loadSettings();
    assert.equal(root.btrfsVolumeGroups[0].poolName, '/home');
    assert.ok(root.btrfsVolumeGroups[0].datasets.every(entry => entry.mount !== '/'));
    assert.equal(root.primaryUsagePercent, 49);
    settings.excludeMounts = ['/home', '/swap', '/var/*'];
    root.loadSettings();
    assert.equal(root.btrfsVolumeGroups.length, 0);
    assert.deepEqual(mounts(root.importantMounts), ['/', '/boot']);
    assert.equal(root.primaryUsagePercent, 49);
    settings.excludeMounts = ['/dev/nvme0n1p2'];
    root.loadSettings();
    assert.deepEqual(mounts(root.importantMounts), ['/boot']);
    assert.equal(root.primaryUsagePercent, 95);
});

test('loadSettings applies partition and ZFS visibility changes to cached df', () => {
    const settings = { showPartitions: true, showZfs: true };
    const root = widget(settings);
    root.acceptDf([
        row('/dev/sda2', 'ext4', 20, '/'),
        row('/dev/sdb1', 'ext4', 40, '/media/data'),
        row('tank/data', 'zfs', 60, '/tank/data'),
    ].join('\n'));
    assert.deepEqual(mounts(root.otherMounts), ['/media/data']);
    assert.equal(root.zfsPoolGroups.length, 1);
    settings.showPartitions = false;
    root.loadSettings();
    assert.equal(root.otherMounts.length, 0);
    assert.equal(root.zfsPoolGroups.length, 1);
    settings.showZfs = false;
    root.loadSettings();
    assert.equal(root.zfsPoolGroups.length, 0);
    settings.showPartitions = true;
    root.loadSettings();
    assert.deepEqual(mounts(root.otherMounts), ['/media/data', '/tank/data']);
});

const mergedRows = [
    row('/dev/system', 'ext4', 21, '/'),
    row('/dev/disk-a', 'xfs', 41, '/mnt/disk-a'),
    row('/dev/disk-b', 'xfs', 63, '/mnt/disk-b'),
    row('disk-a:disk-b', 'fuse.mergerfs', 52, '/pool'),
].join('\n');

function poolMetadata(device = 'disk-a:disk-b') {
    return {
        '/pool': {
            device,
            available: true,
            branches: [
                { path: '/mnt/disk-a/data', mode: 'RW' },
                { path: '/mnt/disk-b/data', mode: 'RO' },
            ],
        },
    };
}

test('mergerfs pool owns two XFS members without double listing or changing the system pill', () => {
    const root = widget();
    root.mergerfsMetadata = poolMetadata();
    root.acceptDf(mergedRows);
    assert.equal(root.mergerfsGroups.length, 1);
    const group = root.mergerfsGroups[0];
    assert.equal(group.mount, '/pool');
    assert.equal(group.percent, 52);
    assert.equal(group.detailsAvailable, true);
    assert.deepEqual(mounts(group.members), ['/mnt/disk-a', '/mnt/disk-b']);
    assert.deepEqual(Array.from(group.members, member => member.mode), ['RW', 'RO']);
    assert.deepEqual(Array.from(group.members, member => member.percent), [41, 63]);
    assert.deepEqual(mounts(root.importantMounts), ['/']);
    assert.deepEqual(mounts(root.otherMounts), []);
    assert.equal(root.primaryUsagePercent, 21);
});

test('priority member stays a system row while serving as a pool branch', () => {
    const root = widget();
    root.mergerfsMetadata = {
        '/pool': { device: 'home:disk-b', available: true,
            branches: [{ path: '/home/media', mode: 'RW' }, { path: '/mnt/disk-b/data', mode: 'RW' }] },
    };
    root.acceptDf([
        row('/dev/home', 'xfs', 35, '/home'),
        row('/dev/disk-b', 'xfs', 63, '/mnt/disk-b'),
        row('home:disk-b', 'fuse.mergerfs', 51, '/pool'),
    ].join('\n'));
    assert.deepEqual(mounts(root.importantMounts), ['/home']);
    assert.deepEqual(mounts(root.mergerfsGroups[0].members), ['/home', '/mnt/disk-b']);
    assert.equal(root.otherMounts.length, 0);
    assert.equal(root.primaryUsagePercent, 35);
});

test('branches on one filesystem produce one member card and one capacity', () => {
    const root = widget();
    root.mergerfsMetadata = {
        '/pool': { device: 'disk-a:disk-b', available: true,
            branches: [
                { path: '/mnt/disk-a/movies', mode: 'RW' },
                { path: '/mnt/disk-a/music', mode: 'RO' },
                { path: '/mnt/disk-b/data', mode: 'NC' },
            ] },
    };
    root.acceptDf(mergedRows);
    const members = root.mergerfsGroups[0].members;
    assert.deepEqual(mounts(members), ['/mnt/disk-a', '/mnt/disk-b']);
    assert.equal(members[0].branch, '/mnt/disk-a/movies, /mnt/disk-a/music');
    assert.equal(members[0].mode, 'RW/RO');
    assert.equal(members[0].size, '931G');
    assert.equal(members[0].percent, 41);
    assert.equal(members[1].mode, 'NC');
    assert.equal(root.otherMounts.length, 0);
});

test('pool stays visible without metadata and unclaimed physical rows remain visible', () => {
    const root = widget();
    root.acceptDf(mergedRows);
    assert.deepEqual(mounts(root.mergerfsGroups), ['/pool']);
    assert.equal(root.mergerfsGroups[0].detailsLoading, true);
    assert.equal(root.mergerfsGroups[0].detailsAvailable, false);
    assert.equal(root.mergerfsGroups[0].members.length, 0);
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a', '/mnt/disk-b']);
    root.acceptMergerfsMetadata('/pool', 'disk-a:disk-b', 'invalid metadata');
    assert.equal(root.mergerfsGroups[0].detailsLoading, false);
    assert.equal(root.mergerfsGroups[0].detailsAvailable, false);
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a', '/mnt/disk-b']);
});

test('missing mergerfs member remains unknown and does not inherit root capacity', () => {
    const root = widget();
    root.mergerfsMetadata = {
        '/pool': { device: 'disk-a:disk-b', available: true,
            branches: [{ path: '/mnt/missing/data', mode: 'NC' }] },
    };
    root.acceptDf(mergedRows);
    const member = root.mergerfsGroups[0].members[0];
    assert.equal(member.mount, '/mnt/missing/data');
    assert.equal(member.branch, '/mnt/missing/data');
    assert.equal(member.mode, 'NC');
    assert.equal(member.percent, null);
    assert.equal(member.size, '?');
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a', '/mnt/disk-b']);
});

test('member resolution uses longest mount path with a path boundary', () => {
    const root = widget();
    root.mergerfsMetadata = {
        '/pool': { device: 'disk-a:disk-b', available: true,
            branches: [
                { path: '/mnt/disk-a/nested/data', mode: 'RW' },
                { path: '/mnt/disk-ab/data', mode: 'RO' },
            ] },
    };
    root.acceptDf([
        row('/dev/system', 'ext4', 10, '/'),
        row('/dev/disk-a', 'xfs', 20, '/mnt/disk-a'),
        row('/dev/nested', 'xfs', 30, '/mnt/disk-a/nested'),
        row('disk-a:disk-b', 'fuse.mergerfs', 40, '/pool'),
    ].join('\n'));
    assert.deepEqual(mounts(root.mergerfsGroups[0].members),
        ['/mnt/disk-a/nested', '/mnt/disk-ab/data']);
    assert.equal(root.mergerfsGroups[0].members[0].percent, 30);
    assert.equal(root.mergerfsGroups[0].members[1].percent, null);
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a']);
});

test('branch and pool exclusions update cached df without hiding unrelated disks', () => {
    const settings = { excludeMounts: [] };
    const root = widget(settings);
    root.mergerfsMetadata = poolMetadata();
    root.acceptDf(mergedRows);
    settings.excludeMounts = ['/mnt/disk-a/data'];
    root.loadSettings();
    assert.deepEqual(mounts(root.mergerfsGroups[0].members), ['/mnt/disk-b']);
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a']);
    settings.excludeMounts = ['/pool'];
    root.loadSettings();
    assert.equal(root.mergerfsGroups.length, 0);
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a', '/mnt/disk-b']);
    assert.equal(root.mergerfsRequests.length, 0);
});

test('excluding a device removes its pool member rather than showing an unknown branch', () => {
    const root = widget({ excludeMounts: ['/dev/disk-a'] });
    root.mergerfsMetadata = poolMetadata();
    root.acceptDf(mergedRows);
    assert.deepEqual(mounts(root.mergerfsGroups[0].members), ['/mnt/disk-b']);
    assert.equal(root.otherMounts.length, 0);
});

test('merged storage toggle restores member rows and hides pool', () => {
    const settings = { showMergedStorage: true };
    const root = widget(settings);
    root.mergerfsMetadata = poolMetadata();
    root.acceptDf(mergedRows);
    settings.showMergedStorage = false;
    root.loadSettings();
    assert.equal(root.mergerfsGroups.length, 0);
    assert.deepEqual(mounts(root.otherMounts), ['/mnt/disk-a', '/mnt/disk-b']);
    settings.showMergedStorage = true;
    root.loadSettings();
    assert.deepEqual(mounts(root.mergerfsGroups), ['/pool']);
    assert.equal(root.otherMounts.length, 0);
});

test('network types are classified without combining repeated sources or capacities', () => {
    const root = widget({ dedupeByDevice: true });
    const types = [
        ['nfs', 'NFS'], ['nfs4', 'NFS'], ['cifs', 'SMB'], ['smb3', 'SMB'],
        ['sshfs', 'SSHFS'], ['fuse.sshfs', 'SSHFS'],
        ['rclone', 'Rclone'], ['fuse.rclone', 'Rclone'],
    ];
    root.acceptDf([
        row('/dev/system', 'ext4', 17, '/'),
        ...types.map(([fstype], index) => row('host:/same', fstype, index + 20, `/remote/${index}`)),
        row('unclassified', 'fuse.other', 91, '/local-fuse'),
    ].join('\n'));
    assert.deepEqual(Array.from(root.networkMounts, entry => entry.protocol), types.map(([, protocol]) => protocol));
    assert.deepEqual(mounts(root.networkMounts), types.map((_, index) => `/remote/${index}`));
    assert.deepEqual(Array.from(root.networkMounts, entry => entry.percent), types.map((_, index) => index + 20));
    assert.deepEqual(mounts(root.otherMounts), ['/local-fuse']);
    assert.equal(root.primaryUsagePercent, 17);
});

test('network visibility toggle preserves a priority system mount', () => {
    const settings = { showNetworkMounts: true };
    const root = widget(settings);
    root.acceptDf([
        row('/dev/system', 'ext4', 10, '/'),
        row('host:/home', 'nfs4', 60, '/home'),
        row('host:/share', 'nfs4', 80, '/remote'),
    ].join('\n'));
    assert.deepEqual(mounts(root.importantMounts), ['/', '/home']);
    assert.deepEqual(mounts(root.networkMounts), ['/remote']);
    settings.showNetworkMounts = false;
    root.loadSettings();
    assert.deepEqual(mounts(root.importantMounts), ['/', '/home']);
    assert.equal(root.networkMounts.length, 0);
    assert.equal(root.primaryUsagePercent, 10);
});

test('mergerfs metadata rejects stale devices and unmounted pools', () => {
    const root = widget();
    root.acceptDf(mergedRows);
    const original = root.mergerfsGroups[0];
    root.acceptMergerfsMetadata('/pool', 'old-device', '/mnt/disk-a=RW');
    root.acceptMergerfsMetadata('/unmounted', 'disk-a:disk-b', '/mnt/disk-a=RW');
    assert.equal(root.mergerfsGroups[0], original);
    assert.equal(Object.keys(root.mergerfsMetadata).length, 0);
    root.acceptMergerfsMetadata('/pool', 'disk-a:disk-b', '/mnt/disk-a=RW:/mnt/disk-b=RO');
    assert.equal(root.mergerfsGroups[0].detailsAvailable, true);
    assert.deepEqual(mounts(root.mergerfsGroups[0].members), ['/mnt/disk-a', '/mnt/disk-b']);
    root.acceptDf(mergedRows.replace('disk-a:disk-b fuse.mergerfs', 'replacement fuse.mergerfs'));
    assert.equal(root.mergerfsGroups[0].detailsAvailable, false);
    root.acceptMergerfsMetadata('/pool', 'disk-a:disk-b', '/mnt/disk-a=RW');
    assert.equal(root.mergerfsGroups[0].detailsAvailable, false);
});

test('mergerfs requests preserve waiting order, discard stale work, and run one at a time', () => {
    const root = widget();
    root.acceptDf([
        row('first', 'fuse.mergerfs', 20, '/pool-a'),
        row('second', 'fuse.mergerfs', 30, '/pool-b'),
    ].join('\n'));
    root.refreshMergerfsMetadata();
    assert.equal(root.mergerfsProcess.mountPoint, '/pool-a');
    assert.equal(root.mergerfsProcess.sourceDevice, 'first');
    assert.equal(root.mergerfsProcess.running, true);
    assert.deepEqual(Array.from(root.mergerfsQueue, request => request.mount), ['/pool-b']);
    root.acceptDf(row('replacement', 'fuse.mergerfs', 40, '/pool-b'));
    root.refreshMergerfsMetadata();
    assert.deepEqual(Array.from(root.mergerfsQueue, request => request.device), ['replacement']);
    root.mergerfsProcess.running = false;
    root.startNextMergerfsRequest();
    assert.equal(root.mergerfsProcess.mountPoint, '/pool-b');
    assert.equal(root.mergerfsProcess.sourceDevice, 'replacement');
    assert.equal(root.mergerfsQueue.length, 0);
});

test('repeated refreshes keep the waiting pool ahead of in-flight and new requests', () => {
    const root = widget();
    root.acceptDf([
        row('first', 'fuse.mergerfs', 20, '/pool-a'),
        row('second', 'fuse.mergerfs', 30, '/pool-b'),
    ].join('\n'));
    root.refreshMergerfsMetadata();
    assert.equal(root.mergerfsProcess.mountPoint, '/pool-a');
    root.acceptDf([
        row('third', 'fuse.mergerfs', 40, '/pool-c'),
        row('first', 'fuse.mergerfs', 20, '/pool-a'),
        row('second', 'fuse.mergerfs', 30, '/pool-b'),
    ].join('\n'));
    root.refreshMergerfsMetadata();
    root.refreshMergerfsMetadata();
    assert.deepEqual(mounts(root.mergerfsQueue), ['/pool-b', '/pool-c']);
    root.mergerfsProcess.running = false;
    root.startNextMergerfsRequest();
    assert.equal(root.mergerfsProcess.mountPoint, '/pool-b');
    assert.deepEqual(mounts(root.mergerfsQueue), ['/pool-c']);
    root.refreshMergerfsMetadata();
    assert.deepEqual(mounts(root.mergerfsQueue), ['/pool-c', '/pool-a']);
    root.showMergedStorage = false;
    root.updateMounts(root.lastDfOutput);
    assert.equal(root.mergerfsQueue.length, 0);
    assert.equal(root.mergerfsRequests.length, 0);
});

test('branch parser accepts RW, RO, NC and rejects malformed metadata', () => {
    const root = widget();
    assert.deepEqual(Array.from(root.parseMergerfsBranches('/mnt/disk-a/=RW:/mnt/disk-b=RO:/mnt/disk-c=NC'),
        branch => ({ path: branch.path, mode: branch.mode })), [
        { path: '/mnt/disk-a', mode: 'RW' },
        { path: '/mnt/disk-b', mode: 'RO' },
        { path: '/mnt/disk-c', mode: 'NC' },
    ]);
    for (const input of ['', 'relative=RW', '/mnt/disk-a=XX', '/mnt/disk-a=RW:broken', '/mnt/disk-a'])
        assert.equal(root.parseMergerfsBranches(input).length, 0, input);
});


test('unexcluding a pool starts metadata discovery without waiting for df', () => {
    const settings = { excludeMounts: ['/pool'] };
    const root = widget(settings);
    root.acceptDf(mergedRows);
    assert.equal(root.mergerfsRequests.length, 0);
    assert.equal(root.mergerfsProcess.running, false);
    settings.excludeMounts = [];
    root.loadSettings();
    assert.equal(root.mergerfsGroups[0].detailsLoading, true);
    assert.equal(root.mergerfsProcess.running, true);
    assert.equal(root.mergerfsProcess.mountPoint, '/pool');
});
