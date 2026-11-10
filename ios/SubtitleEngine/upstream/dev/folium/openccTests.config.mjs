import { defineConfig } from 'vitest/config';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { hostDirectory } from '../../scripts/paths.mjs';

// Isolated plugin checks, using the host's real lyric DTO and reconstruction pipeline.
const root = fileURLToPath(new URL('../../', import.meta.url));
const host = hostDirectory();
export default defineConfig({
    root,
    resolve: { alias: {
        '@folia': path.join(host, 'src'), '@': path.join(host, 'src'),
        '@applemusic-like-lyrics/ttml': path.join(root, 'node_modules/@applemusic-like-lyrics/ttml'),
        '@xmldom/xmldom': path.join(root, 'node_modules/@xmldom/xmldom'),
    } },
    test: {
        environment: 'node',
        include: ['test/unit/mod-system/*.test.ts'],
        server: { deps: { inline: [/parserCore\.ts$/] } },
    },
});
