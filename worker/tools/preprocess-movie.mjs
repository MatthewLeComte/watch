#!/usr/bin/env node
/**
 * One stream-ready MP4 per upload.
 *
 * Watch plays a single file by byte range, so the output is one faststart MP4
 * with a single mdat. Quality stays on the source pixels. A 12s HEVC sample
 * (x265 CRF 18) is the shrink test: the whole file is re-encoded only when
 * that sample's video bitrate is under 90% of the source. Otherwise the
 * elementary streams are copied. CRF 18 on a clean 1080p master lands well
 * under a typical delivery bitrate at VMAF around 97. On an already-small
 * H.264 rip the same CRF is larger, and copying is the closer picture.
 *
 *   node tools/preprocess-movie.mjs <input.mp4> [output.mp4]
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, extname, join, resolve } from 'node:path';

const input = resolve(process.argv[2] || '');
const output = resolve(
  process.argv[3] ||
    join(dirname(input), `${basename(input, extname(input))}.watch.mp4`),
);
if (!input || process.argv.includes('-h')) {
  process.stderr.write('usage: preprocess-movie.mjs <input> [output]\n');
  process.exit(2);
}

function run(args, what) {
  const r = spawnSync('ffmpeg', args, { encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(r.stderr || '');
    throw new Error(what);
  }
  return r.stderr || '';
}

function probe(file) {
  const r = spawnSync(
    'ffprobe',
    ['-v', 'error', '-show_format', '-show_streams', '-of', 'json', file],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) throw new Error(r.stderr || 'ffprobe failed');
  return JSON.parse(r.stdout);
}

const info = probe(input);
const video = info.streams.find((s) => s.codec_type === 'video');
const audio = info.streams.find((s) => s.codec_type === 'audio');
if (!video) throw new Error('no video stream');
const duration = Number(info.format.duration);
const fps = (() => {
  const [n, d] = String(video.avg_frame_rate || '24/1').split('/').map(Number);
  const v = d ? n / d : 24;
  return v > 1 && v <= 60 ? v : 24;
})();
const videoBps = Number(video.bit_rate) || Math.max(0, Number(info.format.bit_rate) - Number(audio?.bit_rate || 0));
const keyint = Math.max(24, Math.round(fps * 2));
const copyAudio = audio && ['aac', 'ac3', 'eac3', 'alac'].includes(audio.codec_name);
const audioArgs = !audio
  ? ['-an']
  : copyAudio
    ? ['-c:a', 'copy']
    : ['-c:a', 'aac', '-b:a', '160k', '-ac', '2', '-ar', '48000'];

const scratch = mkdtempSync(join(tmpdir(), 'watch-pre-'));
let mode = 'remux';
let sampleBps = 0;
try {
  const sample = join(scratch, 'sample.mp4');
  const start = Math.min(Math.max(duration * 0.1, 0), Math.max(duration - 12, 0));
  run(
    [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-ss', start.toFixed(3), '-t', '12', '-i', input,
      '-map', '0:v:0', '-an',
      '-c:v', 'libx265', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1',
      '-x265-params', `keyint=${keyint}:min-keyint=${keyint}:open-gop=0:scenecut=40:aq-mode=3`,
      sample,
    ],
    'sample encode failed',
  );
  const sampleInfo = probe(sample);
  sampleBps = Number(sampleInfo.format.bit_rate) || 0;
  if (videoBps > 0 && sampleBps > 0 && sampleBps < videoBps * 0.9) mode = 'encode';

  if (mode === 'encode') {
    run(
      [
        '-y', '-hide_banner', '-loglevel', 'error', '-stats',
        '-i', input,
        '-map', '0:v:0',
        ...(audio ? ['-map', '0:a:0'] : []),
        '-c:v', 'libx265', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1',
        '-x265-params', `keyint=${keyint}:min-keyint=${keyint}:open-gop=0:scenecut=40:aq-mode=3`,
        ...audioArgs,
        '-movflags', '+faststart',
        output,
      ],
      'encode failed',
    );
  } else {
    run(
      [
        '-y', '-hide_banner', '-loglevel', 'error', '-stats',
        '-fflags', '+genpts', '-i', input,
        '-map', '0:v:0',
        ...(audio ? ['-map', '0:a:0'] : []),
        '-c:v', 'copy',
        ...audioArgs,
        '-movflags', '+faststart',
        output,
      ],
      'remux failed',
    );
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

const out = probe(output);
const outVideo = out.streams.find((s) => s.codec_type === 'video');
const report = {
  mode,
  input,
  output,
  inBytes: statSync(input).size,
  outBytes: statSync(output).size,
  sourceVideoBps: videoBps,
  sampleHevcBps: sampleBps,
  duration,
  outDuration: Number(out.format.duration),
  video: `${video.codec_name} ${video.width}x${video.height}`,
  outVideo: `${outVideo?.codec_name} ${outVideo?.codec_tag_string}`,
  keyintSeconds: 2,
};
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
