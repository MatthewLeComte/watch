// Live HLS from a progressive MP4 already in R2. Segments are cut on the
// keyframes in the file and wrapped as MPEG-TS in the response. Nothing is
// re-encoded and nothing is stored beside the original object.

export type Sample = { offset: number; size: number; dts: number; pts: number };
export type SegmentPlan = {
  duration: number;
  videoScale: number;
  audioScale: number;
  video: Sample[];
  audio: Sample[];
  sps: Uint8Array[];
  pps: Uint8Array[];
  lengthSize: number;
  audioConfig: Uint8Array;
};

type Track = {
  kind: "vide" | "soun";
  samples: Sample[];
  sync: number[];
  timescale: number;
  sps: Uint8Array[];
  pps: Uint8Array[];
  lengthSize: number;
  audioConfig: Uint8Array;
};

const TS = 188;

export function planSegments(mp4: Uint8Array): SegmentPlan[] {
  const tracks = parseTracks(mp4);
  const video = tracks.find((t) => t.kind === "vide");
  const audio = tracks.find((t) => t.kind === "soun");
  if (!video || video.samples.length === 0 || video.timescale <= 0) return [];
  const starts = segmentStarts(video);
  const plans: SegmentPlan[] = [];
  const audioSamples = audio?.samples ?? [];
  const audioScale = audio?.timescale || video.timescale;
  let ai = 0;
  for (let s = 0; s < starts.length; s++) {
    const from = starts[s]!;
    const to = s + 1 < starts.length ? starts[s + 1]! : video.samples.length;
    const v = video.samples.slice(from, to);
    if (v.length === 0) continue;
    const t0 = v[0]!.dts / video.timescale;
    const next = video.samples[to];
    const last = v[v.length - 1]!;
    const prev = v.length > 1 ? v[v.length - 2]! : null;
    const lastDur = next ? next.dts - last.dts : prev ? last.dts - prev.dts : Math.round(video.timescale / 24);
    const t1 = (last.dts + lastDur) / video.timescale;
    while (ai < audioSamples.length && audioSamples[ai]!.dts / audioScale < t0 - 0.001) ai++;
    const a: Sample[] = [];
    let aj = ai;
    while (aj < audioSamples.length && audioSamples[aj]!.dts / audioScale < t1 - 0.001) {
      a.push(audioSamples[aj]!);
      aj++;
    }
    ai = aj;
    plans.push({
      duration: Math.max(0.001, t1 - t0),
      videoScale: video.timescale,
      audioScale: audio?.timescale || video.timescale,
      video: v,
      audio: a,
      sps: video.sps,
      pps: video.pps,
      lengthSize: video.lengthSize,
      audioConfig: audio?.audioConfig ?? new Uint8Array(),
    });
  }
  return plans;
}

// A missing or per-frame sync table used to emit one segment per sample.
// That allocated until the isolate hit the memory limit on index.m3u8.
const MAX_SEGMENTS = 4000;
const MIN_GAP_SEC = 2;

function segmentStarts(video: Track): number[] {
  const sync = video.sync;
  if (sync.length > 0 && sync.length <= MAX_SEGMENTS) return sync;
  const scale = video.timescale;
  const samples = video.samples;
  const marks = sync.length > 0 ? sync : null;
  const n = marks ? marks.length : samples.length;
  const first = samples[marks ? marks[0]! : 0];
  const lastIdx = marks ? marks[n - 1]! : n - 1;
  const last = samples[lastIdx];
  const dur = first && last ? Math.max(0, (last.dts - first.dts) / scale) : 0;
  const gap = Math.max(MIN_GAP_SEC, dur / MAX_SEGMENTS);
  const starts: number[] = [];
  let lastT = -1e9;
  for (let i = 0; i < n; i++) {
    const idx = marks ? marks[i]! : i;
    const sample = samples[idx];
    if (!sample) continue;
    const t = sample.dts / scale;
    if (starts.length === 0 || t - lastT >= gap) {
      starts.push(idx);
      lastT = t;
    }
  }
  return starts;
}

