.PHONY: all fixture verify measure clean

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -ffp-contract=off

all: verify

fixture:
	python3 make_fixture.py

verify: verify.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o verify verify.c mxfp4_gemv.c -lm
	./verify

measure: sim_c500.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o sim_c500 sim_c500.c mxfp4_gemv.c -lm
	./sim_c500

clean:
	rm -f verify sim_c500 fixture_mxfp4.bin
