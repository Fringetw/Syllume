import { SonnetPixiRuntime } from './desktop/src/components/visualizer/sonnet/createSonnetPixiRuntime';
import { compileSonnetProgram } from './desktop/src/components/visualizer/sonnet/sonnetProgram';
import { LumierePixiRuntime } from './desktop/src/components/visualizer/lumiere/createLumierePixiRuntime';
import { compileLumiereProgram } from './desktop/src/components/visualizer/lumiere/lumiereProgram';
import { DEFAULT_SONNET_TUNING, DEFAULT_LUMIERE_TUNING } from './desktop/src/types';
import { createStageController } from './stageController.mjs';

// Offline desktop directors share one native clock; no audio is copied into the renderer.
const host = document.getElementById('stage')! as HTMLDivElement;
const notify = (type: string, detail = '') => (window as any).webkit?.messageHandlers?.stage?.postMessage({ type, detail });
const theme = { name: 'Folia', backgroundColor: '#100e16', primaryColor: '#fff0df',
    accentColor: '#a1dbd1', secondaryColor: '#9b869f', fontStyle: 'serif' as const,
    animationIntensity: 'normal' as const, fontWeight: 600 };
const zero = { get: () => 0 };
const linesFor = (song: any) => song.lines.map((line: any, index: number) => ({ ...line, id: String(index), isChorus: false }));
const stage = createStageController({ host, notify, async createRuntime(song: any, clock: any, signal: AbortSignal, paused: boolean) {
    const renderScale = song.energySaving ? 0.75 : 1;
    const maxFPS = song.energySaving ? 30 : 60;
    if (song.style === 'lumiere') {
        const runtime = await LumierePixiRuntime.create({ host, signal, maxFPS,
            song: { seed: song.id, program: compileLumiereProgram(linesFor(song), song.id), theme },
            tuning: { ...DEFAULT_LUMIERE_TUNING, renderQuality: song.energySaving ? 'low' : 'balanced' },
            currentTime: clock, audioPower: zero as any, audioBands: { bass: zero, mid: zero, treble: zero } as any,
            staticMode: song.reduceMotion, showText: true, paused,
            metadata: { title: song.title, artist: song.artist }, renderScale, antialias: false });
        return { setPaused: (value: boolean) => runtime.setPaused(value), renderOnce: () => runtime.renderOnce(), destroy: () => runtime.destroy(),
            async updateSong(next: any, abort: AbortSignal) {
                runtime.setStaticMode(next.reduceMotion);
                runtime.setSongMetadata({ title: next.title, artist: next.artist });
                await runtime.swapSong({ seed: next.id, program: compileLumiereProgram(linesFor(next), next.id), theme }, abort);
            } };
    }
    const runtime = await SonnetPixiRuntime.create({ host, signal, maxFPS,
        program: compileSonnetProgram(linesFor(song), song.id), songSeed: song.id, theme,
        tuning: { ...DEFAULT_SONNET_TUNING, textureResolution: 1, cameraIntensity: 0.7, typographyMotion: 1, postProcessEnabled: false },
        renderScale, antialias: false, smartBeatEnabled: false, currentTime: clock,
        lyricsFontScale: 1, staticMode: song.reduceMotion, transparentBackground: true, paused,
        songTitle: song.title, songArtist: song.artist });
    return { setPaused: (value: boolean) => runtime.setPaused(value), renderOnce: () => runtime.renderOnce(), destroy: () => runtime.destroy(),
        async updateSong(next: any, abort: AbortSignal) {
            runtime.setStaticMode(next.reduceMotion);
            runtime.setSongMetadata({ title: next.title, artist: next.artist });
            await runtime.swapSong({ seed: next.id, program: compileSonnetProgram(linesFor(next), next.id), theme }, abort);
        } };
} });
(window as any).FoliaStage = stage;
document.addEventListener('visibilitychange', () => { if (document.hidden) stage.suspend(); });
notify('loaded');
