# Folia Sonnet and Lumiere for iOS

This directory contains the desktop Sonnet (商籟) and Lumiere (繪光) program compilers and Pixi renderers from [Folia](https://github.com/chthollyphile/folia-major/tree/3125d376557182e25a12c915e39099db13ba63c8), pinned to revision `3125d376557182e25a12c915e39099db13ba63c8`, under AGPL-3.0. Original comments and credits are preserved. `provenance.json` records original SHA-256 hashes plus documented iOS patch hashes.

The two small runtime patches allow the iOS host to cap the ticker at 60 or 30 fps; Sonnet also commits a song handover immediately while paused, so it cannot await a stopped ticker. Everything else in the source snapshot is unchanged.

`entry.ts` replaces the React host with an offline WKWebView bridge. `stageController.mjs` reuses same-style runtimes for song and lyric changes, rejects late async creations, and renders no repeated paused frames. It consumes native absolute time and interpolates up to one second between corrections. Pausing, visibility changes, style replacement and teardown stop the ticker. Reduce Motion uses static frames. Lumiere currently receives zero audio-band values: its lighting and typography work, but this port does not claim live audio analysis or beat-synchronous light.

Balanced mode uses a 60 fps cap and bounded resolution; energy-saving or system Low Power Mode uses 30 fps, reduced render scale and Lumiere's lower graphics quality. The native atmosphere uses a separate 15 Hz canvas without an extra full-screen blur pass. These are cost limits, not measured device frame-rate guarantees.

The generated offline resource is committed at `../Folia/Resources/FoliaStage/`; Xcode needs no Node downloads. With Node 24+, run `npm ci`, `npm run build`, then `npm test`. Source, generated resource, and actual WebKit rendering are checked separately. `node_modules/` and `build-graph.json` are local intermediates. The source snapshot contains only the two renderer dependency graphs, not the desktop application.

YouTube uses a separate visible official IFrame player. No audio extraction, account tokens, or remote code are passed to the lyric stage. The Debug-only media fixture exercises real WebKit audio pause and resume without contacting YouTube; it is excluded from Release.
