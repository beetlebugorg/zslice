# zslice documentation

## Start

- [Your first print](user/getting-started.md): open a model, slice it, and print it.

## Everyday tasks

- [Look at the print](user/look.md): the view, the layers, the colors, and the replay.
- [Click a line](user/lines.md): what a line is, and why it prints as it does.
- [Change a setting](user/change-settings.md): the search, the panel, and where a value comes from.
- [Place the parts](user/parts.md): move, turn, grab, scale, and cut.
- [Add support](user/support.md): support from the settings, support where you click, and the tree editor.
- [Check the print](user/check.md): the check list, the gaps, and the measure tape.
- [Plates and files](user/plates.md): plates, the project file, and Cura projects.
- [Send to a printer](user/printers.md): add a printer, connect it, and print.
- [Undo and history](user/history.md): go back to any change.

## Features

- [The best features](user/features.md): what zslice does that other slicers do not.
- [The print as it forms](user/print-as-it-forms.md): the plastic sags and falls, layer by layer.
- [printdeck projects](user/projects.md): a repository of parts to print.
- [A print farm](user/farm.md): all your printers on one page.

## Reference

- [Keys and mouse](user/keys.md)
- [Settings](user/settings.md): each setting, its unit, and its default.
- [Formulas and rules](user/expert.md): settings for some layers, formulas, and path rules.
- [Profiles](user/profiles.md): machine, filament, and project files, with inheritance.
- [The command line](user/command-line.md): slice with no window, check a slice, and measure the speed.
- [Web, Linux, and Mac](user/apps.md): where the apps differ.
- [The macOS app](user/macos.md): the keys, the drawer, printers, and the Keychain.
- [Problems and errors](user/troubleshooting.md): what each error means and what to do.

## For developers who use the library

- [Overview](embedding/overview.md): the objects, the memory, the threads, and the errors.
- [Zig API](embedding/zig.md)
- [C API](embedding/c.md)
- [JavaScript and WebAssembly](embedding/javascript.md)
- [The G-code viewer](embedding/viewer.md): a 3D view of a G-code file on a web page, with a live demo.

## The app

- [The app](app/README.md): the core and the native shells, and the contract between them.
- [Linux (GTK4)](../linux/README.md)
- [Web](../web/app/README.md)

## For developers who change or extend zslice

- [How a slicer works](internals/how-slicing-works.md): the stages from mesh to G-code.
- [Architecture](internals/architecture.md): the modules, the data types, the memory model, and the threads.
- [Settings for some layers](internals/layer-settings.md): which settings can change per layer, and which code reads them.
- [Arachne walls](internals/arachne.md): walls with a variable line width, ported from CuraEngine.
- [The print simulation](internals/print-sim.md): the physics of the plastic: bridges that sag, and strands that fall with no support.
- [Contributing](internals/contributing.md): the rules, the tests, and step-by-step guides to add a setting, a feature, or an infill pattern.
- [Code quality](internals/code-quality.md): the plan to make the code clearer, ranked by value.
- [The macOS app](internals/macos.md): the SwiftUI shell, its build, and the Metal renderer of the 3D view.

## Documentation

The site at https://zslice.beetlebug.org/docs.html comes from these Markdown files. `docs/build.py` writes the pages into `docs/`, with one folder for each page. It needs only Python 3.

```sh
python3 docs/build.py
```

Run it after a change to a Markdown file, and commit the pages with the change. At the end, the script checks each link of the site. It stops with an error for a link to a file or an anchor that does not exist. A push to `master` that changes `docs/` publishes the site (`.github/workflows/pages.yml`).

To add a page, add its Markdown file to `SOURCES` in `docs/build.py`. The script stops with an error for a Markdown file in `docs/` that has no page.
