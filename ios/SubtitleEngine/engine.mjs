import { getConverter, transformLines } from './upstream/mods/opencc-traditional-lyrics/converter.mjs';
import { createChineseSelector } from './upstream/mods/opencc-traditional-lyrics/selectChinese.mjs';
import { chineseTranslation, repairWordTimings } from './upstream/mods/opencc-traditional-lyrics/lyricQuality.mjs';

export const defaults = Object.freeze({ active: true, enabled: true, target: 'tw', convertOriginal: true,
    convertTranslation: true, protectJapanese: true, autoSelectChinese: true, fallbackOnFailure: true,
    searchDepth: 'standard', reportVisible: true });

// FIA can carry a previously rendered translation. Recompute it from the converted
// fields so the native lyric list and visualizers never prefer an old simplified copy.
export function displayLines(lines, settings) {
    if (!settings.active) return lines;
    const canonicalize = getConverter();
    return lines.map(line => {
        const [converted] = transformLines([line], settings);
        const displayTranslation = chineseTranslation(converted, canonicalize).text || converted.translation
            || transformLines([{ translation: converted.displayTranslation }], settings)[0].translation;
        return displayTranslation && (converted.displayTranslation || displayTranslation !== converted.translation)
            ? { ...converted, displayTranslation } : converted;
    });
}

export function cleanAnnotations(lines) {
    return lines.map(line => {
        let next = line;
        for (const key of ['alternateTexts', 'backgroundVocals']) {
            const list = line[key];
            if (list == null) continue;
            const items = Array.isArray(list) ? list.filter(item => item && typeof item.text === 'string') : [];
            if (items.length !== list.length || !Array.isArray(list)) next = { ...next, [key]: items };
        }
        return next;
    });
}

// Only the platform boundary changes. The pinned plugin owns conversion, matching, budgets and reports.
export function createSubtitleEngine({ request, publish: sendDisplay, report: sendReport, toast = () => {} }) {
    let settings = { ...defaults }, providers = [], input = null, selector = null, account = '';
    let configurationRevision = 0;
    const publish = value => sendDisplay({ ...value, configurationRevision });
    const report = value => sendReport({ ...value, configurationRevision });
    let reportTimer = null;
    const searchReady = () => input && !input.manual && !input.waitingForAudio && (input.song.source !== 'ytm'
        || (input.duration > 0 && input.song.artist?.trim() && input.song.title !== 'YouTube 影片'));
    const folium = {
        host: { folia: 'Folia-iOS' },
        playback: { getState: () => input && ({ song: searchReady() ? input.song : null, duration: input.duration }) },
        lyrics: { getLines: () => input?.lines ?? [] },
        omni: {
            listProviders: () => providers,
            describeSong: song => ({ durationMs: song?.durationMs ?? 0 }),
            searchSongs: (query, options) => request('search', { query, providerId: options.providerId }, options.signal),
            getLyrics: async (song, options) => {
                const response = await request('lyrics', { ref: song.ref, providerId: song.source }, options.signal);
                return { ...response, lines: repairWordTimings(response.lines, (song.durationMs ?? 0) / 1000) };
            },
        },
        ui: { toast }, log: { info() {}, warn() {} },
    };
    function diagnostics() {
        if (!selector || !input) return;
        if (!searchReady()) {
            report({ token: input.token, text: input.manual ? '正在顯示手動選取的翻譯字幕。' :
                '等待歌曲資料與音源；離線簡轉繁仍可使用。', value: null });
            return;
        }
        report({ token: input.token, text: selector.reportText(), value: selector.getReport() });
    }
    function scheduleReport() {
        clearTimeout(reportTimer);
        reportTimer = setTimeout(diagnostics, 100);
    }
    function refresh() {
        if (!input) return;
        const selected = settings.active && !input.manual && selector
            ? selector.transform(input.song, input.lines) : input.lines;
        const lines = displayLines(selected, settings);
        publish({ token: input.token, lines });
        scheduleReport();
    }
    function start() {
        if (!selector && settings.active) {
            selector = createChineseSelector(folium, () => settings, refresh, getConverter());
            selector.subscribeReport(scheduleReport);
            selector.start();
        }
    }
    return {
        configure(next, listed, accountKey = '') {
            const revision = Number.isSafeInteger(next.nativeRevision) ? next.nativeRevision : 0;
            if (revision < configurationRevision) return;
            configurationRevision = revision;
            const changedAccount = accountKey !== account;
            settings = { ...defaults, ...next }; providers = listed; account = accountKey;
            folium.host.folia = typeof next.hostVersion === 'string' ? next.hostVersion.slice(0, 80) : 'Folia-iOS';
            if (!settings.active) {
                selector?.dispose(); selector = null; clearTimeout(reportTimer);
                report({ token: input?.token, text: '內建模組已停用；顯示原字幕。', value: null });
            } else {
                start();
                if (changedAccount) selector.accountChanged();
                selector.settingsChanged();
            }
            refresh();
        },
        load(next) {
            input = next && { ...next, lines: cleanAnnotations(next.lines) };
            if (selector) selector.songChanged(searchReady() ? next.song : null);
            if (next) { refresh(); if (searchReady()) selector?.loaded(input.song, input.lines); }
            else { clearTimeout(reportTimer); publish({ token: null, lines: [] }); report({ token: null, text: '目前沒有歌曲。', value: null }); }
        },
        command(name) {
            if (!selector) return;
            if (name === 'retry') selector.retry();
            if (name === 'restore') selector.restore();
            if (name === 'status') selector.showStatus();
            diagnostics();
        },
        dispose() { selector?.dispose(); selector = null; clearTimeout(reportTimer); input = null; },
    };
}
