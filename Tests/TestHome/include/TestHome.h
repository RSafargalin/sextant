#ifndef SEXTANT_TEST_HOME_H
#define SEXTANT_TEST_HOME_H

/// The home directory every test in this process runs with: a fresh directory under /tmp, set as
/// CFFIXED_USER_HOME before any test starts, so neither the tests nor the processes they start
/// read or write the real home. It starts with a copy of what `make fixture` left in
/// `.build/fixture-home` (the fixture's compile flags and index snapshot). Removed when the process
/// exits. Empty if it could not be created.
const char *sextant_test_home(void);

#endif