export function playlist(plans: SegmentPlan[], segmentUrl: (n: number) => string): string {
  const max = Math.max(1, ...plans.map((p) => Math.ceil(p.duration)));
  const lines = [
    "#EXTM3U",
    "#EXT-X-VERSION:3",
    `#EXT-X-TARGETDURATION:${max}`,
    "#EXT-X-PLAYLIST-TYPE:VOD",
    "#EXT-X-MEDIA-SEQUENCE:0",
  ];
  plans.forEach((p, n) => {
    lines.push(`#EXTINF:${p.duration.toFixed(3)},`);
    lines.push(segmentUrl(n));
  });
  lines.push("#EXT-X-ENDLIST");
  return lines.join("\n") + "\n";
}

export function muxSegment(file: Uint8Array, plan: SegmentPlan): Uint8Array<ArrayBuffer> {
  const packets: Uint8Array[] = [];
  const cc = { pat: 0, pmt: 0, v: 0, a: 0 };
  const pcr = to90(plan.video[0]!.dts, plan.videoScale);
  packets.push(sectionPacket(0x0000, pat(), cc, "pat"));
  packets.push(sectionPacket(0x1000, pmt(), cc, "pmt", pcr));
  writePes(packets, 0x100, 0xe0, plan.video, file, cc, "v", true, plan, plan.videoScale);
  if (plan.audio.length > 0) writePes(packets, 0x101, 0xc0, plan.audio, file, cc, "a", false, plan, plan.audioScale);
  const out = new Uint8Array(packets.length * TS);
  packets.forEach((p, i) => out.set(p, i * TS));
  return out;
}

function to90(ticks: number, scale: number): number {
  if (scale <= 0) return 0;
  return Math.round((ticks / scale) * 90_000);
}

function writePes(
  packets: Uint8Array[],
  pid: number,
  streamId: number,
  samples: Sample[],
  file: Uint8Array,
  cc: { pat: number; pmt: number; v: number; a: number },
  which: "v" | "a",
  video: boolean,
  plan: SegmentPlan,
  scale: number,
) {
  for (const sample of samples) {
    const annex = video ? annexB(file, sample, plan) : adts(file, sample, plan.audioConfig);
    const pts = to90(sample.pts, scale);
    const dts = to90(sample.dts, scale);
    const pes = pesPacket(streamId, annex, pts, dts, video);
    let off = 0;
    let first = true;
    while (off < pes.length) {
      const pcr = first && video ? dts : undefined;
      const left = pes.length - off;
      const minAdapt = pcr !== undefined ? 8 : left < TS - 4 ? 2 : 0;
      const capacity = TS - 4 - minAdapt;
      const take = Math.min(capacity, left);
      const stuff = capacity - take;
      packets.push(payloadPacket(pid, pes.subarray(off, off + take), first, cc, which, stuff, pcr));
      off += take;
      first = false;
    }
  }
}

function annexB(file: Uint8Array, sample: Sample, plan: SegmentPlan): Uint8Array {
  const body = file.subarray(sample.offset, sample.offset + sample.size);
  const nals: Uint8Array[] = [];
  const ls = plan.lengthSize || 4;
  let o = 0;
  let idr = false;
  while (o + ls <= body.length) {
    let len = 0;
    for (let i = 0; i < ls; i++) len = (len << 8) | body[o + i]!;
    o += ls;
    if (len <= 0 || o + len > body.length) break;
    const nal = body.subarray(o, o + len);
    if ((nal[0]! & 0x1f) === 5) idr = true;
    nals.push(nal);
    o += len;
  }
  const start = new Uint8Array([0, 0, 0, 1]);
  const parts: Uint8Array[] = [];
  if (idr) {
    for (const s of plan.sps) parts.push(start, s);
    for (const p of plan.pps) parts.push(start, p);
  }
  for (const n of nals) parts.push(start, n);
  return concat(parts);
}

