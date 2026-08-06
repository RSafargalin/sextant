// The subset of the libclang C ABI that sextant uses.
//
// The Xcode toolchain ships libclang.dylib without the clang-c headers, so the types and
// signatures are declared here and the symbols are resolved with dlsym at run time. Linking
// against the dylib instead would make every command — including the Swift-only ones — fail to
// start on a machine with no toolchain.
//
// The layouts mirror clang-c/Index.h and clang-c/CXString.h. They are part of a C ABI that has
// been stable for many years; a mismatch would show up immediately in the tests that parse a
// real file.
#ifndef SEXTANT_CCLANG_SHIM_H
#define SEXTANT_CCLANG_SHIM_H

typedef void *SXIndex;
typedef void *SXTranslationUnit;
typedef void *SXDiagnostic;
typedef void *SXFile;

typedef struct { const void *data; unsigned private_flags; } SXString;
typedef struct { int kind; int xdata; const void *data[3]; } SXCursor;
typedef struct { const void *ptr_data[2]; unsigned int_data; } SXSourceLocation;
typedef struct { const void *ptr_data[2]; unsigned begin_int_data; unsigned end_int_data; } SXSourceRange;

/// Return values of a cursor visitor (CXChildVisitResult).
typedef enum {
    SXChildVisitBreak = 0,
    SXChildVisitContinue = 1,
    SXChildVisitRecurse = 2
} SXChildVisitResult;

typedef SXChildVisitResult (*SXCursorVisitor)(SXCursor cursor, SXCursor parent, void *clientData);

// MARK: - Index and translation unit

typedef SXIndex (*sx_createIndex)(int excludeDeclarationsFromPCH, int displayDiagnostics);
typedef void (*sx_disposeIndex)(SXIndex);
typedef SXTranslationUnit (*sx_parseTranslationUnit)(SXIndex, const char *sourceFile,
                                                     const char *const *commandLineArgs, int numArgs,
                                                     void *unsavedFiles, unsigned numUnsavedFiles,
                                                     unsigned options);
typedef void (*sx_disposeTranslationUnit)(SXTranslationUnit);

// MARK: - Diagnostics

typedef unsigned (*sx_getNumDiagnostics)(SXTranslationUnit);
typedef SXDiagnostic (*sx_getDiagnostic)(SXTranslationUnit, unsigned index);
typedef int (*sx_getDiagnosticSeverity)(SXDiagnostic);
typedef SXString (*sx_formatDiagnostic)(SXDiagnostic, unsigned options);
typedef void (*sx_disposeDiagnostic)(SXDiagnostic);

// MARK: - Cursors

typedef SXCursor (*sx_getTranslationUnitCursor)(SXTranslationUnit);
typedef unsigned (*sx_visitChildren)(SXCursor parent, SXCursorVisitor visitor, void *clientData);
typedef SXString (*sx_getCursorSpelling)(SXCursor);
typedef SXString (*sx_getCursorKindSpelling)(int kind);
typedef SXSourceLocation (*sx_getCursorLocation)(SXCursor);
typedef SXSourceRange (*sx_getCursorExtent)(SXCursor);
typedef SXSourceLocation (*sx_getRangeStart)(SXSourceRange);
typedef SXSourceLocation (*sx_getRangeEnd)(SXSourceRange);
typedef int (*sx_Location_isFromMainFile)(SXSourceLocation);
typedef void (*sx_getSpellingLocation)(SXSourceLocation, SXFile *file, unsigned *line, unsigned *column, unsigned *offset);

// MARK: - Strings

typedef const char *(*sx_getCString)(SXString);
typedef void (*sx_disposeString)(SXString);

#endif
