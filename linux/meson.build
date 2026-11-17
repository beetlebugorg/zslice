# The zslice app for Linux: a GTK4 shell around the Zig app core.
#
# build-core.sh runs `zig build lib` and puts libzslice.a and the two headers
# in the build directory. The shell links the archive. All app logic is in
# the core (include/zslice-app.h); this shell draws widgets, reads and writes
# files, and moves core events to the GTK main thread.

project('zslice-gtk', 'c',
  version: '0.1.0',
  license: 'AGPL-3.0-or-later',
  default_options: ['c_std=gnu11', 'warning_level=2'],
)

cc = meson.get_compiler('c')

# Callback signatures are fixed by the signal, so many have parameters that
# they do not use.
add_project_arguments(cc.get_supported_arguments(
  '-Wno-unused-parameter',
  '-Wno-missing-field-initializers',
), language: 'c')

gtk_dep = dependency('gtk4', version: '>= 4.14')
# The 3D view: the core draws with Vulkan into a Wayland subsurface. The
# shell makes the subsurface with wayland-client (which GTK also uses). The
# core loads the Vulkan loader at run time, so nothing links Vulkan here.
wayland_dep = dependency('wayland-client')
thread_dep = dependency('threads')
m_dep = cc.find_library('m', required: false)
# Printers: HTTP (OctoPrint, Moonraker, printdeck) and JSON. Both are GNOME
# libraries with GTK; other shells use the HTTP of their platform.
soup_dep = dependency('libsoup-3.0')
json_dep = dependency('json-glib-1.0')

find_program('zig', required: true)
build_core = find_program('build-core.sh', native: true)

# zig build has its own cache, so it runs as one target that is always
# stale. The headers are outputs, so that meson builds this target before it
# compiles the C files.
core = custom_target('zslice-core',
  output: ['libzslice.a', 'zslice.h', 'zslice-app.h'],
  console: true,
  build_always_stale: true,
  command: [build_core, meson.current_source_dir() / '..', get_option('core-optimize'),
            '@OUTPUT0@', '@OUTPUT1@', '@OUTPUT2@'],
)

executable('zslice-gtk',
  'src/main.c',
  'src/model/app-model.c',
  'src/ui/window.c',
  'src/ui/settings-panel.c',
  'src/ui/inspector.c',
  'src/ui/part-page.c',
  'src/ui/profile-menus.c',
  'src/ui/settings-browser.c',
  'src/ui/setting-row.c',
  'src/ui/setting-editor.c',
  'src/ui/widgets.c',
  'src/ui/preview.c',
  'src/ui/layer-draw.c',
  'src/ui/toolpath-nav.c',
  'src/ui/layer-range.c',
  'src/ui/licenses.c',
  'src/ui/preferences.c',
  'src/ui/cura-compare.c',
  'src/ui/view3d.c',
  'src/ui/native-surface.c',
  'src/prefs/printers.c',
  'src/prefs/cura-stack.c',
  'src/net/printer-link.c',
  core[1], core[2],
  link_with: core[0],
  c_args: ['-DZG_VERSION="' + meson.project_version() + '"'],
  dependencies: [gtk_dep, wayland_dep, thread_dep, m_dep, soup_dep, json_dep],
  install: true,
)

install_data('data/org.beetlebug.Zslice.desktop', install_dir: get_option('datadir') / 'applications')
