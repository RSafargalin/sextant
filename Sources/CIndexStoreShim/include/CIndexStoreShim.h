// The subset of the libIndexStore C ABI that sextant uses.
//
// IndexStoreDB answers questions about symbols; it says nothing about the UNITS a store holds —
// which file each was compiled from, for which target, in which configuration. That is what
// decides whether a store covers this project at all, so it is read here directly.
//
// Declared rather than imported for the same reason as the libclang shim: the toolchain ships
// libIndexStore.dylib without its headers, and linking against it would make every command fail
// to start where there is no toolchain.
//
// The layouts mirror clang/include/indexstore/indexstore.h. The `_f` (function-pointer) variants
// of the applier calls are used instead of the block-based ones: a C function pointer plus a
// context is what Swift can hand over without an Objective-C block ABI in the middle.
#ifndef SEXTANT_CINDEXSTORE_SHIM_H
#define SEXTANT_CINDEXSTORE_SHIM_H

#include <stdbool.h>
#include <stddef.h>

typedef void *SXIndexStore;
typedef void *SXUnitReader;
typedef void *SXIndexStoreError;

/// A string owned by the library: not NUL-terminated, so the length is the only safe end.
typedef struct {
    const char *data;
    size_t length;
} SXIndexStoreString;

typedef SXIndexStore (*sx_indexstore_store_create)(const char *store_path, SXIndexStoreError *error);
typedef void (*sx_indexstore_store_dispose)(SXIndexStore store);

typedef const char *(*sx_indexstore_error_get_description)(SXIndexStoreError error);
typedef void (*sx_indexstore_error_dispose)(SXIndexStoreError error);

/// Calls `applier` once per unit name in the store. Returning false stops the walk.
typedef bool (*sx_indexstore_store_units_apply_f)(SXIndexStore store, unsigned sorted, void *context,
                                                  bool (*applier)(void *context, SXIndexStoreString unit_name));

typedef SXUnitReader (*sx_indexstore_unit_reader_create)(SXIndexStore store, const char *unit_name,
                                                         SXIndexStoreError *error);
typedef void (*sx_indexstore_unit_reader_dispose)(SXUnitReader reader);

/// The source file this unit was compiled from — the fact that says what a store covers.
typedef SXIndexStoreString (*sx_indexstore_unit_reader_get_main_file)(SXUnitReader reader);
/// The object file it produced: its directory identifies the build that wrote the unit.
typedef SXIndexStoreString (*sx_indexstore_unit_reader_get_output_file)(SXUnitReader reader);
/// False for a module unit — one that stands for a whole module rather than a compiled file.
typedef bool (*sx_indexstore_unit_reader_has_main_file)(SXUnitReader reader);
typedef bool (*sx_indexstore_unit_reader_is_system_unit)(SXUnitReader reader);
typedef SXIndexStoreString (*sx_indexstore_unit_reader_get_module_name)(SXUnitReader reader);
typedef SXIndexStoreString (*sx_indexstore_unit_reader_get_target)(SXUnitReader reader);
typedef bool (*sx_indexstore_unit_reader_is_debug_compilation)(SXUnitReader reader);

#endif
