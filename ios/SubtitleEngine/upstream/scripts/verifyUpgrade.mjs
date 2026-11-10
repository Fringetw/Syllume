import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { unzipSync } from 'fflate';
import { hostDirectory, root, readManifest } from './paths.mjs';

// Install the actual previous and current ZIPs, then load both entry fingerprints with native ESM.
const previousZip = process.argv[2];
if (!previousZip || !fs.existsSync(previousZip)) throw new Error('Pass the actual previous install ZIP as the first argument.');
const host = hostDirectory();
const requireHost = createRequire(path.join(host, 'package.json'));
const { createZipInstall } = requireHost('./electron/modSystem/zipInstall.cjs');
const { computeModDigest, shortDigest } = requireHost('./electron/modSystem/modDigest.cjs');
const manifest = readManifest();
const currentZip = path.join(root, 'dist', `${manifest.id}-${manifest.version}.zip`);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'opencc-upgrade-'));
const checks = [];
const report = { hostVersion: JSON.parse(fs.readFileSync(path.join(host, 'package.json'))).version,
    fromVersion: '1.1.5', toVersion: manifest.version, checks, completed: false,
    scope: 'Actual saved ZIPs, official installer/digest and native ESM. Offline host API; no Windows GUI or live music.' };
const check = (name, test) => { test(); checks.push({ name, passed: true }); };
const commands = new Map();
const callbacks = new Set();
const settingsListeners = new Set();
let sections = 0;
const settings = { enabled: true, target: 'tw', convertOriginal: false, convertTranslation: true,
    protectJapanese: true, autoSelectChinese: true, fallbackOnFailure: true, searchDepth: 'deep' };
const savedSettings = JSON.stringify(settings);
const api = {
    host: { folia: report.hostVersion, folium: { major: 1, minor: 7 } }, env: { context: 'main' },
    registries: {
        settingsSections: { register: () => {
            sections++;
            return { settings: { get: () => settings, set: patch => Object.assign(settings, patch),
                onChange: listener => { settingsListeners.add(listener); return () => settingsListeners.delete(listener); } },
                unregister: () => { sections--; } };
        } },
        commands: { register: definition => { commands.set(definition.id, definition);
            return { unregister: () => commands.delete(definition.id) }; } },
    },
    events: { on: (name, callback) => { const item = { name, callback }; callbacks.add(item); return () => callbacks.delete(item); } },
    playback: { getState: () => ({ song: null, duration: 0 }) },
    lyrics: { getLines: () => [], refresh: () => {} }, ui: { toast: () => {} }, log: { info() {}, warn() {} },
    omni: { listProviders: () => [], searchSongs: async () => ({ items: [] }), getLyrics: async () => ({ lines: [] }) },
};
const installed = path.join(profile, 'mods', manifest.id);
let stop = () => {};
try {
    const installer = createZipInstall({ app: { getPath: () => profile }, isModSystemEnabled: () => true,
        loadAll: () => [], emitLog: () => {}, serializeError: error => error.message });
    const initialInstall = await installer.installModFromZip(path.resolve(previousZip));
    check('official installer accepts the saved 1.1.5 ZIP', () => assert.equal(initialInstall.ok, true));
    check('installed manifest is 1.1.5', () => assert.equal(JSON.parse(fs.readFileSync(path.join(installed, 'mod.json'))).version, '1.1.5'));
    const oldDigest = computeModDigest(installed);
    const oldEntry = await import(pathToFileURL(path.join(installed, 'client.mjs')).href + '?v=' + shortDigest(oldDigest));
    stop = oldEntry.default(api);
    const diagnostic = () => commands.get('diagnostic-report').run();
    check('native old activation reports v1.1.5', () => assert.match(diagnostic(), /OpenCC v1\.1\.5/));
    const oldMatcher = await import(pathToFileURL(path.join(installed, 'songMatch.mjs')).href + '?v=' + shortDigest(oldDigest));
    const target = { source: 'ytm', title: '青のすみか (Acoustic ver.) - Where Our Blue Is (Acoustic version)', artist: 'Tatsuya Kitani' };
    const candidate = { source: 'netease', title: '青のすみか (Acoustic ver.)', artist: 'キタニタツヤ', ref: 'fixture' };
    check('actual old installed matcher reproduces the reported rejection', () => assert.equal(oldMatcher.matchSong(target, candidate, 204, 203.592), 0));
    assert.equal((await installer.installModFromZip(currentZip)).ok, true);
    check('official installer upgrades the same mod ID with the current ZIP', () => assert.equal(JSON.parse(fs.readFileSync(path.join(installed, 'mod.json'))).version, manifest.version));
    const nextDigest = computeModDigest(installed);
    check('official content digest and entry URL fingerprint change', () => { assert.notEqual(nextDigest, oldDigest); assert.notEqual(shortDigest(nextDigest), shortDigest(oldDigest)); });
    const bytes = unzipSync(fs.readFileSync(currentZip));
    check('every installed file equals the tested delivered archive', () => {
        for (const [name, content] of Object.entries(bytes)) {
            if (!name.endsWith('/')) assert.deepEqual(fs.readFileSync(path.join(profile, 'mods', name)), Buffer.from(content));
        }
    });
    check('disk replacement does not silently mutate an already active module', () => assert.match(diagnostic(), /OpenCC v1\.1\.5/));
    stop(); stop = () => {};
    check('old activation releases every registration', () => assert.equal(commands.size + callbacks.size + settingsListeners.size + sections, 0));
    const entry = await import(pathToFileURL(path.join(installed, 'client.mjs')).href + '?v=' + shortDigest(nextDigest));
    stop = entry.default(api);
    check('new activation and diagnostic dependency report the current version', () => assert.ok(diagnostic().includes('OpenCC v' + manifest.version)));
    const matcher = await import(pathToFileURL(path.join(installed, 'songMatch.mjs')).href + '?v=' + shortDigest(nextDigest));
    check('actual new installed matcher accepts exact reported metadata', () => assert.equal(matcher.matchSong(target, candidate, 204, 203.592), 1));
    check('diagnostic commands remain available', () => ['diagnostic-report', 'copy-diagnostic-report', 'download-diagnostic-report'].forEach(name => assert.ok(commands.has(name))));
    check('saved module settings remain intact', () => assert.equal(JSON.stringify(settings), savedSettings));
    stop(); stop = () => {};
    check('new activation releases every registration', () => assert.equal(commands.size + callbacks.size + settingsListeners.size + sections, 0));
    report.completed = true;
} catch (error) {
    report.error = String(error.stack ?? error); process.exitCode = 1;
} finally {
    stop(); fs.rmSync(profile, { recursive: true, force: true });
    const destination = path.join(root, 'docs/validation', `upgrade-1.1.5-to-${manifest.version}-folia-${report.hostVersion}.json`);
    fs.writeFileSync(destination, JSON.stringify(report, null, 2) + '\n');
    console.log(`${checks.length} upgrade checks; completed=${report.completed}; ${destination}`);
    if (report.error) console.error(report.error);
}
