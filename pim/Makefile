.PHONY: all fixture verify measure clean

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -ffp-contract=off

all: verify

fixture:
	python3 make_fixture.py

verify: verify.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o verify verify.c mxfp4_gemv.c -lm
	./verify

measure: sim_device.c mxfp4_gemv.c mxfp4_gemv.h fixture
	$(CC) $(CFLAGS) -o sim_device sim_device.c mxfp4_gemv.c -lm
	./sim_device

clean:
	rm -f verify sim_device fixture_mxfp4.bin
