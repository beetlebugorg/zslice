# 15. The docs site, the references, CI, releases, and the Homebrew tap

## Goal

Keep a docs site from Markdown with no dependencies beyond Python 3, a references section with a searchable explorer, CI that runs only the jobs a change needs, a release workflow for each version tag, and a Homebrew tap. Start this part early: each earlier part writes docs and reference entries as it goes.

## Read first

- [docs/README.md](../docs/README.md): the contents and how the site is built.
- [References and licenses](../docs/references/README.md): the rule and the form of an entry.
- [CI and releases](../docs/internals/release.md): the CI jobs, the release steps, the tags, the files of a release, Homebrew, and the secrets (by name only).
- [Contributing](../docs/internals/contributing.md) and [Code quality](../docs/internals/code-quality.md).
- The newer internals pages: [G-code reference](../docs/internals/gcode.md) and [Import from a model page](../docs/internals/model-import.md). The new reference pages: [Printables](../docs/references/printables.md) and [Thingiverse](../docs/references/thingiverse.md).
- `.github/workflows/ci.yml`, `release.yml`, `site.yml`, `npm.yml`.

## Build

1. `docs/build.py`: a small Markdown converter (headings, paragraphs, lists with task boxes, fenced code, tables, inline code, bold, links, comments). Each page is in `SOURCES` with its folder and sidebar group. The guide pages get numbers. The script writes one folder for each page, checks each link and anchor, and stops on a broken link or on a Markdown file with no page. Run it with `python3 -I docs/build.py`, and commit the pages with the change. A fence "```html live" puts its HTML in the page and also shows it as code, so a demo runs the code that the page shows. The G-code viewer page runs a live demo on `docs/embedding/viewer/bridges.gcode`. The web step installs `zslice-view.js` in `zig-out/web/app`, and the site has that folder at its root.
2. The references: one page for each source or area. Each entry is a level 3 heading, a `ref` block (kind, source, license, link, version, files, area, summary), and its text. The build checks the fields and the paths, and makes the explorer page from them.
3. `tools/settings_doc.py` writes `docs/user/settings.md` and `src/settings_meta.zig`. `tools/setting_coverage.py` writes `docs/user/setting-coverage.md` from the Cura and OrcaSlicer coverage lists.
4. `ci.yml`: on a push to main, each pull request, and by hand. A change of docs or Markdown only starts no job. The first job picks the jobs the change needs. A core change starts all jobs: core tests (`zig build test` and a 20 mm cube), the web app (`zig build web` and the Node tests), the Linux app (meson with `-Dwerror=true`, then `meson test`), the Mac app (the Xcode project lists each Swift file; build; open a box, slice, and take a picture), and the Windows app (x64 and ARM64).
5. `release.yml` on a tag: the command line tool (Linux musl, macOS), the C library for printer hosts, the Mac dmg (signed, notarized, stapled, or ad hoc with no Apple secrets), the Linux GTK tarball, the web zip, the Windows zips (unsigned), and `SHA256SUMS`. The notes come from the commit subjects since the tag before.
6. The icon: a Z of print lines on a dark square with a light rim, and an orange first layer. `assets/icon/zslice.svg` is the icon, and `zslice-small.svg` has thicker lines for 16 to 48 px. `tools/icons.sh` makes the files of each app. `docs/build.py` makes the favicon of the docs from the small icon. `assets/icon/out` has the 1024 px picture for the Mac and the `.ico` file for Windows.
7. Homebrew: the `homebrew` job writes `Formula/zslice.rb`, `Formula/zslice-gtk.rb`, and `Casks/zslice.rb` to the tap with `packaging/homebrew/tap.sh`.
8. `site.yml`: on a push to main, build the web app and the docs, and upload them to the S3 bucket behind CloudFront. The bucket, the distribution, and the deploy role are in a separate private repository. CloudFront sends the isolation headers. GitHub Pages cannot.
9. `npm.yml`: the npm package with the embeddable G-code viewer.

## Rules that matter

- A tag is `v` and the version: `v0.6.0-beta`. No counter such as `beta.2`. `-beta` and a plain version update the tap. Any other suffix (`-rc1`, `-test`) makes a prerelease and leaves the tap alone.
- Keep the names of the tool and library tarballs: the printdeck Action downloads the Linux tools by name.
- The site serves the app and docs files with `no-cache`, and the bed models with one day.
- The privacy page says what the host keeps: no request logs on CloudFront or S3.
- Pin each GitHub Action by its commit hash, with the version in a comment.
- Write each doc in short, plain sentences, one idea each, in the present tense.
- The docs have three parts: `docs/user/`, `docs/embedding/`, `docs/internals/`. Keep each current with the code in the same commit.

## Lessons

- Make the doc pages again after each merge that changes a Markdown file. The range of this update has several such commits (for example `b42d385c`, "Build the doc pages again after the merge").
- A cached script with a fresh page broke the app after a deploy: send the app files with `no-cache`.
- Add a privacy page, and load no fonts from Google.
- Say in the privacy page that AWS hosts the site, with no logs.
- **Check the doc pages against the code after a batch of features.** An audit found, for example: the C link needs `-lm`, the status codes 10 to 17 were not in the table, and the user pages had old names of tools, qualities, and keys. Some pages are still older than the code in places; parts 09, 11, and 12 name them.
- **Link to a reference page, not to a heading that has no anchor.** A link to an anchor in the PrusaSlicer references went nowhere, and `docs/build.py` stopped with an error. The link now goes to the page and names the entry.
- **Give the icon a light rim.** On a dark Dock or desktop the near black square lost its edge.
- **Give each new area a contract page.** The import from a model page has `docs/internals/model-import.md`: the call order for the apps that do not have it yet, what each site allows (CORS, tokens, and terms), and the state of each app.
- The Mac CI job builds Debug: keep each Swift expression small enough to type-check in time (part 11).

## Acceptance checks

1. `python3 -I docs/build.py` runs with no error and no broken link.
2. A new reference entry with a wrong path fails the build.
3. A push of a docs-only change starts no CI job.
4. A `v0.0.0-test` tag makes a prerelease with each file and `SHA256SUMS`, and leaves the tap alone.
5. `sha256sum -c SHA256SUMS --ignore-missing` passes on the downloaded files.
6. The G-code viewer page runs its live demo from the files of the site.
