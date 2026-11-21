/* Links the core with MSVC and calls it through the C API.
 *
 * The test writes a short G-code file under a folder with characters
 * outside the ANSI code page. It opens the file by its UTF-8 path, because
 * each path in the C API is UTF-8.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <string.h>

#include "zslice.h"
#include "zslice-app.h"

static const char gcode[] =
    "G21\nG90\nM83\n"
    "G1 Z0.2 F600\n"
    "G1 X0 Y0 F3000\n"
    "G1 X10 Y0 E0.5 F1200\n"
    "G1 X10 Y10 E0.5\n"
    "G1 X0 Y10 E0.5\n";

static int fail(const char *what) {
    fprintf(stderr, "FAIL: %s (last error %lu)\n", what, GetLastError());
    return 1;
}

int main(void) {
    wchar_t dir[MAX_PATH];
    wchar_t path[MAX_PATH];
    char utf8[MAX_PATH * 4];
    DWORD written = 0;
    HANDLE file;
    zs_gcode *g = NULL;
    zs_gcode_info info;
    int status;

    printf("zslice %s\n", zs_version());

    if (!GetTempPathW(MAX_PATH, dir)) return fail("GetTempPathW");
    if (wcscat_s(dir, MAX_PATH, L"zslice-é世界-test") != 0) return fail("folder name");
    if (!CreateDirectoryW(dir, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return fail("CreateDirectoryW");
    if (swprintf_s(path, MAX_PATH, L"%ls\\pärt.gcode", dir) < 0) return fail("file name");

    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return fail("CreateFileW");
    WriteFile(file, gcode, (DWORD)strlen(gcode), &written, NULL);
    CloseHandle(file);
    if (written != strlen(gcode)) return fail("WriteFile");

    if (!WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, sizeof utf8, NULL, NULL)) return fail("UTF-8 path");

    status = zs_gcode_open(utf8, &g);
    DeleteFileW(path);
    RemoveDirectoryW(dir);
    if (status != ZS_OK) {
        fprintf(stderr, "FAIL: zs_gcode_open: %s\n", zs_status_string(status));
        return 1;
    }

    status = zs_gcode_get_info(g, &info);
    if (status != ZS_OK) {
        fprintf(stderr, "FAIL: zs_gcode_get_info: %s\n", zs_status_string(status));
        zs_gcode_free(g);
        return 1;
    }
    if (info.size != strlen(gcode) || info.moves == 0) {
        fprintf(stderr, "FAIL: read %llu bytes, %llu moves\n", info.size, info.moves);
        zs_gcode_free(g);
        return 1;
    }
    printf("ok: %llu bytes, %llu moves, by a UTF-8 path\n", info.size, info.moves);
    zs_gcode_free(g);
    return 0;
}
