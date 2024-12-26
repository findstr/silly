uname_S := $(shell sh -c 'uname -s 2>/dev/null || echo not')
uname_M := $(shell sh -c 'uname -m 2>/dev/null || echo not')
CC := gcc -std=gnu99
LD := gcc
CFLAGS = -g3 -O2 -Wall -Wextra -DSILLY_GIT_SHA1=$(GITSHA1) $(MYCFLAGS)
LDFLAGS := -lm -lpthread $(MYLDFLAGS)
SHARED :=
A := a
SO := so
LUA_PLAT :=

ifeq ($(uname_S),Linux)
	LDFLAGS += -ldl -Wl,-E -lrt
	SHARED += --share -fPIC
	SO = so
	A = a
	LIBPREFIX = lib
ifeq ($(TEST),ON)
	CFLAGS += -fsanitize=address -fno-omit-frame-pointer -DSILLY_TEST
	LDFLAGS += -fsanitize=address -fno-omit-frame-pointer
endif
endif

ifeq ($(uname_S),Darwin)
ifeq ($(TLS),ON)
	CFLAGS += $(shell pkg-config --cflags openssl)
	LDFLAGS += $(shell pkg-config --libs openssl)
	SHARED += $(shell pkg-config --libs openssl)
endif
	LDFLAGS += -ldl -Wl,-no_compact_unwind
	SHARED += -dynamiclib -fPIC -Wl,-undefined,dynamic_lookup
	SO = so
	A = a
	LIBPREFIX = lib
ifeq ($(TEST),ON)
	CFLAGS += -fsanitize=address -fno-omit-frame-pointer -DSILLY_TEST
	LDFLAGS += -fsanitize=address -fno-omit-frame-pointer
endif
endif

ifeq ($(findstring _NT, $(uname_S)),_NT)
	LDFLAGS += -lws2_32 -Wl,--export-all-symbols,--out-implib,$(SRC_PATH)/lib$(TARGET).lib
	SHARED += --share -fPIC -L$(SRC_PATH) -l$(TARGET) -lws2_32
	SO = dll
	A = lib
	LIBPREFIX =
	LUA_PLAT = mingw
ifeq ($(TEST),ON)
	CFLAGS += -DSILLY_TEST
endif
endif

GITSHA1=$(shell git log -1 --pretty=format:"%h")


