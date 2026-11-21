# Formats and protocols

The file formats, the network protocols, the printer APIs, and the platform documents that zslice reads and writes.

## Algorithms, formats, and conventions

### SVG 1.1 path data and arcs

```ref
kind: format
source: W3C
license: W3C standard
link: https://www.w3.org/TR/SVG11/
files: macos/Sources/ZSlice/Views/HistoryGlyph.swift, web/app/history.js
area: ui
summary: The Mac app draws the glyphs of the history steps (the SVG paths of `web/app/history.js`) with SwiftUI paths.
```

Scalable Vector Graphics (SVG) 1.1, W3C Recommendation: path data, and the conversion of an arc from its end points to its center (appendix F.6.5), https://www.w3.org/TR/SVG11/

**License:** W3C standard

**Used in:** `macos/Sources/ZSlice/Views/HistoryGlyph.swift`

**How zslice uses it:** The Mac app draws the glyphs of the history steps (the SVG paths of `web/app/history.js`) with SwiftUI paths. The code is new.

### TOML v1.0.0

```ref
kind: format
source: TOML
license: MIT
link: https://toml.io/en/v1.0.0
files: src/toml.zig, src/profile.zig
area: files
summary: The profile file format.
```

TOML v1.0.0, https://toml.io/en/v1.0.0

**License:** MIT (the specification)

**Used in:** `src/toml.zig`, `src/profile.zig`

**How zslice uses it:** The profile file format. zslice parses a subset.

### GitHub REST API and Git LFS pointers

```ref
kind: format
source: GitHub
license: The APIs and the format
link: https://docs.github.com/rest
files: web/app/project.js, linux/src/net/project-source.c
area: network
summary: Open a printdeck.yml project from a public repository with no login.
```

GitHub REST API, https://docs.github.com/rest (`GET /repos/{owner}/{repo}` for `default_branch`, `GET /repos/{owner}/{repo}/commits/{ref}` for `sha`, `GET /repos/{owner}/{repo}/git/trees/{sha}?recursive=1`), the files at `raw.githubusercontent.com/{owner}/{repo}/{sha}/{path}`, and the Git LFS pointer file (https://github.com/git-lfs/git-lfs, `docs/spec.md`: a small text file that starts with `version https://git-lfs`) with the file at `media.githubusercontent.com/media/{owner}/{repo}/{sha}/{path}`

**License:** The APIs and the format (facts, no code)

**Used in:** `web/app/project.js`, `linux/src/net/project-source.c`

**How zslice uses it:** Open a printdeck.yml project from a public repository with no login.

### OctoPrint REST API

```ref
kind: format
source: OctoPrint
license: AGPL-3.0
link: https://docs.octoprint.org/en/master/api/
files: linux/src/net/printer-link.c, tools/farm_sim/farm_sim.py
area: network
summary: Read the state of a printer, and send G-code to it.
```

OctoPrint REST API, https://docs.octoprint.org/en/master/api/ (`/api/printer`, `/api/printerprofiles`, `/api/job`, `/api/files/local`, the `X-Api-Key` header)

**License:** AGPL-3.0 (OctoPrint; the API, not code)

**Used in:** `linux/src/net/printer-link.c`, `tools/farm_sim/farm_sim.py`

**How zslice uses it:** Read the state of a printer, and send G-code to it. printdeck has the same API.

### OctoPrint App Keys

```ref
kind: format
source: OctoPrint
license: AGPL-3.0
link: https://docs.octoprint.org/en/master/bundledplugins/appkeys.html
files: linux/src/net/printer-link.c, web/app/link.js
area: network
summary: "Get a key": the printer asks its user to allow zslice, and gives zslice an API key of its own.
```

The App Keys plugin of OctoPrint, https://docs.octoprint.org/en/master/bundledplugins/appkeys.html (`POST /plugin/appkeys/request` with the app name, then `GET /plugin/appkeys/request/<app_token>`: 202 wait, 200 with `api_key`, 404 denied)

**License:** AGPL-3.0 (OctoPrint; the API, not code)

**Used in:** `linux/src/net/printer-link.c`, `web/app/link.js`

