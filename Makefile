# NIF build — links contract-bus's libweft-harness.a + iceoryx2 stubs.
# iceoryx2 itself is dlopen'd at runtime via WEFT_ICEORYX2_PATH.

ERL_INCLUDE := $(shell erl -eval 'io:format("~ts", [code:root_dir()])' -s init stop -noshell)/erts-$(shell erl -eval 'io:format("~ts", [erlang:system_info(version)])' -s init stop -noshell)/include

BUS_ROOT := ../../2-contract/bus
BUS_BUILD := $(BUS_ROOT)/build
BUS_INCLUDE := -I$(BUS_ROOT)/include -I$(BUS_ROOT)/src -I$(BUS_ROOT) -I$(BUS_BUILD)/gen

CXX ?= c++
CXXFLAGS := -std=c++17 -O2 -fPIC -Wall -Wno-unused-function \
            -I$(ERL_INCLUDE) $(BUS_INCLUDE)

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LDFLAGS := -shared -undefined dynamic_lookup
    SO_EXT := so
else
    LDFLAGS := -shared -ldl
    SO_EXT := so
endif

TARGET := priv/weft_bus_nif.$(SO_EXT)
SRCS := c_src/weft_bus_nif.cpp $(BUS_BUILD)/gen/native/harness/iceoryx2_stubs.cc

$(TARGET): $(SRCS)
	@mkdir -p priv
	$(CXX) $(CXXFLAGS) $(SRCS) $(LDFLAGS) -o $@

clean:
	rm -f $(TARGET)

.PHONY: clean
