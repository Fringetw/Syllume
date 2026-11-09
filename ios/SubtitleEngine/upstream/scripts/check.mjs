import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { hostDirectory, modDirectory, readManifest } from './paths.mjs';

// Validate with Folia's own manifest and API checker, rather than duplicating its rules.
readManifest();
const host = hostDirectory();
const result = spawnSync(process.execPath, [path.join(host, 'dev/folium/check.mjs'), modDirectory], {
    cwd: host,
    stdio: 'inherit',
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
