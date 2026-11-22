/* float.h: the cards that float over the view: the search, the line card,
 * the part card, and the print card (docs/internals/one-view.md).
 *
 * A card is a child of a GtkOverlay (the preview). A card with a place
 * has its top left corner at that point of the overlay, at its natural
 * size, and it stays inside the overlay. A card with no place uses its
 * alignment and its margins, as any child of an overlay.
 *
 * A card can move with a drag of its head (zg_float_movable). A press on
 * a button or an entry of the head does not move it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

/* Places the cards of `overlay` at their points. Call it once. */
void zg_float_install(GtkWidget *overlay);

/* A new card: a vertical box with the "zg-card" style. The keys of the
 * preview leave a card alone (zg_float_in_card). */
GtkWidget *zg_card_new(void);

/* TRUE if `widget` is a card or in a card. */
gboolean zg_float_in_card(GtkWidget *widget);

/* Puts the top left corner of `card` at x, y of its overlay. */
void zg_float_place(GtkWidget *card, double x, double y);
/* Gives the card its alignment and its margins again. */
void zg_float_unplace(GtkWidget *card);
/* The place of the card. FALSE if it has none. */
gboolean zg_float_get(GtkWidget *card, double *x, double *y);

/* A drag of `handle` moves `card`. moved(card, x, y, data) follows each
 * step of a drag (can be NULL). */
typedef void (*ZgFloatMoved)(GtkWidget *card, double x, double y, gpointer data);
void zg_float_movable(GtkWidget *card, GtkWidget *handle, ZgFloatMoved moved, gpointer data);
/* A fixed card does not move with a drag of its handle (the search on a
 * rail). */
void zg_float_set_fixed(GtkWidget *card, gboolean fixed);
/* TRUE after the user moved the card, until zg_float_forget. */
gboolean zg_float_user_moved(GtkWidget *card);
void zg_float_forget(GtkWidget *card);

/* Where a card goes next to the thing that it is about: it never covers
 * that thing. box: the thing on the screen (x0, y0, x1, y1); area: the free
 * part of the view; w, h: the size of the card. The first side with room
 * for the whole card (right, left, below, above), else the side with the
 * most room. */
void zg_place_beside(const double box[4], const double area[4], double w, double h, double *x, double *y);
/* The free area of the view `host`: the tool strip, the bottom bar, and
 * the layer slider left out. */
void zg_free_area(GtkWidget *host, double area[4]);

/* The head of a card: a bold title at the left (the label is the result,
 * for its text later), the extra widget (can be NULL), and a close button
 * at the right. `head` gets the head box, for zg_float_movable. */
GtkWidget *zg_card_head(GtkWidget *card, GtkWidget **head, GtkWidget *extra, GCallback on_close, gpointer data);
