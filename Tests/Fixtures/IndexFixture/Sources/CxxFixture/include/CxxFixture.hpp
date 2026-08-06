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

/// Overloads: one name, two signatures. The index keys symbols by USR, so both must survive
/// resolution by name rather than one shadowing the other.
int scale(int value);
double scale(double value);

/// A template, defined entirely in the header the way templates have to be. Nothing instantiates
/// it inside the fixture: the question it asks is whether an uninstantiated template reaches the
/// index at all.
template <typename T>
struct Box {
    T value;
    T get() const { return value; }
};

/// A nested namespace, so resolution has to cope with a symbol whose qualified name differs from
/// the one a user would type.
namespace inner {
int nestedDouble(int value);
}

}
