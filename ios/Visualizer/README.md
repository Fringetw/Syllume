# Folia Sonnet for iOS

This directory contains the corresponding desktop renderer source and the iOS clock adapter.
The original renderer is from [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major/tree/3125d376557182e25a12c915e39099db13ba63c8), revision `3125d376557182e25a12c915e39099db13ba63c8`, under AGPL-3.0. Original source comments and notices are preserved. `provenance.json` records the snapshot files and their SHA-256 hashes.

`entry.ts` replaces the desktop React host with a small WKWebView bridge. It uses the original Sonnet program compiler, scene layouts, Pixi renderer, glyph animation, transitions and resource cleanup. It receives no audio or platform credentials. The native playback clock sends bounded corrections; the renderer interpolates at most 400 ms between updates. It freezes when paused and stops when removed. Reduce Motion uses static frames.

The WebKit resource is committed at `../Folia/Resources/FoliaStage/`; building the Xcode app does not require Node or downloading JavaScript. To rebuild it, use Node 24+, run `npm ci` in this directory, then `npm run build`. `node_modules/` and `build-graph.json` are local intermediates. The source snapshot is intentionally limited to this renderer's build graph, rather than the full desktop application.

This ports Sonnet only. Other desktop visualizers, Folium modules and desktop audio transports are not part of this snapshot. YouTube uses a separate visible official IFrame player; the stage never extracts video or audio.
