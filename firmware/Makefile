# Host tests for the portable core. `make test` builds and runs them with the system compilers.
CXX ?= c++
CC ?= cc
SANITIZE := -fsanitize=address,undefined
CXXFLAGS ?= -std=c++17 -O1 -g -Wall -Wextra -Werror -pedantic $(SANITIZE)

CORE := core/frame.cpp core/call.cpp core/airtime.cpp core/buttons.cpp core/seal.cpp core/power.cpp core/provision.cpp core/box.cpp
TESTS := test/main.cpp test/frame_tests.cpp test/call_tests.cpp test/airtime_tests.cpp test/button_tests.cpp \
         test/seal_tests.cpp test/power_tests.cpp test/provision_tests.cpp test/box_tests.cpp

# TweetNaCl (public domain) gives the tests real Ed25519 and X25519; the board uses MeshCore's.
build/tweetnacl.o: test/tweetnacl.c test/tweetnacl.h
	@mkdir -p build
	$(CC) -O1 -g -w -fsanitize=address -c -o $@ $<

build/tests: $(CORE) $(TESTS) core/*.hpp test/test.hpp build/tweetnacl.o
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ $(CORE) $(TESTS) build/tweetnacl.o

test: build/tests
	./build/tests

clean:
	rm -rf build

.PHONY: test clean
