// Canvas needs the actual face before measuring lyrics and building text textures.
export async function loadLyricFont(fonts, timeoutMs = 8000) {
    const family = 'GenSenRounded2JP-M';
    let timer;
    try {
        const faces = await Promise.race([
            fonts.load(`500 28px "${family}"`, '繁體かなABC'),
            new Promise(resolve => { timer = setTimeout(() => resolve([]), timeoutMs); }),
        ]);
        return faces.some(face => face.status === 'loaded') ? family : undefined;
    } catch {
        return undefined;
    } finally {
        clearTimeout(timer);
    }
}

// Keep the native media clock authoritative and stop GPU work when nothing changes.
export function createStageController({ createRuntime, host, notify, now = () => performance.now(), visible = () => !document.hidden }) {
    let runtime = null, runtimeKey = '', generation = 0, controller;
    let baseTime = 0, stamp = now(), playing = false, reduced = false, paused = true;
    const clock = { get: () => baseTime + (playing ? Math.min(1, Math.max(0, now() - stamp) / 1000) : 0) };
    function applyPause(force = false) {
        const next = !playing || reduced;
        if (runtime && (force || next !== paused)) runtime.setPaused(next);
        paused = next;
    }
    return {
        async setSong(song) {
            const request = ++generation;
            controller?.abort(); controller = new AbortController();
            const signal = controller.signal;
            const commandStarted = now();
            const trace = typeof song.traceID === 'string' && song.traceID
                ? phase => {
                    if (request === generation && !signal.aborted) {
                        notify('boot', `${song.traceID}|${phase}|${Math.round(now() - commandStarted)}`);
                    }
                }
                : undefined;
            reduced = !!song.reduceMotion;
            const key = [song.style === 'lumiere' ? 'lumiere' : 'sonnet', song.energySaving ? 'low' : 'balanced'].join('|');
            try {
                if (runtime && key === runtimeKey) {
                    applyPause();
                    trace?.('runtime-reuse');
                    await runtime.updateSong(song, signal);
                    trace?.('runtime-reused');
                } else {
                    runtime?.destroy(); runtime = null; host.replaceChildren();
                    trace?.('runtime-create');
                    const created = await createRuntime(song, clock, signal, !playing || reduced, trace);
                    if (request !== generation || signal.aborted) { created.destroy(); return; }
                    trace?.('runtime-returned');
                    runtime = created; runtimeKey = key; applyPause(true);
                }
                if (request === generation && !signal.aborted) notify('ready');
            } catch (error) {
                if (request === generation && !signal.aborted) notify('error', String(error));
            }
        },
        setClock(snapshot) {
            if (!Number.isFinite(snapshot.time)) return;
            const oldTime = baseTime, wasPaused = paused;
            baseTime = Math.max(0, snapshot.time); stamp = now();
            playing = !!snapshot.playing && visible(); reduced = !!snapshot.reduceMotion;
            applyPause();
            if (runtime && paused && wasPaused && Math.abs(baseTime - oldTime) > 0.001) runtime.renderOnce();
        },
        suspend() {
            baseTime = clock.get(); stamp = now(); playing = false; applyPause();
        },
        stop() {
            controller?.abort(); generation++; playing = false; paused = true;
            runtime?.destroy(); runtime = null; runtimeKey = ''; host.replaceChildren();
        },
        diagnostics() { return { ready: !!runtime, time: clock.get(), playing, paused, style: runtimeKey.split('|')[0], canvas: !!host.querySelector('canvas') }; },
    };
}
