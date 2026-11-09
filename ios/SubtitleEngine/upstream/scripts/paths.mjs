import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Shared repository paths; the host stays outside the distributed plugin.
export const root = fileURLToPath(new URL('../', import.meta.url));
export const modDirectory = path.join(root, 'mods/opencc-traditional-lyrics');

export function hostDirectory() {
    const host = path.resolve(root, process.env.FOLIA_SOURCE_ROOT || '.test-host/folia-major');
    for (const file of ['package.json', 'src/mods/folium/dto.ts', 'electron/modSystem/zipInstall.cjs']) {
        if (!fs.existsSync(path.join(host, file))) {
            throw new Error('找不到 Folia 原始碼。請先依 DEVELOPMENT.md 下載 .test-host/folia-major，或設定 FOLIA_SOURCE_ROOT。');
        }
    }
    return host;
}

export function readManifest() {
    const manifest = JSON.parse(fs.readFileSync(path.join(modDirectory, 'mod.json'), 'utf8'));
    const project = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
    if (manifest.id !== 'opencc-traditional-lyrics' || !/^\d+\.\d+\.\d+$/.test(manifest.version)) {
        throw new Error('模組 id 或版本格式不正確。');
    }
    if (manifest.version !== project.version) throw new Error('package.json 與 mod.json 的版本不一致。');
    return manifest;
}
