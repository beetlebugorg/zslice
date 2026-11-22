# Thingiverse

zslice reads the address of a Thingiverse thing, and the ZIP file of its files. See [Import a model from a model page](../internals/model-import.md).

### The Thingiverse API and the ZIP file of a thing

```ref
kind: format
source: Thingiverse (UltiMaker)
license: The API and the page forms (facts, no code)
link: https://www.thingiverse.com/developers
version: The API and the site, read on 2026-11-22
files: src/model_import.zig, web/app/modelimport.js, linux/src/ui/model-import.c
area: network
summary: The form of a thing address (thing:<id>), and the reason that zslice does not call the API.
```

The page of a thing is `https://www.thingiverse.com/thing:<id>`. Its "Download all files" button gives one ZIP file with the files of the thing (in `files/`) and its images. zslice lists such a ZIP file (`zs_import_list_zip`).

The API (`https://api.thingiverse.com/things/<id>/files`) answers 401 `NO_TOKEN_PROVIDED` with no token. Each call needs a bearer token: an app token from a registered app, or an OAuth token of a user. An app token in the source or the binaries of an open app is public, and the app cannot keep it secret. So zslice does not call the API. zslice calls no API of any model site (see also [Printables](printables.md)). It opens the page in the browser, and the user downloads the ZIP file. The API sends `Access-Control-Allow-Origin: *`, so a page could call it with a token.
