import { afterEach, describe, expect, it, vi } from 'vitest';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { copyReport, downloadReport, mountDiagnostics } from '../../../mods/opencc-traditional-lyrics/diagnosticsUi.mjs';
import { sanitizeFoliumParams } from '@folia/mods/params/params';
import activate from '../../../mods/opencc-traditional-lyrics/client.mjs';

vi.mock('@folia/mods/runtime/status', () => ({ reportFoliumIssue: vi.fn() }));

// DOM/clipboard/download contract tests, not Chromium layout or real Windows playback verification.
const { JSDOM } = createRequire(fileURLToPath(new URL('../../../package.json', import.meta.url)))('jsdom');
const closes: Array<() => void> = [];
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

function setup(options: any = {}) {
    const dom = new JSDOM('<!doctype html><html><body><div id="panel"></div></body></html>', { url: 'http://localhost/' });
    closes.push(() => dom.window.close());
    const container = dom.window.document.getElementById('panel');
    let text = options.text ?? 'OpenCC v1.1.6 完整診斷報告\n<script>alert(1)</script>\n' + '完整事件\n'.repeat(200);
    let listener: (() => void) | undefined;
    let settings: any = { reportVisible: true };
    const changes = new Set<() => void>();
    const off = vi.fn(() => { listener = undefined; });
    const data = { schemaVersion: 1, modVersion: '1.1.6', generatedAt: '2026-11-01T15:30:00.000Z', status: 'searching',
        events: Array.from({ length: 60 }, (_, i) => ({ sequence: i + 1, stage: 'search', query: `歌名 ${i}` })) };
    const selector = { reportText: () => text, getReport: () => data,
        subscribeReport: (next: () => void) => { listener = next; return off; } };
    const ctx = { locale: options.locale ?? 'zh-TW', settings: {
        get: () => settings, set: (patch: any) => { settings = { ...settings, ...patch }; changes.forEach(fn => fn()); },
        onChange: (fn: () => void) => { changes.add(fn); return () => changes.delete(fn); },
    } };
    const dispose = mountDiagnostics(selector)(container, ctx);
    closes.push(dispose);
    return { dom, container, data, selector, off, dispose, ctx, changes,
        update(value: string) { text = value; listener?.(); },
        button(label: string) { return [...container.querySelectorAll('button')].find((node: any) => node.textContent === label) as any; },
        output: container.querySelector('textarea') as any };
}

afterEach(() => { closes.splice(0).reverse().forEach(close => close()); vi.restoreAllMocks(); });

