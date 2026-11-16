# zslice documentation

## For people who slice with zslice

- [Getting started](user/getting-started.md): build zslice, slice a part, look at the layers.
- [Settings reference](user/settings.md): each setting, its unit, and its default.
- [Profiles](user/profiles.md): machine, filament, and project files, with inheritance and overrides.
- [Problems and errors](user/troubleshooting.md): what each error means and what to do.

## For developers who use the library

- [Overview](embedding/overview.md): the objects, the memory, the threads, and the errors.
- [Zig API](embedding/zig.md)
- [C API](embedding/c.md)
- [JavaScript and WebAssembly](embedding/javascript.md)

## The app

- [The app](app/README.md): the core and the native shells, and the contract between them.
- [Linux (GTK4)](../linux/README.md)

## For developers who change or extend zslice

- [How a slicer works](internals/how-slicing-works.md): the stages from mesh to G-code.
- [Architecture](internals/architecture.md): the modules, the data types, the memory model, and the threads.
- [Settings for some layers](internals/layer-settings.md): which settings can change per layer, and which code reads them.
- [Contributing](internals/contributing.md): the rules, the tests, and step-by-step guides to add a setting, a feature, or an infill pattern.
- [Code quality](internals/code-quality.md): the plan to make the code clearer, ranked by value.

## Documentation

The site at https://beetlebug.org/zslice/ comes from these Markdown files. `docs/build.py` writes the pages into `docs/`, with one folder for each page. It needs only Python 3.

```sh
python3 docs/build.py
```

Run it after a change to a Markdown file, and commit the pages with the change. At the end, the script checks each link of the site. It stops with an error for a link to a file or an anchor that does not exist. A push to `master` that changes `docs/` publishes the site (`.github/workflows/pages.yml`).

To add a page, add its Markdown file to `SOURCES` in `docs/build.py`. The script stops with an error for a Markdown file in `docs/` that has no page.
