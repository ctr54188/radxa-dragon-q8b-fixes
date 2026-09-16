# =====================================================================
#  q8b-fan - build the C implementation into one binary
#
#    make                                   native build  -> build/q8b-fan
#    make STATIC=1                          static build
#    make CROSS_COMPILE=aarch64-linux-gnu-  cross build (aarch64)
#    make CROSS_COMPILE=aarch64-linux-gnu- STATIC=1
#    make shc                               wrap the bash script into an ELF
#    sudo make install                      install to /usr/local/sbin
#
#  The bash version (./q8b-fan) needs no build at all and has exactly the
#  same CLI.  Build the binary if you want a dependency free single file.
# =====================================================================

CROSS_COMPILE ?=
CC            := $(CROSS_COMPILE)gcc
CFLAGS        ?= -O2 -Wall -Wextra -std=gnu11
LDFLAGS       ?=
STATIC        ?= 0

ifeq ($(STATIC),1)
  LDFLAGS += -static
endif

SRC      := src/q8b-fan.c
OUTDIR   := build
BIN      := $(OUTDIR)/q8b-fan
PREFIX   ?= /usr/local
DESTDIR  ?=

.PHONY: all clean install uninstall shc info

all: $(BIN)

$(BIN): $(SRC) Makefile
	@mkdir -p $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "built: $@"
	-@file -b $@ 2>/dev/null | sed 's/^/       /'

# "compile" the shell version into an ELF with shc (still needs bash at runtime)
shc:
	@command -v shc >/dev/null 2>&1 || { echo "shc not found - install it (apt install shc / brew install shc)"; exit 1; }
	@mkdir -p $(OUTDIR)
	@cp -f q8b-fan $(OUTDIR)/q8b-fan.sh
	shc -r -f $(OUTDIR)/q8b-fan.sh -o $(OUTDIR)/q8b-fan-shc
	@rm -f $(OUTDIR)/q8b-fan.sh.x.c $(OUTDIR)/q8b-fan.sh
	@echo "built: $(OUTDIR)/q8b-fan-shc  (embedded script, needs bash at runtime)"
	-@file -b $(OUTDIR)/q8b-fan-shc 2>/dev/null | sed 's/^/       /'

info:
	@echo "CC       = $(CC)"
	@echo "CFLAGS   = $(CFLAGS)"
	@echo "LDFLAGS  = $(LDFLAGS)"
	@echo "BIN      = $(BIN)"

install: $(BIN)
	install -d $(DESTDIR)$(PREFIX)/sbin
	install -m 0755 $(BIN) $(DESTDIR)$(PREFIX)/sbin/q8b-fan

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/sbin/q8b-fan

clean:
	rm -rf $(OUTDIR)
