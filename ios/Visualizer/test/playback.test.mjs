import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { createStageController, loadLyricFont } from '../stageController.mjs';

function stageHarness(factory) {
    let now = 0, visible = true;
    const calls = [], messages = [], host = { replaceChildren() {}, querySelector() { return {}; } };
    const runtime = { setPaused: v => calls.push(['pause', v]), renderOnce: () => calls.push(['render']), destroy: () => calls.push(['destroy']), updateSong: async song => calls.push(['song', song.id]) };
    const stage = createStageController({ host, now: () => now, visible: () => visible,
        notify: (...args) => messages.push(args), createRuntime: factory ?? (async () => runtime) });
    return { stage, calls, messages, runtime, advance(ms) { now += ms; }, hide() { visible = false; stage.suspend(); } };
}
const song = { id: 'a', style: 'sonnet', lines: [], reduceMotion: false, energySaving: false };

test('animation waits for the bundled JP face and falls back on load failure or timeout', async () => {
    const calls = [];
    const fonts = { load: async (...args) => { calls.push(args); return [{ status: 'loaded' }]; } };
    assert.equal(await loadLyricFont(fonts), 'GenSenRounded2JP-M');
    assert.deepEqual(calls, [['500 28px "GenSenRounded2JP-M"', '繁體かなABC']]);
    assert.equal(await loadLyricFont({ load: async () => [] }), undefined);
    assert.equal(await loadLyricFont({ load: async () => { throw new Error('file unavailable'); } }), undefined);
    assert.equal(await loadLyricFont({ load: () => new Promise(() => {}) }, 5), undefined);
});

test('paused stage freezes its clock and does no repeated GPU work', async () => {
    const h = stageHarness(); await h.stage.setSong(song);
    h.stage.setClock({ time: 4, playing: true }); h.advance(120);
    assert.equal(h.stage.diagnostics().time, 4.12);
    h.stage.setClock({ time: 4.12, playing: false });
    const before = h.calls.length;
    for (let i = 0; i < 30; i++) { h.advance(250); h.stage.setClock({ time: 4.12, playing: false }); }
    assert.equal(h.stage.diagnostics().time, 4.12); assert.equal(h.calls.length, before);
    h.stage.setClock({ time: 10, playing: false });
    assert.deepEqual(h.calls.at(-1), ['render']); assert.equal(h.stage.diagnostics().time, 10);
});

test('stage time interpolates between corrections but cannot run away after a lost bridge', () => {
    const h = stageHarness(); h.stage.setClock({ time: 5, playing: true });
    h.advance(800); assert.equal(h.stage.diagnostics().time, 5.8);
    h.advance(5000); assert.equal(h.stage.diagnostics().time, 6);
    h.hide(); const frozen = h.stage.diagnostics().time; h.advance(5000);
    assert.equal(h.stage.diagnostics().time, frozen); assert.equal(h.stage.diagnostics().playing, false);
});

test('lyric updates and track changes reuse a renderer instead of recreating WebGL', async () => {
    const h = stageHarness(); await h.stage.setSong(song); await h.stage.setSong({ ...song, id: 'b' });
    assert.deepEqual(h.calls.filter(c => c[0] === 'song'), [['song', 'b']]);
    assert.equal(h.calls.some(c => c[0] === 'destroy'), false);
});

test('pause during runtime creation is applied before the stage becomes ready', async () => {
    let resolve; const h = stageHarness(() => new Promise(r => { resolve = r; }));
    h.stage.setClock({ time: 2, playing: true }); const pending = h.stage.setSong(song);
    h.stage.setClock({ time: 2.2, playing: false }); resolve(h.runtime); await pending;
    assert.deepEqual(h.calls.at(-1), ['pause', true]); assert.equal(h.stage.diagnostics().playing, false);
});

