# Printables

zslice reads the address of a Printables model, and the ZIP file of its files. zslice does not call the API of Printables. See [Import a model from a model page](../internals/model-import.md).

### The Printables terms and the ZIP file of a model

```ref
kind: format
source: Printables (Prusa Research)
license: The page forms (facts, no code); the terms of the Prusa sites
link: https://www.printables.com
version: The site and the terms, read on 2026-11-22
files: src/model_import.zig, web/app/modelimport.js, linux/src/ui/model-import.c
area: network
summary: The form of a model address (model/<id>), and the reason that zslice does not call the API.
```

The page of a model is `https://www.printables.com/model/<id>-<name>`, or the same path after a language (`/de/model/<id>`). Its "Download all" button gives one ZIP file with the files of the model. zslice lists such a ZIP file (`zs_import_list_zip`).

zslice does not call the API of Printables. The site has a GraphQL API (`api.printables.com/graphql/`) for its own pages. That API is private: it has no documentation, and the site gives no permission to other apps to use it. The terms of the site forbid this use:

- The [Terms of Service of Printables](https://www.prusa3d.com/page/terms-of-service-of-printables-com_231249/) (from 15 October 2026).
- The [General Terms of the Prusa websites](https://www.prusa3d.com/page/general-terms-and-conditions-of-use-of-the-prusa-websites_231226/) (from 20 April 2026). Article 9.1 asks for use "in the usual manner", and forbids automated extraction and scraping.

An earlier version of zslice (before 2026-11-22) read the list of files and the download links from that API. zslice removed that code. zslice now does what it does for Thingiverse: it opens the page in the browser, and the user downloads the ZIP file. A direct link to one file (for example a `zslice://open?file=` link) still downloads that file, as a browser does.