**How zslice uses it:** "Get a key": the printer asks its user to allow zslice, and gives zslice an API key of its own. printdeck has the same flow.

### DNS, Multicast DNS, and DNS-SD

```ref
kind: format
source: IETF
license: IETF RFCs
link: https://www.rfc-editor.org
files: src/discovery.zig
area: network
summary: The query packet (PTR questions with the unicast bit) and the reading of the PTR, SRV, TXT, and A records of an answer.
```

RFC 1035 (DNS messages and name compression), RFC 6762 (Multicast DNS), and RFC 6763 (DNS-Based Service Discovery), https://www.rfc-editor.org

**License:** IETF RFCs (the formats)

**Used in:** `src/discovery.zig`

**How zslice uses it:** The query packet (PTR questions with the unicast bit) and the reading of the PTR, SRV, TXT, and A records of an answer. A query from a port other than 5353 gets a unicast answer (RFC 6762, section 6.7).

### Service types of printer servers

```ref
kind: format
source: OctoPrint, Moonraker, PrusaLink, printdeck
license: The names and the TXT keys
link: https://github.com/OctoPrint/OctoPrint
files: src/discovery.zig
area: network
summary: The service types that the finder asks for, and the TXT keys `path`, `model`, and `version`. The `text` of `/api/version` tells printdeck ("Printdeck") and PrusaLink from OctoPrint.
```

