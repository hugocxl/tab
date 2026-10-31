import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { checkout } = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
const { PNG } = await import(
  pathToFileURL(resolve(checkout, "node_modules/.pnpm/pngjs@7.0.0/node_modules/pngjs/lib/png.js"))
    .href
);
const output = resolve(root, ".work/qa/full-source-differential");
mkdirSync(output, { recursive: true });
const comparisons = [];
for (const width of [360, 800])
  for (const dark of [false, true])
    for (const state of ["collapsed", "expanded"]) {
      const name = `${width}-${dark}-${state}`;
      const expected = PNG.sync.read(
        readFileSync(
          resolve(
            checkout,
            `apps/web/src/components/chat/__screenshots__/tab-full-source/${name}.png`,
          ),
        ),
      );
      const actual = PNG.sync.read(readFileSync(resolve(output, `${name}.png`)));
      if (expected.width !== actual.width || expected.height !== actual.height) {
        comparisons.push({
          name,
          expected: [expected.width, expected.height],
          actual: [actual.width, actual.height],
        });
        continue;
      }
      let differentPixels = 0,
        maxChannelDelta = 0,
        minX = Infinity,
        minY = Infinity,
        maxX = -1,
        maxY = -1;
      const diff = new PNG({ width: actual.width, height: actual.height });
      for (let index = 0; index < actual.data.length; index += 4) {
        let changed = false;
        for (let channel = 0; channel < 4; channel++) {
          const delta = Math.abs(actual.data[index + channel] - expected.data[index + channel]);
          if (delta) {
            changed = true;
            maxChannelDelta = Math.max(maxChannelDelta, delta);
          }
        }
        if (changed) {
          differentPixels++;
          const pixel = index / 4,
            x = pixel % actual.width,
            y = Math.floor(pixel / actual.width);
          minX = Math.min(minX, x);
          maxX = Math.max(maxX, x);
          minY = Math.min(minY, y);
          maxY = Math.max(maxY, y);
          diff.data[index] = 255;
          diff.data[index + 1] = 0;
          diff.data[index + 2] = 0;
          diff.data[index + 3] = 255;
        } else {
          diff.data[index] = actual.data[index];
          diff.data[index + 1] = actual.data[index + 1];
          diff.data[index + 2] = actual.data[index + 2];
          diff.data[index + 3] = 80;
        }
      }
      if (differentPixels) writeFileSync(resolve(output, `${name}-diff.png`), PNG.sync.write(diff));
      comparisons.push({
        name,
        width: actual.width,
        height: actual.height,
        differentPixels,
        totalPixels: actual.width * actual.height,
        maxChannelDelta,
        bounds: differentPixels ? { minX, minY, maxX, maxY } : null,
      });
    }
const report = { comparisons };
writeFileSync(resolve(output, "pixels.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
if (comparisons.some((value) => value.differentPixels !== 0)) process.exitCode = 1;
