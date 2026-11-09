import { afterEach, describe, expect, it, vi } from 'vitest';
import activate from '../../../mods/opencc-traditional-lyrics/client.mjs';
import { getConverter } from '../../../mods/opencc-traditional-lyrics/converter.mjs';
import { createChineseSelector } from '../../../mods/opencc-traditional-lyrics/selectChinese.mjs';
import { alignLyrics, analyzeLyrics, chooseLyrics, chineseTranslation, isChineseText, lyricsKey, matchSong, mergeTranslations, songKey, repairWordTimings,
    translationQuality } from '../../../mods/opencc-traditional-lyrics/lyricQuality.mjs';
import { fromFoliumLines, toFoliumLines } from '@folia/mods/folium/dto';
import { createFoliumOmniService, registerFoliumOmniSource } from '@folia/mods/folium/omni/service';
import { resetFoliumRequestQuotasForTest } from '@folia/mods/folium/omni/requestQuota';
import { parseLRC } from '@folia/utils/lyrics/parserCore';
import { artistKey, searchQueries, titleForms, probeSong } from '../../../mods/opencc-traditional-lyrics/songMatch.mjs';
import { beginReport, finishReport, record, safeText, safeError } from '../../../mods/opencc-traditional-lyrics/diagnostics.mjs';
import { applyLyricsTransform, installLyricsTransformHook, lyricsForNoLyrics, rerunLyricsTransform } from '@folia/services/hostExtensionHooks';
import acousticReport from '../../fixtures/acoustic-0.7.25-report.json';

// Offline tests: real host DTO/rebuild/Omni boundary, deterministic provider responses; no user accounts.
const canonicalize = getConverter();
const target = (extra: any = {}) => ({ id: 'a', source: 'local', title: '夜に駆ける', artist: 'YOASOBI', album: null, ref: 'song-local', ...extra });
const candidate = (extra: any = {}) => target({ id: 'online', source: 'netease', ref: 'song-online', ...extra });
const line = (fullText: string, index = 0, translation?: string) => ({ fullText, startTime: 10 + index * 5, endTime: 14 + index * 5,
    words: [{ text: fullText, startTime: 10 + index * 5, endTime: 14 + index * 5 }], ...(translation ? { translation } : {}) });
const originals = ['青い紙飛行機を折る', '机の上で地図を広げる', '窓際の小さな鉢に水を注ぐ', '新しい駅の名前を覚える'];
const translations = ['摺一架藍色紙飛機', '在桌面上攤開地圖', '替窗邊的小盆栽澆水', '記住新車站的名字'];
const lyrics = (count = 0) => originals.map((text, index) => line(text, index, index < count ? translations[index] : undefined));
const donor = (lines: any[], source = 'test') => ({ lines: toFoliumLines(lines), source, match: 1 });
const flush = async () => { for (let i = 0; i < 50; i++) await Promise.resolve(); };
const deferred = () => { let resolve: (value: any) => void = () => {}; const promise = new Promise<any>((r) => { resolve = r; }); return { promise, resolve }; };
const stops: Array<() => void> = [];

function harness(options: any = {}) {
    let song = options.song ?? target();
    let raw: any = options.empty ? null : { lines: options.lines ?? lyrics() };
    let shown = raw;
    let values: any = { enabled: true, target: 'tw', autoSelectChinese: true, fallbackOnFailure: true, searchDepth: 'standard', ...options.settings };
    const callbacks = new Map<string, Set<any>>();
    const changes = new Set<any>();
    const commands = new Map<string, any>();
    const emit = (name: string, payload: any) => callbacks.get(name)?.forEach((fn) => fn(payload));
    const onTransform = (source: any) => {
        const sourceLines = toFoliumLines(source.lines);
        const event = { song, lines: sourceLines };
        emit('lyrics.transform', event);
        return event.lines === sourceLines ? source : { ...source, lines: fromFoliumLines(source.lines, sourceLines, event.lines) };
    };
    installLyricsTransformHook(onTransform);
    const settings = { get: () => values, set: (patch: any) => { values = { ...values, ...patch }; changes.forEach((fn) => fn()); },
        onChange: (fn: any) => { changes.add(fn); return () => changes.delete(fn); } };
    const providers = options.providers ?? [{ providerId: 'netease', displayName: '網易雲', configured: true, supports: { search: true, lyrics: true } }];
    const api: any = {
        env: { context: 'main' },
        registries: {
            settingsSections: { register: () => ({ settings, unregister: vi.fn() }) },
            commands: { register: (definition: any) => { commands.set(definition.id, definition); return { unregister: () => commands.delete(definition.id) }; } },
        },
        playback: { getState: () => ({ song, duration: options.duration ?? 200 }) },
        lyrics: { getLines: () => toFoliumLines(shown?.lines), refresh: vi.fn(() => { shown = rerunLyricsTransform(shown); }) },
        events: { on: (name: string, fn: any) => {
            if (!callbacks.has(name)) callbacks.set(name, new Set()); callbacks.get(name)!.add(fn);
            return () => callbacks.get(name)?.delete(fn);
        } },
        ui: { toast: vi.fn() }, log: { warn: vi.fn() },
        omni: {
            listProviders: () => providers,
            describeSong: () => ({ durationMs: 200000 }),
            searchSongs: vi.fn(async () => ({ items: [candidate()], nextCursor: null })),
            getLyrics: vi.fn(async () => ({ lines: toFoliumLines(lyrics(4)), isPureMusic: false })),
            ...options.omni,
        },
    };
    return {
        api, settings, commands, emit,
        shown: () => shown,
        raw: () => raw,
        change(next: any, lines: any[] | null = lyrics()) {
            song = next;
            raw = lines === null ? null : { lines };
            emit('playback.songChanged', { song });
            shown = raw ? applyLyricsTransform(raw) : lyricsForNoLyrics();
            emit('lyrics.loaded', { song, lines: toFoliumLines(shown?.lines) });
        },
        rebuild() { raw = { lines: raw.lines.map((item: any) => ({ ...item, wordSegments: Array.from(item.fullText) })) }; shown = applyLyricsTransform(raw); },
        failWithoutNotification() { raw = null; shown = lyricsForNoLyrics(); },
        listenCount: () => [...callbacks.values()].reduce((sum, set) => sum + set.size, 0),
        start() { const stop = activate(api); stops.push(stop); return stop; },
    };
}

afterEach(() => { stops.splice(0).reverse().forEach((stop) => stop()); installLyricsTransformHook(null);
    registerFoliumOmniSource(null); resetFoliumRequestQuotasForTest(); vi.useRealTimers(); });

const reportFrom = (h: ReturnType<typeof harness>) => {
    const text = h.commands.get('diagnostic-report').run();
    return JSON.parse(text.split('── 完整結構化紀錄 ──\n')[1]);
};

