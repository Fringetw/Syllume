import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';

// Load the production methods, with only the GPU and asset operations replaced by test doubles.
const source = '/desktop/src/components/visualizer';
let server, SonnetPixiRuntime, LumierePixiRuntime, PixiSongSwap;

before(async () => {
    server = await createServer({ root: fileURLToPath(new URL('..', import.meta.url)), configFile: false,
        appType: 'custom', server: { middlewareMode: true, watch: null, ws: false } });
    ({ SonnetPixiRuntime } = await server.ssrLoadModule(`${source}/sonnet/createSonnetPixiRuntime.ts`));
    ({ LumierePixiRuntime } = await server.ssrLoadModule(`${source}/lumiere/createLumierePixiRuntime.ts`));
    ({ PixiSongSwap } = await server.ssrLoadModule(`${source}/pixiSongSwap.ts`));
});

after(async () => server?.close());

const time = 11.25;
const currentTime = { get: () => time };
const previous = { seed: 'previous', program: { paragraphs: [{}] }, theme: {} };
const next = { seed: 'next', program: { paragraphs: [] }, theme: {} };
const emptyIcons = { textures: new Map(), urls: new Set() };

function sonnet(loadIconTextures = async () => emptyIcons) {
    const events = [];
    const runtime = Object.assign(Object.create(SonnetPixiRuntime.prototype), {
        options: { paused: false, songSeed: previous.seed, program: previous.program, currentTime }, lastWidth: 320,
        app: { start: () => events.push('start'), stop: () => events.push('stop') },
        loadIconTextures,
        commitSongContext(song) { this.options.songSeed = song.seed; },
        releaseIconUrls(urls) { events.push(['release', urls]); },
        renderOnce() { events.push(['draw', this.options.songSeed, this.options.currentTime.get()]); },
    });
    return { runtime, events };
}

test('Sonnet commits a paused song after icon preload without starting the ticker', async () => {
    const icons = Promise.withResolvers();
    const { runtime, events } = sonnet(() => icons.promise);
    const swapped = runtime.swapSong(next);
    runtime.setPaused(true);
    assert.deepEqual(events, ['stop', ['draw', previous.seed, time]]);
    events.length = 0;

    icons.resolve(emptyIcons);
    await Promise.resolve();
    assert.deepEqual(events, [['draw', next.seed, time]]);
    await swapped;
});

test('Sonnet settles an active dissolve before painting the paused frame', async () => {
    const { runtime, events } = sonnet();
    const swapped = runtime.swapSong(next);
    await Promise.resolve();
    assert.equal(runtime.songSwap.pending, next);
    assert.equal(runtime.options.songSeed, previous.seed);

    runtime.setPaused(true);
    assert.deepEqual(events, ['stop', ['draw', next.seed, time]]);
    assert.equal(runtime.songSwap, null);
    await swapped;
});

test('an aborted Sonnet preload releases the incoming textures and leaves the current song intact', async () => {
    const icons = Promise.withResolvers();
    const url = new Set(['unused-icon']);
    const { runtime, events } = sonnet(() => icons.promise);
    const abort = new AbortController();
    const swapped = runtime.swapSong(next, abort.signal);
    abort.abort();
    icons.resolve({ textures: new Map(), urls: url });
    await swapped;
    assert.equal(runtime.options.songSeed, previous.seed);
    assert.deepEqual(events, [['release', url]]);
});

for (const hasStagedFrame of [false, true]) {
    test(`Lumiere settles the pending song when paused ${hasStagedFrame ? 'after' : 'before'} staging`, async () => {
        const events = [];
        const staged = {};
        const runtime = Object.assign(Object.create(LumierePixiRuntime.prototype), {
            options: { paused: false, song: previous, currentTime }, width: 320, sceneCache: { size: 1 },
            app: { start: () => events.push('start'), stop: () => events.push('stop') },
            renderOnce() {
                this.songSwap.advance();
                events.push(['draw', this.options.song.seed, this.options.currentTime.get()]);
            },
        });
        runtime.songSwap = new PixiSongSwap({ stage: () => staged, discard: () => events.push('discard'),
            commit: (song, prepared) => {
                assert.equal(prepared, hasStagedFrame ? staged : null);
                runtime.options.song = song;
            } });
        const swapped = runtime.swapSong(next);
        if (hasStagedFrame) runtime.songSwap.advance();
        assert.equal(runtime.options.song, previous);

        runtime.setPaused(true);
        assert.deepEqual(events, ['stop', ['draw', next.seed, time]]);
        assert.equal(runtime.songSwap.active, false);
        await swapped;
    });
}