function adts(file: Uint8Array, sample: Sample, config: Uint8Array): Uint8Array {
  const raw = file.subarray(sample.offset, sample.offset + sample.size);
  const profile = config.length > 0 ? ((config[0]! >> 3) & 0x1f) : 2;
  const freq = config.length > 0 ? (((config[0]! & 7) << 1) | (config[1]! >> 7)) : 3;
  const channels = config.length > 1 ? ((config[1]! >> 3) & 0x0f) : 2;
  const full = raw.length + 7;
  const h = new Uint8Array(7);
  h[0] = 0xff;
  h[1] = 0xf1;
  h[2] = ((profile - 1) << 6) | ((freq & 0x0f) << 2) | ((channels >> 2) & 1);
  h[3] = ((channels & 3) << 6) | ((full >> 11) & 3);
  h[4] = (full >> 3) & 0xff;
  h[5] = ((full & 7) << 5) | 0x1f;
  h[6] = 0xfc;
  return concat([h, raw]);
}

function pesPacket(streamId: number, payload: Uint8Array, pts: number, dts: number, withDts: boolean): Uint8Array {
  const flags = withDts ? 0xc0 : 0x80;
  const hdrLen = withDts ? 10 : 5;
  const hdr = new Uint8Array(9 + hdrLen);
  hdr[0] = 0;
  hdr[1] = 0;
  hdr[2] = 1;
  hdr[3] = streamId;
  const len = withDts ? 0 : Math.min(0xffff, payload.length + 3 + hdrLen);
  hdr[4] = (len >> 8) & 0xff;
  hdr[5] = len & 0xff;
  hdr[6] = 0x80;
  hdr[7] = flags;
  hdr[8] = hdrLen;
  writeTs(hdr, 9, flags >> 6, pts);
  if (withDts) writeTs(hdr, 14, 1, dts);
  return concat([hdr, payload]);
}

function writeTs(out: Uint8Array, at: number, prefix: number, ts: number) {
  const v = Math.max(0, ts) % 0x200000000;
  out[at] = (prefix << 4) | (((v / 0x40000000) | 0) << 1) | 1;
  const top = Math.floor(v / 0x8000) & 0x7fff;
  out[at + 1] = (top >> 7) & 0xff;
  out[at + 2] = ((top << 1) & 0xff) | 1;
  const low = v & 0x7fff;
  out[at + 3] = (low >> 7) & 0xff;
  out[at + 4] = ((low << 1) & 0xff) | 1;
}

function pat(): Uint8Array {
  const s = section([
    0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00, 0x00, 0x01, 0xf0, 0x00,
  ]);
  return s;
}

function pmt(): Uint8Array {
  // program 1, pcr pid 0x100, video h264 0x1b pid 0x100, aac 0x0f pid 0x101
  return section([
    0x02, 0xb0, 0x17, 0x00, 0x01, 0xc1, 0x00, 0x00, 0xe1, 0x00, 0xf0, 0x00,
    0x1b, 0xe1, 0x00, 0xf0, 0x00,
    0x0f, 0xe1, 0x01, 0xf0, 0x00,
  ]);
}

function section(bodyNoCrc: number[]): Uint8Array {
  const body = new Uint8Array(bodyNoCrc);
  const crc = crc32(body);
  const out = new Uint8Array(body.length + 4);
  out.set(body);
  out[body.length] = (crc >>> 24) & 0xff;
  out[body.length + 1] = (crc >>> 16) & 0xff;
  out[body.length + 2] = (crc >>> 8) & 0xff;
  out[body.length + 3] = crc & 0xff;
  return out;
}

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (const b of data) {
    c ^= b << 24;
    for (let i = 0; i < 8; i++) c = (c & 0x80000000) !== 0 ? ((c << 1) ^ 0x04c11db7) : (c << 1);
    c >>>= 0;
  }
  return c >>> 0;
}

function sectionPacket(pid: number, sectionBytes: Uint8Array, cc: { pat: number; pmt: number }, which: "pat" | "pmt", pcr?: number): Uint8Array {
  const pointer = new Uint8Array(1 + sectionBytes.length);
  pointer.set(sectionBytes, 1);
  const minAdapt = pcr !== undefined ? 8 : pointer.length < TS - 4 ? 2 : 0;
  const capacity = TS - 4 - minAdapt;
  const take = Math.min(capacity, pointer.length);
  const stuff = capacity - take;
  return payloadPacket(pid, pointer.subarray(0, take), true, cc as { pat: number; pmt: number; v: number; a: number }, which, stuff, pcr);
}

