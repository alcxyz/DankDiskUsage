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
        dedupeByDevice: false,
        excludeMounts: [],
        importantMounts: [],
        zfsPoolGroups: [],
        btrfsVolumeGroups: [],
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
    for (const name of ['updateMounts', 'loadSettings', 'groupBtrfsVolumes', 'dedupeSameDevice', 'updatePrimaryUsage']) {
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
    assert.equal(root.otherMounts.length, sources.length * 2);
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
