# zslice documentation

## For people who slice with zslice

- [Getting started](user/getting-started.md): build zslice, slice a part, look at the layers.
- [Settings reference](user/settings.md): each setting, its unit, and its default.
- [Problems and errors](user/troubleshooting.md): what each error means and what to do.

## For developers who use the library

- [Overview](embedding/overview.md): the objects, the memory, the threads, and the errors.
- [Zig API](embedding/zig.md)
- [C API](embedding/c.md)
- [JavaScript and WebAssembly](embedding/javascript.md)

## The app

- [The app](app/README.md): the core and the native shells, and the contract between them.

## For developers who change or extend zslice

- [How a slicer works](internals/how-slicing-works.md): the stages from mesh to G-code.
- [Architecture](internals/architecture.md): the modules, the data types, the memory model, and the threads.
- [Contributing](internals/contributing.md): the rules, the tests, and step-by-step guides to add a setting, a feature, or an infill pattern.