function payloadPacket(
  pid: number,
  payload: Uint8Array,
  start: boolean,
  cc: { pat: number; pmt: number; v: number; a: number },
  which: "pat" | "pmt" | "v" | "a",
  stuff: number,
  pcr?: number,
): Uint8Array {
  const pkt = new Uint8Array(TS);
  pkt.fill(0xff);
  pkt[0] = 0x47;
  pkt[1] = ((start ? 0x40 : 0) | ((pid >> 8) & 0x1f)) & 0xff;
  pkt[2] = pid & 0xff;
  const n = cc[which] & 0x0f;
  cc[which] = (n + 1) & 0x0f;
  const hasAdapt = stuff > 0 || pcr !== undefined;
  pkt[3] = ((hasAdapt ? 0x30 : 0x10) | n) & 0xff;
  let i = 4;
  if (hasAdapt) {
    const pcrBytes = pcr !== undefined ? 6 : 0;
    const adaptLen = 1 + pcrBytes + stuff;
    pkt[i++] = adaptLen;
    pkt[i++] = pcr !== undefined ? 0x10 : 0x00;
    if (pcr !== undefined) {
      const p = Math.max(0, pcr);
      pkt[i++] = Math.floor(p / 0x2000000) & 0xff;
      pkt[i++] = Math.floor(p / 0x20000) & 0xff;
      pkt[i++] = Math.floor(p / 0x200) & 0xff;
      pkt[i++] = Math.floor(p / 2) & 0xff;
      pkt[i++] = ((p & 1) << 7) | 0x7e;
      pkt[i++] = 0x00;
    }
    i += stuff;
  }
  pkt.set(payload, i);
  return pkt;
}

