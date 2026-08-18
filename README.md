# Qaf

Qaf (formerly “Flint”) is a tiny, self-contained imperative programming language and interpreter implemented entirely in x86-64 assembly. It is designed for education and experimentation: the whole toolchain (lexer, parser, AST storage, evaluator, basic I/O) is implemented without libc or any external runtime — all I/O uses raw Linux syscalls.

This repository contains:
- flint.s — the full interpreter implemented in x86-64 assembly (single-file source)
- Makefile — build and test automation
- qaf — a small shell wrapper that runs the built interpreter as `qaf`
- prebuilt binaries (flint, flint.o) and a suite of `.qf` example/test programs
- LICENSE — Apache License 2.0
- docs/ — language reference and implementation notes (new)

See docs/LANGUAGE_SPEC.md for the complete language reference, storage model, runtime limits, and implementation details.

Quick highlights
- Values are 64-bit signed integers. Booleans are 1 (true) and 0 (false).
- Language features: user-defined functions (with recursion), integer variables, arithmetic with correct operator precedence, comparisons, logical `&&`/`||` with short-circuiting, `if`/`else`, `while`, `break`, `continue`, `return`, `print`, `read`, `putchar`, and `getchar`.
- Memory model: no heap allocation; tokens, AST nodes, symbols, strings, and call frames live in fixed-size static arrays in `.bss` (see docs for limits).
- Errors: the interpreter prints explicit messages for parse/runtime faults (parse error with line number, division/modulo by zero, undefined function, stack overflow).

Build
Requires GNU binutils (as/ld) on x86-64 Linux.

```bash
make
# or manually:
as --64 flint.s -o flint.o
ld -o flint flint.o
cp flint qaf
chmod +x qaf
```

Run

```bash
./qaf path/to/program.qf
# or: ./flint path/to/program.fl
```

The `qaf` script is a convenience wrapper that launches the `flint` binary and accepts `.qf` files.

Tests

Run the included tests / demo programs:

```bash
make test
```

Included example/test files: fib.qf, fact.qf, primes.qf, collatz.qf, test_arithmetic.qf, test_char_io.qf, test_functions.qf, test_input.qf, test_while.qf.

Quick example

```
fn fact(n) {
  if (n <= 1) {
    return 1;
  }
  return n * fact(n - 1);
}

print fact(5);
```

Files of interest
- flint.s — interpreter source (see comments and symbol maps inside for token/AST kinds and storage layout)
- Makefile — build & test
- qaf — wrapper script
- *.qf — example programs and tests
- docs/LANGUAGE_SPEC.md — comprehensive language spec (new)

Limitations & extension ideas
- Only 64-bit integers are supported (no floats, no string expressions).
- Fixed-size static storage; bounds are compile-time constants in flint.s.
- No standard library beyond minimal I/O (print/read/putchar/getchar).

Common next steps: string literals and string ops, heap allocator (brk/mmap), arrays, richer I/O, or ports to other ISAs.

Contributing
Read docs/LANGUAGE_SPEC.md before changing core storage sizes or data layout — many constants and arrays in flint.s depend on those limits.
