.PHONY: all fixture verify clean

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -ffp-contract=off

all: verify

fixture:
	python3 make_fixture.py

verify: verify.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o verify verify.c mxfp4_gemv.c -lm
	./verify

clean:
	rm -f verify fixture_mxfp4.bin
