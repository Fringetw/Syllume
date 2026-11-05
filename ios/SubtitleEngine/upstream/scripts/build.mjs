import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { zipSync } from 'fflate';
import { modDirectory, readManifest, root } from './paths.mjs';

// Build a complete unsigned installation ZIP and its checksum from this exact source tree.
const manifest = readManifest();
if (!manifest.preview) throw new Error('mod.json 缺少 preview。');
for (const file of [manifest.client, manifest.preview]) {
    if (typeof file !== 'string' || path.isAbsolute(file) || file.split(/[\\/]/).includes('..')) {
        throw new Error('入口或預覽圖路徑不正確。');
    }
    if (!fs.statSync(path.join(modDirectory, file)).isFile()) throw new Error(`找不到 ${file}`);
}
if (fs.statSync(path.join(modDirectory, manifest.preview)).size > 1048576) {
    throw new Error('預覽圖超過 1 MiB。');
}

const files = {};
const fixedTime = new Date(2020, 0, 1, 0, 0, 0);
function collect(directory, relative = '') {
    const entries = fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, 'en'));
    for (const entry of entries) {
        if (entry.isSymbolicLink()) throw new Error('模組不得包含符號連結。');
        if (entry.name.startsWith('.') || entry.name === 'node_modules') throw new Error(`模組內含非發布內容：${entry.name}`);
        const name = relative + entry.name;
        if (entry.isDirectory()) collect(path.join(directory, entry.name), name + '/');
        else if (entry.isFile()) {
            if (entry.name === 'folium.sig.json') throw new Error('請勿將既有簽章混入新版本；本腳本只產生未簽章的送審包。');
            files[manifest.id + '/' + name] = [fs.readFileSync(path.join(directory, entry.name)), { mtime: fixedTime }];
        }
    }
}
collect(modDirectory);
const archive = zipSync(files, { level: 9 });
const output = path.join(root, 'dist');
fs.mkdirSync(output, { recursive: true });
const filename = `${manifest.id}-${manifest.version}.zip`;
fs.writeFileSync(path.join(output, filename), archive);
const digest = createHash('sha256').update(archive).digest('hex');
fs.writeFileSync(path.join(output, 'SHA256SUMS.txt'), `${digest}  ${filename}\n`);
console.log(`Built ${filename} (${archive.length} bytes, unsigned)`);
