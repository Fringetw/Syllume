import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { createSubtitleEngine, defaults } from '../engine.mjs';

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const song = { id: 'native', source: 'local', title: '夜に駆ける', artist: 'YOASOBI', durationMs: 60000 };
const originals = ['青い紙飛行機を折る', '机の上で地図を広げる', '窓際の小さな鉢に水を注ぐ', '新しい駅の名前を覚える'];
const translations = ['摺一架藍色紙飛機', '在桌面上攤開地圖', '替窗邊的小盆栽澆水', '記住新車站的名字'];
const lines = originals.map((fullText, i) => ({ fullText, startTime: 10 + i * 5, endTime: 14 + i * 5,
    words: [{ text: fullText, startTime: 10 + i * 5, endTime: 14 + i * 5 }] }));
function harness(request = async () => ({ items: [] })) {
    const shown = [], reports = [], messages = [];
    const engine = createSubtitleEngine({ request, publish: value => shown.push(value), report: value => reports.push(value),
        toast: text => messages.push(text) });
    return { engine, shown, reports, messages, last: () => shown.at(-1) };
}
const provider = { providerId: 'donor', displayName: 'Test', configured: true, supports: { search: true, lyrics: true } };

test('the embedded engine and dictionaries match the pinned plugin bytes', () => {
    const provenance = JSON.parse(fs.readFileSync(new URL('../provenance.json', import.meta.url)));
    for (const [path, expected] of Object.entries(provenance.blobs)) {
        const url = new URL('../upstream/' + path, import.meta.url);
        if (!fs.existsSync(url)) continue;
        const content = fs.readFileSync(url);
        const hash = crypto.createHash('sha1').update('blob ' + content.length + '\0').update(content).digest('hex');
        assert.equal(hash, expected, path);
    }
    assert.equal(provenance.version, '1.1.6');
});

test('offline conversion preserves timing, syllables, harmony and input immutability', () => {
    const raw = [{ fullText: '头发发现', startTime: 0, endTime: 4, translation: '风里的回声', romanization: 'unchanged',
        words: [{ text: '头发', startTime: 0, endTime: 2, syllables: [{ text: '头', startTime: 0, endTime: 1 }, { text: '发', startTime: 1, endTime: 2 }] },
            { text: '发现', startTime: 2, endTime: 4 }], wordSegments: ['头发', '发现'],
        backgroundVocals: [{ text: '风', startTime: 2, endTime: 3, words: [{ text: '风', startTime: 2, endTime: 3 }] }] }];
    const before = JSON.stringify(raw), h = harness();
    h.engine.configure({ ...defaults, autoSelectChinese: false, fallbackOnFailure: false }, []);
    h.engine.load({ token: 'a', song, duration: 60, lines: raw });
    assert.equal(h.last().lines[0].fullText, '頭髮發現');
    assert.deepEqual(h.last().lines[0].words.map(w => [w.text, w.startTime, w.endTime]), [['頭髮', 0, 2], ['發現', 2, 4]]);
    assert.equal(h.last().lines[0].words[0].syllables[1].text, '髮');
    assert.equal(h.last().lines[0].backgroundVocals[0].text, '風');
    assert.equal(h.last().lines[0].translation, '風裡的回聲');
    assert.equal(JSON.stringify(raw), before);
    h.engine.dispose();
});

test('conversion settings remain independent and module disable restores raw text', () => {
    const h = harness(), raw = [{ ...lines[0], fullText: '风', words: [], translation: '云', romanization: 'kumo' }];
    h.engine.configure({ ...defaults, autoSelectChinese: false, convertOriginal: false }, []);
    h.engine.load({ token: 'a', song, duration: 60, lines: raw });
    assert.equal(h.last().lines[0].fullText, '风'); assert.equal(h.last().lines[0].translation, '雲');
    h.engine.configure({ ...defaults, active: false }, []);
    assert.deepEqual(h.last().lines, raw);
    h.engine.configure({ ...defaults, autoSelectChinese: false, protectJapanese: true }, []);
    h.engine.load({ token: 'b', song, duration: 60, lines: [{ ...raw[0], fullText: '風が吹く', translation: '云' }] });
    assert.equal(h.last().lines[0].fullText, '風が吹く');
    assert.equal(h.last().lines[0].translation, '雲');
    h.engine.dispose();
});

