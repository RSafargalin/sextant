#include "TestHome.h"

#include <copyfile.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char home[64];

static int remove_entry(const char *path, const struct stat *status, int flag, struct FTW *walk) {
    (void)status; (void)flag; (void)walk;
    return remove(path);
}

/// Removes the directory and everything in it; links are removed as links, never followed.
static void remove_home(void) {
    if (home[0] != '\0') nftw(home, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

/// Copies in what `make fixture` left in the home it indexes the fixture with
/// (`.build/fixture-home` in this repository): the fixture's compile flags and the snapshot of
/// its index store, which the C-family and freshness tests read. Nothing when it is not there.
static void seed_from_fixture_home(void) {
    const char *suffix = "/Tests/TestHome/TestHome.c";
    const char *file = __FILE__;
    size_t length = strlen(file), suffix_length = strlen(suffix);
    if (length <= suffix_length || strcmp(file + length - suffix_length, suffix) != 0) return;
    char source[2048], destination[128];
    int written = snprintf(source, sizeof source, "%.*s/.build/fixture-home/Library",
                           (int)(length - suffix_length), file);
    if (written <= 0 || (size_t)written >= sizeof source) return;
    struct stat status;
    if (stat(source, &status) != 0 || !S_ISDIR(status.st_mode)) return;
    snprintf(destination, sizeof destination, "%s/Library", home);
    copyfile(source, destination, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW);
}

/// Runs when the test bundle is loaded, before any test. The path is short on purpose: a daemon's
/// socket lives under the home, and a unix socket path is limited to about 104 bytes.
__attribute__((constructor)) static void isolate_home(void) {
    strcpy(home, "/tmp/sextant-tests-XXXXXX");
    if (mkdtemp(home) == NULL) {
        home[0] = '\0';
        return;
    }
    setenv("CFFIXED_USER_HOME", home, 1);
    atexit(remove_home);
    seed_from_fixture_home();
}

const char *sextant_test_home(void) {
    return home;
}
