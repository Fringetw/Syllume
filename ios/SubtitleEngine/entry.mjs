import { createSubtitleEngine } from './engine.mjs';

const send = message => window.webkit.messageHandlers.subtitles.postMessage(message);
const pending = new Map();
let serial = 0;
const engine = createSubtitleEngine({
    request(method, params, signal) {
        return new Promise((resolve, reject) => {
            if (signal?.aborted) return reject(Object.assign(new Error('aborted'), { code: 'aborted' }));
            const id = String(++serial);
            const abort = () => {
                pending.delete(id); send({ type: 'cancel', id });
                reject(Object.assign(new Error('aborted'), { code: 'aborted' }));
            };
            pending.set(id, { resolve, reject, cleanup: () => signal?.removeEventListener('abort', abort) });
            signal?.addEventListener('abort', abort, { once: true });
            send({ type: 'request', id, method, params });
        });
    },
    publish: data => send({ type: 'display', ...data }),
    report: data => send({ type: 'report', ...data }),
    toast: text => send({ type: 'toast', text }),
});
window.FoliaSubtitles = {
    configure: (settings, providers, account) => engine.configure(settings, providers, account),
    load: input => engine.load(input),
    command: name => engine.command(name),
    resolve(id, result, error) {
        const item = pending.get(id); if (!item) return;
        pending.delete(id); item.cleanup();
        if (error) item.reject(Object.assign(new Error(error.message), { code: error.code }));
        else item.resolve(result);
    },
};
window.addEventListener('pagehide', () => engine.dispose());
send({ type: 'ready' });
