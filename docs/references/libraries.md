# Libraries and tools

The code of other projects in the zslice binaries, the libraries that the app shells link, the code from projects of the same author, and the programs of the test tools.

The zslice library, command line tool, and wasm module contain code from the projects under "Code in the binaries". Their license texts are in `licenses/`.

zslice has ports of the code of CuraEngine (see [Cura](cura.md)) and boost::polygon (below). It copies no other code.

## Code in the binaries

### Zig standard library

```ref
kind: code
source: Zig
license: MIT
files: build.zig
texts: licenses/zig-std-MIT.txt
area: build
summary: The compiler links the parts that zslice calls into each binary.
```

Zig standard library

**License:** MIT

**Text:** `licenses/zig-std-MIT.txt`

**Notes:** The compiler links the parts that zslice calls into each binary.

### musl libc math functions

```ref
kind: code
source: musl
license: MIT
files: src/offset.zig
texts: licenses/musl-MIT.txt
area: slicing
summary: The Zig standard library has ports of musl math functions.
```

musl libc (math functions in the Zig standard library, for example `atan2` and `acos`)

**License:** MIT

**Text:** `licenses/musl-MIT.txt`

**Notes:** The Zig standard library has ports of musl math functions. The port keeps the musl notice.

### Go strconv parseFloat

```ref
kind: code
source: Go
license: BSD-3-Clause
files: src/mesh.zig, src/toml.zig
texts: licenses/go-BSD-3-Clause.txt
area: files
summary: zslice parses numbers in ASCII STL files and in settings with `parseFloat`.
```

Go (`std.fmt.parseFloat` in the Zig standard library is derived from Go `strconv/atof.go`)

**License:** BSD-3-Clause

**Text:** `licenses/go-BSD-3-Clause.txt`

**Notes:** zslice parses numbers in ASCII STL files and in settings with `parseFloat`.

### ARM optimized-routines acos and atan

```ref
kind: code
source: ARM optimized-routines
license: MIT
files: src/offset.zig, src/arachne/skeletal.zig
texts: licenses/arm-optimized-routines.txt
area: walls
summary: `src/offset.zig` uses `acos` for round joins.
```

ARM optimized-routines (`std.math.acos` and `std.math.atan` in the Zig standard library)

**License:** MIT (dual MIT OR Apache-2.0 WITH LLVM-exception; zslice uses the MIT terms)

**Text:** `licenses/arm-optimized-routines.txt`

**Notes:** `src/offset.zig` uses `acos` for round joins. `src/arachne/skeletal.zig` uses `atan` (a port of musl and ARM) for the parabola steps.

### Khronos Vulkan headers

```ref
kind: code
source: Khronos
license: Apache-2.0
files: vendor/vulkan/include, src/render/vk.zig
texts: licenses/vulkan-headers.txt, licenses/apache-2.0.txt
area: ui
summary: The types of the Vulkan renderer.
```

Khronos Vulkan headers (`vendor/vulkan/include`, version 1.4.350, copied from charttable)

**License:** Apache-2.0 (the headers say `SPDX-License-Identifier: Apache-2.0`; the repository also allows MIT)

**Text:** `licenses/vulkan-headers.txt`, `licenses/apache-2.0.txt`

**Notes:** The types of the Vulkan renderer. The headers have declarations only. zslice loads the Vulkan loader at run time and does not link it.

### Zig compiler_rt

```ref
kind: code
source: Zig
license: MIT, and Apache-2.0 WITH LLVM-exception
files: build.zig
texts: licenses/zig-std-MIT.txt
area: build
summary: The LLVM exception removes the notice requirement for compiled code.
```

Zig compiler_rt (parts ported from LLVM compiler-rt)

**License:** MIT, and Apache-2.0 WITH LLVM-exception

**Text:** `licenses/zig-std-MIT.txt`

**Notes:** The LLVM exception removes the notice requirement for compiled code. The entry is here for completeness.

### boost::polygon Voronoi

```ref
kind: code
source: boost
license: Boost Software License 1.0
link: https://github.com/boostorg/polygon
version: commit ddb9c8adadbbb539fe52cb7f8ee0a446ba5ead04
files: src/voronoi.zig, src/voronoi_predicates.zig, src/voronoi_ctypes.zig
texts: licenses/boost-BSL-1.0.txt
area: walls
summary: A Zig port of the boost::polygon sweep line Voronoi diagram of points and segments, with robust predicates.
```

boost::polygon Voronoi, Andrii Sydorchuk, https://github.com/boostorg/polygon, commit `ddb9c8adadbbb539fe52cb7f8ee0a446ba5ead04` (2 May 2025). "Copyright Andrii Sydorchuk 2010-2012."

**License:** Boost Software License 1.0

**Text:** `licenses/boost-BSL-1.0.txt`