test('search merges Chinese, restores and retries with the original word clock', async () => {
    let reads = 0;
    const h = harness(async method => { reads++; return method === 'search'
        ? { items: [{ ...song, id: 'match', source: 'donor', ref: 'ref' }] }
        : { lines: lines.map((line, i) => ({ ...line, translation: translations[i] })) }; });
    h.engine.configure(defaults, [provider]);
    h.engine.load({ token: 'a', song, duration: 60, lines });
    await wait(80);
    assert.equal(h.last().lines[0].translation, translations[0]);
    assert.deepEqual(h.last().lines[0].words, lines[0].words);
    h.engine.command('restore');
    assert.equal(h.last().lines[0].translation, undefined);
    const afterRestore = reads; await wait(30); assert.equal(reads, afterRestore);
    h.engine.command('retry'); await wait(80);
    assert.equal(h.last().lines[0].translation, translations[0]);
    assert.ok(reads > afterRestore);
    h.engine.dispose();
});

test('track changes abort pending source reads and ignore late results', async () => {
    let resolve, signal;
    const h = harness(async (method, params, requestSignal) => {
        signal = requestSignal; return await new Promise(r => { resolve = r; });
    });
    h.engine.configure(defaults, [provider]);
    h.engine.load({ token: 'old', song, duration: 60, lines });
    await wait(5);
    h.engine.load({ token: 'new', song: { ...song, id: 'next' }, duration: 60, lines: [{ ...lines[0], fullText: '另一首' }] });
    assert.equal(signal.aborted, true);
    resolve({ items: [{ ...song, source: 'donor' }] }); await wait(5);
    assert.equal(h.last().token, 'new'); assert.equal(h.last().lines[0].fullText, '另一首');
    h.engine.dispose();
});

test('diagnostic viewing/export and conversion toggles do not issue new reads', async () => {
    let reads = 0;
    const h = harness(async () => { reads++; return { items: [] }; });
    h.engine.configure(defaults, [provider]); h.engine.load({ token: 'a', song, duration: 60, lines });
    await wait(120); const before = reads;
    h.engine.command('status');
    const report = JSON.parse(JSON.stringify(h.reports.at(-1).value));
    assert.equal(report.modVersion, '1.1.6'); assert.ok(report.events.length);
    h.engine.configure({ ...defaults, enabled: false }, [provider]);
    await wait(20); assert.equal(reads, before);
    assert.equal(JSON.stringify(report).includes(originals[0]), false);
    h.engine.dispose();
});

test('the shipped browser bundle starts and converts without network access', () => {
    const sent = [], window = { webkit: { messageHandlers: { subtitles: { postMessage: value => sent.push(value) } } }, addEventListener() {} };
    const context = { window, URL, AbortController, setTimeout, clearTimeout, queueMicrotask, console };
    vm.runInNewContext(fs.readFileSync(new URL('../../Folia/Resources/FoliaSubtitles/subtitles.js', import.meta.url), 'utf8'), context);
    assert.equal(sent[0].type, 'ready');
    window.FoliaSubtitles.configure({ ...defaults, autoSelectChinese: false, fallbackOnFailure: false }, [], 'account');
    window.FoliaSubtitles.load({ token: 'native', song, duration: 60,
        lines: [{ fullText: '头发', startTime: 0, endTime: 1, words: [{ text: '头发', startTime: 0, endTime: 1 }] }] });
    assert.equal(sent.findLast(m => m.type === 'display').lines[0].fullText, '頭髮');
    assert.equal(sent.filter(m => m.type === 'request').length, 0);
    window.FoliaSubtitles.configure({ ...defaults, active: false }, [], 'account');
});