describe('full search diagnostics', () => {
    it('records successful requests, comparisons, alignment and the applied choice without lyric bodies', async () => {
        const h = harness(); h.start(); await flush();
        const r = reportFrom(h);
        expect(r).toMatchObject({ schemaVersion: 1, modVersion: '1.1.6', status: 'selected', trigger: 'automatic',
            selection: { strategy: 'merged', metrics: { coverage: 1 } } });
        expect(r.startedAt).toBeTruthy(); expect(r.finishedAt).toBeTruthy();
        expect(r.providers).toEqual([expect.objectContaining({ id: 'netease', included: true })]);
        expect(r.events.filter((event: any) => ['search', 'lyrics'].includes(event.stage)))
            .toEqual([expect.objectContaining({ stage: 'search', status: 'success', elapsedMs: expect.any(Number) }),
                expect.objectContaining({ stage: 'lyrics', status: 'success', elapsedMs: expect.any(Number) })]);
        expect(r.events.find((event: any) => event.stage === 'candidate-match')).toMatchObject({
            outcome: 'lyrics-requested', comparison: { exactTitle: true, versionDifferences: [] } });
        expect(r.decisions[0]).toMatchObject({ outcome: 'applied', alignment: { safe: true, anchors: 4 } });
        expect(JSON.stringify(r)).not.toContain(originals[0]);
        expect(JSON.stringify(r)).not.toContain('song-online');
    });
    it('shows rejected metadata and normalized names before any lyric request', async () => {
        const h = harness({ omni: { searchSongs: vi.fn(async () => ({ items: [candidate({ title: '違う作品 (Live)', artist: 'Other' })] })) } });
        h.start(); await flush();
        const r = reportFrom(h);
        const rejected = r.events.filter((event: any) => event.stage === 'candidate-match');
        expect(rejected.length).toBeGreaterThan(0);
        expect(rejected[0]).toMatchObject({ outcome: 'rejected', reason: 'identity-unconfirmed',
            comparison: { exactTitle: false, artistAgreement: 0, versionDifferences: ['live'] } });
        expect(rejected[0].comparison.targetTitleForms.length).toBeGreaterThan(0);
        expect(h.api.omni.getLyrics).not.toHaveBeenCalled();
    });
    it.each([
        ['empty', { lines: [] }], ['instrumental', { lines: [], isPureMusic: true }],
        ['no-chinese', { lines: toFoliumLines(lyrics()) }],
        ['invalid', { lines: [{ fullText: '', startTime: 10, endTime: 14, words: [] }] }],
    ])('records the exact lyric-quality rejection: %s', async (reason, answer) => {
        const h = harness({ omni: { getLyrics: vi.fn(async () => answer) } }); h.start(); await flush();
        expect(reportFrom(h).events).toContainEqual(expect.objectContaining({ stage: 'lyric-quality', outcome: 'rejected', reason }));
    });
    it('records low alignment evidence without changing the original animation', async () => {
        const wrong = lyrics(4).map((item, i) => ({ ...item, fullText: `全く別の文章が続いている${i}` }));
        const h = harness({ song: target({ artist: 'Unknown spelling' }), omni: { getLyrics: vi.fn(async () => ({ lines: toFoliumLines(wrong) })) } });
        h.start(); await flush();
        const r = reportFrom(h);
        expect(r.decisions[0]).toMatchObject({ outcome: 'rejected', reason: 'alignment-insufficient', alignment: { safe: false, coverage: 0 } });
        expect(r.selection.strategy).toBe('original');
        expect(h.shown().lines).toEqual(h.raw().lines);
    });
    it('records source errors by stage and does not export arbitrary errors, refs, credentials or response bodies', async () => {
        const h = harness({ song: target({ ref: 'PRIVATE-REF', album: 'token=PRIVATE-TOKEN' }), omni: {
            searchSongs: vi.fn(async () => { throw Object.assign(new Error('https://private.example/?token=PRIVATE-TOKEN'),
                { code: 'network', body: { cookie: 'PRIVATE-COOKIE' }, diagnosticOrigin: 'PRIVATE-ORIGIN' }); }),
        } }); h.start(); await flush();
        const r = reportFrom(h); const encoded = JSON.stringify(r);
        expect(r.events[0]).toMatchObject({ stage: 'search', status: 'failed', provider: 'netease', error: { code: 'network', origin: 'folia-source' } });
        for (const secret of ['PRIVATE-REF', 'PRIVATE-TOKEN', 'PRIVATE-COOKIE', 'PRIVATE-ORIGIN', 'private.example']) expect(encoded).not.toContain(secret);
    });
    it('distinguishes plugin request-budget exhaustion from source rate limits', async () => {
        const h = harness();
        const selector = createChineseSelector(h.api, () => h.settings.get(), vi.fn(), canonicalize, { requestsPerMinute: 1 });
        stops.push(() => selector.dispose()); selector.start(); await flush();
        expect(selector.getReport().events).toContainEqual(expect.objectContaining({ stage: 'lyrics', status: 'blocked',
            error: expect.objectContaining({ code: 'rate-limited', origin: 'plugin-budget', retryAfterMs: expect.any(Number) }) }));
        expect(h.api.omni.getLyrics).not.toHaveBeenCalled();
        const other = harness({ omni: { searchSongs: vi.fn(async () => { throw Object.assign(new Error('rate-limited'), { code: 'rate-limited' }); }) } });
        other.start(); await flush();
        expect(reportFrom(other).events).toContainEqual(expect.objectContaining({ stage: 'search', status: 'failed', error: expect.objectContaining({ origin: 'folia-source' }) }));
        expect(reportFrom(other).events[0].error.detail).toContain('可能是 Folia 宿主配額或平台限流');
    });
    it('finishes per-request timeouts and labels an in-progress report truthfully', async () => {
        vi.useFakeTimers();
        const h = harness({ omni: { searchSongs: vi.fn(() => new Promise(() => {})) } });
        const selector = createChineseSelector(h.api, () => h.settings.get(), vi.fn(), canonicalize, { requestMs: 10, runMs: 100 });
        stops.push(() => selector.dispose()); selector.start(); await flush();
        expect(selector.getReport()).toMatchObject({ status: 'searching', finishedAt: null });
        await vi.advanceTimersByTimeAsync(80);
        const r = selector.getReport();
        expect(r.status).toBe('kept-original'); expect(r.finishedAt).toBeTruthy();
        expect(r.events[0]).toMatchObject({ status: 'failed', error: { reason: 'timeout', origin: 'plugin-timeout' } });
    });
    it('records an overall deadline and cancels a provider that ignores AbortSignal', async () => {
        vi.useFakeTimers();
        const h = harness({ omni: { searchSongs: vi.fn(() => new Promise(() => {})) } });
        const selector = createChineseSelector(h.api, () => h.settings.get(), vi.fn(), canonicalize, { requestMs: 100, runMs: 10 });
        stops.push(() => selector.dispose()); selector.start(); await flush();
        await vi.advanceTimersByTimeAsync(11);
        const r = selector.getReport();
        expect(r).toMatchObject({ status: 'kept-original', stopReason: 'deadline', finishedAt: expect.any(String) });
        expect(r.events).toContainEqual(expect.objectContaining({ stage: 'search', status: 'cancelled' }));
    });
    it('opening or repeatedly exporting a report issues no requests and returns detached snapshots', async () => {
        const h = harness(); h.start(); await flush();
        const requests = h.api.omni.searchSongs.mock.calls.length + h.api.omni.getLyrics.mock.calls.length;
        const first = reportFrom(h); first.events.length = 0; first.selection.metrics.coverage = -1;
        const second = reportFrom(h);
        expect(second.events.length).toBeGreaterThan(0); expect(second.selection.metrics.coverage).toBe(1);
        expect(h.api.omni.searchSongs.mock.calls.length + h.api.omni.getLyrics.mock.calls.length).toBe(requests);
    });
    it('manual retry creates a new report instead of combining failure counters from past runs', async () => {
        const h = harness({ omni: { searchSongs: vi.fn(async () => { throw Object.assign(new Error('network'), { code: 'network' }); }) } });
        h.start(); await flush(); const previous = reportFrom(h);
        h.commands.get('retry-chinese').run(); await flush(); const current = reportFrom(h);
        expect(current.trigger).toBe('manual-retry'); expect(current.events.length).toBe(previous.events.length);
        expect(current.failedResults).toBe(previous.failedResults);
        expect(current.events[0].sequence).toBe(1);
    });
    it('does not report a lower-quality retry as applied when a better cached translation was retained', async () => {
        const h = harness(); h.start(); await flush();
        h.api.omni.getLyrics.mockResolvedValue({ lines: toFoliumLines(lyrics(2)), isPureMusic: false });
        h.commands.get('retry-chinese').run(); await flush();
        const r = reportFrom(h);
        expect(r.selection.metrics.coverage).toBe(1);
        expect(r.decisions[0]).toMatchObject({ outcome: 'not-applied', reason: 'cached-choice-retained' });
        expect(r.events).toContainEqual(expect.objectContaining({ stage: 'selection-retained' }));
        expect(h.shown().lines.every((item: any) => item.translation)).toBe(true);
    });
    it('track switches cannot put an old response in the new song report; account changes clear cached reports', async () => {
        const pending = deferred();
        const h = harness({ omni: { getLyrics: vi.fn(() => pending.promise) } }); h.start(); await flush();
        h.api.omni.searchSongs.mockResolvedValue({ items: [] });
        h.change(target({ id: 'next', title: '次の作品' })); await flush();
        pending.resolve({ lines: toFoliumLines(lyrics(4)) }); await flush();
        expect(reportFrom(h).song.title).toBe('次の作品');
        expect(reportFrom(h).selection.metrics.coverage).toBe(0);
        h.change(null, null); h.emit('account.changed', {}); await flush();
        expect(reportFrom(h)).toMatchObject({ currentState: 'no-song', events: [] });
    });
    it('bounds long traces explicitly and records truncation rather than claiming missing events exist', () => {
        const report = beginReport(target(), 200, {}, {}, null, {}, 'test');
        for (let i = 0; i < 650; i++) record(report, 'search');
        finishReport(report, 'kept-original');
        expect(report.events.length).toBe(600); expect(report.droppedEvents).toBe(51);
        expect(report.finishedAt).toBeTruthy();
    });
    it('removes URLs, credential assignments, control characters and local file paths from public metadata', () => {
        const cleaned = safeText('Song\ntoken=SECRET https://x.example/?q=SECRET C:\\Users\\SECRET\\file /home/SECRET/file');
        expect(cleaned).not.toContain('SECRET'); expect(cleaned).not.toContain('\n');
        expect(safeError({ code: 'not-signed-in', message: 'SECRET' })).toMatchObject({ reason: 'auth', origin: 'folia-source' });
    });
});

