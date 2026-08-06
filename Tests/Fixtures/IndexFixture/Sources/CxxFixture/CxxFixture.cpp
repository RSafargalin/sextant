#include "CxxFixture.hpp"

namespace sextantfixture {

int Counter::bump(int by) { return value + by; }

Widget::Widget(int size) : size_(size) {}
int Widget::area() const { return size_ * size_; }

int scale(int value) { return value * 2; }
double scale(double value) { return value * 2.0; }

namespace inner {
int nestedDouble(int value) { return scale(value); }
}

}
