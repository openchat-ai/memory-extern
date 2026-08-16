.PHONY: all fixture verify measure clean

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -ffp-contract=off

all: verify

fixture:
	python3 make_fixture.py

verify: verify.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o verify verify.c mxfp4_gemv.c -lm
	./verify

measure: sim_cim.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o sim_cim sim_cim.c mxfp4_gemv.c -lm
	./sim_cim

clean:
	rm -f verify sim_cim fixture_mxfp4.bin