describe('Folia 0.7.25 actual double-qualified bilingual title', () => {
    const reportedSong = () => target({ ...acousticReport.song, id: 'reported', ref: 'reported-track' });
    const reportedCandidate = (index = 0) => candidate({ ...acousticReport.candidates[index], ref: 'reported-candidate' });
    it('searches each recording qualifier once when both aliases carry it', () => {
        expect(searchQueries(reportedSong(), canonicalize)[0]).toBe('青のすみか (acoustic) Tatsuya Kitani');
    });
    it('retains the exact native title form and the Acoustic recording constraint', () => {
        expect(titleForms(reportedSong().title, canonicalize)).toContain('青のすみか (acoustic)');
        expect(matchSong(reportedSong(), candidate({ title: '青のすみか', artist: 'Tatsuya Kitani' }), 204, 204, canonicalize)).toBe(0);
    });
    it.each(acousticReport.candidates)('recognizes the reported same-recording metadata from $source', (metadata) => {
        expect(matchSong(reportedSong(), candidate({ ...metadata, ref: 'candidate' }), 204, metadata.durationSeconds, canonicalize)).toBe(1);
    });
    it('compares exact kana pronunciation with the two Latin name tokens in Japanese order', () => {
        const song = target({ title: '同じ曲', artist: 'Tatsuya Kitani' });
        expect(matchSong(song, candidate({ title: '同じ曲', artist: 'キタニタツヤ' }), 200, 200, canonicalize)).toBe(1);
        expect(matchSong(song, candidate({ title: '同じ曲', artist: 'タツヤキタニ' }), 200, 200, canonicalize)).toBe(1);
        expect(matchSong(song, candidate({ title: '同じ曲', artist: 'キタニタツオ' }), 200, 200, canonicalize)).toBe(0);
    });
    it('does not treat arbitrary Latin token reorderings or kana anagrams as artist aliases', () => {
        expect(matchSong(target({ artist: 'George Michael' }), candidate({ artist: 'Michael George' }), 200, 200, canonicalize)).toBe(0);
        expect(matchSong(target({ artist: 'Tatsuya Kitani' }), candidate({ artist: 'ニタキタツヤ' }), 200, 200, canonicalize)).toBe(0);
    });
    it('still probes an unknown artist spelling only for verification against existing lyrics', () => {
        const unknown = reportedCandidate(); unknown.artist = '未確認の別名';
        expect(probeSong(reportedSong(), unknown, 204, 203.592, canonicalize, true)).toMatchObject({ translationOnly: true });
        expect(probeSong(reportedSong(), unknown, 204, 203.592, canonicalize, false)).toBeNull();
    });
    it('reads the formerly rejected NetEase candidate and preserves every original animation word', async () => {
        const original = lyrics();
        const h = harness({ song: reportedSong(), lines: original, duration: 204, omni: {
            describeSong: (song: any) => ({ durationMs: song.durationSeconds * 1000 }),
            searchSongs: vi.fn(async () => ({ items: [reportedCandidate()] })),
        } });
        h.start(); await flush();
        expect(h.api.omni.getLyrics).toHaveBeenCalledTimes(1);
        expect(h.shown().lines.every((item: any, i: number) => item.translation === translations[i])).toBe(true);
        h.shown().lines.forEach((item: any, i: number) => {
            expect(item.words).toEqual(original[i].words); expect(item.startTime).toBe(original[i].startTime);
        });
        const report = reportFrom(h);
        expect(report.events.find((event: any) => event.stage === 'candidate-match')).toMatchObject({
            outcome: 'lyrics-requested', comparison: { exactTitle: true, artistAgreement: 1 } });
        expect(report.selection.metrics.coverage).toBe(1);
    });
    it('can recover an empty original only after the exact reported title and phonetic artist agree', async () => {
        const h = harness({ song: reportedSong(), empty: true, duration: 204, omni: {
            describeSong: (song: any) => ({ durationMs: song.durationSeconds * 1000 }),
            searchSongs: vi.fn(async () => ({ items: [reportedCandidate()] })),
        } });
        h.start(); await flush();
        expect(h.shown()?.lines).toHaveLength(4);
        expect(reportFrom(h).selection.strategy).toBe('replaced');
    });
    it('does not transfer a different recording when the complete original sequence differs', () => {
        const evidence = probeSong(reportedSong(), candidate({ title: '青のすみか', artist: 'キタニタツヤ' }), 204, 196, canonicalize, true);
        expect(evidence).toMatchObject({ translationOnly: true, originalTextOnly: true });
        const unrelated = lyrics(4); unrelated[2] = line('ほかの録音だけにある言葉', 2, translations[2]);
        const answer = chooseLyrics(toFoliumLines(lyrics()), [{ ...donor(unrelated), ...evidence }], 204, canonicalize);
        expect(answer.changed).toBe(false);
        expect(answer.decisions[0].reason).toBe('original-sequence-mismatch');
    });
    it('preserves differing part numbers on double-qualified aliases', () => {
        const song = target({ title: 'あぶく (Part 1) (Acoustic) - Bubble (Part 1) (Acoustic)' });
        expect(probeSong(song, candidate({ title: 'あぶく (Part 2) (Acoustic)' }), 200, 200, canonicalize, true)).toBeNull();
    });
});

describe('reported acoustic titles and blank animation regressions', () => {
    const acoustic = () => target({ source: 'ytm', title: '青のすみか (Acoustic ver.) - Where Our Blue Is', artist: 'Tatsuya Kitani' });
    it('searches the native acoustic title before the full bilingual video title', () => {
        expect(searchQueries(acoustic())[0]).toBe('青のすみか (acoustic) Tatsuya Kitani');
    });
    it('matches equivalent acoustic labels while preserving that version on every title alias', () => {
        expect(matchSong(acoustic(), candidate({ title: '青のすみか (Acoustic Version)', artist: 'Tatsuya Kitani' }), 203, 203)).toBe(1);
        expect(matchSong(acoustic(), candidate({ title: '青のすみか', artist: 'Tatsuya Kitani' }), 203, 203)).toBe(0);
    });
    it('recognizes exact kana readings with the two Latin name tokens reversed', () => {
        expect(probeSong(acoustic(), candidate({ title: '青のすみか (Acoustic Version)', artist: 'キタニタツヤ' }), 203, 203, canonicalize, true))
            .toMatchObject({ match: 1, translationOnly: false });
    });
    it('allows reading another recording only for complete original-text translation proof', () => {
        expect(probeSong(acoustic(), candidate({ title: '青のすみか', artist: 'キタニタツヤ' }), 203, 195, canonicalize, true))
            .toMatchObject({ translationOnly: true, originalTextOnly: true });
        expect(probeSong(acoustic(), candidate({ title: '青のすみか', artist: 'キタニタツヤ' }), 203, 195, canonicalize, false)).toBeNull();
    });
    it('never strips part numbers while considering a recording variant for translation', () => {
        expect(probeSong(target({ title: 'あぶく (Part 1) (Acoustic)' }), candidate({ title: 'あぶく (Part 2)' }), 200, 200, canonicalize, true)).toBeNull();
    });
    it('merges a proven full original sequence despite different recording timing, without changing animation', () => {
        const base = toFoliumLines(lyrics());
        const alternate = lyrics(4).map((item, i) => ({ ...item, startTime: 15 + i * 9, endTime: 19 + i * 9 }));
        const answer = chooseLyrics(base, [{ ...donor(alternate), translationOnly: true, originalTextOnly: true }], 200, canonicalize);
        expect(answer.metrics.coverage).toBe(1);
        expect(answer.strategy).toBe('merged');
        answer.lines.forEach((item: any, i: number) => { expect(item.words).toBe(base[i].words); expect(item.startTime).toBe(base[i].startTime); });
    });
    it('does not borrow a recording translation when one original phrase differs', () => {
        const alternate = lyrics(4).map((item, i) => i === 3 ? { ...item, fullText: '違う物語がここから始まる' } : item);
        const base = toFoliumLines(lyrics());
        expect(chooseLyrics(base, [{ ...donor(alternate), translationOnly: true, originalTextOnly: true }], 200, canonicalize).lines).toBe(base);
    });
    it('never uses a translation-only recording to replace an empty source', () => {
        expect(chooseLyrics([], [{ ...donor(lyrics(4)), translationOnly: true, originalTextOnly: true }], 200, canonicalize).changed).toBe(false);
    });
    it.each([0, 10])('repairs all-zero-duration words inside a valid line starting at %s', start => {
        const source = [{ fullText: originals[0], startTime: start, endTime: start + 4,
            words: [{ text: originals[0], startTime: start, endTime: start }] }];
        expect(repairWordTimings(source)[0].words).toEqual([{ text: originals[0], startTime: start, endTime: start + 4 }]);
    });
    it('repairs zero-duration syllables that otherwise hide a valid whole word', () => {
        const source = [{ ...line(originals[0]), words: [{ text: originals[0], startTime: 10, endTime: 14,
            syllables: [{ text: originals[0], startTime: 10, endTime: 10 }] }] }];
        expect(repairWordTimings(source)[0].words).toEqual([{ text: originals[0], startTime: 10, endTime: 14 }]);
    });
    it('recovers a missing line end from the next known cue and final track duration', () => {
        const source = [{ ...line(originals[0]), endTime: 10, words: [] }, { ...line(originals[1], 1), endTime: NaN, words: [] }];
        const next = repairWordTimings(source, 20);
        expect(next.map((item: any) => item.endTime)).toEqual([15, 20]);
        expect(next[0].words[0]).toEqual({ text: originals[0], startTime: 10, endTime: 15 });
    });
    it('does not invent an end for simultaneous untimed lines', () => {
        const source = [line(originals[0]), line(originals[1])].map(item => ({ ...item, startTime: 0, endTime: 0, words: [] }));
        expect(repairWordTimings(source, 200)).toBe(source);
    });
    it('uses current song metadata instead of a previous audio duration during a track switch', async () => {
        const h = harness({ duration: 8, song: target({ source: 'ytm', title: '燈 - Akari', artist: 'Soushi Sakiyama' }), omni: {
            describeSong: () => ({ durationMs: 200000 }),
            searchSongs: vi.fn(async () => ({ items: [candidate({ title: '燈', artist: '崎山蒼志' })] })),
        } });
        h.start(); await flush();
        expect(analyzeLyrics(h.shown().lines).coverage).toBe(1);
    });
});

