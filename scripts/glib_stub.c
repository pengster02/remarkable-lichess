/* Minimal no-op stub for the 15 GLib symbols libQt6Core.so.6 references for
 * its optional GLib event-loop integration. Exists because the dev-machine
 * build pipeline (see build-rm.sh) runs Qt's `rcc` resource compiler via a
 * PySide6 PyPI wheel rather than a system Qt install, and that wheel's
 * libQt6Core.so.6 is dynamically linked against libglib-2.0.so.0 even though
 * a plain file-to-file `rcc` invocation never actually drives a GLib-backed
 * event loop. Real libglib2.0 isn't reliably installable via apt in every
 * build environment (some sandboxes can reach PyPI/crates.io/Docker Hub but
 * not deb/ubuntu package mirrors) -- this sidesteps needing it at all.
 *
 * `g_main_context_default`/`g_main_context_new`/`g_source_new` are real (if
 * minimal) allocators, not pure no-ops: Qt's glib integration plugin
 * dereferences/writes into whatever they return during its own
 * initialization (confirmed live -- returning NULL segfaults immediately),
 * even though the loop itself is never actually iterated for this use case.
 */
#include <stddef.h>
#include <stdlib.h>

void *g_main_context_default(void) {
    static char dummy[256];
    return dummy;
}

void *g_main_context_new(void) { return calloc(1, 256); }

/* Qt subclasses GSource with extra trailing fields sized by struct_size and
 * writes into them right after creation -- must actually allocate that much,
 * zeroed, or those writes land on an invalid/too-small pointer. */
void *g_source_new(void *funcs, unsigned int struct_size) {
    (void)funcs;
    if (struct_size < sizeof(void *)) struct_size = sizeof(void *);
    return calloc(1, struct_size);
}

int g_main_context_iteration(void *ctx, int may_block) { (void)ctx; (void)may_block; return 0; }
void g_main_context_pop_thread_default(void *ctx) { (void)ctx; }
void g_main_context_push_thread_default(void *ctx) { (void)ctx; }
void *g_main_context_ref(void *ctx) { return ctx; }
void g_main_context_unref(void *ctx) { (void)ctx; }
void g_main_context_wakeup(void *ctx) { (void)ctx; }
void g_source_add_poll(void *source, void *fd) { (void)source; (void)fd; }
unsigned int g_source_attach(void *source, void *ctx) { (void)source; (void)ctx; return 1; }
void g_source_destroy(void *source) { (void)source; }
void g_source_remove_poll(void *source, void *fd) { (void)source; (void)fd; }
void g_source_set_can_recurse(void *source, int can_recurse) { (void)source; (void)can_recurse; }
void g_source_set_name(void *source, const char *name) { (void)source; (void)name; }
void g_source_unref(void *source) { (void)source; }
