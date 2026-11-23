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
gnome = import('gnome')

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
# The RTSP camera of Bambu Lab printers: GStreamer (LGPL-2.1-or-later, a
# shared library). GTK uses it for its media too. With no GStreamer, the
# app still reads the JPEG camera of the P1 and A1 printers.
gst_deps = [dependency('gstreamer-1.0', required: false),
            dependency('gstreamer-app-1.0', required: false),
            dependency('gstreamer-video-1.0', required: false)]
have_gst = gst_deps[0].found() and gst_deps[1].found() and gst_deps[2].found()

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
  'src/ui/filaments.c',
  'src/ui/widgets.c',
  'src/ui/float.c',
  'src/ui/search.c',
  'src/ui/part-card.c',
  'src/ui/range-card.c',
  'src/ui/line-card.c',
  'src/ui/shortcuts.c',
  'src/ui/preview.c',
  'src/ui/layer-draw.c',
  'src/ui/toolpath-nav.c',
  'src/ui/layer-range.c',
  'src/ui/history.c',
  'src/ui/project-page.c',
  'src/ui/farm-page.c',
  'src/ui/camera-view.c',
  'src/ui/pair-dialog.c',
  'src/ui/licenses.c',
  'src/ui/preferences.c',
  'src/ui/printer-picker.c',
  'src/ui/cura-compare.c',
  'src/ui/view3d.c',
  'src/ui/support-tool.c',
  'src/ui/clipboard.c',
  'src/ui/label-model.c',
  'src/ui/label-tool.c',
  'src/ui/label-card.c',
  'src/ui/part-mesh.c',
  'src/ui/paint-tool.c',
  'src/ui/paint-card.c',
  'src/ui/bed-model.c',
  'src/ui/native-surface.c',
  'src/ui/open-link.c',
  'src/ui/model-import.c',
  'src/prefs/printers.c',
  'src/prefs/cura-stack.c',
  'src/net/printer-link.c',
  'src/net/bambu-link.c',
  'src/net/signing.c',
  'src/net/discovery.c',
  'src/net/project-source.c',
  'src/net/key-header.c',
  'src/net/deck-filaments.c',
  'src/net/model-download.c',
  core[1], core[2],
  link_with: core[0],
  c_args: ['-DZG_VERSION="' + meson.project_version() + '"',
           '-DZG_BEDS_SRC_DIR="' + meson.current_source_dir() / '..' / 'src' / 'printers' / 'beds' + '"']
          + (have_gst ? ['-DZG_HAVE_GST'] : []),
  dependencies: [gtk_dep, wayland_dep, thread_dep, m_dep, soup_dep, json_dep] + (have_gst ? gst_deps : []),
  install: true,
)

# The .desktop file names the model types and the zslice:// links
# (x-scheme-handler/zslice). An install runs update-desktop-database, so
# the desktop finds the link handler.
install_data('data/org.beetlebug.Zslice.desktop', install_dir: get_option('datadir') / 'applications')
# The icon of the app, in the hicolor theme (tools/icons.sh makes it).
install_subdir('data/icons/hicolor', install_dir: get_option('datadir') / 'icons')
gnome.post_install(update_desktop_database: true, gtk_update_icon_cache: true)

# Tests of the network code with local servers only: `meson test -C
# linux/build`. They need no core and no display.
test('key header', executable('key-header-test', 'tests/key-header-test.c', 'src/net/key-header.c',
                              dependencies: [soup_dep]))
test('deck target', executable('deck-target-test', 'tests/deck-target-test.c', 'src/net/printer-link.c', 'src/net/key-header.c',
                               'src/net/signing.c', 'src/prefs/printers.c', core[1], core[2], link_with: core[0],
                               dependencies: [gtk_dep, thread_dep, m_dep, soup_dep, json_dep]))
# The nozzle codes and the loaded filaments of a printdeck printer: pure
# logic, with no network and no core.
test('deck filaments', executable('deck-filaments-test', 'tests/deck-filaments-test.c', 'src/net/deck-filaments.c',
                                  dependencies: [json_dep]))
# The model of a label of the Label tool: JSON, frame, and shapes, with no
# core and no display.
test('label model', executable('label-model-test', 'tests/label-model-test.c', 'src/ui/label-model.c',
                               dependencies: [json_dep, m_dep]))
# The download of a zslice:// link: a name that resolves to a local
# address gets no connection. A stub resolver gives the addresses, so the
# test sends no packet.
test('model download', executable('model-download-test', 'tests/model-download-test.c', 'src/net/model-download.c',
                                  core[1], core[2], link_with: core[0],
                                  dependencies: [thread_dep, m_dep, soup_dep]))
test('bambu pin', executable('bambu-pin-test', 'tests/bambu-pin-test.c', 'src/net/bambu-link.c', 'src/prefs/printers.c',
                             core[1], core[2], link_with: core[0],
                             dependencies: [gtk_dep, thread_dep, m_dep]))
test('bambu gate', executable('bambu-gate-test', 'tests/bambu-gate-test.c', 'src/net/bambu-link.c', 'src/prefs/printers.c',
                              core[1], core[2], link_with: core[0],
                              dependencies: [gtk_dep, thread_dep, m_dep]))

# The bed models of the printers (src/printers/beds, made by
# tools/printer_library.py). The 3D view loads the file of the current
# printer from share/zslice/beds (see src/ui/bed-model.h).
install_subdir('../src/printers/beds', install_dir: get_option('datadir') / 'zslice')
