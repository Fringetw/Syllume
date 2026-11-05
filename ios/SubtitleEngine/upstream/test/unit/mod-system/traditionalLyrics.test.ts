import { afterEach, describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { unzipSync } from 'fflate';
import activate from '../../../mods/opencc-traditional-lyrics/client.mjs';
import { getConverter, transformLines } from '../../../mods/opencc-traditional-lyrics/converter.mjs';
import { Locale } from '../../../mods/opencc-traditional-lyrics/vendor/opencc-cn2t-1.4.2.mjs';
import { fromFoliumLines, toFoliumLines } from '@folia/mods/folium/dto';
import { applyLyricsTransform, installLyricsTransformHook, rerunLyricsTransform } from '@folia/services/hostExtensionHooks';
import { hostDirectory } from '../../../scripts/paths.mjs';

// Real OpenCC dictionaries plus Folia's actual frozen DTO and lyric rebuild pipeline.
const word = (text: string, startTime = 1, endTime = 2) => ({ text, startTime, endTime });
const line = (text: string, extra = {}) => ({
    fullText: text, words: [word(text)], startTime: 1, endTime: 2, ...extra,
});
const freeze = (value: any): any => {
    if (value && typeof value === 'object') {
        Object.values(value).forEach(freeze);
        Object.freeze(value);
    }
    return value;
};

function host(source: any = { lines: [line('头发发现')] }, saved: any = {}, ready = true) {
    let current = source;
    let values = { enabled: true, target: 'tw', convertOriginal: true, convertTranslation: true, protectJapanese: true, ...saved };
    const handlers = new Set<any>();
    const changes = new Set<any>();
    let command: any;
    let refreshCount = 0;
    let registrations = 0;
    const settings = {
        get: () => values,
        set: (patch: any) => { values = { ...values, ...patch }; [...changes].forEach(fn => fn()); },
        onChange: (fn: any) => { changes.add(fn); return () => changes.delete(fn); },
    };
    installLyricsTransformHook((lyrics: any) => {
        const original = toFoliumLines(lyrics.lines);
        const event = { song: null, lines: original };
        handlers.forEach(fn => fn(event));
        return event.lines === original ? lyrics : { ...lyrics, lines: fromFoliumLines(lyrics.lines, original, event.lines) };
    });
    const api = {
        env: { context: 'main' },
        registries: {
            settingsSections: { register: () => { registrations++; return { settings, unregister: () => { registrations--; } }; } },
            commands: { register: (definition: any) => { command = definition; return { unregister: () => { command = undefined; } }; } },
        },
        events: { on: (name: string, fn: any) => {
            expect(name).toBe('lyrics.transform'); handlers.add(fn); return () => handlers.delete(fn);
        } },
        lyrics: { refresh: () => {
            if (!ready) throw new Error('lyrics-unavailable-in-main-context');
            refreshCount++; current = rerunLyricsTransform(current);
        } },
    };
    return {
        api, settings,
        current: () => current,
        load: (next: any) => { ready = true; current = applyLyricsTransform(next); },
        toggle: () => command.run(),
        handlers: () => handlers.size,
        listeners: () => changes.size,
        registrations: () => registrations,
        refreshCount: () => refreshCount,
    };
}

afterEach(() => installLyricsTransformHook(null));

describe('OpenCC phrase conversion and time preservation', () => {
    it('converts ambiguous characters in whole-line context across word boundaries', () => {
        const source = freeze([line('头发发现干杯干活', { words: Array.from('头发发现干杯干活', ch => word(ch)) })]);
        const output = transformLines(source);
        expect(output[0].fullText).toBe('頭髮發現乾杯幹活');
        expect(output[0].words.map((w: any) => w.text).join('')).toBe(output[0].fullText);
        expect(source[0].fullText).toBe('头发发现干杯干活');
        output[0].words.forEach((w: any, i: number) => {
            expect([w.startTime, w.endTime]).toEqual([source[0].words[i].startTime, source[0].words[i].endTime]);
        });
    });
    it.each(['头发，发现。', '头发、发现', '头发「发现」', '头发！发现？'])('converts Chinese punctuation: %s', (text) => {
        expect(transformLines([line(text)])[0].fullText).toBe(getConverter()(text));
    });
    it('supports Taiwan and standard variants without rewriting regional vocabulary', () => {
        expect(transformLines([line('里面的互联网软件')])[0].fullText).toBe('裡面的互聯網軟件');
        expect(transformLines([line('里面')], { target: 't' })[0].fullText).toBe('裏面');
    });
    it('converts syllables in the same phrase context; preserves ruby, flags and exact times', () => {
        const syllables = [
            { ...word('头', 1, 1.2), ruby: [word('tou')], obscene: true, emptyBeat: 1 },
            { ...word('发', 1.2, 1.6), endsWithSpace: true }, word('发现', 1.6, 2),
        ];
        const source = freeze([line('头发 发现', { words: [{ ...word('头发 发现'), syllables }] })]);
        const result = transformLines(source)[0].words[0];
        expect(result.text).toBe('頭髮 發現');
        expect(result.syllables.map((s: any) => s.text)).toEqual(['頭', '髮', '發現']);
        expect(result.syllables[0].ruby).toBe(syllables[0].ruby);
        expect(result.syllables[0]).toMatchObject({ startTime: 1, endTime: 1.2, obscene: true, emptyBeat: 1 });
        expect(result.syllables[1].endsWithSpace).toBe(true);
    });
    it('keeps emoji, variation selectors, astral Han and subsequent text aligned', () => {
        const text = '😀头发𠮷发现❤️';
        const source = [line(text, { words: Array.from(text, ch => word(ch)), wordSegments: ['😀头', '发𠮷', '发现❤️'] })];
        const result = transformLines(source)[0];
        expect(result.words.map((w: any) => w.text).join('')).toBe(result.fullText);
        expect(result.wordSegments.join('')).toBe(result.fullText);
        expect(result.fullText).toBe('😀頭髮𠮷發現❤️');
    });
    it('maps normalization between BMP and astral code points without splitting surrogates', () => {
        const dict = Locale.configs.s2tw.normalizationChain[0][0];
        const entries = typeof dict === 'string' ? dict.split('|').map((entry: string) => entry.split(' ')) : dict;
        const pair = entries.find(([a, b]: string[]) => a.length !== b.length);
        expect(pair).toBeDefined();
        const source = [line(pair[0] + '头发', { words: [word(pair[0]), word('头'), word('发')] })];
        const result = transformLines(source)[0];
        expect(result.words.map((w: any) => w.text).join('')).toBe(result.fullText);
        expect(result.words.slice(1).map((w: any) => w.text)).toEqual(['頭', '髮']);
    });
    it('preserves original word segmentation after contextual conversion', () => {
        const result = transformLines([line('头发发现', { wordSegments: ['头', '发', '发现'] })])[0];
        expect(result.wordSegments).toEqual(['頭', '髮', '發現']);
    });
    it('drops an invalid saved split instead of attaching it to converted text', () => {
        expect(transformLines([line('头发', { wordSegments: ['wrong'] })])[0].wordSegments).toBeUndefined();
    });
    it('handles missing word spans and annotations that do not join the line', () => {
        const result = transformLines([line('头发', { words: [word('头发'), word('(干杯)')] })])[0];
        expect(result.words[1].text).toBe('(乾杯)');
        expect(transformLines([line('头发', { words: [] })])[0].fullText).toBe('頭髮');
    });
    it('verifies every bundled s2t/s2tw dictionary replacement preserves code point counts', () => {
        for (const mode of ['s2t', 's2tw']) {
            const config = Locale.configs[mode];
            for (const group of [...config.normalizationChain, ...config.conversionChain]) {
                for (const dict of group) {
                    const pairs = typeof dict === 'string' ? dict.split('|').map((entry: string) => entry.split(' ')) : dict;
                    for (const [a, b] of pairs) expect(Array.from(a).length, a).toBe(Array.from(b).length);
                }
            }
        }
    });
});

describe('translation and language handling', () => {
    it('preserves kana-containing Japanese while converting its Chinese translation', () => {
        const source = freeze([line('君の笑顔を见て', { translation: '头发，发现。', romanization: 'kimi no egao' })]);
        const result = transformLines(source)[0];
        expect(result.fullText).toBe(source[0].fullText);
        expect(result.words).toBe(source[0].words);
        expect(result.translation).toBe('頭髮，發現。');
        expect(result.romanization).toBe('kimi no egao');
    });
    it.each(['君ﾉ笑顔', '너의笑颜', 'キミの笑顔', 'きみの笑顔'])('preserves native scripts: %s', (text) => {
        const source = [line(text)];
        expect(transformLines(source)).toBe(source);
    });
    it('supports translation-only conversion, including kanji-only original text', () => {
        const result = transformLines([line('愛', { translation: '发现' })], { convertOriginal: false })[0];
        expect(result.fullText).toBe('愛');
        expect(result.translation).toBe('發現');
    });
    it('allows explicitly disabling script protection', () => {
        expect(transformLines([line('你の头发')], { protectJapanese: false })[0].fullText).toBe('你の頭髮');
    });
    it('converts Chinese alternates and their timed syllables; keeps explicit Japanese and romanizations', () => {
        const alternates = [
            { role: 'translation', language: 'zh-Hans', text: '头发', syllables: [word('头'), word('发')] },
            { role: 'translation', language: 'ja', text: '芸術' },
            { role: 'romanization', language: 'zh-Latn', text: '头发' },
            { role: 'translation', text: '发现' },
            { role: 'translation', language: 'zh-Latn', text: '头发' },
        ];
        const result = transformLines([line('English', { alternateTexts: alternates })])[0].alternateTexts;
        expect(result[0].text).toBe('頭髮');
        expect(result[0].syllables.map((s: any) => s.text)).toEqual(['頭', '髮']);
        expect(result[1]).toBe(alternates[1]);
        expect(result[2]).toBe(alternates[2]);
        expect(result[3].text).toBe('發現');
        expect(result[4]).toBe(alternates[4]);
    });
    it('can leave translations unchanged', () => {
        const source = [line('头发', { translation: '发现', alternateTexts: [{ role: 'translation', text: '发现' }] })];
        const result = transformLines(source, { convertTranslation: false })[0];
        expect(result.fullText).toBe('頭髮');
        expect(result.translation).toBe('发现');
        expect(result.alternateTexts).toBe(source[0].alternateTexts);
    });
    it('converts harmony text, words and translations without losing IDs', () => {
        const vocal = { text: '头发', startTime: 1, endTime: 2, words: [word('头'), word('发')], agentId: 'v2', translation: '发现' };
        const result = transformLines([line('Music', { backgroundVocals: [vocal], id: 'L1', isChorus: true })])[0];
        expect(result.backgroundVocals[0]).toMatchObject({ text: '頭髮', agentId: 'v2', translation: '發現' });
        expect(result.backgroundVocals[0].words.map((w: any) => w.text)).toEqual(['頭', '髮']);
        expect(result.id).toBe('L1');
        expect(result.isChorus).toBe(true);
    });
    it.each(['English lyrics', '😀 ❤️ 123', '繁體歌詞', ''])('preserves identity of unchanged text: %s', (text) => {
        const source = freeze([line(text)]);
        expect(transformLines(source)).toBe(source);
    });
    it('leaves disabled, empty and absent lyrics alone', () => {
        const source = [line('头发')];
        expect(transformLines(source, { enabled: false })).toBe(source);
        expect(transformLines([])).toEqual([]);
        expect(transformLines(null)).toBe(null);
    });
});

describe('Folium lifecycle with the real host rebuild and DTO validation', () => {
    it('reloads converter code when the host changes the entry fingerprint', async () => {
        const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'folia-opencc-reload-'));
        try {
            fs.copyFileSync(fileURLToPath(new URL('../../../mods/opencc-traditional-lyrics/client.mjs', import.meta.url)), path.join(temp, 'client.mjs'));
            for (const file of ['selectChinese.mjs', 'lyricQuality.mjs', 'songMatch.mjs', 'diagnostics.mjs', 'diagnosticsUi.mjs']) {
                fs.copyFileSync(fileURLToPath(new URL('../../../mods/opencc-traditional-lyrics/' + file, import.meta.url)), path.join(temp, file));
            }
            fs.mkdirSync(path.join(temp, 'vendor'));
            fs.copyFileSync(fileURLToPath(new URL('../../../mods/opencc-traditional-lyrics/vendor/opencc-jp-characters-1.4.2.mjs', import.meta.url)),
                path.join(temp, 'vendor/opencc-jp-characters-1.4.2.mjs'));
            // Use native ESM: Vite's test module cache normalizes queries and rewrites import.meta.url.
            const result = spawnSync(process.execPath, ['--input-type=module', '-e', `
                import fs from 'node:fs';
                import path from 'node:path';
                import assert from 'node:assert/strict';
                import { pathToFileURL } from 'node:url';
                const folder = process.argv[1];
                const selectorSource = fs.readFileSync(path.join(folder, 'selectChinese.mjs'), 'utf8');
                const qualitySource = fs.readFileSync(path.join(folder, 'lyricQuality.mjs'), 'utf8');
                const matchSource = fs.readFileSync(path.join(folder, 'songMatch.mjs'), 'utf8');
                const diagnosticsSource = fs.readFileSync(path.join(folder, 'diagnostics.mjs'), 'utf8');
                const diagnosticsUiSource = fs.readFileSync(path.join(folder, 'diagnosticsUi.mjs'), 'utf8');
                globalThis.selectorVersions = [];
                globalThis.qualityVersions = [];
                globalThis.matchVersions = [];
                globalThis.diagnosticsVersions = [];
                globalThis.diagnosticsUiVersions = [];
                const hooks = new Set();
                let current;
                const api = {
                    env: { context: 'main' },
                    registries: {
                        settingsSections: { register: () => ({ settings: { get: () => ({ target: 'tw' }), onChange: () => () => {} }, unregister() {} }) },
                        commands: { register: () => ({ unregister() {} }) },
                    },
                    events: { on: (_, fn) => { hooks.add(fn); return () => hooks.delete(fn); } },
                    lyrics: { refresh: () => { const event = { lines: [{ fullText: 'source' }] }; hooks.forEach(fn => fn(event)); current = event.lines[0].fullText; } },
                };
                for (const text of ['first', 'second']) {
                    fs.writeFileSync(path.join(folder, 'selectChinese.mjs'), selectorSource + "\\nglobalThis.selectorVersions.push('" + text + "');\\n");
                    fs.writeFileSync(path.join(folder, 'lyricQuality.mjs'), qualitySource + "\\nglobalThis.qualityVersions.push('" + text + "');\\n");
                    fs.writeFileSync(path.join(folder, 'songMatch.mjs'), matchSource + "\\nglobalThis.matchVersions.push('" + text + "');\\n");
                    fs.writeFileSync(path.join(folder, 'diagnostics.mjs'), diagnosticsSource + "\\nglobalThis.diagnosticsVersions.push('" + text + "');\\n");
                    fs.writeFileSync(path.join(folder, 'diagnosticsUi.mjs'), diagnosticsUiSource + "\\nglobalThis.diagnosticsUiVersions.push('" + text + "');\\n");
                    fs.writeFileSync(path.join(folder, 'converter.mjs'), "export const getConverter = () => {}; export const transformLines = lines => lines.map(line => ({ ...line, fullText: '" + text + "' }));");
                    const module = await import(pathToFileURL(path.join(folder, 'client.mjs')).href + '?v=' + text);
                    const stop = module.default(api);
                    assert.equal(current, text);
                    stop();
                }
                assert.deepEqual(globalThis.selectorVersions, ['first', 'second']);
                assert.deepEqual(globalThis.qualityVersions, ['first', 'second']);
                assert.deepEqual(globalThis.matchVersions, ['first', 'second']);
                assert.deepEqual(globalThis.diagnosticsVersions, ['first', 'second']);
                assert.deepEqual(globalThis.diagnosticsUiVersions, ['first', 'second']);
            `, temp], { encoding: 'utf8' });
            expect(result.stderr).toBe('');
            expect(result.status).toBe(0);
        } finally {
            fs.rmSync(temp, { recursive: true, force: true });
        }
    });
    it('installs and replaces the complete offline ZIP through Folia\'s real installer', async () => {
        const require = createRequire(path.join(hostDirectory(), 'package.json'));
        const { createZipInstall } = require('./electron/modSystem/zipInstall.cjs');
        const projectRoot = fileURLToPath(new URL('../../../', import.meta.url));
        const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'folia-opencc-test-'));
        try {
            const build = spawnSync(process.execPath, [path.join(projectRoot, 'scripts/build.mjs')], { encoding: 'utf8' });
            expect(build.stderr).toBe('');
            expect(build.status).toBe(0);
            const manifest = JSON.parse(fs.readFileSync(path.join(projectRoot, 'mods/opencc-traditional-lyrics/mod.json'), 'utf8'));
            const zip = path.join(projectRoot, `dist/${manifest.id}-${manifest.version}.zip`);
            const contents = unzipSync(fs.readFileSync(zip));
            const prefix = manifest.id + '/';
            expect(JSON.parse(Buffer.from(contents[prefix + 'mod.json']).toString()).version).toBe(manifest.version);
            expect(contents[prefix + 'preview.png'].length).toBeLessThanOrEqual(1048576);
            expect(contents[prefix + 'vendor/LICENSE.opencc-js']).toBeDefined();
            expect(contents[prefix + 'vendor/LICENSE.OpenCC']).toBeDefined();
            expect(contents[prefix + 'vendor/THIRD_PARTY_LICENSES.md']).toBeDefined();
            expect(contents[prefix + 'VALIDATION.md']).toBeUndefined();
            expect(contents[prefix + 'folium.sig.json']).toBeUndefined();
            expect(contents[prefix + 'selectChinese.mjs']).toBeDefined();
            expect(contents[prefix + 'lyricQuality.mjs']).toBeDefined();
            expect(contents[prefix + 'songMatch.mjs']).toBeDefined();
            const installer = createZipInstall({
                app: { getPath: () => temp }, isModSystemEnabled: () => true,
                loadAll: () => [], emitLog: () => {}, serializeError: (error: Error) => error.message,
            });
            expect(await installer.installModFromZip(zip)).toMatchObject({ ok: true, id: 'opencc-traditional-lyrics' });
            expect(await installer.installModFromZip(zip)).toMatchObject({ ok: true, id: 'opencc-traditional-lyrics' });
            const installed = path.join(temp, 'mods/opencc-traditional-lyrics');
            expect(fs.existsSync(path.join(installed, 'vendor/opencc-cn2t-1.4.2.mjs'))).toBe(true);
            const module = await import(/* @vite-ignore */ pathToFileURL(path.join(installed, 'converter.mjs')).href);
            expect(module.transformLines([line('头发')])[0].fullText).toBe('頭髮');
            const entry = await import(/* @vite-ignore */ pathToFileURL(path.join(installed, 'client.mjs')).href);
            const h = host();
            const stop = entry.default(h.api);
            expect(h.current().lines[0].fullText).toBe('頭髮發現');
            stop();
            expect(h.current().lines[0].fullText).toBe('头发发现');
        } finally {
            fs.rmSync(temp, { recursive: true, force: true });
        }
    });
    it('immediately converts the current song and restores it on disable', () => {
        const h = host();
        const stop = activate(h.api);
        expect(h.current().lines[0].fullText).toBe('頭髮發現');
        expect(h.current().lines[0].words[0].text).toBe('頭髮發現');
        stop();
        expect(h.current().lines[0].fullText).toBe('头发发现');
        expect([h.handlers(), h.listeners(), h.registrations()]).toEqual([0, 0, 0]);
    });
    it('rebuilds from unmodified source when settings change and command toggles', () => {
        const h = host({ lines: [line('里面')] });
        const stop = activate(h.api);
        expect(h.current().lines[0].fullText).toBe('裡面');
        h.settings.set({ target: 't' });
        expect(h.current().lines[0].fullText).toBe('裏面');
        h.toggle();
        expect(h.current().lines[0].fullText).toBe('里面');
        h.toggle();
        expect(h.current().lines[0].fullText).toBe('裏面');
        stop();
    });
    it('can activate before App actions exist and converts the first later load', () => {
        const h = host(null, {}, false);
        const stop = activate(h.api);
        h.load({ lines: [line('头发')] });
        expect(h.current().lines[0].fullText).toBe('頭髮');
        stop();
    });
    it('survives repeated enable/disable without accumulating listeners or converting twice', () => {
        const h = host();
        for (let i = 0; i < 10; i++) {
            const stop = activate(h.api);
            expect(h.handlers()).toBe(1);
            expect(h.current().lines[0].fullText).toBe('頭髮發現');
            stop();
            expect(h.handlers()).toBe(0);
            expect(h.current().lines[0].fullText).toBe('头发发现');
        }
    });
    it('uses saved settings on activation', () => {
        const h = host({ lines: [line('头发')] }, { enabled: false });
        const stop = activate(h.api);
        expect(h.current().lines[0].fullText).toBe('头发');
        stop();
    });
    it('handles songs without lyrics and changes of song', () => {
        const h = host();
        const stop = activate(h.api);
        h.load({ lines: [] });
        expect(h.current().lines).toEqual([]);
        h.load({ lines: [line('里面')] });
        expect(h.current().lines[0].fullText).toBe('裡面');
        stop();
        expect(h.current().lines[0].fullText).toBe('里面');
    });
    it('does not call main-only services or register transforms in export context', () => {
        expect(activate({ env: { context: 'export' } })).toBeUndefined();
    });
    it('rejects an unsupported host with a useful error', () => {
        expect(() => activate({ env: { context: 'main' }, lyrics: {} })).toThrow('請更新 Folia');
    });
    it('does not swallow unrelated host refresh errors', () => {
        const h = host();
        h.api.lyrics.refresh = () => { throw new Error('unexpected-host-failure'); };
        expect(() => activate(h.api)).toThrow('unexpected-host-failure');
        expect([h.handlers(), h.listeners(), h.registrations()]).toEqual([0, 0, 0]);
    });
    it('can dispose twice without refreshing twice or removing other registrations', () => {
        const h = host();
        const stop = activate(h.api);
        stop();
        const count = h.refreshCount();
        stop();
        expect(h.refreshCount()).toBe(count);
        expect(h.registrations()).toBe(0);
    });
    it('keeps converted timing and alternate metadata through actual host sanitization', () => {
        const source = { lines: [line('头发', {
            id: 'L1', agentId: 'v1', isChorus: true, wordSegments: ['头', '发'],
            words: [{ ...word('头发'), syllables: [word('头', 1, 1.5), word('发', 1.5, 2)] }],
            alternateTexts: [{ role: 'translation', language: 'zh-CN', text: '发现', syllables: [word('发'), word('现')] }],
        })] };
        const h = host(source);
        const stop = activate(h.api);
        expect(h.current().lines[0]).toMatchObject({
            fullText: '頭髮', id: 'L1', agentId: 'v1', isChorus: true, wordSegments: ['頭', '髮'],
            words: [{ text: '頭髮', startTime: 1, endTime: 2, syllables: [{ text: '頭', startTime: 1, endTime: 1.5 }, { text: '髮', startTime: 1.5, endTime: 2 }] }],
            alternateTexts: [{ role: 'translation', text: '發現' }],
        });
        expect(h.current().lines[0].renderHints.renderEndTime).toBeGreaterThanOrEqual(2);
        expect(source.lines[0].fullText).toBe('头发');
        stop();
    });
});
