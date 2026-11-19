/* native-surface.c: see native-surface.h.
 *
 * References (see REFERENCES.md): adapted from the Wayland subsurface of
 * Lookout Marine (linux/src/engine/surface.c, same author, MIT).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "native-surface.h"

#include <gdk/wayland/gdkwayland.h>
#include <wayland-client.h>

struct _ZgNativeSurface {
    zs_surface handle;
    int x, y, scale;
    struct wl_surface *wl_surface;
    struct wl_subsurface *wl_subsurface;
    struct wl_subcompositor *wl_subcompositor;
    struct wl_event_queue *wl_queue;
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct wl_subcompositor **out = data;
    if (g_strcmp0(interface, wl_subcompositor_interface.name) == 0) {
        *out = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {}

static const struct wl_registry_listener registry_listener = {registry_global, registry_global_remove};

ZgNativeSurface *zg_native_surface_new(GdkSurface *parent, int x, int y, int scale, GError **error) {
    if (!GDK_IS_WAYLAND_SURFACE(parent)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                            "the 3D view needs Wayland (X11 is not supported yet)");
        return NULL;
    }
    GdkDisplay *display = gdk_surface_get_display(parent);
    struct wl_display *wl_display = gdk_wayland_display_get_wl_display(display);
    struct wl_compositor *compositor = gdk_wayland_display_get_wl_compositor(display);
    struct wl_surface *wl_parent = gdk_wayland_surface_get_wl_surface(parent);
    if (!wl_display || !compositor || !wl_parent) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "the window has no Wayland surface yet");
        return NULL;
    }

    ZgNativeSurface *self = g_new0(ZgNativeSurface, 1);
    self->x = x;
    self->y = y;
    self->scale = MAX(1, scale);

    /* GDK gives no subcompositor, so bind it from the registry, on a private
     * queue: a roundtrip on the GDK queue would run input events inside a
     * widget callback. */
    self->wl_queue = wl_display_create_queue(wl_display);
    struct wl_display *wrapped = wl_proxy_create_wrapper(wl_display);
    wl_proxy_set_queue((struct wl_proxy *)wrapped, self->wl_queue);
    struct wl_registry *registry = wl_display_get_registry(wrapped);
    wl_proxy_wrapper_destroy(wrapped);
    wl_registry_add_listener(registry, &registry_listener, &self->wl_subcompositor);
    wl_display_roundtrip_queue(wl_display, self->wl_queue);
    wl_registry_destroy(registry);
    if (!self->wl_subcompositor) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "the compositor has no wl_subcompositor");
        zg_native_surface_free(self);
        return NULL;
    }

    /* On the default queue: GDK reads that queue, and wl_surface has
     * events. */
    self->wl_surface = wl_compositor_create_surface(compositor);
    self->wl_subsurface = wl_subcompositor_get_subsurface(self->wl_subcompositor, self->wl_surface, wl_parent);
    /* Below the window: the view shows through the transparent hole. */
    wl_subsurface_place_below(self->wl_subsurface, wl_parent);
    /* An empty input region: the events go to the GTK widget. */
    struct wl_region *empty = wl_compositor_create_region(compositor);
    wl_surface_set_input_region(self->wl_surface, empty);
    wl_region_destroy(empty);
    /* Each frame is opaque, but its format has alpha (see makeSwapchain in
     * src/render/vk.zig): the opaque region tells the compositor. */
    struct wl_region *all = wl_compositor_create_region(compositor);
    wl_region_add(all, 0, 0, INT32_MAX, INT32_MAX);
    wl_surface_set_opaque_region(self->wl_surface, all);
    wl_region_destroy(all);
    wl_subsurface_set_position(self->wl_subsurface, x, y);
    /* Desync: a frame shows when Vulkan presents it, not when GTK commits
     * the window. */
    wl_subsurface_set_desync(self->wl_subsurface);
    wl_surface_set_buffer_scale(self->wl_surface, self->scale);
    wl_surface_commit(self->wl_surface);

    self->handle.kind = ZS_SURFACE_WAYLAND;
    self->handle.display = wl_display;
    self->handle.surface = self->wl_surface;
    return self;
}

void zg_native_surface_free(ZgNativeSurface *self) {
    if (!self) return;
    g_clear_pointer(&self->wl_subsurface, wl_subsurface_destroy);
    g_clear_pointer(&self->wl_surface, wl_surface_destroy);
    g_clear_pointer(&self->wl_subcompositor, wl_subcompositor_destroy);
    g_clear_pointer(&self->wl_queue, wl_event_queue_destroy);
    g_free(self);
}

const zs_surface *zg_native_surface_handle(ZgNativeSurface *self) {
    return &self->handle;
}

void zg_native_surface_move(ZgNativeSurface *self, int x, int y, int scale) {
    scale = MAX(1, scale);
    if (x == self->x && y == self->y && scale == self->scale) return;
    self->x = x;
    self->y = y;
    self->scale = scale;
    wl_subsurface_set_position(self->wl_subsurface, x, y);
    wl_surface_set_buffer_scale(self->wl_surface, scale);
    wl_surface_commit(self->wl_surface);
}

void zg_native_surface_hide(ZgNativeSurface *self) {
    /* A subsurface with no buffer is hidden. The next present shows it. */
    wl_surface_attach(self->wl_surface, NULL, 0, 0);
    wl_surface_commit(self->wl_surface);
}
