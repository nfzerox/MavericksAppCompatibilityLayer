/*
 * dlcheck — for diff_imports.py. Reads "lib_path SP symbol\n" lines from
 * stdin; prints one of:
 *   "OK lib symbol"          dlsym() resolves either against the named
 *                            lib or, as a fallback, the flat global
 *                            namespace (RTLD_DEFAULT).
 *   "MISSING lib symbol"     dylib opens but the symbol is absent
 *                            even via RTLD_DEFAULT.
 *   "LIBMISSING lib symbol"  dylib path doesn't open AND the symbol is
 *                            not reachable via RTLD_DEFAULT either.
 *
 * The RTLD_DEFAULT fallback matters for Apple frameworks that moved
 * between releases (e.g. CoreImage.framework standalone on 10.13 vs
 * QuartzCore subframework on 10.9). dyld's flat lookup finds the symbol
 * at runtime, so our patched binary works fine -- emitting a stub for
 * it would shadow / conflict with the real implementation.
 *
 * Build: clang -O2 dlcheck.c -ldl -o dlcheck
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

static int probe_objc_class(const char *bare_sym) {
    /* `_OBJC_CLASS_$_Foo` has no dlsym slot per se (it's a private
     * runtime symbol), but the ObjC runtime exposes it indirectly via
     * objc_getClass("Foo"). Try that to cover ObjC class symbols that
     * live in re-exporting umbrellas. */
    const char *prefix_cls = "OBJC_CLASS_$_";
    const char *prefix_meta = "OBJC_METACLASS_$_";
    const char *name = NULL;
    if (strncmp(bare_sym, prefix_cls, strlen(prefix_cls)) == 0)
        name = bare_sym + strlen(prefix_cls);
    else if (strncmp(bare_sym, prefix_meta, strlen(prefix_meta)) == 0)
        name = bare_sym + strlen(prefix_meta);
    if (!name) return 0;
    typedef void *(*objc_getClass_t)(const char *);
    static objc_getClass_t getCls = NULL;
    if (!getCls) getCls = (objc_getClass_t)dlsym(RTLD_DEFAULT, "objc_getClass");
    if (!getCls) return 0;
    return getCls(name) != NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    char line[2048];
    char prev_lib[1024] = "";
    void *h = NULL;
    while (fgets(line, sizeof(line), stdin)) {
        char *sp = strchr(line, ' ');
        if (!sp) continue;
        *sp = 0;
        char *sym = sp + 1;
        char *nl = strchr(sym, '\n');
        if (nl) *nl = 0;
        if (strcmp(line, prev_lib) != 0) {
            if (h) dlclose(h);
            h = dlopen(line, RTLD_LAZY | RTLD_NOLOAD);
            if (!h) h = dlopen(line, RTLD_LAZY);
            strncpy(prev_lib, line, sizeof(prev_lib)-1);
            /* Emit a per-lib status line so the consumer can identify
             * libs whose recorded path does NOT exist on the target OS,
             * independent of symbol resolution. dyld at launch requires
             * the LC_LOAD_DYLIB path to either open or be marked weak,
             * regardless of whether some other already-loaded dylib
             * happens to re-export the symbol. */
            printf("LIBSTATUS %s %s\n", h ? "opened" : "failed", line);
        }
        const char *bare = (sym[0] == '_') ? sym + 1 : sym;
        void *p = h ? dlsym(h, bare) : NULL;
        if (!p) p = dlsym(RTLD_DEFAULT, bare);
        int ok = (p != NULL) || probe_objc_class(bare);
        const char *status = ok ? "OK" : (h ? "MISSING" : "LIBMISSING");
        printf("%s %s %s\n", status, line, sym);
    }
    return 0;
}
