/* app-model.h: the app core as a GObject.
 *
 * ZgModel owns the zs_app of the core. The core sends its events from a
 * worker thread. ZgModel moves each event to the GTK main thread and emits
 * the "core-event" signal there, so that the UI code runs on one thread
 * only.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "zslice-app.h"

G_BEGIN_DECLS

#define ZG_TYPE_MODEL (zg_model_get_type())
G_DECLARE_FINAL_TYPE(ZgModel, zg_model, ZG, MODEL, GObject)

ZgModel *zg_model_new(void);

/* The core. Call it only from the main thread. */
zs_app *zg_model_core(ZgModel *self);
/* The plate set: one app for each plate; zg_model_core is the app of the
 * active plate. "plates-changed" follows a change of the list, of the
 * active plate, or of a status. */
zs_set *zg_model_plate_set(ZgModel *self);

/* The name of the loaded model file, or NULL. */
const char *zg_model_name(ZgModel *self);

/* Loads an STL file from memory and starts a slice. */
gboolean zg_model_load(ZgModel *self, const char *name, const void *data, gsize len, GError **error);

/* Adds a model to the plate as a new part (or loads it, if the plate is
 * empty), and starts a new slice. */
gboolean zg_model_add(ZgModel *self, const char *name, const void *data, gsize len, GError **error);

/* The selected part of the plate (Ctrl+click), or -1. "part-selected"
 * follows each change. */
void zg_model_select_part(ZgModel *self, gint64 part);
gint64 zg_model_selected_part(ZgModel *self);
/* The plate: each call changes the core, emits "plate-changed", and
 * starts a new slice. */
void zg_model_part_move(ZgModel *self, size_t i, double x, double y);
void zg_model_part_rotate(ZgModel *self, size_t i, double degrees);
/* A setting of one part (see zs_app_part_setting_set): value NULL gives
 * the part the value of the plate again. FALSE for a bad value. */
gboolean zg_model_part_setting_set(ZgModel *self, size_t i, const char *name, const char *value);
/* The part whose settings the editors change (zg_model_get_for and
 * zg_model_set_for, out of a layer scope), or -1 for the plate. Only the
 * project and filament settings belong to a part. "part-scope-changed"
 * follows. */
void zg_model_set_part_scope(ZgModel *self, gint64 part);
/* The scope of the global settings (for all prints): the editors change
 * the global project settings (zs_app_global_setting_set), saved in
 * global.toml. */
#define ZG_SCOPE_GLOBAL ((gint64)-2)
/* Clears a global setting (the default again). */
gboolean zg_model_global_clear(ZgModel *self, const char *key);
gint64 zg_model_part_scope(ZgModel *self);
/* The value of a setting of part i, or NULL if it has the value of the
 * plate. Free with g_free. */
char *zg_model_part_setting(ZgModel *self, size_t i, const char *name);
/* Placement (see zs_app_part_scale and the calls after it). The scale is
 * uniform here (1 = 100 %). */
void zg_model_part_scale(ZgModel *self, size_t i, double s);
void zg_model_part_turn(ZgModel *self, size_t i, int axis, double degrees);
void zg_model_part_put_down_at(ZgModel *self, size_t i, double x, double y, double z);
void zg_model_part_place(ZgModel *self, size_t i, int mode, int axis);
void zg_model_part_reset(ZgModel *self, size_t i);
gboolean zg_model_plate_smart_place(ZgModel *self);
/* Plates (see zs_set): each plate has its own app, settings, undo list,
 * and slice. The set slices the plates in the background. */
void zg_model_plate_select(ZgModel *self, size_t i);
void zg_model_plate_add(ZgModel *self);
void zg_model_plate_remove(ZgModel *self, size_t i);
void zg_model_part_remove(ZgModel *self, size_t i);
/* A copy of part i at a free place on the bed, with its settings (see
 * zs_app_part_duplicate). Returns the index of the copy, or -1. */
gint64 zg_model_part_duplicate(ZgModel *self, size_t i);
/* Splits part i into its separate bodies (zs_app_part_split): the count of
 * new parts (at index i on), 0 for a part of one body, or -1. */
gint64 zg_model_part_split(ZgModel *self, size_t i);
/* Applies the status of a printer (zs_app_apply_printer_status): what 1
 * the machine, 2 the filament, 3 both. */
void zg_model_apply_printer_status(ZgModel *self, const zs_printer_status *status, int what);
gboolean zg_model_plate_arrange(ZgModel *self);
void zg_model_plate_clear(ZgModel *self);