**Notes:** `src/voronoi.zig`, `src/voronoi_predicates.zig`, and `src/voronoi_ctypes.zig` are a port to Zig of `include/boost/polygon/voronoi_builder.hpp`, `voronoi_diagram.hpp`, `voronoi_geometry_type.hpp`, `detail/voronoi_structures.hpp`, `detail/voronoi_predicates.hpp`, `detail/voronoi_robust_fpt.hpp`, and `detail/voronoi_ctypes.hpp`: the sweep line Voronoi diagram of points and segments, with robust predicates. The Arachne walls use it. Each file keeps the copyright line and names its sources.

### charttable Direct3D 12 declarations

```ref
kind: code
source: charttable
license: MIT
files: src/render/c_d3d12.zig, src/render/d3d12.zig
texts: licenses/charttable-MIT.txt
area: ui
summary: The COM declarations of Direct3D 12 and DXGI, and the structure of the Windows backend.
```

charttable, `src/gpu/c_d3d12.zig` and `src/gpu/gpu_d3d12.zig` at commit 2a4b6d3 (same author, MIT license)

**License:** MIT

**Text:** `licenses/charttable-MIT.txt`

**Notes:** `src/render/c_d3d12.zig` is a copy of the declarations, with the calls that the zslice backend adds and the IID that `EnumWarpAdapter` needs. `src/render/d3d12.zig` follows the structure of the charttable backend: run-time loading of the DLLs, upload-heap buffers, a composition swapchain, and a WARP fallback. Its draw code is a port of `src/render/vk.zig`.

## Libraries that the app shells link

The shells link these libraries as shared libraries from the system. Their code is not in a zslice binary. The Licenses window of each shell lists them.

### GTK 4

```ref
kind: code
source: GTK 4
license: LGPL-2.1-or-later
files: linux/meson.build
area: ui
summary: LGPL-2.1-or-later.
```

**Shell:** Linux (`linux/`)

**Library:** GTK 4

**License:** LGPL-2.1-or-later

### GLib

```ref
kind: code
source: GLib
license: LGPL-2.1-or-later
files: linux/meson.build
area: ui
summary: LGPL-2.1-or-later.
```

**Shell:** Linux (`linux/`)

**Library:** GLib

**License:** LGPL-2.1-or-later

### cairo

```ref
kind: code
source: cairo
license: LGPL-2.1-only OR MPL-1.1
files: linux/meson.build
area: ui
summary: LGPL-2.1-only OR MPL-1.1.
```

**Shell:** Linux (`linux/`)

**Library:** cairo

**License:** LGPL-2.1-only OR MPL-1.1

### libsoup

```ref
kind: code
source: libsoup
license: LGPL-2.0-or-later
files: linux/src/net/printer-link.c
area: ui
summary: LGPL-2.0-or-later.
```

**Shell:** Linux (`linux/`)

**Library:** libsoup 3 (HTTP for the printer connections)

**License:** LGPL-2.0-or-later

### json-glib

```ref
kind: code
source: json-glib
license: LGPL-2.1-or-later
files: linux/src/net/printer-link.c
area: ui
summary: LGPL-2.1-or-later.
```

**Shell:** Linux (`linux/`)

**Library:** json-glib (the JSON of the printer APIs)

**License:** LGPL-2.1-or-later

### GStreamer

```ref
kind: code
source: GStreamer
license: LGPL-2.1-or-later
files: linux/src/ui/camera-view.c
area: ui
summary: LGPL-2.1-or-later.
```

**Shell:** Linux (`linux/`)

**Library:** GStreamer (the RTSP camera of Bambu Lab printers; optional at build time)

**License:** LGPL-2.1-or-later

### macOS system frameworks

```ref
kind: code
source: Apple
license: Apple system frameworks, part of macOS
files: macos/Sources/ZSlice
area: ui
summary: Apple system frameworks, part of macOS.
```

**Shell:** macOS (`macos/`)

**Library:** The system frameworks of macOS: SwiftUI, AppKit, Metal, QuartzCore, ImageIO, UniformTypeIdentifiers, AVFoundation, Network, CryptoKit, Security

**License:** Apple system frameworks, part of macOS

### Windows system libraries for the printer links

```ref
kind: code
source: Microsoft
license: Windows system libraries, part of Windows
files: windows/src/net, windows/src/prefs
area: network
summary: HTTP, TLS, the H.264 camera decoder, and the encryption of the saved keys in the Windows app.
```

**Shell:** Windows (`windows/`)

**Library:** The system libraries of Windows: WinHTTP (HTTP), Schannel through SSPI (TLS with a pinned certificate), Media Foundation (the H.264 Video Decoder MFT, for the RTSP camera of Bambu Lab printers), DPAPI (`CryptProtectData`, the saved keys), CNG (SHA-256 and random bytes), and Winsock (the printer search)

**License:** Windows system libraries, part of Windows

## Algorithms, formats, and conventions

### Lookout Marine Wayland subsurface

```ref
kind: code
source: Lookout Marine
license: MIT
files: linux/src/ui/native-surface.c
area: ui
summary: Adapted: a Wayland subsurface under the GTK window, with an empty input region, for the Vulkan view.
```

Lookout Marine, `linux/src/engine/surface.c` (same author, MIT license)

**License:** MIT

**Used in:** `linux/src/ui/native-surface.c`