test('YouTube converts immediately but waits for real metadata before searching', async () => {
    const queries = [];
    const h = harness(async (method, params) => { queries.push(params.query); return { items: [] }; });
    h.engine.configure(defaults, [provider]);
    const raw = [{ fullText: '头发', startTime: 0, endTime: 4, words: [] }, ...lines];
    h.engine.load({ token: 'pending', song: { ...song, source: 'ytm', title: 'YouTube 影片', artist: '', durationMs: 0 }, duration: 0, lines: raw });
    await wait(20);
    assert.equal(queries.length, 0);
    assert.equal(h.last().lines[0].fullText, '頭髮');
    h.engine.configure(defaults, [provider], 'new-account'); await wait(10);
    assert.equal(queries.length, 0);
    h.engine.load({ token: 'ready', song: { ...song, source: 'ytm' }, duration: 60, lines: raw });
    await wait(30);
    assert.ok(queries.length > 0);
    assert.equal(queries.some(query => query.includes('YouTube 影片')), false);
    h.engine.dispose();
});

test('native display uses the plugin’s Chinese alternate-text choice without replacing other languages', () => {
    const h = harness();
    const raw = [{ ...lines[0], translation: 'An English sentence', alternateTexts: [
        { role: 'translation', language: 'en', text: 'An English sentence' },
        { role: 'translation', language: 'zh-CN', text: '摺一架蓝色纸飞机' },
    ] }];
    h.engine.configure({ ...defaults, autoSelectChinese: false, fallbackOnFailure: false }, []);
    h.engine.load({ token: 'alternate', song, duration: 60, lines: raw });
    assert.equal(h.last().lines[0].displayTranslation, '摺一架藍色紙飛機');
    assert.equal(h.last().lines[0].translation, 'An English sentence');
    assert.equal(h.last().lines[0].alternateTexts[0].text, 'An English sentence');
    h.engine.dispose();
});

test('reenabling the built-in module restarts search for the current song', async () => {
    let reads = 0;
    const h = harness(async () => { reads++; return { items: [] }; });
    h.engine.configure({ ...defaults, active: false }, [provider]);
    h.engine.load({ token: 'current', song, duration: 60, lines });
    await wait(10); assert.equal(reads, 0);
    h.engine.configure(defaults, [provider]);
    await wait(30); assert.ok(reads > 0);
    h.engine.dispose();
});


test('diagnostics receive the native app version instead of a stale bundled version', async () => {
    const h = harness();
    h.engine.configure({ ...defaults, hostVersion: 'Folia-iOS/0.3.3' }, [provider]);
    h.engine.load({ token: 'host', song, duration: 60, lines });
    await wait(130);
    assert.equal(h.reports.at(-1).value.host.folia, 'Folia-iOS/0.3.3');
    h.engine.dispose();
});

test('configuration revisions reject an older disable arriving after reenable', () => {
    const h = harness();
    const raw = [{ fullText: '头发发现', startTime: 0, endTime: 4, words: [] }];
    h.engine.configure({ ...defaults, enabled: false, nativeRevision: 1 }, []);
    h.engine.load({ token: 'config', song, duration: 60, lines: raw });
    h.engine.configure({ ...defaults, active: false, nativeRevision: 2 }, []);
    assert.equal(h.last().lines[0].fullText, '头发发现');
    h.engine.configure({ ...defaults, nativeRevision: 4 }, []);
    assert.equal(h.last().lines[0].fullText, '頭髮發現');
    assert.equal(h.last().configurationRevision, 4);
    h.engine.configure({ ...defaults, active: false, nativeRevision: 3 }, []);
    assert.equal(h.last().lines[0].fullText, '頭髮發現');
    assert.equal(h.last().configurationRevision, 4);
    h.engine.dispose();
});