/* Sets a setting and starts a new slice. */
gboolean zg_model_set(ZgModel *self, const char *key, const char *value, GError **error);

/* Gets a setting as text. Free the result with g_free. */
char *zg_model_get(ZgModel *self, const char *key);

/* The selected path (an index into zs_app_toolpaths), or -1. A new slice
 * clears it. "selection-changed" follows each change. */
void zg_model_select(ZgModel *self, gint64 path);
gint64 zg_model_selected(ZgModel *self);
/* TRUE if the user selected a line, and the last slice has no line of that
 * kind at its place (the next slice can bring it back). */
gboolean zg_model_selection_lost(ZgModel *self);
/* A multiple selection (Shift+click): adds the line, or removes it if it
 * is in the selection. The first line stays the line of the inspector.
 * A plain zg_model_select clears the other lines. */
void zg_model_toggle_more(ZgModel *self, gint64 path);
/* The other lines of the selection (n of them; valid until the next
 * change of the selection). */
const gint64 *zg_model_more(ZgModel *self, guint *n);
/* Support marks (see zs_app_mark_add): each call slices again. */
void zg_model_mark_add(ZgModel *self, double x, double y, double z, double r, int kind);
size_t zg_model_mark_remove_near(ZgModel *self, double x, double y, double z, double r);
/* Changes the kind (enum zs_mark_kind) and the radius of mark i, or
 * removes it; slices again. */
void zg_model_mark_set(ZgModel *self, size_t i, int kind, double r);
void zg_model_mark_remove(ZgModel *self, size_t i);
void zg_model_marks_clear(ZgModel *self);
/* With a selected line: TRUE fades all other lines (ghosts), so only the
 * selection is solid. FALSE (the default) keeps their colors. */
/* Selects one segment of a line (segment k goes from point k to point
 * k + 1), or -1 for the whole line. It selects the line first if it is a
 * new line. Signal: segment-changed(gint64 segment). zg_model_select clears
 * the segment. */
void zg_model_select_segment(ZgModel *self, gint64 path, gint64 segment);
gint64 zg_model_segment(ZgModel *self);
void zg_model_set_isolate(ZgModel *self, gboolean on);
gboolean zg_model_isolate(ZgModel *self);

/* The gaps view: the previews show the gaps of the top layer in red (see
 * zs_app_layer_gaps), and a click on a gap selects it. "gaps-changed"
 * follows each change of the flag or of the selected gap. */
void zg_model_set_gaps(ZgModel *self, gboolean on);
gboolean zg_model_gaps(ZgModel *self);
/* Selects gap `index` of layer `layer` (index -1: no gap). */
void zg_model_select_gap(ZgModel *self, gint64 layer, gint64 index);
/* The selected gap, or -1; `layer` (can be NULL) gets its layer. */
gint64 zg_model_selected_gap(ZgModel *self, gint64 *layer);

/* The focus of the previews: the features whose lines a setting changes
 * (a bit for each enum zs_feature, 0 for no focus), and if only the first
 * layer. The settings browser sets it. "focus-changed" follows each
 * change. */
void zg_model_set_focus(ZgModel *self, guint32 features, gboolean first_layer_only);
guint32 zg_model_focus(ZgModel *self, gboolean *first_layer_only);

/* The scope of the edits of the inspector: all layers (on = FALSE), or
 * the layers with a top z from z_min to z_max (an override for each edit,
 * zs_app_override_set). z_show is the z of the selection: the editors show
 * the values there. "scope-changed" follows each change. */
void zg_model_set_scope(ZgModel *self, gboolean on, double z_min, double z_max, double z_show);
gboolean zg_model_scope(ZgModel *self, double *z_min, double *z_max, double *z_show);

/* zg_model_get and zg_model_set for an editor of the inspector (scoped):
 * in a layer scope, they read the value at z_show and set an override. */
char *zg_model_get_for(ZgModel *self, const char *key, gboolean scoped);
gboolean zg_model_set_for(ZgModel *self, const char *key, const char *value, gboolean scoped, GError **error);
/* TRUE if an override of the setting covers z_show of the scope. */
gboolean zg_model_overridden(ZgModel *self, const char *key);
/* Removes the change of the setting for the scope (or, if there is none
 * for exactly the scope, the changes at z_show), and slices again. */
void zg_model_clear_override(ZgModel *self, const char *key);