describe('same song and version matching', () => {
    it('uses portable source/id keys and separates equal ids on different sources', () => {
        expect(songKey(target())).not.toBe(songKey(target({ source: 'qq' })));
        expect(songKey(target())).toBe(songKey(target({ ref: 'song-new' })));
        expect(songKey(target({ id: null, title: 'a' }))).not.toBe(songKey(target({ id: null, title: 'b' })));
        expect(songKey(null)).toBeNull();
    });
    it('accepts same title/artist with punctuation or Simplified/Traditional differences', () => {
        expect(matchSong(target({ title: '头发，发现', artist: '周杰伦' }), candidate({ title: '頭髮發現', artist: '周杰倫' }), 200, 201, canonicalize)).toBe(1);
    });
    it.each([' (Live)', ' (Remix)', ' (Acoustic)', ' (Instrumental)', ' (Cover)', ' (Sped Up)', ' (Slowed)', ' (TV Size)'])('rejects another version %s', (version) => {
        expect(matchSong(target(), candidate({ title: target().title + version }), 200, 200, canonicalize)).toBe(0);
    });
    it('rejects the same title by a different artist and a duration mismatch', () => {
        expect(matchSong(target(), candidate({ artist: 'Other' }), 200, 200)).toBe(0);
        expect(matchSong(target(), candidate(), 200, 225)).toBe(0);
        expect(matchSong(target(), candidate({ ref: null }), 200, 200)).toBe(0);
    });
    it('accepts a collaboration only with an exact shared artist token', () => {
        expect(matchSong(target(), candidate({ artist: 'YOASOBI / Other' }), 200, 200)).toBeGreaterThan(0.9);
        expect(matchSong(target(), candidate({ artist: 'YOASOBI tribute band' }), 200, 200)).toBe(0);
    });
    it('needs independent duration confirmation when the target has no artist', () => {
        expect(matchSong(target({ artist: '' }), candidate(), 200, 201)).toBe(0.9);
        expect(matchSong(target({ artist: '' }), candidate(), 0, 0)).toBe(0);
    });
    it('keeps meaningful bracketed part numbers in the title', () => {
        expect(matchSong(target({ title: 'Song (Part 1)' }), candidate({ title: 'Song (Part 2)' }), 200, 200)).toBe(0);
    });
    it('ignores presentation labels without deleting version information', () => {
        expect(matchSong(target({ title: 'Song' }), candidate({ title: 'Song (Official Audio)' }), 200, 200)).toBe(1);
        expect(matchSong(target({ title: 'Song (2024 Remaster)' }), candidate({ title: 'Song (2025 Remaster)' }), 200, 200)).toBeLessThan(0.98);
    });
    it.each(['ライブ', 'リミックス', 'アコースティック', 'カラオケ'])('rejects another version labelled in Japanese: %s', (version) => {
        expect(matchSong(target(), candidate({ title: target().title + ' (' + version + ')' }), 200, 200)).toBe(0);
    });
    it('never lets a fuzzy long title qualify as an exact whole-document replacement', () => {
        const prefix = 'A very long name that shares almost every word with a different song version '.repeat(4);
        const score = matchSong(target({ title: prefix + '(Part 1)' }), candidate({ title: prefix + '(Part 2)' }), 200, 200);
        expect(score).toBeGreaterThanOrEqual(0.9);
        expect(score).toBeLessThan(0.98);
        expect(chooseLyrics([], [{ ...donor(lyrics(4)), match: score }], 200).changed).toBe(false);
    });
});

describe('missing animation data', () => {
    it.each([
        [],
        [{ text: originals[0], startTime: NaN, endTime: 14 }],
        [{ text: originals[0], startTime: 14, endTime: 10 }],
        [{ text: originals[0], startTime: 0, endTime: 0 }],
        [{ text: '', startTime: 10, endTime: 14 }],
    ])('recovers malformed words with proven whole-line timing: %j', (words) => {
        const source = Object.freeze([{ ...line(originals[0]), words: Object.freeze(words) }]);
        const result = repairWordTimings(source);
        expect(result).not.toBe(source);
        expect(result[0].words).toEqual([{ text: originals[0], startTime: 10, endTime: 14 }]);
        expect(result[0].fullText).toBe(source[0].fullText);
        expect(source[0].words).toBe(words);
    });
    it('preserves usable timing including valid sustained words beyond the line end', () => {
        const source = [{ ...line(originals[0]), words: [{ text: originals[0], startTime: 12, endTime: 30 }] }];
        expect(repairWordTimings(source)).toBe(source);
        expect(repairWordTimings(lyrics())).toEqual(lyrics());
    });
    it('does not invent missing line start/end times', () => {
        const source = [{ ...line(originals[0]), startTime: NaN, words: [] }];
        expect(repairWordTimings(source)).toBe(source);
    });
    it('restores line animation with empty word data even when no provider responds', async () => {
        const h = harness({ lines: lyrics().map(item => ({ ...item, words: [] })), omni: { searchSongs: vi.fn(async () => ({ items: [] })) } });
        h.start(); await flush();
        expect(h.shown().lines).toHaveLength(4);
        h.shown().lines.forEach((item: any, i: number) => {
            expect(item.words).toEqual([{ text: originals[i], startTime: 10 + i * 5, endTime: 14 + i * 5 }]);
        });
        expect(h.raw().lines[0].words).toEqual([]);
    });
});