function concat(parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

function parseTracks(mp4: Uint8Array): Track[] {
  const tracks: Track[] = [];
  const moov = findChild(mp4, 0, mp4.length, "moov");
  if (!moov) return tracks;
  for (const trak of children(mp4, moov.body, moov.end)) {
    if (trak.type !== "trak") continue;
    const mdia = findChild(mp4, trak.body, trak.end, "mdia");
    if (!mdia) continue;
    const hdlr = findChild(mp4, mdia.body, mdia.end, "hdlr");
    const kind = hdlr && ascii(mp4, hdlr.body + 8, 4) === "vide" ? "vide" : hdlr && ascii(mp4, hdlr.body + 8, 4) === "soun" ? "soun" : null;
    if (!kind) continue;
    const mdhd = findChild(mp4, mdia.body, mdia.end, "mdhd");
    const minf = findChild(mp4, mdia.body, mdia.end, "minf");
    const stbl = minf && findChild(mp4, minf.body, minf.end, "stbl");
    if (!mdhd || !stbl) continue;
    const ver = mp4[mdhd.body]!;
    const timescale = ver === 0 ? u32(mp4, mdhd.body + 12) : u32(mp4, mdhd.body + 20);
    const stts = findChild(mp4, stbl.body, stbl.end, "stts");
    const stsc = findChild(mp4, stbl.body, stbl.end, "stsc");
    const stsz = findChild(mp4, stbl.body, stbl.end, "stsz");
    const stco = findChild(mp4, stbl.body, stbl.end, "stco") || findChild(mp4, stbl.body, stbl.end, "co64");
    const stss = findChild(mp4, stbl.body, stbl.end, "stss");
    const ctts = findChild(mp4, stbl.body, stbl.end, "ctts");
    if (!stts || !stsc || !stsz || !stco) continue;
    const sizes = readSizes(mp4, stsz);
    if (sizes.length > 1_500_000) continue;
    const chunks = readChunks(mp4, stco);
    const sc = readStsc(mp4, stsc);
    const durations = readStts(mp4, stts);
    const offsets = place(sizes, chunks, sc);
    const cto = ctts ? readCtts(mp4, ctts) : [];
    const samples: Sample[] = [];
    let dts = 0;
    for (let i = 0; i < sizes.length; i++) {
      const pts = dts + (cto[i] ?? 0);
      samples.push({ offset: offsets[i] ?? 0, size: sizes[i] ?? 0, dts, pts });
      dts += durations[i] ?? durations[durations.length - 1] ?? 0;
    }
    const sync = stss ? readSync(mp4, stss).map((n) => n - 1).filter((n) => n >= 0 && n < samples.length) : [];
    const stsd = findChild(mp4, stbl.body, stbl.end, "stsd");
    const codec = stsd ? readCodec(mp4, stsd) : { sps: [], pps: [], lengthSize: 4, audioConfig: new Uint8Array() };
    tracks.push({ kind, samples, sync, timescale, ...codec });
  }
  return tracks;
}

function place(sizes: number[], chunks: number[], sc: { first: number; per: number }[]): number[] {
  const out: number[] = [];
  const perFor = (chunk: number) => {
    let per = sc[0]?.per ?? 1;
    for (const row of sc) if (row.first <= chunk) per = row.per;
    return per;
  };
  let sample = 0;
  for (let c = 0; c < chunks.length; c++) {
    let cursor = chunks[c]!;
    const per = perFor(c + 1);
    for (let s = 0; s < per && sample < sizes.length; s++) {
      out[sample] = cursor;
      cursor += sizes[sample] ?? 0;
      sample++;
    }
  }
  return out;
}

function readSizes(b: Uint8Array, box: Box): number[] {
  const sampleSize = u32(b, box.body + 4);
  const count = u32(b, box.body + 8);
  if (sampleSize > 0) return Array.from({ length: count }, () => sampleSize);
  const out: number[] = [];
  for (let i = 0; i < count; i++) out.push(u32(b, box.body + 12 + i * 4));
  return out;
}

function readChunks(b: Uint8Array, box: Box): number[] {
  const count = u32(b, box.body + 4);
  const wide = box.type === "co64";
  const out: number[] = [];
  for (let i = 0; i < count; i++) {
    out.push(wide ? Number(u64(b, box.body + 8 + i * 8)) : u32(b, box.body + 8 + i * 4));
  }
  return out;
}

function readStsc(b: Uint8Array, box: Box): { first: number; per: number }[] {
  const count = u32(b, box.body + 4);
  const out: { first: number; per: number }[] = [];
  for (let i = 0; i < count; i++) {
    out.push({ first: u32(b, box.body + 8 + i * 12), per: u32(b, box.body + 12 + i * 12) });
  }
  return out;
}

function readStts(b: Uint8Array, box: Box): number[] {
  const count = u32(b, box.body + 4);
  const out: number[] = [];
  let p = box.body + 8;
  for (let i = 0; i < count; i++) {
    const n = u32(b, p);
    const d = u32(b, p + 4);
    for (let k = 0; k < n; k++) out.push(d);
    p += 8;
  }
  return out;
}

function readCtts(b: Uint8Array, box: Box): number[] {
  const count = u32(b, box.body + 4);
  const out: number[] = [];
  let p = box.body + 8;
  for (let i = 0; i < count; i++) {
    const n = u32(b, p);
    const d = u32(b, p + 4);
    for (let k = 0; k < n; k++) out.push(d);
    p += 8;
  }
  return out;
}

function readSync(b: Uint8Array, box: Box): number[] {
  const count = u32(b, box.body + 4);
  const out: number[] = [];
  for (let i = 0; i < count; i++) out.push(u32(b, box.body + 8 + i * 4));
  return out;
}

function readCodec(b: Uint8Array, stsd: Box): { sps: Uint8Array[]; pps: Uint8Array[]; lengthSize: number; audioConfig: Uint8Array } {
  const entry = stsd.body + 8;
  const entryEnd = Math.min(stsd.end, entry + u32(b, entry));
  const avcC = findChild(b, entry + 8 + 78, entryEnd, "avcC");
  const esds = findChild(b, entry + 8 + 28, entryEnd, "esds");
  const sps: Uint8Array[] = [];
  const pps: Uint8Array[] = [];
  let lengthSize = 4;
  if (avcC && avcC.body + 6 < b.length) {
    lengthSize = (b[avcC.body + 4]! & 3) + 1;
    let p = avcC.body + 5;
    const ns = b[p]! & 0x1f;
    p++;
    for (let i = 0; i < ns && p + 2 <= b.length; i++) {
      const n = (b[p]! << 8) | b[p + 1]!;
      p += 2;
      sps.push(Uint8Array.from(b.subarray(p, p + n)));
      p += n;
    }
    const np = b[p] ?? 0;
    p++;
    for (let i = 0; i < np && p + 2 <= b.length; i++) {
      const n = (b[p]! << 8) | b[p + 1]!;
      p += 2;
      pps.push(Uint8Array.from(b.subarray(p, p + n)));
      p += n;
    }
  }
  let audioConfig = new Uint8Array();
  if (esds) audioConfig = Uint8Array.from(decoderSpecific(b.subarray(esds.body, esds.end)));
  return { sps, pps, lengthSize, audioConfig };
}

function decoderSpecific(esds: Uint8Array): Uint8Array {
  let i = 4;
  while (i < esds.length) {
    const tag = esds[i]!;
    i++;
    let len = 0;
    for (let k = 0; k < 4 && i < esds.length; k++) {
      const byte = esds[i++]!;
      len = (len << 7) | (byte & 0x7f);
      if ((byte & 0x80) === 0) break;
    }
    if (tag === 0x05) return esds.slice(i, i + len);
    if (tag === 0x03 || tag === 0x04) continue;
    i += len;
  }
  return new Uint8Array();
}

type Box = { type: string; body: number; end: number };

function children(b: Uint8Array, start: number, end: number): Box[] {
  const out: Box[] = [];
  let i = start;
  while (i + 8 <= end) {
    let size = u32(b, i);
    let hdr = 8;
    if (size === 1 && i + 16 <= end) {
      size = Number(u64(b, i + 8));
      hdr = 16;
    } else if (size === 0) size = end - i;
    if (size < hdr || i + size > end) break;
    out.push({ type: ascii(b, i + 4, 4), body: i + hdr, end: i + size });
    i += size;
  }
  return out;
}

function findChild(b: Uint8Array, start: number, end: number, type: string): Box | null {
  return children(b, start, end).find((x) => x.type === type) ?? null;
}

function findDescendant(b: Uint8Array, start: number, end: number, type: string): Box | null {
  for (const box of children(b, start, end)) {
    if (box.type === type) return box;
    const hit = findDescendant(b, box.body, box.end, type);
    if (hit) return hit;
  }
  return null;
}

function ascii(b: Uint8Array, o: number, n: number): string {
  let s = "";
  for (let i = 0; i < n && o + i < b.length; i++) s += String.fromCharCode(b[o + i]!);
  return s;
}

function u32(b: Uint8Array, o: number): number {
  return ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;
}

function u64(b: Uint8Array, o: number): bigint {
  let n = 0n;
  for (let i = 0; i < 8; i++) n = (n << 8n) | BigInt(b[o + i]!);
  return n;
}

export function segmentSpan(plan: SegmentPlan): { offset: number; length: number } | null {
  const all = [...plan.video, ...plan.audio].filter((s) => s.size > 0);
  if (all.length === 0) return null;
  let start = all[0]!.offset;
  let end = start + all[0]!.size;
  for (const s of all) {
    if (s.offset < start) start = s.offset;
    if (s.offset + s.size > end) end = s.offset + s.size;
  }
  if (end <= start || end - start > 32 * 1024 * 1024) return null;
  return { offset: start, length: end - start };
}

export function shiftPlan(plan: SegmentPlan, base: number): SegmentPlan {
  const move = (s: Sample): Sample => ({ ...s, offset: s.offset - base });
  return { ...plan, video: plan.video.map(move), audio: plan.audio.map(move) };
}
