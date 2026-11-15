#include "CFixture.h"

int c_fixture_double(int input) {
    /* A brace inside a comment: { — the delimiter must not count it. */
    const char *brace = "{";
    return brace[0] == '{' ? input * 2 : input;
}

/* Columns after text that is not ASCII: Cyrillic, an emoji and a tab before each call. */
int c_fixture_columns(void) {
    /* привет */ int cyrillic = c_fixture_double(1);
    /* 😀 */ int emoji = c_fixture_double(2);
	int tabbed = c_fixture_double(3);
    return cyrillic + emoji + tabbed;
}
