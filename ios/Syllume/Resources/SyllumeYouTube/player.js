// The native command revision travels with every sample, so delayed play events cannot undo pause.
let player, ready = false, wants = false, revision = -1, awaiting = false, pendingSeek = null;
let attempts = 0, lastCommand = 0, stopped = false;
const emit = (type, extra = {}) => window.webkit.messageHandlers.youtube.postMessage({ type, session, ...extra });
let waitingForVisibleCommand = document.hidden;
const canPlay = () => wants && !document.hidden && !waitingForVisibleCommand;
const applyPlayback = () => {
    if (!ready || stopped || revision < 0) return;
    lastCommand = performance.now(); attempts++;
    canPlay() ? player.playVideo() : player.pauseVideo();
};
const applySeek = (time) => {
    player.seekTo(time, true);
    if (!canPlay()) {
        awaiting = true; attempts = 0;
        applyPlayback();
    }
};
const snapshot = () => {
    if (!ready || document.hidden || waitingForVisibleCommand) return;
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
        if (stopped || !Number.isSafeInteger(command) || command < revision) return;
        revision = command; wants = !!value; waitingForVisibleCommand = document.hidden;
        awaiting = true; attempts = 0; applyPlayback();
    },
    seek(time) { if (stopped) return; if (ready) applySeek(time); else pendingSeek = time; },
    stop() {
        if (stopped) return;
        stopped = true; wants = false; ready = false;
        clearTimeout(timeout); clearInterval(timer); player?.destroy();
    },
};
const timeout = setTimeout(() => emit('error', { code: -1 }), 25000);
window.onYouTubeIframeAPIReady = () => {
    if (stopped) return;
    player = new YT.Player('player', { width: '100%', height: '100%', videoId: videoID,
        playerVars: { playsinline: 1, controls: 1, autoplay: 0, origin, widget_referrer: origin, start: startSeconds },
        events: {
            onReady() {
                if (stopped) return;
                ready = true; clearTimeout(timeout);
                if (pendingSeek !== null) { applySeek(pendingSeek); pendingSeek = null; }
                applyPlayback(); snapshot();
            },
            onStateChange: snapshot,
            onAutoplayBlocked() {
                if (stopped || !canPlay()) return;
                awaiting = false; wants = false; emit('blocked', { commandRevision: revision });
            },
            onError(e) { if (!stopped) emit('error', { code: e.data }); },
        } });
};
const timer = setInterval(snapshot, 250);
document.addEventListener('visibilitychange', () => {
    if (stopped) return;
    if (document.hidden) {
        waitingForVisibleCommand = true;
        if (ready) player.pauseVideo();
    } else if (waitingForVisibleCommand) {
        // Native still owns the intent and checks that the player is actually onscreen.
        emit('visible');
    }
});
emit('loaded');
