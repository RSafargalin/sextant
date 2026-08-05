#pragma once

namespace sextantfixture {

/// Declared only in the header: `api` keeps it, the map keeps it, and `body` must include the
/// trailing semicolon that a Swift declaration would not have.
struct Counter {
    int value;
    int bump(int by);
};

class Widget {
public:
    explicit Widget(int size);
    int area() const;
private:
    int size_;
};

}
