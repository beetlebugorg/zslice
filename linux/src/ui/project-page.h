/* project-page.h: the Project page of the side panel.
 *
 * A project is a repository with a printdeck.yml (src/project.zig): the
 * parts to print, with their files, printer, Cura profile, material, and
 * settings. The page is the same as the Project tab of the web app
 * (web/app/project.js):
 *
 * - Open a project from GitHub ("owner/repo", or a github.com URL, also
 *   with /tree/<branch>), or from a folder on this computer.
 * - Choose the parts and their counts. The core puts them on plates.
 * - Open a plate: the page reads its files, and the model loads its
 *   profiles, settings, and parts, and slices it (project mode, see
 *   app-model.h).
 * - Each plate has a status (to print, printing, printed, failed). A print
 *   that the window sends sets "printing" on the open plate.
 *
 * The project, the counts, the status, and the open plate stay in
 * <config>/zslice/project.json across a restart. After a restart, the page
 * opens the folder again from its path, or gets the list of files from
 * GitHub again at the saved commit.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_project_page_new(ZgModel *model);