describe('reported YouTube Music / NetEase mismatch', () => {
    it.each([
        ['怪獸 - Kaiju', 'sakanaction', '怪獣', 'サカナクション'],
        ['燈 - Akari', 'Soushi Sakiyama', '燈', '崎山蒼志'],
        ['睨めっ娘 (友成空) / ダズビー COVER', 'DAZBEE', '睨めっ娘 (cover)', 'DAZBEE'],
    ])('reads and verifies screenshot candidate %s instead of discarding its artist alias', async (title, artist, nativeTitle, nativeArtist) => {
        const h = harness({ song: target({ source: 'ytm', title, artist }),
            omni: { searchSongs: vi.fn(async () => ({ items: [candidate({ title: nativeTitle, artist: nativeArtist })] })) } });
        h.start(); await flush();
        expect(h.api.omni.getLyrics).toHaveBeenCalled();
        expect(analyzeLyrics(toFoliumLines(h.shown().lines)).coverage).toBe(1);
        h.shown().lines.forEach((item: any, i: number) => expect(item.words).toEqual(h.raw().lines[i].words));
    });
    it('recovers empty cover lyrics using performer and structured cover title', async () => {
        const title = '睨めっ娘 (友成空) / ダズビー COVER';
        expect(searchQueries(target({ title, artist: 'DAZBEE' }))[0]).toBe('睨めっ娘 DAZBEE');
        const h = harness({ empty: true, song: target({ source: 'ytm', title, artist: 'DAZBEE' }),
            omni: { searchSongs: vi.fn(async () => ({ items: [candidate({ title: '睨めっ娘 (cover)', artist: 'DAZBEE' })] })) } });
        h.start(); await flush();
        expect(h.shown()?.lines.length).toBe(4);
        expect(analyzeLyrics(h.shown().lines).coverage).toBe(1);
        expect(h.shown().lines.every((item: any) => item.words.length > 0)).toBe(true);
    });
    it('searches Japanese shinjitai without rewriting display lyrics', () => {
        expect(searchQueries(target({ title: '怪獸 - Kaiju', artist: 'sakanaction' }), canonicalize)).toContain('怪獣');
        expect(matchSong(target({ title: '怪獸', artist: 'same' }), candidate({ title: '怪獣', artist: 'same' }), 200, 200, canonicalize)).toBe(1);
    });
    it('never guesses a kanji alias when an empty source cannot provide original lyric proof', async () => {
        const song = target({ title: '燈 - Akari', artist: 'Soushi Sakiyama', source: 'ytm' });
        const other = candidate({ title: '燈', artist: '崎山蒼志' });
        expect(probeSong(song, other, 200, 200, canonicalize, false)).toBeNull();
        const h = harness({ empty: true, song, omni: { searchSongs: vi.fn(async () => ({ items: [other] })) } });
        h.start(); await flush();
        expect(h.api.omni.getLyrics).not.toHaveBeenCalled(); expect(h.shown()).toBeNull();
    });
    it('rejects same-name candidates with unrelated original lyrics before borrowing translations', async () => {
        const h = harness({ song: target({ title: '燈 - Akari', artist: 'Soushi Sakiyama', source: 'ytm' }), omni: {
            searchSongs: vi.fn(async () => ({ items: [candidate({ title: '燈', artist: '崎山蒼志' })] })),
            getLyrics: vi.fn(async () => ({ lines: toFoliumLines(lyrics(4).map((item, i) => ({ ...item, fullText: '別の歌詞がここにあります' + i }))) })),
        } });
        h.start(); await flush(); expect(h.api.omni.getLyrics).toHaveBeenCalled();
        expect(analyzeLyrics(h.shown().lines).coverage).toBe(0);
        expect(h.shown().lines.map((item: any) => item.fullText)).toEqual(originals);
    });
    it('keeps part/year/remix distinctions when simplifying cover presentation', () => {
        for (const detail of ['Part 2', '2025 Remaster', 'Remix']) {
            expect(matchSong(target({ title: `睨めっ娘 (${detail}) / ダズビー COVER`, artist: 'DAZBEE' }),
                candidate({ title: '睨めっ娘 (cover)', artist: 'DAZBEE' }), 200, 200, canonicalize)).toBeLessThan(0.98);
        }
    });
    it('does not use candidate timing outside the playing song just because its own duration is valid', () => {
        const long = lyrics(4).map((item, i) => ({ ...item, startTime: 220 + i * 5, endTime: 224 + i * 5 }));
        expect(chooseLyrics([], [{ ...donor(long), duration: 250 }], 200).changed).toBe(false);
    });
    // Titles/artists come from the user's screenshots. Lyric documents below are synthetic fixtures,
    // not captured platform responses: these tests do not claim live platform or full-song verification.
    it.each([
        ['シャケナベイベー - Shake Na Baby', 'AKASAKI', 'シャケナベイベー', 'AKASAKI'],
        ['あぶく - Bubble', 'Yorushika', 'あぶく', 'ヨルシカ'],
        ['あぶく (Bubble)', 'Yorushika - Topic', 'あぶく', 'ヨルシカ'],
    ])('matches cross-provider metadata: %s', (title, artist, otherTitle, otherArtist) => {
        expect(matchSong(target({ source: 'ytm', title, artist }), candidate({ title: otherTitle, artist: otherArtist }), 234, 234, canonicalize)).toBe(1);
    });
    it('recognizes kana/Hepburn names without a hard-coded artist alias list', () => {
        expect(artistKey('ヨルシカ')).toBe('yorushika');
        expect(artistKey('よるしか')).toBe('yorushika');
        expect(artistKey('ヨアソビ')).toBe('yoasobi');
        expect(artistKey('ミッチ')).toBe('mitchi');
        expect(artistKey('キョウ')).toBe('kyou');
    });
    it('does not infer a Japanese artist alias for an unrelated artist', () => {
        expect(matchSong(target({ title: 'あぶく - Bubble', artist: 'Yorushika' }), candidate({ title: 'あぶく', artist: 'Other' }), 200, 200)).toBe(0);
        expect(matchSong(target({ title: 'あぶく', artist: ' ' }), candidate({ title: 'あぶく', artist: ' ' }), 200, 200)).toBe(0);
    });
    it.each(['Part 1', 'Part1', '2025 Remaster', 'Live', 'Cover', 'English Version'])('does not discard a version from a bilingual title: %s', (version) => {
        const title = `あぶく - Bubble (${version})`;
        expect(matchSong(target({ title, artist: 'Yorushika' }), candidate({ title: 'あぶく', artist: 'ヨルシカ' }), 200, 200)).toBeLessThan(0.98);
    });
    it('keeps meaningful single-language subtitles and generates a native-title search', () => {
        expect(titleForms('Song - Part 1')).toEqual(['Song - Part 1']);
        expect(searchQueries(target({ title: 'あぶく - Bubble', artist: 'Yorushika - Topic' }))).toEqual([
            'あぶく Yorushika', 'あぶく', 'あぶく - Bubble Yorushika',
        ]);
        expect(searchQueries(target({ title: 'あぶく (Bubble)', artist: 'Yorushika' }))[0]).toBe('あぶく Yorushika');
    });
    it('does not mistake a video title artist prefix for a song-title alias', () => {
        expect(matchSong(target({ title: 'AKASAKI - シャケナベイベー', artist: 'AKASAKI' }), candidate({ title: 'AKASAKI', artist: 'AKASAKI' }), 200, 200)).toBe(0);
        expect(searchQueries(target({ title: 'ヨルシカ - Bubble', artist: 'Yorushika' }))[0]).toBe('Bubble Yorushika');
    });
    it('allows a bounded YT video intro difference only for later lyric validation', () => {
        const score = matchSong(target({ source: 'ytm' }), candidate(), 210, 200);
        expect(score).toBeGreaterThanOrEqual(0.9); expect(score).toBeLessThan(0.98);
        expect(chooseLyrics([], [{ ...donor(lyrics(4)), match: score }], 210).changed).toBe(false);
        expect(matchSong(target({ source: 'ytm' }), candidate(), 240, 200)).toBe(0);
    });
    it('infers a constant offset from several distinct original phrases and preserves all original word timings', () => {
        const base = toFoliumLines(lyrics());
        const translated = lyrics(4).map((item) => ({ ...item, startTime: item.startTime - 4, endTime: item.endTime - 4 }));
        expect(alignLyrics(base, translated, canonicalize)).toMatchObject({ safe: true, offset: 4, coverage: 1 });
        const choice = chooseLyrics(base, [donor(translated)], 200, canonicalize);
        expect(choice.metrics.coverage).toBe(1); expect(choice.strategy).toBe('merged');
        choice.lines.forEach((item: any, i: number) => { expect(item.words).toBe(base[i].words); expect(item.startTime).toBe(base[i].startTime); });
    });
    it('does not infer an offset from a single shared line or from divergent timing', () => {
        expect(alignLyrics(lyrics(), [line(originals[0], 0, translations[0])]).safe).toBe(false);
        const wrong = lyrics(4).map((item, i) => ({ ...item, startTime: item.startTime + i * 5, endTime: item.endTime + i * 5 }));
        expect(alignLyrics(lyrics(), wrong).safe).toBe(false);
    });
    it('does not treat identical text as proof of matching timing in later repeated sections', () => {
        const base = [...lyrics().slice(0, 3), ...Array.from({ length: 10 }, (_, i) => line('同じ言葉が繰り返している', i + 3))];
        const donorLines = base.map((item, i) => ({ ...item, translation: '測試用中文譯文' + i,
            startTime: item.startTime + (i >= 6 ? 3 : 0), endTime: item.endTime + (i >= 6 ? 3 : 0) }));
        expect(alignLyrics(base, donorLines).safe).toBe(false);
        expect(chooseLyrics(base, [donor(donorLines)], 200).strategy).not.toBe('replaced');
    });
    it('can join adjacent donor lines to fill one original line without splitting word timings', () => {
        const base = [line('青い紙飛行機を折る机の上で地図を広げる', 0)];
        const translated = [line('青い紙飛行機を折る', 0, translations[0]), { ...line('机の上で地図を広げる', 1, translations[1]), startTime: 12, endTime: 14 }];
        const result = chooseLyrics(base, [donor(translated)], 200, canonicalize);
        expect(result.lines[0].translation).toBe(translations[0] + ' ' + translations[1]);
        expect(result.lines[0].words).toBe(base[0].words);
    });
    it('keeps animated source lines when a translated sentence spans several source lines', () => {
        const source = [
            ...lyrics(),
            line('新しい物語が続いていく', 4), line('遠い空の向こうに見える', 5),
        ];
        const base = toFoliumLines(source);
        const translated = [
            ...source.slice(0, 3).map((item, i) => ({ ...item, translation: translations[i],
                startTime: item.startTime - 4, endTime: item.endTime - 4,
                words: [{ text: item.fullText, startTime: item.startTime - 4, endTime: item.endTime - 4 }] })),
            { ...line(source[3].fullText + source[4].fullText, 3, '把接下來的故事一起說完'), startTime: 21, endTime: 30,
                words: [{ text: source[3].fullText + source[4].fullText, startTime: 21, endTime: 30,
                    syllables: [{ text: source[3].fullText, startTime: 21, endTime: 25, ruby: [{ text: 'annotation', startTime: 21, endTime: 25 }] },
                        { text: source[4].fullText, startTime: 26, endTime: 30 }] }],
                backgroundVocals: [{ text: 'harmony', startTime: 22, endTime: 24, words: [{ text: 'harmony', startTime: 22, endTime: 24 }] }] },
            { ...source[5], startTime: 31, endTime: 35, words: [{ text: source[5].fullText, startTime: 31, endTime: 35 }], translation: '遠方天空的彼端' },
        ];
        const choice = chooseLyrics(base, [donor(translated)], 200, canonicalize);
        expect(choice.strategy).toBe('merged'); expect(choice.metrics.coverage).toBe(1); expect(choice.lines).toHaveLength(6);
        const rebuilt = fromFoliumLines(source as any, base, choice.lines);
        expect(rebuilt[3].translation).toBe('把接下來的故事一起說完');
        expect(rebuilt[4].translation).toBe('把接下來的故事一起說完');
        choice.lines.forEach((item: any, i: number) => {
            expect(item.words).toBe(base[i].words);
            expect([item.startTime, item.endTime, item.fullText]).toEqual([base[i].startTime, base[i].endTime, base[i].fullText]);
        });
        expect(rebuilt[3].backgroundVocals).toBeUndefined();
        expect(rebuilt[3].words[0].syllables).toBeUndefined();
        expect(choice.offset).toBe(4);
        expect(translated[3].startTime).toBe(21);
    });
    it('never replaces an existing usable track based on metadata alone', () => {
        const other = lyrics(4).map((item, i) => ({ ...item, fullText: '別の曲にある言葉です' + i }));
        expect(chooseLyrics(lyrics(), [donor(other)], 200, canonicalize).changed).toBe(false);
    });
    it('works with the real host LRC parser and cross-source line breaks', () => {
        const source = parseLRC('[00:10.00]青い紙飛行機を折る机の上で地図を広げる\n[00:20.00]窓際の小さな鉢に水を注ぐ\n[00:30.00]新しい駅の名前を覚える');
        const translated = parseLRC('[00:10.00]青い紙飛行機を折る\n[00:12.00]机の上で地図を広げる\n[00:20.00]窓際の小さな鉢に水を注ぐ\n[00:30.00]新しい駅の名前を覚える',
            '[00:10.00]摺一架藍色紙飛機\n[00:12.00]在桌面上攤開地圖\n[00:20.00]替窗邊的小盆栽澆水\n[00:30.00]記住新車站的名字');
        const choice = chooseLyrics(toFoliumLines(source.lines), [donor(translated.lines)], 200, canonicalize);
        expect(choice.metrics.coverage).toBe(1);
        expect(choice.lines.find((item: any) => item.fullText === '青い紙飛行機を折る机の上で地図を広げる')?.translation).toContain('在桌面上攤開地圖');
    });
    it('automatically adds NetEase Chinese lyrics to the bilingual AKASAKI song while audio stays on YT Music', async () => {
        const song = target({ source: 'ytm', title: 'シャケナベイベー - Shake Na Baby', artist: 'AKASAKI' });
        const searchSongs = vi.fn(async () => ({ items: [candidate({ title: 'シャケナベイベー', artist: 'AKASAKI' })] }));
        const h = harness({ song, omni: { searchSongs } }); h.start(); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        expect(h.api.playback.getState().song.source).toBe('ytm');
        expect(searchSongs.mock.calls[0][0]).toBe('シャケナベイベー AKASAKI');
    });
    it('retries a title-only search when the romanized artist query finds no result', async () => {
        const song = target({ source: 'ytm', title: 'あぶく - Bubble', artist: 'Yorushika' });
        const searchSongs = vi.fn(async (query: string) => ({ items: query === 'あぶく' ? [candidate({ title: 'あぶく', artist: 'ヨルシカ' })] : [] }));
        const h = harness({ song, omni: { searchSongs } }); h.start(); await flush();
        expect(searchSongs).toHaveBeenCalledTimes(2);
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        h.commands.get('subtitle-status').run(); expect(h.api.ui.toast.mock.calls.at(-1)[0]).toContain('網易雲');
    });
});

