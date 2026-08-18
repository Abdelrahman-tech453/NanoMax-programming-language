# Flint

A small programming language, implemented entirely in hand-written x86-64
assembly. The lexer, parser, AST, and evaluator are all assembly — there is
no libc and no runtime underneath; every I/O operation is a raw Linux
syscall.

Built and tested on x86-64 Linux with GNU `as`/`ld` (Intel syntax via
`.intel_syntax noprefix`).

## Build & run

Using `make`:
```bash
make
make test
./flint fib.fl
```

Or manually:
```bash
as --64 flint.s -o flint.o
ld -o flint flint.o
./flint fib.fl
```

No NASM, no cross-compiler, no dependencies beyond binutils.

## The language

Flint is a small imperative language: user-defined functions with recursion, integer variables,
arithmetic with real operator precedence, logical operators with short-circuiting, comparisons,
`if`/`else`, `while`, `break`, `continue`, `return`, booleans, and `print`.
It's Turing-complete and enough to write real (if simple) programs.

```
fn fact(n) {
  if (n <= 1) {
    return 1;
  }
  return n * fact(n - 1);
}

fn gcd(a, b) {
  while (b != 0) {
    t = b;
    b = a % b;
    a = t;
  }
  return a;
}

print fact(5);     # 120
print gcd(48, 18); # 6
```

**Grammar**

```
program    := stmt*
stmt       := "fn" IDENT "(" [IDENT ("," IDENT)*] ")" block
            | "return" [expr] ";"
            | "if" "(" expr ")" block ("else" block)?
            | "while" "(" expr ")" block
            | "print" expr ";"
            | "break" ";"
            | "continue" ";"
            | IDENT "=" expr ";"
            | expr ";"
block      := "{" stmt* "}"

expr       := logical_or
logical_or := logical_and ("||" logical_and)*
logical_and:= equality ("&&" equality)*
equality   := relational (("==" | "!=") relational)*
relational := additive (("<" | ">" | "<=" | ">=") additive)*
additive   := mult (("+" | "-") mult)*
mult       := unary (("*" | "/" | "%") unary)*
unary      := ("-" | "!") unary | primary
primary    := NUMBER | "true" | "false" | IDENT "(" [expr ("," expr)*] ")" | IDENT | "(" expr ")"
```

**Notes**

- All values are 64-bit signed integers. Booleans evaluate to `1` (`true`) and `0` (`false`).
- User-defined functions support recursion, multiple parameters, and return values (`return expr;` or implicit `0`).
- Each function invocation runs in an isolated local stack frame allocated on an internal call stack.
- Logical `&&` and `||` evaluate with short-circuit behavior (the right operand is not evaluated if the result is determined by the left).
- Identifiers can be any length (`[a-zA-Z_][a-zA-Z0-9_]*`) and are resolved
  through a symbol table — see Architecture below.
- `#` starts a comment that runs to end of line.
- Division and modulo by zero are caught and reported.
- Syntax errors report the offending source line number (`flint: parse error on line <N>`).
- Blocks are mandatory for control flow: `if (x) { ... }`, `while (x) { ... }`.

## Architecture

```
source text -> tokenize -> AST (parse) -> exec_list / eval (tree-walk)
```

**Storage.** Nothing is heap-allocated (no `malloc`, no libc). Tokens,
AST nodes, and call frames live in fixed-size static arrays in `.bss`, addressed by index:

- `tok_type` / `tok_val` / `tok_line` — parallel token arrays recording type, value, and source line.
- `node_type` / `node_a` / `node_b` / `node_c` / `node_next` — parallel AST arrays.
  Node `0` is reserved to mean "null".
- `sym_name_ptr` / `sym_name_len` — a linear-scan symbol table.
- `fn_sym` / `fn_param_count` / `fn_param_syms` / `fn_body` — registered function definitions.
- `call_stack` / `call_depth` — 256 isolated activation frames with parameter and local variable storage per depth level.

**Lexer** (`tokenize`) walks the source once, tracking line numbers and classifying
characters into tokens: numbers, booleans (`true`/`false`), keywords (`fn`, `return`, `if`,
`else`, `while`, `print`, `break`, `continue`), identifiers, operators, and punctuation.

**Parser** is recursive-descent with precedence climbing for expressions.

**Evaluator** (`eval` for expressions, `exec_stmt`/`exec_list` for statements) is a
tree walk over the AST. Statements return execution status codes
(`0 = OK`, `1 = BREAK`, `2 = CONTINUE`, `3 = RETURN`), handling early function returns and loop unwinding cleanly.

## Files

```
flint.s              the whole interpreter (one self-contained file)
Makefile             build and test automation
fib.fl               first 10 Fibonacci numbers
fact.fl              5!
primes.fl            primes up to 50 (nested while + if)
collatz.fl           Collatz step count from 27 (if/else inside while)
test_logical.fl      boolean literals, logical operators, short-circuit test
test_loop_control.fl break and continue in single and nested loops
test_functions.fl    recursive factorial, recursive fibonacci, gcd, multi-arg functions
```

## Limitations / where to take it next

Natural next steps if you want to extend it further:

- **Strings & Character I/O.** String literals (`"hello"`), `putchar(c)`, `getchar()`.
- **Standard Input (`read`).** Built-in input expression to parse integers from `stdin`.
- **Arrays & Dynamic Memory.** Heap bump allocator using `sys_brk` / `sys_mmap`.
- **Direct x86-64 Machine Code Compiler (JIT).** Emitting native machine instructions into executable memory pages for speed.
- **Other Architectures.** ARM64 or RISC-V ports.
