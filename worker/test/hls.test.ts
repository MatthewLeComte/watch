import assert from "node:assert/strict";
import test from "node:test";
import { muxSegment, planSegments, playlist, segmentSpan, shiftPlan } from "../src/hls.ts";

function u32(n: number): number[] {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
}

function box(type: string, body: number[]): number[] {
  const size = 8 + body.length;
  return [...u32(size), ...type.split("").map((c) => c.charCodeAt(0)), ...body];
}

function fullBox(type: string, body: number[]): number[] {
  return box(type, [0, 0, 0, 0, ...body]);
}

test("two keyframes become two mpeg-ts segments", () => {
  const nal = (type: number) => [0, 0, 0, 4, type, 1, 2, 3];
  const samples = [...nal(5), ...nal(1)];
  const avcC = box("avcC", [
    1, 0x64, 0, 0x1f, 0xff, 0xe1, 0x00, 0x02, 0x67, 0x64, 1, 0x00, 0x01, 0x68, 0xce,
  ]);
  const stsd = fullBox("stsd", [
    0, 0, 0, 1,
    ...box("avc1", [
      0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0x05, 0x00, 0x02, 0xd0,
      0, 0x48, 0, 0, 0, 0x48, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x18, 0xff, 0xff,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ...avcC,
    ]),
  ]);
  const stts = fullBox("stts", [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 24]);
  const stsc = fullBox("stsc", [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1]);
  const stsz = fullBox("stsz", [0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 8, 0, 0, 0, 8]);
  const stco = fullBox("stco", [0, 0, 0, 1, 0, 0, 0, 0]);
  const stss = fullBox("stss", [0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2]);
  const stbl = box("stbl", [...stsd, ...stts, ...stsc, ...stsz, ...stco, ...stss]);
  const vmhd = fullBox("vmhd", [0, 0, 0, 0]);
  const dinf = box("dinf", fullBox("dref", [0, 0, 0, 1, ...box("url ", [])]));
  const minf = box("minf", [...vmhd, ...dinf, ...stbl]);
  const mdhd = fullBox("mdhd", [...u32(0), ...u32(0), ...u32(24), ...u32(48), 0x55, 0xc4, 0, 0]);
  const hdlr = fullBox("hdlr", [...u32(0), ..."vide".split("").map((c) => c.charCodeAt(0)), 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  const mdia = box("mdia", [...mdhd, ...hdlr, ...minf]);
  const tkhd = fullBox("tkhd", [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, ...u32(48)]);
  const trak = box("trak", [...tkhd, ...mdia]);
  const mvhd = fullBox("mvhd", [...u32(0), ...u32(0), ...u32(24), ...u32(48)]);
  const moov = box("moov", [...mvhd, ...trak]);
  const ftyp = box("ftyp", [..."isom".split("").map((c) => c.charCodeAt(0)), ...u32(0), ..."isom".split("").map((c) => c.charCodeAt(0))]);
  const mdatBody = samples;
  const mdat = box("mdat", mdatBody);
  const file = new Uint8Array([...ftyp, ...moov, ...mdat]);
  const mdatAt = ftyp.length + moov.length + 8;
  const stcoAt = file.indexOf(0) ; void stcoAt;
  // patch the chunk offset to the mdat payload
  const view = new DataView(file.buffer);
  const co = file.findIndex((_, i) => String.fromCharCode(file[i]!, file[i + 1]!, file[i + 2]!, file[i + 3]!) === "stco");
  view.setUint32(co + 12, mdatAt);

  const plans = planSegments(file);
  assert.equal(plans.length, 2);
  assert.equal(plans[0]!.sps.length, 1);
  assert.ok(plans[0]!.duration > 0.9 && plans[0]!.duration < 1.1);
  const text = playlist(plans, (n) => `seg/${n}.ts?key=k`);
  assert.match(text, /#EXT-X-PLAYLIST-TYPE:VOD/);
  assert.match(text, /seg\/1\.ts\?key=k/);
  const span = segmentSpan(plans[0]!);
  assert.ok(span);
  const ts = muxSegment(file, shiftPlan(plans[0]!, 0));
  assert.equal(ts.length % 188, 0);
  assert.equal(ts[0], 0x47);
  for (let i = 0; i < ts.length; i += 188) assert.equal(ts[i], 0x47);
  assert.ok(ts.includes(0x67));
});