The service types of printer servers: `_octoprint._tcp` of the OctoPrint discovery plugin (https://github.com/OctoPrint/OctoPrint, `src/octoprint/plugins/discovery/__init__.py`, AGPL-3.0), `_moonraker._tcp` of the Moonraker zeroconf component (https://github.com/Arksine/moonraker, `moonraker/components/zeroconf.py`, GPL-3.0), `_prusalink._tcp` and `_octoprint._tcp` of PrusaLink (https://github.com/prusa3d/Prusa-Link, `prusa/link/service_discovery.py`, GPL-3.0), and the printdeck service file (`os/board/rootfs/usr/lib/systemd/dnssd/printdeck.dnssd`: `_octoprint._tcp`, port 80)

**License:** The names and the TXT keys (facts, no code)

**Used in:** `src/discovery.zig`

**How zslice uses it:** The service types that the finder asks for, and the TXT keys `path`, `model`, and `version`. The `text` of `/api/version` tells printdeck ("Printdeck") and PrusaLink from OctoPrint. The toolhead object of Klipper through Moonraker (`/printer/objects/query?toolhead`, `axis_minimum` and `axis_maximum`) gives the size of the bed. PrusaSlicer (`src/slic3r/GUI/BonjourDialog.cpp`) also finds printers as `_octoprint._tcp` with the TXT keys `version` and `model`.

### Moonraker API

```ref
kind: format
source: Moonraker
license: GPL-3.0
link: https://moonraker.readthedocs.io/
files: linux/src/net/printer-link.c, tools/farm_sim/farm_sim.py
area: network
summary: The same, for Klipper printers.
```

Moonraker API, https://moonraker.readthedocs.io/ (`/printer/objects/query`, `/server/files/upload`)

**License:** GPL-3.0 (Moonraker; the API, not code)

**Used in:** `linux/src/net/printer-link.c`, `tools/farm_sim/farm_sim.py`

**How zslice uses it:** The same, for Klipper printers.

### Printer webcams

```ref
kind: format
source: OctoPrint, Moonraker, printdeck
license: AGPL-3.0
link: https://docs.octoprint.org/en/master/api/settings.html
files: src/app/printer_status.zig, web/app/link.js, web/app/camera.js, tools/farm_sim/farm_sim.py
area: network
summary: The address of the MJPEG stream and of the snapshot of each printer.
```

The webcams of printers: the `webcam` object of the OctoPrint settings API, https://docs.octoprint.org/en/master/api/settings.html (`webcamEnabled`, `streamUrl`, `snapshotUrl`, `flipH`, `flipV`, `rotate90`, and the `webcams[]` list with `compat.stream` and `compat.snapshot` of OctoPrint 1.9 and later); the webcam API of Moonraker, https://moonraker.readthedocs.io/en/latest/external_api/webcams/ (`GET /server/webcams/list`: `enabled`, `service`, `stream_url`, `snapshot_url`, `flip_horizontal`, `flip_vertical`, `rotation` in degrees clockwise); the webcam of printdeck (`../printdeck`, `deck/internal/octoapi/webcam.go`: `/webcam/stream`, `/webcam/snapshot`, the parameters `w` and `fps`)

**License:** AGPL-3.0 (OctoPrint), GPL-3.0 (Moonraker), printdeck; the APIs, no code

**Used in:** `src/app/printer_status.zig`, `web/app/link.js`, `web/app/camera.js`, `tools/farm_sim/farm_sim.py`

**How zslice uses it:** The address of the MJPEG stream and of the snapshot of each printer. zslice reads `rotate90` as a turn of 90° counterclockwise, as the OctoPrint web page shows it (not checked with a real OctoPrint). The Moonraker services `mjpegstreamer` and `uv4l-mjpeg` give an MJPEG stream; for the other services, zslice polls the snapshot.

### MJPEG over HTTP

```ref
kind: format
source: IETF
license: Public standard
link: https://www.rfc-editor.org/rfc/rfc2046
files: web/app/camera.js, linux/src/ui/camera-view.c, macos/Sources/ZSlice/Core/Camera.swift, tools/farm_sim/farm_sim.py
area: network
summary: The live camera of a printer.
```

MJPEG over HTTP: a `multipart/x-mixed-replace` reply with one JPEG in each part, as mjpg-streamer, ustreamer, and printdeck send it; the multipart format of RFC 2046, https://www.rfc-editor.org/rfc/rfc2046

**License:** Public standard

**Used in:** `web/app/camera.js` (the browser plays it in an `<img>`), `linux/src/ui/camera-view.c`, `macos/Sources/ZSlice/Core/Camera.swift` (URLSession reads the parts), `tools/farm_sim/farm_sim.py`

**How zslice uses it:** The live camera of a printer.

### Cross-Origin-Embedder-Policy credentialless

```ref
kind: format
source: Web standards
license: The web standard
link: https://developer.mozilla.org/docs/Web/HTTP/Headers/Cross-Origin-Embedder-Policy
files: web/app/serve.py, web/app/README.md
area: network
summary: The page stays cross-origin isolated (the threads of the slice), and the `<img>` of a printer camera on another origin loads with no cookies.
```

`Cross-Origin-Embedder-Policy: credentialless`, https://developer.mozilla.org/docs/Web/HTTP/Headers/Cross-Origin-Embedder-Policy

**License:** The web standard (HTML)

**Used in:** `web/app/serve.py`, `web/app/README.md`

**How zslice uses it:** The page stays cross-origin isolated (the threads of the slice), and the `<img>` of a printer camera on another origin loads with no cookies.

### printdeck deck API

```ref
kind: format
source: printdeck
license: AGPL-3.0
files: linux/src/net/printer-link.c
area: network
summary: The filament in the printer, for "Use the filament in the printer".
```

printdeck deck API (same author, AGPL-3.0), `deck/internal/octoapi` of printdeck: `/api/plugin/printdeck` (the filament, the spools, the job)

**License:** AGPL-3.0

**Used in:** `linux/src/net/printer-link.c`

**How zslice uses it:** The filament in the printer, for "Use the filament in the printer".

### STL file format

```ref
kind: format
source: 3D Systems
license: File format
link: https://en.wikipedia.org/wiki/STL_(file_format
files: src/mesh.zig
area: files
summary: The binary and ASCII STL loader and the binary STL writer.
```

STL file format, 3D Systems. Description: https://en.wikipedia.org/wiki/STL_(file_format)

**License:** File format

**Used in:** `src/mesh.zig`

**How zslice uses it:** The binary and ASCII STL loader and the binary STL writer.

### STEP (ISO 10303-21 and the B-rep entities)

```ref
kind: format
source: ISO
license: File format
link: https://www.iso.org/standard/63141.html
version: ISO 10303-21:2016; the entities of ISO 10303-42 in AP203, AP214, and AP242
files: src/step.zig
area: files
summary: The STEP reader: the clear text encoding of the exchange structure, and the B-rep entities of a solid (faces, loops, edges, vertices, curves, surfaces, and units).
```

ISO 10303-21 gives the text form of a STEP file. ISO 10303-42 gives the geometry and the topology of a B-rep solid. The NIST STEP File Analyzer documentation and the public EXPRESS schemas of AP203, AP214, and AP242 list the attributes of each entity. zslice reads the files with its own parser; no code is copied.

**License:** File format (a published ISO standard)

**Used in:** `src/step.zig`

**How zslice uses it:** `step.read` parses the DATA section, reads the units, samples the edges, and makes a mesh of each ADVANCED_FACE.

### Wavefront OBJ file format

```ref
kind: format
source: Wavefront Technologies
license: File format
link: https://paulbourke.net/dataformats/obj/
files: src/mesh.zig
area: files
summary: The OBJ loader reads the vertices and the faces, and makes a fan of triangles from each face.
```

The OBJ format of Wavefront Technologies. Description: https://paulbourke.net/dataformats/obj/

**License:** File format

**Used in:** `src/mesh.zig`

**How zslice uses it:** The loader reads the `v` and `f` lines (indices from 1, or negative from the end, with or without texture and normal indices), and makes a fan of triangles from each face. It skips the other lines.

### ZIP file format

```ref
kind: format
source: PKWARE
license: Public specification
link: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
files: src/zipfile.zig
area: files
summary: The zip records (local header, central directory, end record, and the zip64 records and extra field).
```

PKWARE, ".ZIP File Format Specification" (APPNOTE.TXT), https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT

**License:** Public specification

**Used in:** `src/zipfile.zig`

**How zslice uses it:** The zip records (local header, central directory, end record, and the zip64 records and extra field). The header structs and deflate come from the Zig standard library (MIT).

### Ed25519 signatures

```ref
kind: format
source: IETF
license: IETF document
link: https://www.rfc-editor.org/rfc/rfc8032
files: src/gcode_sign.zig, web/app/signing.js, linux/src/net/signing.c, macos/Sources/ZSlice/Core/Signing.swift
area: gcode
summary: Ed25519 signs the G-code files.
```

RFC 8032, "Edwards-Curve Digital Signature Algorithm (EdDSA)", https://www.rfc-editor.org/rfc/rfc8032

**License:** IETF document

**Used in:** `src/gcode_sign.zig`, `web/app/signing.js`, `linux/src/net/signing.c`, `macos/Sources/ZSlice/Core/Signing.swift`

**How zslice uses it:** Ed25519 signs the G-code files. The code is `std.crypto.sign.Ed25519` of the Zig standard library (MIT) in the core, and WebCrypto in the browser. The test uses the key pair of test 1 of section 7.1.

### SHA-256

```ref
kind: format
source: NIST
license: Public specification
link: https://csrc.nist.gov/pubs/fips/180-4/upd1/final
files: src/gcode_sign.zig, web/app/signing.js
area: gcode
summary: SHA-256 hashes the G-code before the signature, and makes the key id.
```

NIST FIPS 180-4, "Secure Hash Standard", https://csrc.nist.gov/pubs/fips/180-4/upd1/final

**License:** Public specification

**Used in:** `src/gcode_sign.zig`, `web/app/signing.js`

**How zslice uses it:** SHA-256 hashes the G-code before the signature, and makes the key id. The code is `std.crypto.hash.sha2` of the Zig standard library (MIT), and WebCrypto in the browser.

### Base64

```ref
kind: format
source: IETF
license: IETF document
link: https://www.rfc-editor.org/rfc/rfc4648
files: src/gcode_sign.zig
area: gcode
summary: The base64 of the keys and the signatures (`std.base64.standard`).
```

RFC 4648, "The Base16, Base32, and Base64 Data Encodings", https://www.rfc-editor.org/rfc/rfc4648

**License:** IETF document

**Used in:** `src/gcode_sign.zig`

**How zslice uses it:** The base64 of the keys and the signatures (`std.base64.standard`).

### Metal and SwiftUI documentation

```ref
kind: format
source: Apple
license: Documentation
link: https://developer.apple.com/documentation/
files: macos/Sources/ZSlice/Render/, macos/Sources/ZSlice/Views/
area: ui
summary: The Metal API and the SwiftUI windows of the macOS app.
```

Apple, "Metal Shading Language Specification" and the Metal, AppKit, and SwiftUI documentation, https://developer.apple.com/documentation/

**License:** Documentation

**Used in:** `macos/Sources/ZSlice/Render/`, `macos/Sources/ZSlice/Views/`

**How zslice uses it:** The Metal API, the shader language, `CAMetalLayer`, the display link of a view (macOS 14), and the document windows of SwiftUI. The shaders port `src/render/shaders/*` to the Metal Shading Language. The code is new.

### Uniform Type Identifiers

```ref
kind: format
source: Apple
license: Apple documentation
files: macos/Info.plist, macos/Sources/ZSlice/ZSliceApp.swift
area: ui
summary: The file types that the app opens.
```

Uniform Type Identifiers: `public.standard-tesselated-geometry-format` (STL, a system type of macOS) and `org.3mf.3mf` (3MF, declared by the app)

**License:** Apple documentation

**Used in:** `macos/Info.plist`, `macos/Sources/ZSlice/ZSliceApp.swift`

**How zslice uses it:** The file types that the app opens.

### DEFLATE and gzip

```ref
kind: format
source: IETF
license: IETF RFC
link: https://www.rfc-editor.org/rfc/rfc1952
files: macos/Sources/ZSlice/Core/Gzip.swift
area: network
summary: The gzip header and trailer around the raw DEFLATE stream of the Compression framework of Apple, for the estimate of a printdeck.
```

RFC 1951 (DEFLATE) and RFC 1952 (the gzip file format, with the CRC-32), https://www.rfc-editor.org/rfc/rfc1952

**License:** IETF RFC

**Used in:** `macos/Sources/ZSlice/Core/Gzip.swift`

**How zslice uses it:** The gzip header and trailer around the raw DEFLATE stream of the Compression framework of Apple, for the estimate of a printdeck. The code is new.

### 3MF Core Specification

```ref
kind: format
source: 3MF Consortium
license: BSD-2-Clause
link: https://github.com/3MFConsortium/spec_core
files: src/threemf.zig
area: files
summary: The 3MF package, the model file, objects, components, build items, transforms, and units.
```

3MF Consortium, "3MF Core Specification" 1.3 and "Production Extension", https://github.com/3MFConsortium/spec_core

**License:** BSD-2-Clause (the specification)

**Used in:** `src/threemf.zig`

**How zslice uses it:** The 3MF package, the model file, objects, components, build items, transforms, and units. The code is new.

### printdeck API and queue

```ref
kind: format
source: printdeck
license: AGPL-3.0
link: https://github.com/beetlebugorg/printdeck
files: tools/farm_sim/farm_sim.py
area: network
summary: The simulated printdecks of the farm simulator answer as printdeck does, and keep a file in the queue until a press on the deck.
```

The printdeck API (deck/internal/octoapi in https://github.com/beetlebugorg/printdeck): `/api/plugin/printdeck` (the roll, the limits, the job) and its queue (`/api/plugin/printdeck/queue`, the move and the delete of an item); a printdeck never starts a print by itself

**License:** AGPL-3.0 (printdeck; the API, not code)

**Used in:** `tools/farm_sim/farm_sim.py`

**How zslice uses it:** The simulated printdecks of the farm simulator answer as printdeck does, and keep a file in the queue until a press on the deck.

### FTP, FTPS, and MQTT

```ref
kind: format
source: IETF, OASIS
license: Public standards
link: https://www.rfc-editor.org/rfc/rfc959
files: macos/Sources/ZSlice/Core/Bambu.swift, macos/tools/fake_bambu.py, src/mqtt.zig
area: network
summary: The FTPS upload and the MQTT packets of the Bambu link of the macOS app.
```

RFC 959 (FTP), https://www.rfc-editor.org/rfc/rfc959; RFC 4217 (FTP over TLS: `PBSZ`, `PROT P`, and the implicit TLS of port 990), https://www.rfc-editor.org/rfc/rfc4217; MQTT Version 3.1.1 (OASIS Standard), https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/mqtt-v3.1.1.html

**License:** Public standards

**Used in:** `macos/Sources/ZSlice/Core/Bambu.swift`, `macos/tools/fake_bambu.py`, `src/mqtt.zig`

**How zslice uses it:** The FTPS upload (`USER`, `PASS`, `TYPE I`, `PASV`, `STOR`, the replies) and the MQTT packets (`CONNECT`, `CONNACK`, `SUBSCRIBE`, `PUBLISH`, `DISCONNECT`, the remaining length) of the Bambu link of the macOS app, and of its test server. The code is new.

### RTSP, RTP, and H.264

```ref
kind: format
source: IETF, ITU-T
license: Public standards
link: https://www.rfc-editor.org/rfc/rfc2326
files: src/rtsp.zig, macos/Sources/ZSlice/Core/Camera.swift, macos/Sources/ZSlice/Core/H264Decoder.swift
area: network
summary: The RTSP camera session of a Bambu Lab printer and its H.264 frames.
```

RFC 2326 (RTSP 1.0), https://www.rfc-editor.org/rfc/rfc2326; RFC 2617 (HTTP Digest and Basic login, MD5), https://www.rfc-editor.org/rfc/rfc2617; RFC 4566 (SDP), https://www.rfc-editor.org/rfc/rfc4566; RFC 3550 (RTP), https://www.rfc-editor.org/rfc/rfc3550; RFC 6184 (H.264 over RTP: single NAL units, STAP-A, FU-A, sprop-parameter-sets), https://www.rfc-editor.org/rfc/rfc6184; ITU-T H.264 Annex B (the byte stream with start codes), https://www.itu.int/rec/T-REC-H.264

**License:** Public standards

**Used in:** `src/rtsp.zig`, `macos/Sources/ZSlice/Core/Camera.swift`, `macos/Sources/ZSlice/Core/H264Decoder.swift`

**How zslice uses it:** The RTSP session of the camera of a Bambu Lab printer (DESCRIBE, SETUP with RTP over the TCP connection, PLAY, the keep-alive, the login), and the H.264 frames that it gives in Annex B. The Mac app decodes them with VideoToolbox of macOS. The code is new.

### PNG

```ref
kind: format
source: W3C
license: W3C specification
link: https://www.w3.org/TR/png-3/
files: src/bed.zig
area: files
summary: The chunks, the filters of the rows (Paeth among them), and the color types of the texture reader.
```

PNG (Portable Network Graphics) Specification, W3C, https://www.w3.org/TR/png-3/

**License:** W3C specification

**Used in:** `src/bed.zig`

**How zslice uses it:** The chunks, the filters of the rows (Paeth among them), and the color types of the texture reader. The zlib stream goes through `std.compress.flate` of the Zig standard library.

### The header and end comments of slicer G-code

```ref
kind: format
source: CuraEngine, PrusaSlicer, OrcaSlicer, Bambu Studio
license: the conventions of the files (no code)
link: https://github.com/Ultimaker/CuraEngine
files: src/gcode_meta.zig
area: gcode
summary: The G-code viewer reads the name of the slicer, the filament length and weight, and the settings of a G-code file from the comments that these slicers write.
```

The header and end comments of the G-code of CuraEngine (`;Filament used:`, `;Generated with Cura_SteamEngine`), PrusaSlicer and OrcaSlicer (`; generated by`, `; filament used [mm] =`), and Bambu Studio (`; BambuStudio`, `; total filament length [mm] :`).

**License:** the conventions of the files (no code)

**Used in:** `src/gcode_meta.zig`

**How zslice uses it:** The name of the slicer, the filament length and weight, and the settings of a G-code file, for the embeddable viewer and the printdeck deck. The code is new.
