#include "CxxFixture.hpp"

namespace sextantfixture {

int Counter::bump(int by) { return value + by; }

Widget::Widget(int size) : size_(size) {}
int Widget::area() const { return size_ * size_; }

}
