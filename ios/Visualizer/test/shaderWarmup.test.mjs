import test from 'node:test';
import assert from 'node:assert/strict';
import { linkPixiPrograms } from '../desktop/src/components/visualizer/pixi/pixiProgramLinks.ts';

const completionStatus = 0x91b1;

function shaderFixture(t, { complete = () => false, supportsParallel = true } = {}) {
    let elapsed = 0;
    const timers = [];
    t.mock.method(performance, 'now', () => elapsed);
    t.mock.method(console, 'info', () => {});
    globalThis.window = { setTimeout: (run, delay) => timers.push({ run, delay }) };
    t.after(() => { delete globalThis.window; });

    class Shader {
        constructor(key) { this.glProgram = { _key: key, vertex: '#version 300 es\n', fragment: '' }; }
    }
    class GlProgramData {
        constructor(program) { this.program = program; }
    }

    const allocatedPrograms = [], allocatedShaders = [], deletedPrograms = [], deletedShaders = [], linkChecks = [];
    const gl = {
        VERTEX_SHADER: 0x8b31, FRAGMENT_SHADER: 0x8b30, LINK_STATUS: 0x8b82,
        getExtension: name => supportsParallel && name === 'KHR_parallel_shader_compile',
        createProgram() {
            const program = { id: allocatedPrograms.length };
            allocatedPrograms.push(program);
            return program;
        },
        attachShader() {},
        linkProgram() {},
        deleteProgram: program => deletedPrograms.push(program),
        deleteShader: shader => deletedShaders.push(shader),
        getProgramParameter(program, parameter) {
            if (parameter === completionStatus) return complete(program);
            assert.equal(parameter, gl.LINK_STATUS);
            linkChecks.push(program);
            return true;
        },
        isContextLost: () => false,
    };
    const pixi = {
        VERSION: '8.21.0', RendererType: { WEBGL: 1 }, Shader, Mesh: class {}, Graphics: class {}, GlProgramData,
        DefaultBatcher: class { shader = new Shader(2); },
        compileShader(_gl, type) {
            const shader = { type, id: allocatedShaders.length };
            allocatedShaders.push(shader);
            return shader;
        },
        extractAttributesFromGlProgram: () => ({}), getUniformData: () => ({}), getUboData: () => ({}),
    };
    const previous = {};
    const cache = { 3: previous };
    const renderer = { type: 1, gl, shader: { _programDataHash: cache }, limits: { maxBatchableTextures: 8 }, backBuffer: {} };
    const stage = { children: [], filters: [new Shader(1), new Shader(3)] };

    async function finish(promise) {
        let settled = false;
        const markSettled = () => { settled = true; };
        promise.then(markSettled, markSettled);
        for (let turns = 0; !settled && turns < 10; turns++) {
            const timer = timers.shift();
            if (timer) {
                elapsed += timer.delay;
                timer.run();
            }
            await Promise.resolve();
        }
        assert.ok(settled, 'The link operation should settle within the scripted clock budget');
        return promise;
    }

    return { pixi, renderer, stage, cache, previous, allocatedPrograms, allocatedShaders, deletedPrograms, deletedShaders,
        linkChecks, finish };
}

test('timed-out shader warmup deletes pending GL resources and preserves valid cache entries', async t => {
    const gl = shaderFixture(t, { complete: program => program.id === 0 });
    assert.equal(await gl.finish(linkPixiPrograms(gl.pixi, gl.renderer, gl.stage, 'test', undefined, 25)), false);

    const [ready, stalled] = gl.allocatedPrograms;
    assert.equal(gl.allocatedPrograms.length, 2);
    assert.equal(gl.allocatedShaders.length, 4);
    assert.deepEqual(gl.deletedPrograms, [stalled]);
    assert.deepEqual(gl.deletedShaders, gl.allocatedShaders);
    assert.deepEqual(gl.linkChecks, [ready]);
    assert.equal(gl.cache[1].program, ready);
    assert.equal(gl.cache[2], undefined);
    assert.equal(gl.cache[3], gl.previous);
});

test('completed shader warmup caches linked programs and keeps their GL programs alive', async t => {
    const gl = shaderFixture(t, { complete: () => true });
    assert.equal(await gl.finish(linkPixiPrograms(gl.pixi, gl.renderer, gl.stage, 'test', undefined, 25)), true);
    assert.deepEqual(gl.deletedPrograms, []);
    assert.deepEqual(gl.deletedShaders, gl.allocatedShaders);
    assert.deepEqual([gl.cache[1].program, gl.cache[2].program], gl.allocatedPrograms);
    assert.equal(gl.cache[3], gl.previous);
});

test('shader warmup hands off a completed link behind an unfinished earlier program', async t => {
    const gl = shaderFixture(t, { complete: program => program.id === 1 });
    assert.equal(await gl.finish(linkPixiPrograms(gl.pixi, gl.renderer, gl.stage, 'test', undefined, 25)), false);

    const [stalled, ready] = gl.allocatedPrograms;
    assert.equal(gl.cache[2]?.program, ready);
    assert.equal(gl.cache[1], undefined);
    assert.equal(gl.cache[3], gl.previous);
    assert.deepEqual(gl.linkChecks, [ready]);
    assert.deepEqual(gl.deletedPrograms, [stalled]);
    assert.deepEqual(new Set(gl.deletedShaders), new Set(gl.allocatedShaders));
});

test('a throwing link poll releases every unfinished program after queue rotation', async t => {
    const failure = new Error('completion poll failed');
    const gl = shaderFixture(t, { complete: program => {
        if (program.id === 1) throw failure;
        return false;
    } });
    await assert.rejects(gl.finish(linkPixiPrograms(gl.pixi, gl.renderer, gl.stage, 'test', undefined, 25)),
        error => error === failure);

    assert.deepEqual(new Set(gl.deletedPrograms), new Set(gl.allocatedPrograms));
    assert.equal(gl.deletedPrograms.length, gl.allocatedPrograms.length);
    assert.deepEqual(new Set(gl.deletedShaders), new Set(gl.allocatedShaders));
    assert.equal(gl.deletedShaders.length, gl.allocatedShaders.length);
    assert.deepEqual(gl.linkChecks, []);
    assert.deepEqual(gl.cache, { 3: gl.previous });
});

test('cancelling shader warmup releases every unfinished link', async t => {
    const gl = shaderFixture(t);
    const abort = new AbortController();
    const links = linkPixiPrograms(gl.pixi, gl.renderer, gl.stage, 'test', abort.signal, 200);
    assert.equal(gl.allocatedPrograms.length, 2);
    abort.abort();

    assert.equal(await gl.finish(links), false);
    assert.deepEqual(gl.deletedPrograms, gl.allocatedPrograms);
    assert.deepEqual(gl.deletedShaders, gl.allocatedShaders);
    assert.deepEqual(gl.linkChecks, []);
    assert.deepEqual(gl.cache, { 3: gl.previous });
});

test('shader warmup without the extension leaves linking to the ordinary first draw', async t => {
    const gl = shaderFixture(t, { supportsParallel: false });
    assert.equal(await gl.finish(linkPixiPrograms(gl.pixi, gl.renderer, gl.stage, 'test')), false);
    assert.deepEqual(gl.allocatedPrograms, []);
    assert.deepEqual(gl.allocatedShaders, []);
    assert.deepEqual(gl.cache, { 3: gl.previous });
});
