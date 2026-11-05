import { SonnetPixiRuntime } from './desktop/src/components/visualizer/sonnet/createSonnetPixiRuntime';
import { compileSonnetProgram } from './desktop/src/components/visualizer/sonnet/sonnetProgram';
import { DEFAULT_SONNET_TUNING } from './desktop/src/types';

// The desktop Sonnet director consumes the native player's absolute clock, never its audio.
const host = document.getElementById('stage')! as HTMLDivElement;
const notify = (type: string, detail = '') => (window as any).webkit?.messageHandlers?.stage?.postMessage({ type, detail });
let runtime: SonnetPixiRuntime | null = null;
let generation = 0;
let baseTime = 0, clockStamp = performance.now(), playing = false;
let controller: AbortController | null = null;
const clock = { get: () => baseTime + (playing ? Math.min(0.4, (performance.now() - clockStamp) / 1000) : 0) };
const theme = { name: 'Folia Sonnet', backgroundColor: '#100e16', primaryColor: '#fff0df',
    accentColor: '#ecc8c2', secondaryColor: '#9b869f', fontStyle: 'serif' as const,
    animationIntensity: 'normal' as const, fontWeight: 600 };

(window as any).FoliaStage = {
    async setSong(song: any) {
        const request = ++generation;
        controller?.abort(); controller = new AbortController();
        const signal = controller.signal;
        runtime?.destroy(); runtime = null;
        host.replaceChildren();
        const lines = song.lines.map((line: any, index: number) => ({ ...line, id: String(index), isChorus: false }));
        try {
            const created = await SonnetPixiRuntime.create({ host, signal, program: compileSonnetProgram(lines, song.id),
                songSeed: song.id, theme, tuning: { ...DEFAULT_SONNET_TUNING, textureResolution: 1,
                    cameraIntensity: 0.7, typographyMotion: 1, postProcessEnabled: false },
                renderScale: 1, antialias: true, smartBeatEnabled: false,
                currentTime: clock as any, lyricsFontScale: 1, staticMode: song.reduceMotion,
                transparentBackground: true, paused: !playing || song.reduceMotion,
                songTitle: song.title, songArtist: song.artist });
            if (request !== generation) { created.destroy(); return; }
            runtime = created;
            runtime.setPaused(!playing || song.reduceMotion);
            notify('ready');
        } catch (error) { if (request === generation) notify('error', String(error)); }
    },
    setClock(snapshot: { time: number; playing: boolean; reduceMotion: boolean }) {
        if (!Number.isFinite(snapshot.time)) return;
        baseTime = Math.max(0, snapshot.time); clockStamp = performance.now();
        playing = snapshot.playing && !document.hidden;
        runtime?.setPaused(!playing || snapshot.reduceMotion);
        if (!playing || snapshot.reduceMotion) runtime?.renderOnce();
    },
    stop() { controller?.abort(); generation++; playing = false; runtime?.destroy(); runtime = null; host.replaceChildren(); },
    diagnostics() { return { ready: !!runtime, time: clock.get(), playing, canvas: !!host.querySelector('canvas') }; },
};
document.addEventListener('visibilitychange', () => { if (document.hidden) { playing = false; runtime?.setPaused(true); } });
notify('loaded');