/* Layer profiles (see zs_app_profile_set): names a layer range, or
 * removes it with all its changes (and slices again). Both emit
 * "profiles-changed". */
void zg_model_profile_set(ZgModel *self, double z_min, double z_max, const char *name);
void zg_model_profile_remove(ZgModel *self, double z_min, double z_max);
/* Asks the settings browser to edit the profile of the range
 * ("open-profile"). */
void zg_model_open_profile(ZgModel *self, double z_min, double z_max);

/* Makes printer `id` the current printer: saves the machine settings of
 * the printer before, and loads the machine profile of the new one.
 * "printer-changed" follows. */
void zg_model_use_printer(ZgModel *self, const char *id);

/* The filament settings from what a printer tells of its filament: the
 * built-in profile of the material, and the name, the diameter (> 0) and
 * the color of the roll (each can be NULL). Saves them. */
void zg_model_filament_from_printer(ZgModel *self, const char *material, const char *name, double diameter, const char *color);
/* The roll of filament in the printer: a key (letters, digits, dashes),
 * or NULL for none. The filament settings follow the roll: the settings
 * of the roll before go to its file (rolls/<key>.toml), and the settings
 * of a roll with a file load. Returns TRUE if the roll had a file; with
 * FALSE the caller sets the settings of a new roll. */
gboolean zg_model_set_roll(ZgModel *self, const char *roll);
const char *zg_model_roll(ZgModel *self);

/* The quality profile (fine, standard, ...: a built-in profile, or a
 * profile of the user in profiles/project/): the level under the changes
 * of this print. keep_edits: the changes of this print stay. Saves the
 * name as the preference profile_project. */
gboolean zg_model_set_quality(ZgModel *self, const char *name, gboolean keep_edits);
const char *zg_model_quality(ZgModel *self);
/* Where the value of a setting comes from, for the plate (part -1) or a
 * part: the text to show ("fine", "Gray", "This print", "This part"), or
 * NULL for the built-in default. `level` (can be NULL) gets the enum
 * zs_level. Free with g_free. */
char *zg_model_source_text(ZgModel *self, const char *key, gint64 part, int *level);
/* The value of a setting with no change of this print: the value of a
 * reset. Free with g_free. */
char *zg_model_base_get(ZgModel *self, const char *key);
/* The formula of a setting (the text after "="), or NULL. A setting gets
 * one from zg_model_set with a value that starts with "=". Free with
 * g_free. */
char *zg_model_formula(ZgModel *self, const char *key);
/* The full profile of a group (see zs_app_profile_write). Free with g_free. */
char *zg_model_profile_text(ZgModel *self, int group);
/* The key of a roll for zg_model_set_roll: the printer ID and the roll ID
 * of the printer, with letters, digits, and dashes. Free with g_free. */
char *zg_model_roll_key(const char *printer, const char *roll_id);

/* A roll of filament at the printer (printdeck). */
typedef struct {
    char *id, *name, *material, *color;
    double left; /* grams */
} ZgRoll;
/* The rolls of the current printer, from its last status: copies them. */
void zg_model_set_rolls(ZgModel *self, const char *printer, const ZgRoll *rolls, size_t n);
/* The rolls, and the printer ID they are of (can be NULL). */
const ZgRoll *zg_model_rolls(ZgModel *self, size_t *n, const char **printer);
/* Uses a roll of the printer: its saved settings, or for a roll with no
 * saved settings, the settings now (the same material) or of its
 * material, with its name and color. */
void zg_model_use_roll(ZgModel *self, const ZgRoll *roll);

/* Undo and redo of the settings (all three groups). A burst of changes
 * (a drag of a slider) is one step. "undo-changed" follows each step. */
gboolean zg_model_undo(ZgModel *self);
gboolean zg_model_redo(ZgModel *self);
gboolean zg_model_can_undo(ZgModel *self);
/* The tools of the preview: select a line (the default), move and turn a
 * part (as with Ctrl), or measure (the measure tape). "tool-changed"
 * follows a change. */
/* Turn: rings around the selected part turn it about X, Y, or Z. */
typedef enum { ZG_TOOL_SELECT = 0, ZG_TOOL_MOVE = 1, ZG_TOOL_MEASURE = 2, ZG_TOOL_TURN = 3 } ZgTool;
ZgTool zg_model_tool(ZgModel *self);
void zg_model_set_tool(ZgModel *self, ZgTool tool);
/* The measure tape: up to two points (x, y, z in mm). A third point starts
 * a new measure. "measure-changed" follows each change. zg_model_measure
 * gives the number of points and the points. */
