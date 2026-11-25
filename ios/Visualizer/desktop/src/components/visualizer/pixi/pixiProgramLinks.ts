import type { Container, GlProgram, GlProgramData, Renderer, Shader, WebGLRenderer } from 'pixi.js';

// src/components/visualizer/pixi/pixiProgramLinks.ts
// Links the shader programs of a Pixi style's first frame before that frame is drawn, all at once
// and without holding the page. Pixi links a program the first time it draws with it and at once
// asks whether the link worked; the answer waits for the GPU process. A program whose vertex source
// is not GLSL ES 3.00 it then links a second time, its attributes bound in name order, and the next
// question waits for that link too. So the first frame of 商籁, 凝彩 and 绘光 held the main thread for
// each of their programs in turn, twice: 32 to 52 ms a start on a fast PC, 55 to 190 ms on four slow
// cores, and 850 ms there the first time 绘光 was drawn (its light field compiles for hundreds of ms).
// Here every program the stage is seen to draw with is handed to the GPU process together, its
// attributes already bound as Pixi binds them, the page goes on while they link side by side
// (KHR_parallel_shader_compile), and each is given to the renderer once linked, as Pixi would have
// made it. A program the walk does not see is linked by Pixi when it draws, as before.
type PixiModule = typeof import('pixi.js');

