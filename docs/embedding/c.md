# C API

The headers are `include/zslice.h` (the slicer) and `include/zslice-app.h` (the app core, for app shells; see `docs/app/README.md`). The library depends only on libc. It links libc so that its threads are the same kind (pthreads) as the threads of the host program.

## Build

```sh
zig build lib -Doptimize=ReleaseFast
```

This makes `zig-out/lib/libzslice.a`, `zig-out/lib/libzslice.so`, `zig-out/include/zslice.h`, and `zig-out/include/zslice-app.h`. Link a program with the static library and `-lc -lpthread`, or with the shared library.

On macOS, the linker, `lipo`, and `libtool` skip an archive member that is not aligned to 8 bytes ("64-bit mach-o not 8-byte aligned"), and the archive of Zig 0.16 does not always align it. The link then fails with undefined symbols, depending on the size of the symbol table. Make the archive again before you link: take the object out with `ar x`, give it mode 644 (`chmod 644`), and make a new archive with `libtool -static`. `macos/build-core.sh` does this.

For another target, add `-Dtarget`. Example: `zig build lib -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu` for a Raspberry Pi.

## Example

```c
#include <stdio.h>
#include <zslice.h>

static int write_file(void *user, const uint8_t *data, size_t len) {
    return fwrite(data, 1, len, (FILE *)user) == len ? 0 : 1;
}

int slice(const uint8_t *stl, size_t stl_len, FILE *out) {
    zs_mesh *mesh = NULL;
    zs_settings *settings = NULL;
    zs_stats stats;
    int rc;

    rc = zs_mesh_load_stl(stl, stl_len, &mesh);
    if (rc != ZS_OK) goto done;

    rc = zs_settings_new(&settings);
    if (rc != ZS_OK) goto done;
    rc = zs_settings_set(settings, "project.wall_count", "3");
    if (rc != ZS_OK) goto done;

    rc = zs_slice(mesh, settings, write_file, out, &stats);
    if (rc == ZS_OK) {
        printf("%u layers, %.2f m filament\n", stats.layer_count, stats.filament_mm / 1000.0);
    }

done:
    if (rc != ZS_OK) fprintf(stderr, "zslice: %s\n", zs_status_string(rc));
    zs_settings_free(settings);
    zs_mesh_free(mesh);
    return rc;
}
```

Link with `-lzslice`. The free functions accept NULL. `examples/c/slice.c` has this example with a `main` function.

## Functions

| Function | What it does |
|---|---|
| `zs_version()` | The version text, for example `"0.1.0"`. |
| `zs_status_string(status)` | The name of a status code. |
| `zs_setting_names()` | All setting names, one on each line. |
| `zs_mesh_load_stl(data, len, &mesh)` | Loads a binary or ASCII STL file from memory. |
| `zs_mesh_from_triangles(xyz, count, &mesh)` | Makes a mesh from 9 floats for each triangle. |
| `zs_mesh_free(mesh)` | Frees a mesh. |
| `zs_settings_new(&settings)` | Makes settings with all defaults. |
| `zs_settings_set(settings, key, value)` | Sets one setting from text. The library copies the text. |
| `zs_settings_free(settings)` | Frees settings. |
| `zs_slice(mesh, settings, write, user, &stats)` | Slices, and sends the G-code to `write` in parts while it runs. |
| `zs_slice_to_buffer(mesh, settings, &ptr, &len, &stats)` | Slices into one buffer. Free it with `zs_buffer_free(ptr, len)`. |
| `zs_alloc(len)`, `zs_free(ptr, len)` | Memory for data that the host passes in. For wasm hosts. |
| `zs_sign_key_from_seed(seed, 32, out, cap)` | The secret key text of 32 random bytes from the OS. |
| `zs_sign_public_key(secret, out, cap)` | The public key text of a secret key text. |
| `zs_sign_key_id(public, out, cap)` | The key id: 16 hex characters. |
| `zs_sign_gcode(secret, gcode, len, &ptr, &len)` | A copy of the G-code with a signature line at its end. Free it with `zs_buffer_free`. |
| `zs_verify_gcode(gcode, len, trusted, &result, key_id)` | Checks the signature line against the trusted public keys (one on each line): ok, unsigned, unknown key, or bad. |

`settings` can be NULL in `zs_slice` and `zs_slice_to_buffer`: the slice then uses all defaults. `stats` can be NULL.

## Signed G-code

The last line of a signed file is a comment: `; zslice-signature: ed25519 <key id> <base64 signature>`. The signature is Ed25519 over the SHA-256 hash of all bytes before that line. The key id is the first 8 bytes of the SHA-256 hash of the public key, in hex. A printer with no check reads a comment, so a signed file prints on any printer. A printdeck with "Signed prints only" queues only files with a good signature of a trusted key.

## The write callback

```c
typedef int (*zs_write_fn)(void *user, const uint8_t *data, size_t len);
```

- The library calls it many times, with parts of the G-code in order. Most parts are about 64 KB. Do not depend on a part size.
- Return 0 to continue. Any other value stops the slice, and `zs_slice` returns `ZS_WRITE_FAILED`.
- The library calls it from the thread that called `zs_slice`.
- `data` is valid only during the call. Copy it if you need it later.

## Threads

The library uses one thread for each CPU. Set `engine.threads` to change it. The functions are safe to call from more than one thread at the same time, with different objects or with the same mesh and settings. Do not change a settings object while a slice uses it.

## Memory

The library uses its own allocator. Free each object with its free function, and each buffer with `zs_buffer_free`. Do not free them with `free()`.