test('a late style creation is destroyed and cannot replace the newer stage', async () => {
    const resolves = []; const h = stageHarness(() => new Promise(r => resolves.push(r)));
    const first = h.stage.setSong(song), second = h.stage.setSong({ ...song, style: 'lumiere' });
    const oldCalls = []; resolves[0]({ ...h.runtime, destroy: () => oldCalls.push('destroy') }); await first;
    assert.deepEqual(oldCalls, ['destroy']); assert.equal(h.messages.length, 0);
    resolves[1](h.runtime); await second;
    assert.equal(h.stage.diagnostics().style, 'lumiere'); assert.equal(h.messages[0][0], 'ready');
    h.stage.stop(); assert.equal(h.stage.diagnostics().ready, false);
});

test('reduced motion stops the ticker while accepting new word positions', async () => {
    const h = stageHarness(); await h.stage.setSong(song);
    h.stage.setClock({ time: 2, playing: true, reduceMotion: true });
    assert.equal(h.stage.diagnostics().paused, true); const before = h.calls.length;
    h.stage.setClock({ time: 3, playing: true, reduceMotion: true });
    assert.equal(h.calls.length, before + 1); assert.deepEqual(h.calls.at(-1), ['render']);
});

function youtubeHarness({ seekStartsPlayback = false, startSeconds = 0 } = {}) {
    const messages = [], calls = []; let now = 0, tick, playerOptions, visibilityChanged;
    const document = { hidden: false, addEventListener(_, callback) { visibilityChanged = callback; } };
    const media = { state: 2, time: 4 };
    const controls = { playVideo() { calls.push('play'); media.state = 1; }, pauseVideo() { calls.push('pause'); media.state = 2; },
        seekTo(time) { calls.push(['seek', time]); media.time = time; if (seekStartsPlayback) media.state = 1; },
        destroy() { calls.push('destroy'); },
        getPlayerState: () => media.state, getVideoData: () => ({ video_id: 'M7lc1UVf-VE' }), getCurrentTime: () => media.time, getDuration: () => 60 };
    const window = { webkit: { messageHandlers: { youtube: { postMessage: m => messages.push(m) } } } };
    const context = { window, session: 'session', videoID: 'M7lc1UVf-VE', origin: 'https://org.folia.community.ios', startSeconds,
        performance: { now: () => now }, document,
        setTimeout: () => 1, clearTimeout() {}, setInterval: fn => { tick = fn; return 2; }, clearInterval() {},
        YT: { Player: function (_, options) { playerOptions = options; return controls; } } };
    vm.runInNewContext(fs.readFileSync(new URL('../../Syllume/Resources/SyllumeYouTube/player.js', import.meta.url), 'utf8'), context);
    return { messages, calls, media, api: window.FoliaYouTube,
        create() { window.onYouTubeIframeAPIReady(); }, didLoad() { playerOptions.events.onReady(); },
        fail(code) { playerOptions.events.onError({ data: code }); },
        playerVars() { return playerOptions.playerVars; },
        setHidden(hidden) { document.hidden = hidden; visibilityChanged(); },
        ready() { this.create(); this.didLoad(); }, tick() { now += 250; tick(); } };
}

test('YouTube pause calls the real player and wins over a delayed older play command', () => {
    const h = youtubeHarness(); h.api.setPlayback(true, 1); h.ready();
    assert.equal(h.media.state, 1); h.api.setPlayback(false, 2); h.api.setPlayback(true, 1); h.tick();
    assert.equal(h.media.state, 2); assert.equal(h.calls.at(-1), 'pause');
    assert.equal(h.messages.at(-1).commandRevision, 2); assert.equal(h.messages.at(-1).state, 2);
});

test('a pause before YouTube readiness prevents autoplay and retains a pending seek', () => {
    const h = youtubeHarness({ seekStartsPlayback: true });
    h.api.setPlayback(true, 1); h.api.seek(12); h.api.setPlayback(false, 2); h.ready();
    assert.equal(h.media.state, 2); assert.equal(h.media.time, 12); assert.equal(h.calls.includes('play'), false);
    h.api.seek(15); assert.equal(h.media.state, 2); assert.equal(h.media.time, 15);
    h.api.setPlayback(true, 3); assert.equal(h.media.state, 1); h.api.stop(); assert.equal(h.calls.at(-1), 'destroy');
});

