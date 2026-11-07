import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { hostDirectory, root } from './paths.mjs';

// Run the suite against an external host checkout; NODE_PATH lets its CJS installer find fflate.
const result = spawnSync(process.execPath, [
    path.join(root, 'node_modules/vitest/vitest.mjs'),
    'run', '--config', path.join(root, 'dev/folium/openccTests.config.mjs'),
], {
    cwd: root,
    stdio: 'inherit',
    env: {
        ...process.env,
        FOLIA_SOURCE_ROOT: hostDirectory(),
        NODE_PATH: [path.join(root, 'node_modules'), process.env.NODE_PATH].filter(Boolean).join(path.delimiter),
    },
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
