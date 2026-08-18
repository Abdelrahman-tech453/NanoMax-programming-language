AS = as
ASFLAGS = --64
LD = ld

all: flint

flint.o: flint.s
	$(AS) $(ASFLAGS) flint.s -o flint.o

flint: flint.o
	$(LD) -o flint flint.o

test: flint
	@echo "Running fib.fl..."
	@./flint fib.fl
	@echo "Running fact.fl..."
	@./flint fact.fl
	@echo "Running primes.fl..."
	@./flint primes.fl
	@echo "Running collatz.fl..."
	@./flint collatz.fl
	@echo "Running test_logical.fl..."
	@./flint test_logical.fl
	@echo "Running test_loop_control.fl..."
	@./flint test_loop_control.fl
	@echo "Running test_functions.fl..."
	@./flint test_functions.fl
	@echo "All tests passed successfully!"

clean:
	rm -f flint flint.o

.PHONY: all test clean