describe('Chinese coverage and subtitle quality', () => {
    it('counts translated lines rather than rewarding long text', () => {
        expect(analyzeLyrics(lyrics(1), 200).coverage).toBe(0.25);
        expect(analyzeLyrics(lyrics(4), 200).coverage).toBe(1);
        const verbose = lyrics(1); verbose[0].translation = '非常長的中文'.repeat(80);
        expect(analyzeLyrics(verbose, 200).coverage).toBe(0);
    });
    it('recognizes a Chinese original without requiring a redundant translation', () => {
        const lines = ['我在這裡等你', '你的聲音很清晰', '我們走過那條街'].map((text, i) => line(text, i));
        expect(analyzeLyrics(lines, 200)).toMatchObject({ nativeChinese: true, coverage: 1 });
    });
    it('does not count kana, Hangul, romanization or explicitly non-Chinese alternates', () => {
        expect(isChineseText('爱してる')).toBe(false);
        expect(isChineseText('사랑漢字')).toBe(false);
        expect(isChineseText('wo ai ni', 'zh-Latn')).toBe(false);
        const item = line('hello');
        expect(chineseTranslation({ ...item, alternateTexts: [{ role: 'translation', language: 'ja', text: '世界' }] }).quality).toBe(0);
        expect(chineseTranslation({ ...item, translation: '世界', alternateTexts: [{ role: 'translation', language: 'ja', text: '世界' }] }).quality).toBe(0);
    });
    it('reads explicitly labelled Chinese alternates', () => {
        expect(chineseTranslation({ ...line('hello'), alternateTexts: [{ role: 'translation', language: 'zh-TW', text: '你好' }] }).text).toBe('你好');
    });
    it.each(['暫無翻譯', '翻译加载失败', '錯誤�字幕', '翻譯：https://example.com', '哈哈哈哈哈哈哈哈', '翻譯：作者'])('rejects broken/placeholder/credit translation %s', (text) => {
        expect(translationQuality(text, 'hello')).toBe(0);
    });
    it('does not count an unchanged original as a translation', () => {
        expect(translationQuality('头发', '頭髮', undefined, canonicalize)).toBe(0);
    });
    it('excludes credits from the coverage denominator', () => {
        expect(analyzeLyrics([...lyrics(4), line('作詞：作者', 5)], 200).coverage).toBe(1);
    });
    it('penalizes one repeated Chinese sentence over many different original lines', () => {
        const bad = Array.from({ length: 10 }, (_, i) => line('foreign original ' + i, i, '完全相同的文字'));
        expect(analyzeLyrics(bad, 200).quality).toBeLessThan(0.6);
    });
    it.each([
        [], [line('hello', 0), { ...line('world', 1), startTime: -1 }],
        [line('hello', 0), { ...line('world', 1), endTime: Infinity }],
        [line('hello', 1), line('world', 0)],
        [line('hello', 0), { ...line('world', 1), startTime: 300, endTime: 305 }],
        [line('hello', 0), { ...line('world', 1), endTime: 400 }],
    ])('rejects empty or invalid time axes %#', (lines) => {
        expect(analyzeLyrics(lines, 200).usable).toBe(false);
    });
    it('rejects untimed multi-line documents and oversized answers', () => {
        expect(analyzeLyrics([line('one'), line('two'), line('three')], 200).usable).toBe(false);
        expect(analyzeLyrics(Array.from({ length: 2501 }, (_, i) => line('hello', i)), 0).usable).toBe(false);
    });
    it('ignores word-segmentation rebuilds but detects changed translations in a cache key', () => {
        const base = lyrics();
        expect(lyricsKey(base)).toBe(lyricsKey(base.map((item) => ({ ...item, wordSegments: ['changed'] }))));
        expect(lyricsKey(base)).not.toBe(lyricsKey(lyrics(1)));
    });
});

describe('selection without breaking original timing', () => {
    it('fills matching lines from multiple sources and retains original timings and ruby', () => {
        const base = toFoliumLines(lyrics().map((item) => ({ ...item, words: item.words.map((word) => ({ ...word, syllables: [{ ...word, ruby: [{ ...word, text: 'ruby' }] }] })) })));
        const a = lyrics(2);
        const b = lyrics().map((item, i) => ({ ...item, ...(i >= 2 ? { translation: translations[i] } : {}) }));
        const answer = chooseLyrics(base, [donor(a, 'A'), donor(b, 'B')], 200, canonicalize);
        expect(answer.metrics.coverage).toBe(1);
        expect(answer.sources).toEqual(['A', 'B']);
        answer.lines.forEach((item: any, i: number) => {
            expect(item.words).toBe(base[i].words);
            expect([item.startTime, item.endTime]).toEqual([base[i].startTime, base[i].endTime]);
        });
        expect(base[0].translation).toBeUndefined();
    });
    it('uses exact original text and close timing rather than blindly zipping line numbers', () => {
        const wrong = lyrics(4).map((item) => ({ ...item, startTime: item.startTime + 20, endTime: item.endTime + 20 }));
        const base = lyrics();
        expect(mergeTranslations(base, wrong)).toBe(base);
        expect(mergeTranslations(base, [line('other song', 0, '別首歌曲')])).toBe(base);
    });
    it('matches repeat occurrences separately and never reuses one translated chorus', () => {
        const base = [line('same', 0), line('same', 4)];
        const answer = mergeTranslations(base, [line('same', 0, '第一次')]);
        expect(answer[0].translation).toBe('第一次');
        expect(answer[1].translation).toBeUndefined();
    });
    it('prefers the more complete donor and preserves a valid existing translation', () => {
        const base = lyrics(1);
        const partial = lyrics(2); partial[1].translation = '較少的版本';
        const answer = chooseLyrics(base, [donor(partial, 'partial'), donor(lyrics(4), 'complete')], 200, canonicalize);
        expect(answer.lines[0]).toBe(base[0]);
        expect(answer.lines[1].translation).toBe(translations[1]);
        expect(answer.sources).toEqual(['complete']);
    });
    it('replaces suspicious repetitive translations with a well-formed donor', () => {
        const good = Array.from({ length: 10 }, (_, i) => line('foreign ' + i, i, '這是第' + i + '行譯文'));
        const bad = good.map((item) => ({ ...item, translation: '同一行不斷重複' }));
        expect(chooseLyrics(bad, [donor(good)], 200).metrics.quality).toBe(1);
    });
    it('keeps complete Chinese originals and equally complete existing translations', () => {
        const chinese = [line('這是原詞', 0), line('另一行歌詞', 1)];
        expect(chooseLyrics(chinese, [donor(lyrics(4))], 200).changed).toBe(false);
        const base = lyrics(4);
        expect(chooseLyrics(base, [donor(lyrics(4))], 200).lines).toBe(base);
    });
    it('requires an exact match when replacing an empty document', () => {
        expect(chooseLyrics([], [{ ...donor(lyrics(4)), match: 0.9 }], 200).changed).toBe(false);
        expect(chooseLyrics([], [donor(lyrics(4))], 200).metrics.coverage).toBe(1);
    });
    it('preserves non-Chinese alternate tracks and adds a Chinese display track', () => {
        const base = [{ ...line('hello'), alternateTexts: [{ role: 'translation', language: 'ja', text: 'こんにちは' }, { role: 'romanization', text: 'hello' }] }];
        const answer = mergeTranslations(base, [line('hello', 0, '你好')]);
        expect(answer[0].alternateTexts).toHaveLength(3);
        expect(answer[0].alternateTexts[0]).toBe(base[0].alternateTexts[0]);
    });
});

