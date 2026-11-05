import { getConverter, transformLines } from './upstream/mods/opencc-traditional-lyrics/converter.mjs';
import { createChineseSelector } from './upstream/mods/opencc-traditional-lyrics/selectChinese.mjs';
import { chineseTranslation } from './upstream/mods/opencc-traditional-lyrics/lyricQuality.mjs';

export const defaults = Object.freeze({ active: true, enabled: true, target: 'tw', convertOriginal: true,
    convertTranslation: true, protectJapanese: true, autoSelectChinese: true, fallbackOnFailure: true,
    searchDepth: 'standard', reportVisible: true });

// Only the platform boundary changes. The pinned plugin owns conversion, matching, budgets and reports.
export function createSubtitleEngine({ request, publish, report, toast = () => {} }) {
    let settings = { ...defaults }, providers = [], input = null, selector = null, account = '';
    let reportTimer = null;
    const searchReady = () => input && (input.song.source !== 'ytm'
        || (input.duration > 0 && input.song.artist?.trim() && input.song.title !== 'YouTube 影片'));
    const folium = {
        host: { folia: 'Folia-iOS/0.3.1' },
        playback: { getState: () => input && ({ song: searchReady() ? input.song : null, duration: input.duration }) },
        lyrics: { getLines: () => input?.lines ?? [] },
        omni: {
            listProviders: () => providers,
            describeSong: song => ({ durationMs: song?.durationMs ?? 0 }),
            searchSongs: (query, options) => request('search', { query, providerId: options.providerId }, options.signal),
            getLyrics: (song, options) => request('lyrics', { ref: song.ref, providerId: song.source }, options.signal),
        },
        ui: { toast }, log: { info() {}, warn() {} },
    };
    function diagnostics() {
        if (!selector || !input) return;
        if (!searchReady()) {
            report({ token: input.token, text: '等待 YouTube 提供歌曲名稱、歌手與時長；離線簡轉繁仍正常運作。', value: null });
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
        let lines = !settings.active || !selector ? input.lines
            : transformLines(selector.transform(input.song, input.lines), settings);
        if (settings.active) lines = lines.map(line => {
            const displayTranslation = chineseTranslation(line, getConverter()).text || line.translation;
            return displayTranslation && displayTranslation !== line.translation ? { ...line, displayTranslation } : line;
        });
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
            const changedAccount = accountKey !== account;
            settings = { ...defaults, ...next }; providers = listed; account = accountKey;
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
            input = next;
            if (selector) selector.songChanged(searchReady() ? next.song : null);
            if (next) { refresh(); if (searchReady()) selector?.loaded(next.song, next.lines); }
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