**How zslice uses it:** Adapted: a Wayland subsurface under the GTK window, with an empty input region, for the Vulkan view.

### charttable Vulkan backend

```ref
kind: idea
source: charttable
license: MIT
files: src/render/vk.zig
area: ui
summary: The structure of the Vulkan backend.
```

charttable, `src/gpu/gpu_vk.zig` (same author, MIT license)

**License:** MIT

**Used in:** `src/render/vk.zig`

**How zslice uses it:** The structure of the Vulkan backend: run-time loading of the loader, a surface from the shell, a swapchain sized by the host, a UNORM swapchain format, and SPIR-V words copied at comptime. The code is new.

### Lookout Marine Windows build

```ref
kind: idea
source: Lookout Marine
license: MIT
files: windows/build-core.ps1, windows/ZSlice.vcxproj, windows/src/app/MainWindow.xaml.cpp, windows/src/app/winrt_glue.cpp
area: build
summary: The layout of the Windows core build and of the WinUI project.
```

Lookout Marine, `windows/build-core.ps1` at commit 221df217, and `windows/LookoutMarine.vcxproj`, `windows/src/app/ui/winrt_glue.cpp`, and the panel code of `windows/src/chart/ui/Open.cpp` at commit 232224f3 (same author, MIT license)

**License:** MIT

**Used in:** `windows/build-core.ps1`, `windows/ZSlice.vcxproj`, `windows/src/app/MainWindow.xaml.cpp`, `windows/src/app/winrt_glue.cpp`

**How zslice uses it:** The form of the script: one PowerShell step that runs `zig build lib` for the MSVC target of the platform. The layout of an unpackaged, self-contained WinUI 3 project that builds with msbuild, the unit that compiles the generated XAML files, and a swapchain in a SwapChainPanel with the inverse of the composition scale. The app code is new.

### Core and native shells

```ref
kind: idea
source: Lookout Marine
license: Same author
files: src/app.zig, linux/
area: ui
summary: The structure of the app: the core has the logic, and each shell draws widgets, does file I/O, and moves events to its UI thread.
```

Lookout Marine (same author): a Zig core with a C API and one native shell for each platform

**License:** Same author

**Used in:** `src/app.zig`, `linux/`

**How zslice uses it:** The structure of the app: the core has the logic, and each shell draws widgets, does file I/O, and moves events to its UI thread.

### XcodeGen

```ref
kind: tool
source: XcodeGen
license: MIT
link: https://github.com/yonaskolb/XcodeGen
files: macos/project.yml, macos/ZSlice.xcodeproj
area: build
summary: Makes the Xcode project of the macOS app from `project.yml`.
```

XcodeGen, https://github.com/yonaskolb/XcodeGen

**License:** MIT (a tool; nothing of it goes into the app)

**Used in:** `macos/project.yml`, `macos/ZSlice.xcodeproj`

**How zslice uses it:** Makes the Xcode project of the macOS app from `project.yml`.

## Test tools

zslice runs these programs in its test tools. No code of these programs
is in zslice.

### CuraEngine as a test oracle

```ref
kind: tool
source: CuraEngine
license: AGPL-3.0
link: https://github.com/Ultimaker/CuraEngine
files: tools/compare_cura.py
area: build
summary: A test oracle.
```

CuraEngine (Ultimaker Cura 5.x), https://github.com/Ultimaker/CuraEngine, and the Cura definition files `fdmprinter.def.json` and `fdmextruder.def.json`

**License:** AGPL-3.0 (CuraEngine), LGPL-3.0 (the definitions)

**Used in:** `tools/compare_cura.py`

**How zslice uses it:** A test oracle. The script slices each STL file of the corpus with zslice and with CuraEngine, and compares the layer count, the filament, the time estimate, the speed, and the memory.

### librsvg

```ref
kind: tool
source: librsvg
license: LGPL-2.1-or-later
link: https://gitlab.gnome.org/GNOME/librsvg
files: tools/printer_beds.py
area: printers
summary: Draws the SVG bed textures as images.
```

librsvg (`rsvg-convert`), https://gitlab.gnome.org/GNOME/librsvg

**License:** LGPL-2.1-or-later

**Used in:** `tools/printer_beds.py`

**How zslice uses it:** Draws the SVG bed textures as images.

### Pillow

```ref
kind: tool
source: Pillow
license: MIT-CMU
link: https://python-pillow.org
files: tools/printer_beds.py
area: printers
summary: Reads, scales, and writes the texture images (PNG with a palette).
```

Pillow, https://python-pillow.org

**License:** MIT-CMU (HPND)

**Used in:** `tools/printer_beds.py`

**How zslice uses it:** Reads, scales, and writes the texture images (PNG with a palette).

### NumPy

```ref
kind: tool
source: NumPy
license: BSD-3-Clause
link: https://numpy.org
files: tools/printer_beds.py
area: printers
summary: The arrays of the meshes, and the vertex clustering.
```

NumPy, https://numpy.org

**License:** BSD-3-Clause

**Used in:** `tools/printer_beds.py`

**How zslice uses it:** The arrays of the meshes, and the vertex clustering.