describe('automatic lookup, fallback and lifecycle', () => {
    it('automatically augments and converts frozen host lyrics, and fully restores on disable', async () => {
        const h = harness(); const stop = h.start(); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        expect(h.shown().lines[0].words).toEqual(h.raw().lines[0].words);
        expect(h.commands.size).toBe(7);
        stop();
        expect(h.shown().lines[0].translation).toBeUndefined();
        expect(h.listenCount()).toBe(0); expect(h.commands.size).toBe(0);
    });
    it('recovers actual host no-lyrics output after the primary lyric load failed', async () => {
        const h = harness({ empty: true }); h.start(); await flush();
        expect(h.shown().lines).toHaveLength(4);
        expect(h.shown().lines[0].translation).toBe(translations[0]);
    });
    it('recovers null-to-null host failures even when lyrics.loaded does not fire', async () => {
        const h = harness({ settings: { autoSelectChinese: false, fallbackOnFailure: true } }); h.start(); await flush();
        expect(h.api.omni.searchSongs).not.toHaveBeenCalled();
        h.failWithoutNotification(); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
    });
    it('tries the next candidate when a lyric request rejects or returns empty lines', async () => {
        const getLyrics = vi.fn().mockRejectedValueOnce(new Error('failed')).mockResolvedValueOnce({ lines: [] })
            .mockResolvedValue({ lines: toFoliumLines(lyrics(4)) });
        const searchSongs = vi.fn(async () => ({ items: [candidate({ id: '1', ref: 'song-1' }), candidate({ id: '2', ref: 'song-2' }), candidate({ id: '3', ref: 'song-3' })] }));
        const h = harness({ empty: true, settings: { searchDepth: 'deep' }, omni: { searchSongs, getLyrics } });
        h.start(); await flush();
        expect(getLyrics).toHaveBeenCalledTimes(3); expect(h.shown().lines).toHaveLength(4);
    });
    it('tries a different source after a search failure or authentication restriction', async () => {
        const providers = ['netease', 'qq', 'kugou'].map((providerId) => ({ providerId, configured: true, supports: { search: true, lyrics: true } }));
        const searchSongs = vi.fn(async (_: any, options: any) => {
            if (options.providerId === 'netease') throw new Error('search failed');
            return { items: [candidate({ source: options.providerId, id: options.providerId, ref: 'song-' + options.providerId })] };
        });
        const getLyrics = vi.fn(async (song: any) => {
            if (song.source === 'qq') throw Object.assign(new Error('not-signed-in'), { code: 'not-signed-in' });
            return { lines: toFoliumLines(lyrics(4)) };
        });
        const h = harness({ providers, omni: { searchSongs, getLyrics } }); h.start(); await flush();
        expect(h.shown().lines[3].translation).toBe(translations[3]);
    });
    it('falls back from a provider that ignores abort and times out', async () => {
        vi.useFakeTimers(); const stuck = deferred();
        const h = harness({ omni: { searchSongs: vi.fn(async () => ({ items: [candidate({ id: '1' }), candidate({ id: '2', ref: 'song-2' })] })),
            getLyrics: vi.fn().mockImplementationOnce(() => stuck.promise).mockResolvedValue({ lines: toFoliumLines(lyrics(4)) }) } });
        h.start(); await flush(); await vi.advanceTimersByTimeAsync(7001); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        stuck.resolve({ lines: toFoliumLines([line('wrong song', 0, '錯誤內容')]) }); await flush();
        expect(h.shown().lines[0].fullText).toBe(originals[0]);
    });
    it('does not overwrite a later song with an earlier song’s late answer', async () => {
        const pending = deferred(); const getLyrics = vi.fn().mockImplementationOnce(() => pending.promise).mockResolvedValue({ lines: [] });
        const h = harness({ omni: { getLyrics } }); h.start(); await flush();
        h.change(target({ id: 'new', title: 'Other Song' }), [line('new original', 0)]); await flush();
        pending.resolve({ lines: toFoliumLines(lyrics(4)) }); await flush();
        expect(h.shown().lines[0].fullText).toBe('new original'); expect(h.shown().lines[0].translation).toBeUndefined();
    });
    it('aborts pending work on disable and ignores its later result', async () => {
        const pending = deferred(); const h = harness({ omni: { getLyrics: vi.fn(() => pending.promise) } }); const stop = h.start(); await flush();
        stop(); const count = h.api.lyrics.refresh.mock.calls.length;
        pending.resolve({ lines: toFoliumLines(lyrics(4)) }); await flush();
        expect(h.api.lyrics.refresh).toHaveBeenCalledTimes(count); expect(h.shown().lines[0].translation).toBeUndefined();
    });
    it('caches successes, avoids refresh loops, and allows explicit retry', async () => {
        const h = harness(); h.start(); await flush();
        h.emit('lyrics.loaded', { song: target(), lines: toFoliumLines(h.shown().lines) }); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1);
        h.commands.get('retry-chinese').run(); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(2);
    });
    it('keeps a successful result when an explicit retry only finds a worse partial answer', async () => {
        const getLyrics = vi.fn().mockResolvedValueOnce({ lines: toFoliumLines(lyrics(4)) })
            .mockResolvedValue({ lines: toFoliumLines(lyrics(1)) });
        const h = harness({ omni: { getLyrics } }); h.start(); await flush();
        h.commands.get('retry-chinese').run(); await flush();
        expect(h.shown().lines[3].translation).toBe(translations[3]);
    });
    it('avoids unnecessary online requests for already complete Chinese subtitles', async () => {
        const h = harness({ lines: lyrics(4) }); h.start(); await flush();
        expect(h.api.omni.searchSongs).not.toHaveBeenCalled();
        h.commands.get('retry-chinese').run(); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1);
        expect(h.shown().lines[0].translation).toBe(translations[0]);
    });
    it('does not loop after all sources fail and retries after cache expiry', async () => {
        vi.useFakeTimers(); const h = harness({ omni: { getLyrics: vi.fn().mockRejectedValue(new Error('offline')) } }); h.start(); await flush();
        h.emit('lyrics.loaded', { song: target(), lines: [] }); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(2);
        await vi.advanceTimersByTimeAsync(600001); h.emit('lyrics.loaded', { song: target(), lines: [] }); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(4);
        expect(h.api.omni.getLyrics).toHaveBeenCalledTimes(2);
    });
    it('keeps the original on restore until an explicit retry and cancels pending auto work', async () => {
        const h = harness(); h.start(); await flush(); h.commands.get('restore-lyrics').run();
        expect(h.shown().lines[0].translation).toBeUndefined();
        h.emit('lyrics.loaded', { song: target(), lines: [] }); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1);
        h.commands.get('retry-chinese').run(); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
    });
    it('respects independent auto-selection and fallback switches', async () => {
        const h = harness({ settings: { autoSelectChinese: false, fallbackOnFailure: false } }); h.start(); await flush();
        expect(h.api.omni.searchSongs).not.toHaveBeenCalled();
        h.settings.set({ fallbackOnFailure: true }); await flush();
        expect(h.api.omni.searchSongs).not.toHaveBeenCalled();
        h.change(target({ id: 'empty' }), null); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        h.settings.set({ fallbackOnFailure: false }); await flush();
        expect(h.shown()).toBeNull();
    });
    it('does not restart a search when only the OpenCC character variant changes', async () => {
        const h = harness(); h.start(); await flush(); h.settings.set({ target: 't' }); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1);
    });
    it('retains new host segmentation while keeping selected translations', async () => {
        const h = harness(); h.start(); await flush(); h.rebuild();
        expect(h.shown().lines[0].wordSegments).toEqual(Array.from(originals[0]));
        expect(h.shown().lines[0].translation).toBe(translations[0]);
    });
    it('drops stale cached lyrics on account changes and searches again', async () => {
        const h = harness(); h.start(); await flush(); h.emit('account.changed', {}); await flush();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(2);
    });
    it('bounds candidates per provider and skips unconfigured/unsupported sources', async () => {
        const h = harness({ providers: [
            { providerId: 'qq', configured: false, supports: { search: true, lyrics: true } },
            { providerId: 'other', configured: true, supports: { search: true, lyrics: false } },
            { providerId: 'netease', configured: true, supports: { search: true, lyrics: true } },
        ], omni: { searchSongs: vi.fn(async () => ({ items: Array.from({ length: 8 }, (_, i) => candidate({ id: String(i), ref: 'song-' + i })) })) } });
        h.start(); await flush(); expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1); expect(h.api.omni.getLyrics).toHaveBeenCalledTimes(2);
    });
    it('rejects wrong songs, instrumental answers, invalid timing and garbled translations', async () => {
        const h = harness({ empty: true, settings: { searchDepth: 'deep' }, omni: {
            searchSongs: vi.fn(async () => ({ items: [candidate({ artist: 'Wrong' }), ...[1, 2, 3].map((i) => candidate({ id: String(i), ref: 'song-' + i }))] })),
            getLyrics: vi.fn().mockResolvedValueOnce({ lines: toFoliumLines(lyrics(4)), isPureMusic: true })
                .mockResolvedValueOnce({ lines: [line('invalid', 99)] })
                .mockResolvedValueOnce({ lines: toFoliumLines(lyrics(4)) }),
        } }); h.start(); await flush(); expect(h.api.omni.getLyrics).toHaveBeenCalledTimes(3); expect(h.shown().lines).toHaveLength(4);
    });
    it('works on an older API without attempting any online reads', async () => {
        const h = harness(); delete h.api.omni; h.start(); await flush(); expect(h.commands.size).toBe(1);
    });
    it('can activate before host actions are ready and search after the first load', async () => {
        const h = harness();
        const readyState = h.api.playback.getState;
        h.api.playback.getState = () => { throw new Error('playback-unavailable-in-main-context'); };
        h.start(); await flush(); expect(h.api.omni.searchSongs).not.toHaveBeenCalled();
        h.api.playback.getState = readyState;
        h.change(target(), lyrics()); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
    });
    it('does not use cached translations after the underlying lyric text/timing changes', async () => {
        const h = harness(); h.start(); await flush();
        h.change(target(), [line('different original', 0)]); await flush();
        expect(h.shown().lines[0].translation).toBeUndefined();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(3);
    });
    it('restores untransformed base lyrics when the selection switches are turned off', async () => {
        const h = harness(); h.start(); await flush();
        h.settings.set({ autoSelectChinese: false, fallbackOnFailure: false }); await flush();
        expect(h.shown().lines[0].translation).toBeUndefined();
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1);
    });
    it('handles a repeated song after its cache was evicted without leaving old work running', async () => {
        const h = harness(); h.start(); await flush();
        for (let i = 0; i < 9; i++) { h.change(target({ id: String(i) }), lyrics()); await flush(); }
        h.change(target(), lyrics()); await flush();
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(11);
    });
    it('shows the chosen source and measurable Chinese coverage', async () => {
        const h = harness(); h.start(); await flush(); h.commands.get('subtitle-status').run();
        const text = h.api.ui.toast.mock.calls.at(-1)[0]; expect(text).toContain('網易雲'); expect(text).toContain('100%'); expect(text).toContain('不代表語意審核');
    });
    it.each([
        ['not-signed-in', '需要登入'], ['session-expired', '登入已過期'], ['rate-limited', '請求上限'],
        ['network', '連線失敗'], ['vip-required', '會員資格'], ['region-restricted', '地區'],
    ])('explains a source failure: %s', async (code, expected) => {
        const getLyrics = vi.fn().mockRejectedValue(Object.assign(new Error(code), { code }));
        const h = harness({ omni: { getLyrics } }); h.start(); await flush();
        h.commands.get('subtitle-status').run();
        expect(h.api.ui.toast.mock.calls.at(-1)[0]).toContain(expected);
        expect(h.shown().lines[0].translation).toBeUndefined();
    });
    it('explains why no configured source can be searched', async () => {
        const h = harness({ providers: [] }); h.start(); await flush(); h.commands.get('subtitle-status').run();
        expect(h.api.ui.toast.mock.calls.at(-1)[0]).toContain('沒有已設定且支援字幕搜尋的來源');
    });
    it('distinguishes no matching songs from an empty lyric result', async () => {
        const h = harness({ omni: { searchSongs: vi.fn(async () => ({ items: [] })) } });
        h.start(); await flush(); h.commands.get('subtitle-status').run();
        expect(h.api.ui.toast.mock.calls.at(-1)[0]).toContain('沒有找到匹配的歌曲');
        h.api.omni.searchSongs.mockResolvedValue({ items: [candidate()] });
        h.api.omni.getLyrics.mockResolvedValue({ lines: [] });
        h.commands.get('retry-chinese').run(); await flush();
        const message = h.api.ui.toast.mock.calls.at(-1)[0];
        expect(message).toContain('來源沒有字幕');
        expect(message).not.toContain('沒有找到匹配的歌曲');
    });
    it('explains a timed-out request without leaving a late result active', async () => {
        vi.useFakeTimers(); const h = harness({ omni: { getLyrics: vi.fn(() => new Promise(() => {})) } });
        h.start(); await flush(); await vi.advanceTimersByTimeAsync(7001); await flush();
        h.commands.get('subtitle-status').run();
        expect(h.api.ui.toast.mock.calls.at(-1)[0]).toContain('單次請求逾時');
    });
    it('reports the whole-search deadline and the disabled state accurately', async () => {
        vi.useFakeTimers(); const h = harness({ omni: { getLyrics: vi.fn(() => new Promise(() => {})) } });
        const selector = createChineseSelector(h.api, () => h.settings.get(), () => {}, canonicalize, { requestMs: 100000, runMs: 1000 });
        stops.push(() => selector.dispose()); selector.transform(target(), toFoliumLines(lyrics())); selector.loaded(target(), []); await flush();
        await vi.advanceTimersByTimeAsync(1001); await flush();
        expect(selector.showStatus()).toContain('整輪搜尋時間上限');
        h.settings.set({ autoSelectChinese: false, fallbackOnFailure: false }); selector.settingsChanged();
        expect(selector.showStatus()).toContain('目前已關閉');
    });
    it('caps requests per minute even if manual retry is repeated', async () => {
        const h = harness(); const selector = createChineseSelector(h.api, () => h.settings.get(), () => {}, canonicalize, { requestsPerMinute: 2 });
        stops.push(() => selector.dispose()); selector.transform(target(), toFoliumLines(lyrics())); selector.loaded(target(), []); await flush();
        selector.retry(); await flush(); expect(h.api.omni.searchSongs).toHaveBeenCalledTimes(1);
    });
    it('stops an entire search at its deadline and keeps the original', async () => {
        vi.useFakeTimers(); const h = harness({ omni: { getLyrics: vi.fn(() => new Promise(() => {})) } });
        const selector = createChineseSelector(h.api, () => h.settings.get(), () => {}, canonicalize, { requestMs: 100000, runMs: 1000 });
        stops.push(() => selector.dispose()); selector.transform(target(), toFoliumLines(lyrics())); selector.loaded(target(), []); await flush();
        await vi.advanceTimersByTimeAsync(1001); await flush(); expect(selector.showStatus()).toContain('保留原字幕');
    });
});

