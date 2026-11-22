# Printables

zslice reads the list of files of a public Printables model, and the download link of each file that the user checks. See [Import a model from a model page](../internals/model-import.md). zslice copies no code from these sources. It uses the facts of the API: the address, the names of the query and the fields, and the forms of the answers.

## The API and the terms

### The Printables GraphQL API

```ref
kind: format
source: Printables (Prusa Research)
license: The API (facts, no code); the terms of the Prusa sites
link: https://www.printables.com
version: The API as the model page of printables.com sends it, read on 2026-11-22
files: src/model_import.zig, linux/src/ui/model-import.c, linux/src/net/model-download.c
area: network
summary: The query of the files of a model and the mutation of a download link, as the model page of the site sends them.
```

The endpoint is `https://api.printables.com/graphql/` (the slash at the end is necessary). It needs no key and no login for a public model. Its introspection is off, and it has no public documentation.

- The query `print(id: $id)` gives the model: `name`, `user { publicUsername }`, `license { name }`, `stls` (each model file: STL, 3MF, STEP, and OBJ, despite the name), and `otherFiles`. Each file has `id`, `name`, `folder`, `fileSize`, and `filePreviewPath` (a path on `https://media.printables.com/`).
- The mutation `getDownloadLink(id, printId, fileType: stl, source: model_detail)` gives `output { link }`: a URL on `files.printables.com`. The site counts it as a download.
- CORS: the API answers only the origin `https://www.printables.com`. The files and the previews send `Access-Control-Allow-Origin: *`. So the web app of zslice cannot read the list.

The terms: the [Terms of Service of Printables](https://www.prusa3d.com/page/terms-of-service-of-printables-com_231249/) (from 15 October 2026) and the [General Terms of the Prusa websites](https://www.prusa3d.com/page/general-terms-and-conditions-of-use-of-the-prusa-websites_231226/) (from 20 April 2026, article 9). Article 9.1 asks for use "in the usual manner", and forbids automated extraction, scraping, and a load that burdens the service. zslice does what the model page does for one user: it asks for one model when the user pastes its address, and downloads only the files that the user checks, one at a time. It keeps no copy of the list, and it sends `zslice/<version> (+https://github.com/beetlebugorg/zslice)` as its User-Agent.

## Projects that use the API

### MosaicSlicer

```ref
kind: idea
source: MosaicSlicer (ading2210)
license: AGPL-3.0
link: https://github.com/ading2210/MosaicSlicer
version: 6bdad26d6e977571cb0345c97739fd9b5a0f7b8f
files: src/model_import.zig
area: network
summary: The query of the model files and the download link mutation of Printables, in a browser extension of a web slicer.
```

`public/extension/printables.js` sends the queries `ModelFiles` and `GetDownloadLink` from an extension on the Printables page, where CORS lets it. zslice took the names of the fields from it, and checked them against the API.

### STLVault

```ref
kind: idea
source: STLVault (moddroid94)
license: MIT
link: https://github.com/moddroid94/STLVault
version: 7bbdacf1b7d8c21bb7c0984f30fe3c04fe6907ef
files: src/model_import.zig
area: network
summary: The variables of the download link mutation (fileType stl, source model_detail) and the media host of the previews.
```

`backend/importers/printables.py` imports the files of a Printables model into a library. zslice took the idea of the preview URL (`filePreviewPath` on the media host). zslice does not copy its browser User-Agent: zslice names itself.

### Thingport

```ref
kind: idea
source: Thingport (TautvydasDerzinskas)
license: AGPL-3.0
link: https://github.com/TautvydasDerzinskas/Thingport
version: 260489f3bf3377a8e0673768a8939dfe51ffed81
files: src/model_import.zig
area: network
summary: The fact that the stls list of a model has each model format, and the license and author fields.
```

`backend/src/providers/printables/api.ts` notes that `stls` holds every model file type, and reads `license` and `user { publicUsername }`.