/** KHR_parallel_shader_compile: whether a link has finished, asked without waiting for it. */
const COMPLETION_STATUS_KHR = 0x91b1;
/** How often the links are looked at. */
const LOOK_EVERY_MS = 10;
/** How long one look may hand linked programs to the renderer: each takes a few answers from the GPU process. */
const HAND_OVER_MS = 4;
/** The optional warmup must leave time to draw the first frame. */
const WARMUP_BUDGET_MS = 1500;
/** The attributes a vertex source declares (GLSL ES 1.00 `attribute`, 3.00 `in`). */
const DECLARED_ATTRIBUTE = /^[ \t]*(?:attribute|in)[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?\w+[ \t]+(\w+)[ \t]*;/gm;

/** The renderer's cache of linked programs (GlShaderSystem), by program key. */
interface ShaderSystemInternals {
    _programDataHash: Record<number, GlProgramData | undefined>;
}

interface PendingLink {
    program: GlProgram;
    webGLProgram: WebGLProgram;
    vertex: WebGLShader;
    fragment: WebGLShader;
    /** Bound again in name order and linked again (attributesInNameOrder). */
    rebound: boolean;
}

/**
 * The programs `stage` draws with that can be seen before it is drawn: each filter's, and those of
 * the passes a filter keeps as fields (Pixi's blur, 绘光's bloom); a mesh's shader; the shader of
 * Graphics; the back buffer's, where the renderer uses one; and the batch program text and sprites
 * draw with.
 */
const programsOf = (pixi: PixiModule, renderer: WebGLRenderer, stage: Container): GlProgram[] => {
    const found = new Map<number, GlProgram>();
    const add = (shader: Shader | null | undefined) => {
        const program = shader?.glProgram;
        if (program && !found.has(program._key)) found.set(program._key, program);
    };
    const batch = new pixi.DefaultBatcher({ maxTextures: renderer.limits.maxBatchableTextures }).shader;
    const walk = (node: Container) => {
        // renderFrame has selected the visible shot, but Pixi hasn't propagated global flags yet.
        // Check each ancestor's local flags so an inactive shot excludes all its descendants.
        if (node.localDisplayStatus < 7 || !node.includeInBuild) return;
        if (node instanceof pixi.Mesh) add(node.shader);
        if (node instanceof pixi.Graphics) {
            const pipe = renderer.renderPipes.graphics as unknown as { _adaptor: { shader: Shader } };
            add(node.context.customShader ?? pipe._adaptor.shader);
        }
        if (node instanceof pixi.Sprite || node instanceof pixi.Text) add(batch);
        node.children.forEach(walk);
        // FilterPipe composites on pop, after drawing the container's contents. FilterSystem
        // skips disabled filters altogether, including any blur/bloom passes they own.
        for (const filter of node.filters ?? []) {
            if (!filter.enabled) continue;
            add(filter);
            for (const field of Object.values(filter)) {
                for (const value of Array.isArray(field) ? field : [field]) {
                    if (value instanceof pixi.Shader) add(value);
                }
            }
        }
    };
    walk(stage);
    // The batch program is one for the page, made with its first batcher: a batcher made here makes it,
    // or hands back the one there is. Left to the first draw, its link was waited for behind every draw
    // queued before it.
    add(batch);
    if (renderer.backBuffer.useBackBuffer) add((renderer.backBuffer as unknown as { _bigTriangleShader: Shader })._bigTriangleShader);
    return [...found.values()];
};

/** Pixi binds the attributes of these in name order and links again (generateProgram, extractAttributesFromGlProgram). */
const bindsAttributesInNameOrder = (program: GlProgram) => !/^[ \t]*#[ \t]*version[ \t]+300[ \t]+es[ \t]*$/m.test(program.vertex ?? '');

const byName = (a: string, b: string) => (a > b ? 1 : -1);

/**
 * For a program Pixi binds in name order: whether its active attributes are where Pixi puts them
 * (0, 1, ... in name order). The binding before the link put the declared ones there; an attribute
 * declared but unused can shift them, and the program is then bound again and linked again.
 */
const attributesInNameOrder = (gl: WebGL2RenderingContext, webGLProgram: WebGLProgram): boolean => {
    const names: string[] = [];
    const count = gl.getProgramParameter(webGLProgram, gl.ACTIVE_ATTRIBUTES) as number;
    for (let index = 0; index < count; index += 1) {
        const name = gl.getActiveAttrib(webGLProgram, index)?.name;
        if (name && !name.startsWith('gl_')) names.push(name);
    }
    names.sort(byName);
    if (names.every((name, location) => gl.getAttribLocation(webGLProgram, name) === location)) return true;
    names.forEach((name, location) => gl.bindAttribLocation(webGLProgram, location, name));
    gl.linkProgram(webGLProgram);
    return false;
};

/**
 * What Pixi's generateProgram does once a link has finished. The attributes are read where they are
 * bound: for a program Pixi binds in name order that is where its second link would have put them.
 */
const handOver = (pixi: PixiModule, gl: WebGL2RenderingContext, { program, webGLProgram, vertex, fragment }: PendingLink): GlProgramData => {
    if (!gl.getProgramParameter(webGLProgram, gl.LINK_STATUS)) {
        pixi.logProgramError(gl, webGLProgram, vertex, fragment);
    }
    program._attributeData = pixi.extractAttributesFromGlProgram(webGLProgram, gl, false);
    program._uniformData = pixi.getUniformData(webGLProgram, gl);
    program._uniformBlockData = pixi.getUboData(webGLProgram, gl);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    const uniformData: GlProgramData['uniformData'] = {};
    for (const name in program._uniformData) {
        const data = program._uniformData[name];
        uniformData[name] = {
            location: gl.getUniformLocation(webGLProgram, name),
            value: pixi.defaultValue(data.type, data.size),
        };
    }
    return new pixi.GlProgramData(webGLProgram, uniformData);
};

/**
 * Warms the programs that the next draw of `stage` is expected to use. An unsupported extension
 * or an expired budget leaves the unfinished programs for Pixi's normal first-draw linker.
 */
export const linkPixiPrograms = async (
    pixi: PixiModule,
    renderer: Renderer,
    stage: Container,
    label: string,
    signal?: AbortSignal,
    maxWaitMs = WARMUP_BUDGET_MS,
    startupCheckpoint?: (phase: string) => void,
): Promise<boolean> => {
    // The shader system's cache is reached into, and generateProgram's steps are repeated: both as
    // this version has them.
    if (signal?.aborted || (pixi.VERSION as string) !== '8.21.0' || renderer.type !== pixi.RendererType.WEBGL) return false;
    const webgl = renderer as WebGLRenderer;
    const gl = webgl.gl;
    startupCheckpoint?.('shader-extension');
    if (!gl.getExtension('KHR_parallel_shader_compile')) {
        console.info(`[PixiPrograms] ${label}: no parallel shader linking here; programs link on first draw`);
        return false;
    }
    const linked = (webgl.shader as unknown as ShaderSystemInternals)._programDataHash;
    const started = performance.now();
    const deadline = started + maxWaitMs;
    const pending: PendingLink[] = [];
    try {
        startupCheckpoint?.('shader-candidates');
        for (const program of programsOf(pixi, webgl, stage)) {
            if (linked[program._key] || program.transformFeedbackVaryings) continue;
            if (performance.now() >= deadline) return false;
            const vertex = pixi.compileShader(gl, gl.VERTEX_SHADER, program.vertex ?? '');
            const fragment = pixi.compileShader(gl, gl.FRAGMENT_SHADER, program.fragment ?? '');
            const webGLProgram = gl.createProgram();
            pending.push({ program, webGLProgram, vertex, fragment, rebound: false });
            gl.attachShader(webGLProgram, vertex);
            gl.attachShader(webGLProgram, fragment);
            if (bindsAttributesInNameOrder(program)) {
                const declared = [...(program.vertex ?? '').matchAll(DECLARED_ATTRIBUTE)].map(match => match[1]).sort(byName);
                declared.forEach((name, location) => gl.bindAttribLocation(webGLProgram, location, name));
            }
            gl.linkProgram(webGLProgram);
        }
        const count = pending.length;
        if (count > 0) startupCheckpoint?.('shader-polling');
        while (pending.length > 0) {
            await new Promise((resolve) => { window.setTimeout(resolve, LOOK_EVERY_MS); });
            if (signal?.aborted || gl.isContextLost() || performance.now() >= deadline) return false;
            // Parallel links can finish out of order. Check each at most once per poll, rotating
            // unfinished work so an earlier slow program cannot hide a later completed one.
            const look = performance.now();
            let checksRemaining = pending.length;
            while (checksRemaining > 0 && pending.length > 0 && performance.now() - look < HAND_OVER_MS) {
                checksRemaining -= 1;
                const next = pending[0];
                if (!gl.getProgramParameter(next.webGLProgram, COMPLETION_STATUS_KHR)) {
                    pending.shift();
                    pending.push(next);
                    continue;
                }
                if (!next.rebound && bindsAttributesInNameOrder(next.program) && !attributesInNameOrder(gl, next.webGLProgram)) {
                    next.rebound = true;
                    pending.shift();
                    pending.push(next);
                    continue;
                }
                linked[next.program._key] = handOver(pixi, gl, next);
                pending.shift();
            }
        }
        if (count > 0) console.info(`[PixiPrograms] ${label}: ${count} programs linked side by side in ${Math.round(performance.now() - started)} ms`);
        return true;
    } finally {
        for (const { webGLProgram, vertex, fragment } of pending) {
            gl.deleteProgram(webGLProgram);
            gl.deleteShader(vertex);
            gl.deleteShader(fragment);
        }
    }
};
