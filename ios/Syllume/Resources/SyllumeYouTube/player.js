// The native command revision travels with every sample, so delayed play events cannot undo pause.
let player, ready = false, wants = false, revision = -1, awaiting = false, pendingSeek = null;
let attempts = 0, lastCommand = 0;
const emit = (type, extra = {}) => window.webkit.messageHandlers.youtube.postMessage({ type, session, ...extra });
const applyPlayback = () => {
    if (!ready || revision < 0) return;
    lastCommand = performance.now(); attempts++;
    wants ? player.playVideo() : player.pauseVideo();
};
const snapshot = () => {
    if (!ready) return;
    const state = player.getPlayerState(), data = player.getVideoData() || {};
    if (awaiting && ((wants && state === 1) || (!wants && [-1, 0, 2, 5].includes(state)))) awaiting = false;
    else if (awaiting && performance.now() - lastCommand >= 750 && attempts < 4) applyPlayback();
    if (!awaiting && (state === 1 || state === 2)) wants = state === 1;
    emit('snapshot', { videoID: data.video_id || videoID, commandRevision: revision, state,
        time: player.getCurrentTime() || 0, duration: player.getDuration() || 0,
        title: data.title || '', author: data.author || '' });
};
window.FoliaYouTube = {
    setPlayback(value, command) {
        if (!Number.isSafeInteger(command) || command < revision) return;
        revision = command; wants = !!value; awaiting = true; attempts = 0; applyPlayback();
    },
    seek(time) { if (ready) player.seekTo(time, true); else pendingSeek = time; },
    stop() { wants = false; clearTimeout(timeout); clearInterval(timer); if (ready) player.destroy(); ready = false; },
};
const timeout = setTimeout(() => emit('error', { code: -1 }), 25000);
window.onYouTubeIframeAPIReady = () => {
    player = new YT.Player('player', { width: '100%', height: '100%', videoId: videoID,
        playerVars: { playsinline: 1, controls: 1, autoplay: 0, origin, widget_referrer: origin },
        events: {
            onReady() { ready = true; clearTimeout(timeout); if (pendingSeek !== null) { player.seekTo(pendingSeek, true); pendingSeek = null; } applyPlayback(); snapshot(); },
            onStateChange: snapshot,
            onAutoplayBlocked() { awaiting = false; wants = false; emit('blocked'); },
            onError(e) { emit('error', { code: e.data }); },
        } });
};
const timer = setInterval(snapshot, 250);
document.addEventListener('visibilitychange', () => {
    if (document.hidden) { wants = false; awaiting = true; attempts = 0; applyPlayback(); }
});
emit('loaded');
