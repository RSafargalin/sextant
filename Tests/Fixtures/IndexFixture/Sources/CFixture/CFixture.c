#include "CFixture.h"

int c_fixture_double(int input) {
    /* A brace inside a comment: { — the delimiter must not count it. */
    const char *brace = "{";
    return brace[0] == '{' ? input * 2 : input;
}
