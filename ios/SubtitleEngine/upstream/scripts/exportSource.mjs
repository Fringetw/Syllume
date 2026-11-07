import fs from 'node:fs';
import path from 'node:path';
import { zipSync } from 'fflate';
import { root, readManifest } from './paths.mjs';

// Reproducible source update archive, separate from the installable mod ZIP.
const manifest = readManifest();
const skip = new Set(['.git', 'node_modules', '.test-host', 'dist', 'test-results', 'coverage', '.vite', '.env', '.dev-credentials', '.DS_Store']);
const files = {};
const mtime = new Date(2020, 0, 1, 0, 0, 0);
function collect(folder, relative = '') {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
        if (skip.has(entry.name) || entry.name.startsWith('.env.') || entry.name.endsWith('.log')) continue;
        if (entry.isSymbolicLink()) throw new Error(`Source archive cannot include symlink: ${entry.name}`);
        const name = relative + entry.name;
        if (entry.isDirectory()) collect(path.join(folder, entry.name), name + '/');
        else if (entry.isFile()) files['folia-traditional-chinese/' + name] = [fs.readFileSync(path.join(folder, entry.name)), { mtime }];
    }
}
collect(root);
fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
const name = `folia-traditional-chinese-${manifest.version}-update.zip`;
fs.writeFileSync(path.join(root, 'dist', name), zipSync(files, { level: 9 }));
console.log(`Built ${name} (${Object.keys(files).length} source files)`);
