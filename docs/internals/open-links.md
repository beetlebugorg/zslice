# Links that open a model

A model site opens a model in a slicer with an "Open in slicer" link. zslice takes links of this form:

```
zslice://open?file=<percent-encoded https URL>
```

This is the shape of the `prusaslicer://open?file=` links that Printables and other sites use (see [PrusaSlicer](../references/prusaslicer.md), the entry "The shape of an open in slicer link"). This page is the contract for each app. The rules are in the core (`src/open_link.zig`, the `zs_link_*` calls of `include/zslice.h`), so that all apps accept and refuse the same links. The Windows app calls the same core rules too (`windows/src/net/zs_open_link.cpp` wraps them).

## The link

- The scheme is `zslice:`, in any case. The web app also takes `web+zslice:`, because a web page can register only a scheme that starts with `web+`.
- The path is `//open?` or `//open/?`. Any other path is refused.
- The query has exactly one `file=` key. Other keys are skipped. A fragment is removed.
- The value of `file` is decoded once (`%XX`). A bad escape refuses the link.
- The whole link is at most 4096 bytes.

`zs_link_check(text, &link)` does these steps, then checks the URL. `zs_link_check_url` checks a plain URL (the `?open=` of the web app).

## The URL

The URL must be an https URL of a public host name:

- The scheme is `https://`.
- The host has no user name (`@`), and no port other than 443.
- The host has only `a-z`, `0-9`, `.`, and `-`, has a dot, and has at most 253 characters. No label is empty, and the host does not start or end with `.` or `-`.
- The last label is two or more letters, or starts with `xn--`. This refuses each form of an IP address (`127.0.0.1`, `2130706433`, `0x7f.0.0.1`, `[::1]`).
- The host does not end in `.local`, `.localhost`, `.internal`, `.lan`, `.home`, `.arpa`, `.localdomain`, `.intranet`, `.corp`, or `.private`. A name with no dot (`localhost`) fails the rule above.
- The text has no control character, no `\`, no `"`, no `<`, and no `>`.

The clean URL has the host in lowercase, no port, no fragment, and `%XX` for each space and each byte over 0x7F. `link.host` is the host to show to the user. `link.name` is the file name in the path if it is a model name, else "".

## The dialog

The app asks before it downloads. Any web page can start a link, so the user must see what comes and from where:

- The title: **Open this model?**
- The file name (`link.name`), or "A model file".
- "From" and the host (`link.host`).
- "zslice downloads the file and opens it on a new plate. It does not start a print."
- The buttons **Cancel** and **Download and open**. Cancel has the focus, so Enter does not start a download.

The app handles one link at a time. A second link while a dialog or a download is open gets "Finish the link that is open, then try this one."

## The download

1. Resolve the host. If an address is not public (`zs_link_address_public` is 0), stop with `ZS_LINK_LOCAL_ADDRESS`. A name of a public site can still resolve to a device on the local network.
2. Connect with no proxy, so that the app sees the real peer. Check the address of the connection again before the TLS handshake. This stops a name that changes its address between the two steps.
3. Send a GET with no cookie, no key, no credentials, and no referrer.
4. Follow no redirect by itself. For a 301, 302, 303, 307, or 308, call `zs_link_redirect(location, &link)`: it takes an absolute URL or a path on the same host, and checks it with the rules above. Then go to step 1. Stop after `ZS_LINK_MAX_REDIRECTS` (5).
5. An answer other than 2xx stops the download.
6. `zs_link_check_reply(content_type, length)` refuses an HTML page and a length over `ZS_LINK_MAX_BYTES` (512 MB).
7. `zs_link_file_name(disposition, &link)` sets the name: from `Content-Disposition` (`filename*=` first, then `filename=`), else from the last URL, else the name of the link. The name has no folder, no control character, no mark that changes the direction of the text, and at most 120 characters. The download stops if no name ends in `.stl`, `.3mf`, `.step`, `.stp`, or `.obj`.
8. Read the body, and stop when it grows over `ZS_LINK_MAX_BYTES`.
9. Refuse a zslice project (`zs_project_file_is`) with `ZS_LINK_PROJECT`: a project replaces the plates and brings its own printer settings.
10. Open the file on a new plate if the active plate has parts. Never start a print.

`zs_link_message(result)` gives the text for the user of each `enum zs_link_result`.

A link to a model page (for example `zslice://open?file=https://www.printables.com/model/3161`) does not download the page. After `zs_link_check`, the app checks `link.url` with `zs_import_page_check`. For a model page, it shows the text of `zs_import_page_text` and offers to open the page. The user downloads the ZIP file of the model there. zslice calls no API of the site. See [Import a model from a model page](model-import.md).

## The apps

| App | Registration | Code |
|---|---|---|
| Linux (GTK) | `MimeType=x-scheme-handler/zslice` in `linux/data/org.beetlebug.Zslice.desktop`, with `Exec=zslice-gtk %U`. Meson runs `update-desktop-database` after an install. | The GApplication `open` signal gets the link (the command line, or a second start that hands it to the first one). `ui/open-link.c` asks, and `net/model-download.c` downloads with libsoup. |
| Windows | `HKCU\Software\Classes\zslice` | `windows/src/net/zs_open_link.cpp` and `windows/src/app/MainWindow.Open.cpp`. See [The Windows app](windows.md). |
| macOS | `CFBundleURLTypes` with the scheme `zslice` in `Info.plist` | The Mac session follows this page. |
| Web | `navigator.registerProtocolHandler("web+zslice", "/?open=%s")` from the **Open** menu | `web/app/openlink.js` and `askOpenLink` in `web/app/app.js`. |

### The web app

A page cannot do each step:

- A `zslice://` link cannot reach a web page. A site can link to `web+zslice://open?file=...` (after the user registers the page), or to `https://zslice.beetlebug.org/?open=<URL>`. The page reads `?open=` and removes it from the address, so a reload does not ask again.
- A page cannot see the address of a host. The browser asks or blocks before a public page reaches a local address (Local Network Access).
- The browser follows redirects by itself. The page checks the last URL (`response.url`) with the same rules.
- The browser reads a file of another site only if the site sends CORS headers (`Access-Control-Allow-Origin`). Without them the fetch fails. The dialog then says so, and offers **Download the file**: the browser downloads it, and the user drops it on the window. `Content-Disposition` is readable only if the site exposes it (`Access-Control-Expose-Headers`).

## Tests

- `zig build test`: the tests of `src/open_link.zig` and `src/c_api/link.zig` (the links, the refused URLs, the names, the redirects, and the addresses).
- `meson test -C linux/build`: `model-download-test` gives a stub resolver to the GTK download. A name that resolves to a private, loopback, or unique local address gets no connection.
- `node web/app/test-node.mjs`: the checks through the wasm module, and downloads from a stub fetch (a redirect to a local address, a web page, no name, a large file, no CORS, and a zslice project).
