import { build } from 'vite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Bundle the checked-in desktop snapshot into an offline WKWebView resource.
const root = path.dirname(fileURLToPath(import.meta.url));
const desktop = process.env.FOLIA_DESKTOP_ROOT || path.join(root, 'desktop');
const entry = path.join(root, 'entry.ts');
const graph = [];
await build({ root, configFile: false, logLevel: 'error',
    resolve: { alias: { '@': path.join(desktop, 'src') } },
    define: { 'process.env.NODE_ENV': '"production"' },
    plugins: [{ name: 'source-provenance', buildEnd() { graph.push(...this.getModuleIds()); } }],
    build: { lib: { entry, name: 'FoliaSonnet', formats: ['iife'], fileName: () => 'sonnet.js' },
        outDir: path.join(root, '../Folia/Resources/FoliaStage'), emptyOutDir: false,
        target: 'safari17', rollupOptions: { output: { inlineDynamicImports: true },
            onwarn(warning, warn) { if (warning.code !== 'MODULE_LEVEL_DIRECTIVE') warn(warning); } } } });
fs.writeFileSync(path.join(root, 'build-graph.json'), JSON.stringify(graph, null, 2));
