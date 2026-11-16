// Draws the app icon: the robot standing in its fire, on a dark rounded square.
// It uses the same drawRobot() as the screens, so the icon always matches.
//
//   node tools/make-icon.mjs <output.iconset folder>

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { drawRobot } from '../public/robot.js';

const out = process.argv[2];
if (!out) throw new Error('usage: make-icon.mjs <output.iconset>');

// ---- a tiny stand-in for a canvas: just enough for drawRobot ----
class Surface {
  constructor(w, h) {
    this.w = w;
    this.h = h;
    this.data = new Float32Array(w * h * 4);
    this.fillStyle = '#000000';
    this.globalAlpha = 1;
  }
  fillRect(x, y, w, h) {
    const hex = this.fillStyle.replace('#', '');
    const rgb = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
    const a = this.globalAlpha;
    for (let yy = Math.max(0, Math.round(y)); yy < Math.min(this.h, Math.round(y + h)); yy++) {
      for (let xx = Math.max(0, Math.round(x)); xx < Math.min(this.w, Math.round(x + w)); xx++) {
        const o = (yy * this.w + xx) * 4;
        for (let c = 0; c < 3; c++) this.data[o + c] = this.data[o + c] * (1 - a) + rgb[c] * a;
        this.data[o + 3] = this.data[o + 3] + (255 - this.data[o + 3]) * a;
      }
    }
  }
}

// ---- the picture, on a 64 x 64 pixel grid ----
const G = 64;
const art = new Surface(G, G);
const T = 1.2; // a moment with eyes open, feet down and the antenna lit
drawRobot(art, 32, 55, 'cruising', T);

// A still frame of the fire along the bottom, over the robot's feet.
const FLAME = ['#7a1c0a', '#c23a10', '#ee7a26', '#ffc44f', '#fff2c4'];
for (let x = 0; x < G; x++) {
  const height = 5 + Math.round(4 * Math.abs(Math.sin(x * 0.55) * Math.cos(x * 0.21 + 1)) + 2 * Math.sin(x * 1.7));
  for (let k = 0; k < height; k++) {
    const heat = Math.min(FLAME.length - 1, Math.floor(((height - k) / height) * FLAME.length));
    art.fillStyle = FLAME[heat];
    art.globalAlpha = k >= height - 2 ? 0.75 : 1;
    art.fillRect(x, G - 1 - k, 1, 1);
  }
}
art.globalAlpha = 1;

// ---- compose at 1024: rounded square, gradient, the pixel art scaled up hard ----
const SIZE = 1024;
const INSET = 96; // macOS icons leave a margin around the shape
const BOX = SIZE - INSET * 2;
const RADIUS = 186;
const PX = BOX / G;
const full = new Uint8ClampedArray(SIZE * SIZE * 4);

function coverage(x, y) {
  // how much of this pixel lies inside the rounded square (4x4 samples for a smooth edge)
  let inside = 0;
  for (let sy = 0; sy < 4; sy++) {
    for (let sx = 0; sx < 4; sx++) {
      const px = x + (sx + 0.5) / 4 - INSET;
      const py = y + (sy + 0.5) / 4 - INSET;
      if (px < 0 || py < 0 || px > BOX || py > BOX) continue;
      const dx = Math.max(RADIUS - px, 0, px - (BOX - RADIUS));
      const dy = Math.max(RADIUS - py, 0, py - (BOX - RADIUS));
      if (dx * dx + dy * dy <= RADIUS * RADIUS) inside++;
    }
  }
  return inside / 16;
}

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const cover = coverage(x, y);
    if (!cover) continue;
    const t = (y - INSET) / BOX;
    // cool dark gradient, warming toward the fire at the bottom
    const glow = Math.max(0, t - 0.45) * 1.6;
    let r = 16 + 10 * (1 - t) + 86 * glow;
    let g = 20 + 10 * (1 - t) + 24 * glow;
    let b = 28 + 12 * (1 - t) - 10 * glow;
    const ax = Math.floor((x - INSET) / PX);
    const ay = Math.floor((y - INSET) / PX);
    if (ax >= 0 && ay >= 0 && ax < G && ay < G) {
      const o = (ay * G + ax) * 4;
      const a = art.data[o + 3] / 255;
      r = r * (1 - a) + art.data[o] * a;
      g = g * (1 - a) + art.data[o + 1] * a;
      b = b * (1 - a) + art.data[o + 2] * a;
    }
    const o = (y * SIZE + x) * 4;
    full[o] = r;
    full[o + 1] = g;
    full[o + 2] = b;
    full[o + 3] = cover * 255;
  }
}

// ---- PNG writing ----
const CRC = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function chunk(type, body) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(body.length, 0);
  head.write(type, 4, 'ascii');
  let crc = 0xffffffff;
  for (const byte of [...head.subarray(4), ...body]) crc = CRC[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 0);
  return Buffer.concat([head, body, tail]);
}
function png(rgba, size) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header.set([8, 6, 0, 0, 0], 8); // 8 bits, RGBA
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) Buffer.from(rgba.buffer, y * size * 4, size * 4).copy(raw, y * (size * 4 + 1) + 1);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

/** Shrinks by a whole factor, averaging with alpha weighting so edges stay clean. */
function shrink(src, from, to) {
  const f = from / to;
  const dst = new Uint8ClampedArray(to * to * 4);
  for (let y = 0; y < to; y++) {
    for (let x = 0; x < to; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let yy = 0; yy < f; yy++) {
        for (let xx = 0; xx < f; xx++) {
          const o = ((y * f + yy) * from + x * f + xx) * 4;
          const alpha = src[o + 3];
          r += src[o] * alpha;
          g += src[o + 1] * alpha;
          b += src[o + 2] * alpha;
          a += alpha;
        }
      }
      const o = (y * to + x) * 4;
      if (a) {
        dst[o] = r / a;
        dst[o + 1] = g / a;
        dst[o + 2] = b / a;
      }
      dst[o + 3] = a / (f * f);
    }
  }
  return dst;
}

fs.mkdirSync(out, { recursive: true });
const names = { 16: ['icon_16x16'], 32: ['icon_16x16@2x', 'icon_32x32'], 64: ['icon_32x32@2x'], 128: ['icon_128x128'], 256: ['icon_128x128@2x', 'icon_256x256'], 512: ['icon_256x256@2x', 'icon_512x512'], 1024: ['icon_512x512@2x'] };
for (const [size, files] of Object.entries(names)) {
  const pixels = Number(size) === SIZE ? full : shrink(full, SIZE, Number(size));
  for (const name of files) fs.writeFileSync(path.join(out, `${name}.png`), png(pixels, Number(size)));
}
console.log(`Icon written to ${out}`);
