# @beetlebugorg/zslice

The zslice slicer in WebAssembly. The package has three parts:

- `app/`: the web app (the page, the worker, and the wasm modules). Serve the folder with any static server. For threads, the server must send `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`; with no headers, the app slices with one thread.
- `zslice.mjs`: a small JavaScript API, `load(wasmBytes)` and `sliceStl(stl, settings)`.
- `zslice`: a Node command that slices a model to G-code, with profiles.

The package is on GitHub Packages, not on npmjs.com.

## Install

Tell npm where the `@beetlebugorg` scope is, in `.npmrc`:

```
@beetlebugorg:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```

GitHub Packages needs a token to install, also for a public package: a personal token with `read:packages`, or `GITHUB_TOKEN` in a GitHub Actions job (`permissions: packages: read`). Then:

```sh
npm install @beetlebugorg/zslice
```

## Slice in Node

```sh
npx zslice slice part.stl -m printer.toml -f pla.toml -p fine -s project.wall_count=3 -o part.gcode --stats stats.json
```

A profile is a built-in name or a `.toml` file (`zslice import cura` of the native command converts a Cura profile stack). `-s` changes one setting after the profiles.

## Serve the web app

The web app is the files in `node_modules/@beetlebugorg/zslice/app/`. Serve them at any path; the app uses only relative URLs.

A printer that serves the app itself (for example a printdeck on the LAN) can put `printer.json` next to `index.html`:

```json
{ "name": "Workhorse", "kind": "printdeck", "url": "", "profile": "<a machine profile, optional>" }
```

`kind` is `printdeck`, `octoprint`, or `moonraker`; an empty `url` is the server of the page. The app adds that printer, and uses it when no printer is set up yet. The print button then sends the G-code to it (`/api/files/local`, or `/server/files/upload` for Moonraker), with no CORS: the page and the printer have the same origin.

## The JavaScript API

```js
import { readFile } from "node:fs/promises";
import { load } from "@beetlebugorg/zslice";

const wasm = await readFile(new URL(import.meta.resolve("@beetlebugorg/zslice/app/zslice.wasm")));
const zslice = await load(wasm);
const { gcode, stats } = zslice.sliceStl(await readFile("part.stl"), { "project.wall_count": 3 });
```

See the [documentation](https://zslice.beetlebug.org/docs.html) for the settings, and the embedding guide.

## License

AGPL-3.0-or-later. See LICENSE.
