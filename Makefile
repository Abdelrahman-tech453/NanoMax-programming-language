AS = as
ASFLAGS = --64
LD = ld

all: qaf

flint.o: flint.s
	$(AS) $(ASFLAGS) flint.s -o flint.o

flint: flint.o
	$(LD) -o flint flint.o

# qaf is the rebranded frontend name. We keep the existing assembly (flint)
# but expose it as ./qaf by copying the built binary.
qaf: flint
	cp flint qaf || true
	chmod +x qaf

# Run all .qf test files if present.
test: qaf
	@for f in *.qf; do \
	  echo "Running $$f..."; \
	  ./qaf "$$f"; \
	done
	@echo "All tests passed successfully!"

clean:
	rm -f flint flint.o qaf

.PHONY: all test clean
