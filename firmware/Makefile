# Host tests for the portable core. `make test` builds and runs them with the system C++ compiler.
CXX ?= c++
CXXFLAGS ?= -std=c++17 -O1 -g -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined

CORE := core/frame.cpp core/call.cpp core/airtime.cpp core/buttons.cpp
TESTS := test/main.cpp test/frame_tests.cpp test/call_tests.cpp test/airtime_tests.cpp test/button_tests.cpp

build/tests: $(CORE) $(TESTS) core/*.hpp test/test.hpp
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ $(CORE) $(TESTS)

test: build/tests
	./build/tests

clean:
	rm -rf build

.PHONY: test clean
