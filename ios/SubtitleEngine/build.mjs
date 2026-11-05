import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'vite';

const root = path.dirname(fileURLToPath(import.meta.url));
// Fold the plugin's cache-busting imports into the offline bundle without editing its source snapshot.
const rewrites = new Map([
    ['selectChinese.mjs', [
        [/const qualityUrl = new URL[\s\S]*?await import\(qualityUrl.href\);/, "import { songKey, lyricsKey, analyzeLyrics, chooseLyrics, probeSong, describeMatch, searchQueries, repairWordTimings } from './lyricQuality.mjs';"],
        [/const diagnosticsUrl = new URL[\s\S]*?await import\(diagnosticsUrl.href\);/, "import { MOD_VERSION, REASONS, errorReason, safeText, safeError, describeSong, beginReport, record, finishReport, formatReport } from './diagnostics.mjs';"],
    ]],
    ['lyricQuality.mjs', [[/const matchUrl = new URL[\s\S]*?await import\(matchUrl.href\);/, "import * as matching from './songMatch.mjs';"]]],
]);
await build({ root, configFile: false, logLevel: 'error',
    plugins: [{ name: 'bundle-pinned-plugin', transform(code, id) {
        for (const [pattern, replacement] of rewrites.get(path.basename(id)) ?? []) {
            if (!pattern.test(code)) throw new Error('Upstream import changed: ' + id);
            code = code.replace(pattern, replacement);
        }
        return code;
    } }],
    build: { target: 'safari17', minify: true, emptyOutDir: false,
        lib: { entry: path.join(root, 'entry.mjs'), name: 'FoliaSubtitles', formats: ['iife'], fileName: () => 'subtitles.js' },
        outDir: path.join(root, '../Folia/Resources/FoliaSubtitles'),
    },
});
const destination = path.join(root, '../Folia/Resources/FoliaSubtitles');
const vendor = path.join(root, 'upstream/mods/opencc-traditional-lyrics');
for (const [source, target] of [['LICENSE', 'LICENSE.plugin.txt'], ['vendor/LICENSE.OpenCC', 'LICENSE.OpenCC.txt'],
    ['vendor/LICENSE.opencc-js', 'LICENSE.opencc-js.txt'], ['vendor/THIRD_PARTY_LICENSES.md', 'THIRD_PARTY_LICENSES.md']]) {
    fs.copyFileSync(path.join(vendor, source), path.join(destination, target));
}
