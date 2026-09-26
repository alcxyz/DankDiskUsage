// Exercise the widget's QML JavaScript without starting Quickshell or Nix.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const qml = fs.readFileSync(path.join(__dirname, '..', 'DankDiskUsageWidget.qml'), 'utf8');
const functions = [...qml.matchAll(/^    function (\w+)\([^\n]*\) \{[\s\S]*?^    \}/gm)]
    .map(match => match[0].replace(/^    /gm, ''));

function widget() {
    const root = {
        collectorSnapshot: null,
        collectorReadError: '',
        collectorNow: Date.parse('2026-09-26T12:00:00Z'),
        showNixStore: true,
        useCollector: true,
        dfProcess: { running: false },
        nixPathCountProcess: { running: false },
        collectorFile: { reloads: 0, reload() { this.reloads++; } },
    };
    root.root = root;
    const context = vm.createContext(root);
    for (const source of functions) {
        const name = source.match(/^function (\w+)/)[1];
        root[name] = vm.runInContext(`(${source})`, context);
    }
    return root;
}

function snapshot() {
    return {
        version: 1,
        nix: {
            registered: { paths: 100, bytes: 1073741824, updatedAt: '2026-09-26T11:10:00Z', checkedAt: '2026-09-26T11:10:00Z', error: '' },
            closure: { paths: 20, bytes: 1024, updatedAt: '2026-09-26T11:59:00Z', checkedAt: '2026-09-26T11:59:00Z', error: '', target: '/run/current-system' },
        },
    };
}

test('accepts the collector schema and formats logical sizes and freshness', () => {
    const root = widget();
    root.acceptCollectorSnapshot(JSON.stringify(snapshot()));
    root.collectorNow = Date.parse('2026-09-26T12:00:00Z');
    assert.equal(root.collectorSnapshot.nix.registered.paths, 100);
    assert.equal(root.formatCollectorBytes(root.collectorSnapshot.nix.registered.bytes), '1.0 GiB');
    assert.match(root.collectorStatus(root.collectorSnapshot.nix.registered, true), /50m ago\) · stale$/);
    assert.match(root.collectorStatus(root.collectorSnapshot.nix.closure, false), /1m ago\)$/);
    assert.equal(root.collectorReadError, '');
});

test('rejects invalid schema while retaining the previous snapshot', () => {
    const root = widget();
    root.acceptCollectorSnapshot(JSON.stringify(snapshot()));
    const previous = root.collectorSnapshot;
    const invalid = snapshot();
    invalid.nix.registered.bytes = -1;
    root.acceptCollectorSnapshot(JSON.stringify(invalid));
    assert.equal(root.collectorSnapshot, previous);
    assert.match(root.collectorReadError, /Invalid collector snapshot/);
    invalid.nix.registered.bytes = 100;
    invalid.nix.closure.updatedAt = 'yesterday';
    root.acceptCollectorSnapshot(JSON.stringify(invalid));
    assert.equal(root.collectorSnapshot, previous);
    root.acceptCollectorSnapshot('{');
    assert.equal(root.collectorSnapshot, previous);
});

test('surfaces collector errors and missing snapshots', () => {
    const root = widget();
    assert.equal(root.collectorStatus(null), 'Waiting for collector snapshot');
    const data = snapshot();
    data.nix.registered.error = 'query failed';
    root.acceptCollectorSnapshot(JSON.stringify(data));
    assert.match(root.collectorStatus(root.collectorSnapshot.nix.registered), /query failed/);
    data.nix.registered.updatedAt = '';
    data.nix.registered.checkedAt = '';
    data.nix.registered.bytes = 0;
    data.nix.registered.paths = 0;
    root.acceptCollectorSnapshot(JSON.stringify(data));
    assert.match(root.collectorStatus(root.collectorSnapshot.nix.registered, true), /No successful measurement · query failed/);
    data.nix.closure.updatedAt = '2026-01-01T00:00:00Z';
    data.nix.closure.checkedAt = '2026-09-26T11:59:00Z';
    root.acceptCollectorSnapshot(JSON.stringify(data));
    root.collectorNow = Date.parse('2026-09-26T12:00:00Z');
    assert.doesNotMatch(root.collectorStatus(root.collectorSnapshot.nix.closure, true), /stale/);
    data.nix.closure.updatedAt = '';
    data.nix.closure.checkedAt = '';
    data.nix.closure.target = '';
    data.nix.closure.error = 'no current system';
    root.acceptCollectorSnapshot(JSON.stringify(data));
    assert.equal(root.collectorSnapshot.nix.closure.target, '');
});

test('refresh in collector mode only reloads the snapshot and disk data', () => {
    const root = widget();
    root.refreshAll();
    assert.equal(root.collectorFile.reloads, 1);
    assert.equal(root.dfProcess.running, true);
    assert.equal(root.nixPathCountProcess.running, false);
    root.useCollector = false;
    root.refreshAll();
    assert.equal(root.nixPathCountProcess.running, true);
    assert.equal(root.collectorFile.reloads, 1);
});

test('FileView reads the cache directly and manual scan remains separate', () => {
    assert.match(qml, /property FileView collectorFile: FileView/);
    assert.match(qml, /Quickshell\.env\("XDG_CACHE_HOME"\)/);
    assert.match(qml, /onFileChanged: reload\(\)/);
    assert.match(qml, /root\.showNixStore && !root\.useCollector && !nixPathCountProcess\.running/);
    assert.match(qml, /Store disk usage \(manual scan\)/);
});
