import test from 'node:test';
import assert from 'node:assert/strict';
import { buildLineGraphemeTimeline } from '../desktop/src/utils/lyrics/graphemeTiming.ts';

test('line-only rows preserve every glyph and share the known line window', () => {
    const line = { startTime: 3, endTime: 9, fullText: 'ABCD', words: [] };
    assert.deepEqual(buildLineGraphemeTimeline(line), [...line.fullText].map(char => ({
        char, startTime: 3, endTime: 9,
    })));
    assert.deepEqual(line.words, [], 'Rendering must not add word timestamps to the source');
});

test('line-only layout retains combined emoji, accents, spaces and punctuation', () => {
    const glyphs = ['霧', ' ', '👩🏽‍🚀', ' ', 'e\u0301', '，', 'か', 'な', '！'];
    const line = { startTime: 0.125, endTime: 6.875, fullText: glyphs.join(''), words: [] };
    const timeline = buildLineGraphemeTimeline(line);
    assert.deepEqual(timeline.map(item => item.char), glyphs);
    assert.equal(timeline.map(item => item.char).join(''), line.fullText);
    assert.ok(timeline.every(item => item.startTime === line.startTime && item.endTime === line.endTime));
    assert.ok(timeline.every(item => item.wordIndex === undefined));
    assert.deepEqual(buildLineGraphemeTimeline({ ...line, fullText: '' }), []);
});

test('real word timing and its gaps retain their existing mapping', () => {
    const line = { startTime: 0, endTime: 4, fullText: 'A B！', words: [
        { text: 'A', startTime: 1, endTime: 1.5 },
        { text: 'B', startTime: 2, endTime: 3 },
    ] };
    const original = structuredClone(line);
    assert.deepEqual(buildLineGraphemeTimeline(line), [
        { char: 'A', startTime: 1, endTime: 1.5, wordIndex: 0 },
        { char: ' ', startTime: 2, endTime: 2 },
        { char: 'B', startTime: 2, endTime: 3, wordIndex: 1 },
        { char: '！', startTime: 3, endTime: 3 },
    ]);
    assert.deepEqual(line, original);
});

test('real syllable boundaries remain distinct within a timed word', () => {
    const line = { startTime: 10, endTime: 14, fullText: '唱歌', words: [
        { text: '唱歌', startTime: 10, endTime: 14, syllables: [
            { text: '唱', startTime: 10.25, endTime: 10.75 },
            { text: '歌', startTime: 12, endTime: 13.25 },
        ] },
    ] };
    assert.deepEqual(buildLineGraphemeTimeline(line), [
        { char: '唱', startTime: 10.25, endTime: 10.75, wordIndex: 0 },
        { char: '歌', startTime: 12, endTime: 13.25, wordIndex: 0 },
    ]);
});