test('discarding an iframe before readiness prevents late playback after a track change', () => {
    const h = youtubeHarness();
    h.api.setPlayback(true, 1);
    h.create(); h.api.stop(); h.didLoad(); h.fail(100); h.tick();
    assert.deepEqual(h.calls, ['destroy']);
    assert.deepEqual(h.messages.map(message => message.type), ['loaded']);
});

test('a reopened iframe receives the retained start time without seeking before playback', () => {
    const h = youtubeHarness({ startSeconds: 22, seekStartsPlayback: true });
    h.api.setPlayback(false, 1); h.ready();
    assert.equal(h.playerVars().start, 22);
    assert.equal(h.playerVars().autoplay, 0);
    assert.deepEqual(h.calls, ['pause']);
    h.api.setPlayback(true, 2);
    assert.deepEqual(h.calls, ['pause', 'play']);
});

test('a hidden document pauses without consuming the next native play command', () => {
    const h = youtubeHarness();
    h.api.setPlayback(true, 1); h.ready();
    h.setHidden(true);
    assert.equal(h.media.state, 2);
    h.api.setPlayback(false, 2);
    h.api.setPlayback(true, 3);
    const beforeShowing = h.messages.length;
    h.tick();
    assert.equal(h.media.state, 2);
    assert.equal(h.messages.length, beforeShowing);
    h.setHidden(false); h.tick();
    assert.equal(h.media.state, 2);
    assert.deepEqual(h.messages.slice(beforeShowing).map(message => message.type), ['visible']);
    h.api.setPlayback(true, 3); h.tick();
    assert.equal(h.media.state, 1);
    assert.equal(h.messages.at(-1).commandRevision, 3);
    assert.equal(h.messages.at(-1).state, 1);
});

test('YouTube retries a visibility request that native cannot accept during presentation', () => {
    const h = youtubeHarness();
    h.api.setPlayback(true, 1); h.ready();
    h.setHidden(true);
    h.api.setPlayback(false, 2);
    h.setHidden(false);
    const visibilityRequests = () => h.messages.filter(message => message.type === 'visible').length;
    assert.equal(visibilityRequests(), 1);
    h.tick(); h.tick();
    assert.equal(visibilityRequests(), 1);
    h.tick();
    assert.equal(visibilityRequests(), 2, 'Retry while native is still waiting for a visible viewport');
    assert.equal(h.media.state, 2, 'The page must wait for native playback intent');

    h.api.setPlayback(true, 3);
    h.tick(); h.tick(); h.tick();
    assert.equal(visibilityRequests(), 2);
    assert.equal(h.media.state, 1);
    assert.equal(h.messages.at(-1).commandRevision, 3);
});

test('YouTube requests its first playback command again if dispatch after load is lost', () => {
    const h = youtubeHarness();
    assert.equal(h.messages.at(-1).type, 'loaded');
    h.ready();
    assert.equal(h.messages.at(-1).type, 'visible');
    h.tick(); h.tick(); h.tick();
    assert.deepEqual(h.messages.map(message => message.type), ['loaded', 'visible', 'visible']);
    assert.equal(h.calls.includes('play'), false);

    h.api.setPlayback(true, 1);
    h.tick();
    assert.equal(h.media.state, 1);
    assert.equal(h.messages.at(-1).commandRevision, 1);
});

test('vendored desktop sources match the pinned snapshot and documented iOS patches', () => {
    const manifest = JSON.parse(fs.readFileSync(new URL('../provenance.json', import.meta.url)));
    assert.equal(manifest.revision, '3125d376557182e25a12c915e39099db13ba63c8');
    for (const [path, hash] of Object.entries(manifest.source_files)) {
        const expected = manifest.ios_patches?.[path]?.patched_sha256 ?? hash;
        const bytes = fs.readFileSync(new URL('../desktop/' + path, import.meta.url));
        assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), expected, path);
    }
});