describe('diagnostic report settings panel and exports', () => {
    it('validates the actual client diagnostic schema with Folia’s parameter validator and unregisters it', () => {
        const modId = 'opencc-diagnostics-test';
        const registered = new Map<string, any>();
        const api = { env: { context: 'main' },
            registries: {
                settingsSections: { register: (def: any) => {
                    const schema = sanitizeFoliumParams(def.settings, modId, { allowSecret: true });
                    expect(schema.length).toBeGreaterThan(0);
                    registered.set(def.id, { ...def, schema });
                    return { unregister: () => registered.delete(def.id), settings: {
                        get: () => Object.fromEntries(schema.map((field: any) => [field.key, field.defaultValue])),
                        onChange: () => () => {},
                    } };
                } },
                commands: { register: () => ({ unregister() {} }) },
            },
            lyrics: { refresh() {}, getLines: () => [] }, playback: { getState: () => ({ song: null }) },
            events: { on: () => () => {} },
            omni: { listProviders: () => [], searchSongs: async () => ({ items: [] }), getLyrics: async () => ({ lines: [] }) },
        };
        const stop = activate(api); closes.push(stop);
        const entry = registered.get('diagnostics');
        expect(entry.schema).toEqual([expect.objectContaining({ key: 'reportVisible', defaultValue: true })]);
        expect(typeof entry.settingsPanel).toBe('function');
        stop();
        expect(registered.size).toBe(0);
    });
    it('keeps all report text selectable in a bounded scroll area and treats source text as text', () => {
        const text = '<script>alert(1)</script>\n' + '完整紀錄\n'.repeat(30000);
        const h = setup({ text });
        expect(h.output.value).toBe(text); expect(h.output.readOnly).toBe(true);
        expect(h.container.querySelector('script')).toBeNull();
        const style = h.dom.window.getComputedStyle(h.output);
        expect(style.height).toBe('360px'); expect(style.overflow).toBe('auto');
        expect(style.userSelect).toBe('text');
    });
    it('updates a running report without dropping the current scroll position or text selection', () => {
        const h = setup(); h.output.focus(); h.output.setSelectionRange(10, 30); h.output.scrollTop = 70;
        h.update(h.output.value + '\n新增完成事件');
        expect(h.output.value).toContain('新增完成事件'); expect(h.output.scrollTop).toBe(70);
        expect([h.output.selectionStart, h.output.selectionEnd]).toEqual([10, 30]);
    });
    it('collapses and reopens the report using its persisted visibility setting', async () => {
        const h = setup(); h.button('收合報告').click(); await flush();
        expect(h.ctx.settings.get().reportVisible).toBe(false); expect(h.output.hidden).toBe(true);
        expect(h.dom.window.getComputedStyle(h.output).display).toBe('none');
        h.button('顯示報告').click(); await flush(); expect(h.output.hidden).toBe(false);
    });
    it('copies the complete text without reading the clipboard or changing the report', async () => {
        const h = setup(); const writeText = vi.fn(async () => {});
        Object.defineProperty(h.dom.window.navigator, 'clipboard', { value: { writeText } });
        h.button('複製完整報告').click(); await flush();
        expect(writeText).toHaveBeenCalledWith(h.output.value);
        expect(h.container.querySelector('[role="status"]').textContent).toBe('已複製完整報告。');
    });
    it('falls back to selection and honest manual-copy feedback if clipboard permission is denied', async () => {
        const h = setup();
        Object.defineProperty(h.dom.window.navigator, 'clipboard', { value: { writeText: vi.fn(async () => { throw new Error('denied'); }) } });
        h.dom.window.document.execCommand = vi.fn(() => false);
        h.button('複製完整報告').click(); await flush();
        expect(h.container.querySelector('[role="status"]').textContent).toContain('無法自動複製');
        expect(h.output.selectionStart).toBe(0); expect(h.output.selectionEnd).toBe(h.output.value.length);
        expect(h.container.querySelectorAll('textarea').length).toBe(1);
    });
    it('downloads parseable, untruncated JSON, removes its temporary link and revokes its blob URL', async () => {
        const h = setup(); let blob: Blob | undefined;
        h.dom.window.Blob = Blob;
        h.dom.window.URL.createObjectURL = vi.fn((value: Blob) => { blob = value; return 'blob:diagnostic-test'; });
        h.dom.window.URL.revokeObjectURL = vi.fn();
        const click = vi.spyOn(h.dom.window.HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
        const timer = vi.spyOn(h.dom.window, 'setTimeout').mockImplementation((fn: () => void) => { fn(); return 0; });
        expect(downloadReport(h.data, h.dom.window.document)).toBe(true);
        expect(JSON.parse(await blob!.text())).toEqual(h.data);
        expect(click).toHaveBeenCalledOnce(); expect(h.container.querySelector('a')).toBeNull();
        expect(h.dom.window.URL.revokeObjectURL).toHaveBeenCalledWith('blob:diagnostic-test');
        timer.mockRestore();
    });
    it('the download button exports the current snapshot instead of an earlier rendered report', async () => {
        const h = setup(); h.dom.window.Blob = Blob; let blob: Blob | undefined;
        h.dom.window.URL.createObjectURL = vi.fn((value: Blob) => { blob = value; return 'blob:current'; });
        h.dom.window.URL.revokeObjectURL = vi.fn();
        vi.spyOn(h.dom.window.HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
        vi.spyOn(h.dom.window, 'setTimeout').mockImplementation((fn: () => void) => { fn(); return 0; });
        h.data.status = 'selected'; h.button('下載報告（JSON）').click(); await flush();
        expect(JSON.parse(await blob!.text()).status).toBe('selected');
    });
    it('reports an unavailable download honestly and leaves the manual-copy report visible', async () => {
        const h = setup(); h.button('下載報告（JSON）').click(); await flush();
        expect(h.container.querySelector('[role="status"]').textContent).toContain('下載不可用');
        expect(h.output.hidden).toBe(false);
    });
    it('expands a collapsed report for manual copying when automatic copy is denied', async () => {
        const h = setup(); h.button('收合報告').click(); await flush();
        h.button('複製完整報告').click(); await flush();
        expect(h.output.hidden).toBe(false); expect(h.output.selectionEnd).toBe(h.output.value.length);
    });
    it('unmounts subscriptions and does not leave content or settings listeners behind', () => {
        const h = setup(); h.dispose();
        expect(h.off).toHaveBeenCalledOnce(); expect(h.changes.size).toBe(0);
        expect(h.container.children.length).toBe(0); h.update('late event'); expect(h.container.textContent).toBe('');
    });
    it('uses English controls when the host locale is English', () => {
        const h = setup({ locale: 'en' }); expect(h.button('Copy full report')).toBeTruthy();
    });
});