/* Moves point i of the measure tape (a drag of an end of it). */
void zg_model_measure_move(ZgModel *self, int i, double x, double y, double z);
void zg_model_measure_add(ZgModel *self, double x, double y, double z);
/* A point at the center of a circle (shape 1) or an arc (shape 2) of the
 * radius, and the radius of point i (0: a plain point). */
void zg_model_measure_add_shape(ZgModel *self, double x, double y, double z, double radius, int shape);
double zg_model_measure_radius(ZgModel *self, int i, int *shape);
void zg_model_measure_clear(ZgModel *self);
int zg_model_measure(ZgModel *self, const double **pts);

/* The history: the steps of undo and redo as one list, the oldest first.
 * zg_model_history_current is the step now; the steps after it are the
 * redo steps. zg_model_history_changes gives the changes of step i from
 * step i - 1 (zs_history_diff lines; NULL for step 0), and
 * zg_model_history_describe gives them in words ("scope\tchange" lines).
 * zg_model_history_goto goes to step i: the preview slices at it.
 * zg_model_history_revert undoes one change line and keeps the others. */
guint zg_model_history_count(ZgModel *self);
guint zg_model_history_current(ZgModel *self);
gint64 zg_model_history_time(ZgModel *self, guint i);
char *zg_model_history_changes(ZgModel *self, guint i);
char *zg_model_history_describe(ZgModel *self, const char *changes);
gboolean zg_model_history_goto(ZgModel *self, guint i);
/* Clears the history after step i: goes to step i first if it is not the
 * step now, then drops the later steps (redo cannot bring them back). */
gboolean zg_model_history_truncate(ZgModel *self, guint i);
/* The setting whose editor has the focus now, or NULL (from the window).
 * The changes of one setting are one step while its editor keeps the
 * focus; a move of the focus to another setting or away ends the step. */
void zg_model_history_set_focus(ZgModel *self, const char *key);
gboolean zg_model_history_revert(ZgModel *self, const char *line);
gboolean zg_model_can_redo(ZgModel *self);

/* Loads a profile text into a group (enum zs_group): the built-in
 * defaults, then the text. On an error the settings stay as they were.
 * Saves the group and slices again. */
gboolean zg_model_load_profile(ZgModel *self, int group, const char *text, size_t len, GError **error);
/* The settings of a group that differ from the defaults, as profile text
 * (zs_app_state_write). Free with g_free. */
char *zg_model_group_text(ZgModel *self, int group);

/* Emits "setting-changed" for each setting whose name starts with
 * `prefix` (for example "filament."), after a change of many values. */
void zg_model_announce(ZgModel *self, const char *prefix);
/* Emits "printers-edited": the list or the names of the printers changed. */
void zg_model_printers_edited(ZgModel *self);
/* Saves a group soon (after a change outside zg_model_set). */
void zg_model_save_soon(ZgModel *self, int group);

/* The time of the last slice, from the request to the result, in ms. */
double zg_model_slice_ms(ZgModel *self);

/* ---- printdeck.yml projects (include/zslice-app.h) ----
 *
 * Project mode: a plate of a project is on the view. Its machine settings
 * come from the project, so the model does not save them in the profile
 * of the printer of the user. "project-changed" follows each start and end
 * of project mode. */

/* Loads plate `plate` of a project: the machine, filament, and project
 * profiles of the plate (zs_project_profiles), then its settings and
 * parts (zs_app_project_load), and slices. Starts project mode, and the
 * title of the window is `title`. Returns ZS_OK, ZS_OUT_OF_RANGE (the
 * parts do not all fit on the bed; message says it), or an error with the
 * reason in message. Free message with g_free. */
int zg_model_project_load(ZgModel *self, const zs_files *files, const char *yml, const char *counts, size_t plate,
                          const char *title, char **message);
gboolean zg_model_project_active(ZgModel *self);
/* Ends project mode: the machine settings of the current printer of the
 * user load again. */
void zg_model_project_end(ZgModel *self);
/* The window sent the plate to a printer to print: in project mode,
 * "project-sent" follows. */
void zg_model_project_sent(ZgModel *self);

/* The text for a core status code. */
const char *zg_status_text(int status);

/* Holds the slices while hold is TRUE (a ring drag): each change marks the
 * plate, and one slice starts when hold goes back to FALSE. */
void zg_model_hold(ZgModel *self, gboolean hold);

G_END_DECLS