describe('real Folia public Omni contract', () => {
    it('accepts plugin queries/refs/signals through the actual host service and reconstructs subtitle DTOs', async () => {
        const h = harness();
        const searched = vi.fn(async (_query: string, provider: string, page: any) => {
            expect(provider).toBe('netease'); expect(page.limit).toBe(8);
            return { items: [candidate()], nextCursor: null, total: 1 };
        });
        const read = vi.fn(async (ref: string, call: any) => {
            expect(ref).toBe('song-online'); expect(typeof call.gate.run).toBe('function');
            return { lines: toFoliumLines(lyrics(4)), isWordByWord: false, isPureMusic: false };
        });
        registerFoliumOmniSource({ listProviders: h.api.omni.listProviders, describeSong: () => ({ durationMs: 200000 }), searchSongs: searched, getLyrics: read } as any);
        let release = () => {};
        h.api.omni = createFoliumOmniService({ id: 'opencc-traditional-lyrics', permissions: [] } as any, 'main', () => false, (off) => { release = off; });
        stops.push(release); h.start(); await flush();
        expect(searched).toHaveBeenCalledTimes(1); expect(read).toHaveBeenCalledTimes(1);
        expect(h.shown().lines[0].translation).toBe(translations[0]);
        expect(h.shown().lines[0].renderHints.renderEndTime).toBeGreaterThanOrEqual(14);
    });
});
