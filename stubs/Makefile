# Build kpf_stubs.dylib on the Mavericks host.
# Targets 10.9 ABI so the dylib loads cleanly there.

CC      = clang
# No -g: STABS debug entries would otherwise leak the build directory
# (and thus the building user's home path) into the shipped dylib.
CFLAGS  = -mmacosx-version-min=10.9 -fobjc-arc -Wall -O0
LDFLAGS = -dynamiclib -framework AppKit -framework Foundation \
          -framework AddressBook -framework Carbon \
          -install_name @rpath/kpf_stubs.dylib

SRCS = kpf_stubs_iwork2015_10_9.m kpf_osatomic.c
ifneq ($(wildcard kpf_auto_stubs.m),)
  SRCS += kpf_auto_stubs.m
endif

kpf_stubs.dylib: $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)
	strip -S $@

clean:
	rm -f kpf_stubs.dylib

.PHONY: clean
