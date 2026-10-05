import assert from "node:assert/strict";
import { test } from "node:test";
import { findSplitData, runToEnd, splitAround } from "../src/layout.ts";

function box(kind: string, size: number): Uint8Array {
  const out = new Uint8Array(size);
  new DataView(out.buffer).setUint32(0, size);
  for (let i = 0; i < 4; i++) out[4 + i] = kind.charCodeAt(i);
  return out;
}

function file(...boxes: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(boxes.reduce((n, b) => n + b.byteLength, 0));
  let at = 0;
  for (const b of boxes) {
    out.set(b, at);
    at += b.byteLength;
  }
  return out;
}

const reader = (bytes: Uint8Array) => async (offset: number, length: number) => bytes.subarray(offset, offset + length);

test("index first with many data blocks: the first block is found", async () => {
  const f = file(box("ftyp", 24), box("moov", 100), box("mdat", 40), box("mdat", 30), box("mdat", 50));
  assert.equal(await findSplitData(reader(f), f.byteLength), 124);
});

test("already one data block: nothing to do", async () => {
  const f = file(box("ftyp", 32), box("moov", 100), box("free", 8), box("mdat", 500));
  assert.equal(await findSplitData(reader(f), f.byteLength), -1);
});

test("one data block followed by something else: nothing to do", async () => {
  const f = file(box("ftyp", 32), box("moov", 100), box("mdat", 500), box("free", 16));
  assert.equal(await findSplitData(reader(f), f.byteLength), -1);
});

test("index after the data: left alone", async () => {
  const f = file(box("ftyp", 24), box("mdat", 40), box("mdat", 40), box("moov", 100));
  assert.equal(await findSplitData(reader(f), f.byteLength), -1);
});

test("not a film file: left alone", async () => {
  const junk = new Uint8Array(64);
  assert.equal(await findSplitData(reader(junk), junk.byteLength), -1);
});

test("the relabelled block runs to the end of the file", () => {
  assert.deepEqual([...runToEnd(124, 244)], [0, 0, 0, 120]);
  assert.deepEqual([...runToEnd(5849744, 4083204988)], [0xf3, 0x07, 0x80, 0xec]);
  assert.deepEqual([...runToEnd(100, 6 * 2 ** 30)], [0, 0, 0, 0]);
});

test("a request is cut around the replaced bytes", () => {
  const patch = new Uint8Array([1, 2, 3, 4]);
  assert.deepEqual(splitAround(0, 100, 200, patch), [{ from: 0, to: 100 }]);
  assert.deepEqual(splitAround(204, 50, 200, patch), [{ from: 204, to: 254 }]);
  assert.deepEqual(splitAround(0, 1000, 200, patch), [{ from: 0, to: 200 }, { bytes: patch }, { from: 204, to: 1000 }]);
  assert.deepEqual(splitAround(202, 10, 200, patch), [{ bytes: patch.subarray(2, 4) }, { from: 204, to: 212 }]);
  assert.deepEqual(splitAround(190, 12, 200, patch), [{ from: 190, to: 200 }, { bytes: patch.subarray(0, 2) }]);
  assert.deepEqual(splitAround(200, 4, 200, patch), [{ bytes: patch }]);
});
