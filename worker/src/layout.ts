// Old uploads keep the picture in thousands of small data blocks. A Roku reads the start of every block
// before it shows anything, so those titles take minutes to open, or never do. In these files the index
// comes first and points at absolute positions, so relabelling the first block to run to the end of the
// file makes the title open like a normal one, without moving or re-uploading a single byte.

export type Reader = (offset: number, length: number) => Promise<Uint8Array | null>;

interface Box {
  kind: string;
  size: number;
  header: number;
}

function parseBox(bytes: Uint8Array | null): Box | null {
  if (!bytes || bytes.byteLength < 8) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const kind = String.fromCharCode(bytes[4]!, bytes[5]!, bytes[6]!, bytes[7]!);
  const small = view.getUint32(0);
  if (small !== 1) return { kind, size: small, header: 8 };
  if (bytes.byteLength < 16) return null;
  return { kind, size: view.getUint32(8) * 2 ** 32 + view.getUint32(12), header: 16 };
}

/** Where the first data block starts when the file is index-first with many data blocks; -1 when the
 * file needs nothing (already one block, index last, or not a layout this understands). */
export async function findSplitData(read: Reader, total: number): Promise<number> {
  let off = 0;
  let sawIndex = false;
  for (let i = 0; i < 8 && off + 8 <= total; i++) {
    const box = parseBox(await read(off, Math.min(16, total - off)));
    if (!box) return -1;
    if (box.kind === "mdat") {
      if (!sawIndex || box.header !== 8 || box.size < 8) return -1;
      const next = off + box.size;
      if (next + 8 > total) return -1; // one block that already runs to the end
      const after = parseBox(await read(next, Math.min(16, total - next)));
      return after && after.kind === "mdat" ? off : -1;
    }
    if (box.kind === "moov") sawIndex = true;
    if (box.size < 8) return -1;
    off += box.size;
  }
  return -1;
}

/** The four bytes that label the block at `start` as running to the end of a file `total` bytes long. */
export function runToEnd(start: number, total: number): Uint8Array {
  const span = total - start;
  const out = new Uint8Array(4);
  // A zero length means "to the end of the file", which is the only way to say it past 4 GB here.
  if (span <= 0xffffffff) new DataView(out.buffer).setUint32(0, span);
  return out;
}

export type Piece = { from: number; to: number } | { bytes: Uint8Array };

/** How to serve [offset, offset + length) with `patch` written at `patchAt`: stored ranges around the
 * replaced bytes. A single stored range means the request does not touch them. */
export function splitAround(offset: number, length: number, patchAt: number, patch: Uint8Array): Piece[] {
  const end = offset + length;
  const patchEnd = patchAt + patch.byteLength;
  if (end <= patchAt || offset >= patchEnd) return [{ from: offset, to: end }];
  const pieces: Piece[] = [];
  if (offset < patchAt) pieces.push({ from: offset, to: patchAt });
  pieces.push({ bytes: patch.subarray(Math.max(patchAt, offset) - patchAt, Math.min(patchEnd, end) - patchAt) });
  if (end > patchEnd) pieces.push({ from: patchEnd, to: end });
  return pieces;
}
