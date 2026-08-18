# Qaf — Language Specification

This document describes the Qaf language (formerly Flint): syntax, semantics, token/AST maps, storage limits, I/O, errors, and annotated examples. It targets both language users and contributors who want to modify the assembly interpreter (flint.s).

Contents
- Language summary
- Concrete grammar
- Expression & statement semantics
- Built-ins and I/O
- Token kinds and AST node kinds (numeric constants)
- Storage model and fixed limits (exact constants from flint.s)
- Error messages
- Examples
- Implementation notes and extension ideas

Language summary
- Value model: 64-bit signed integers. Booleans are integers: 1 = true, 0 = false.
- Basic features: variables, arithmetic (+ - * / %), comparisons, logical operators (&&, ||, !), control flow (if/else, while, break, continue), user-defined functions with recursion, print/read/putchar/getchar I/O.
- All source is single-file programs containing statements and function definitions.
- No heap or libc: all runtime state lives in static arrays in .bss inside flint.s.

Concrete grammar
(Exact grammar implemented by the recursive-descent parser)

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

Notes:
- Blocks (curly braces) are mandatory for `if` and `while` conditions — `if (x) { ... }`.
- Statements are terminated by `;` except function definitions and control structures which are blocks.

Expression & statement semantics
- Numeric arithmetic follows 64-bit signed integer semantics (two's complement). Overflow is not explicitly checked by the interpreter (wraps as in native arithmetic).
- Division `/` performs integer division; behavior on negative numbers follows the machine's idiv instruction semantics.
- Modulo `%` is remainder from idiv. Division or modulo by zero is caught at runtime and prints an error message (see Error messages) and exits.
- Comparison operators evaluate to `1` (true) or `0` (false).
- Logical `&&` and `||` are short-circuiting: the right operand is not evaluated if the left operand decides the result.
- Unary `!` is logical NOT: `!0` -> `1`, `!nonzero` -> `0`.
- Assignment `IDENT = expr;` stores the evaluated integer into the current function's symbol slot for that identifier. Identifiers are resolved through a symbol table and stored per-frame (see Storage model).
- Function calls `IDENT(expr, ...)` push a new activation frame, bind parameters by position, execute the function body, and return an integer. If a function ends without an explicit `return`, it implicitly returns `0`.
- `return` inside a function aborts execution of the function body and returns the provided value (or `0` if omitted) to the caller.
- `break` and `continue` apply to the innermost loop. Nested loops behave normally: `break` only exits the inner loop.

Built-ins and I/O
- print expr; — evaluate expr and print as a decimal integer followed by a newline.
- read() — read an integer from stdin (blocking read). Returns the parsed integer (EOF results in function returning 0 or behavior seen in flint.s read_int). The test suite uses `read()` to get numeric input.
- putchar(code) — write a single byte (low 8 bits of code) to stdout and return the character code.
- getchar() — reads one byte from stdin and returns it, or -1 on EOF.

Token kinds (constants in flint.s)
(Used by the lexer & parser. Numeric values are exact.)
- TOK_EOF = 0
- TOK_NUM = 1
- TOK_IDENT = 2
- TOK_PLUS = 3
- TOK_MINUS = 4
- TOK_STAR = 5
- TOK_SLASH = 6
- TOK_PERCENT = 7
- TOK_ASSIGN = 8
- TOK_EQEQ = 9
- TOK_NE = 10
- TOK_LT = 11
- TOK_GT = 12
- TOK_LE = 13
- TOK_GE = 14
- TOK_LPAREN = 15
- TOK_RPAREN = 16
- TOK_LBRACE = 17
- TOK_RBRACE = 18
- TOK_SEMI = 19
- TOK_IF = 20
- TOK_ELSE = 21
- TOK_WHILE = 22
- TOK_PRINT = 23
- TOK_LOGAND = 24
- TOK_LOGOR = 25
- TOK_BANG = 26
- TOK_BREAK = 27
- TOK_CONTINUE = 28
- TOK_FN = 29
- TOK_RETURN = 30
- TOK_COMMA = 31
- TOK_STR = 32
- TOK_READ = 33
- TOK_PUTCHAR = 34
- TOK_GETCHAR = 35

AST node kinds (constants in flint.s)
- ND_NUM = 1
- ND_VAR = 2
- ND_NEG = 3
- ND_ADD = 4
- ND_SUB = 5
- ND_MUL = 6
- ND_DIV = 7
- ND_MOD = 8
- ND_EQ = 9
- ND_NE = 10
- ND_LT = 11
- ND_GT = 12
- ND_LE = 13
- ND_GE = 14
- ND_ASSIGN = 15
- ND_PRINT = 16
- ND_IF = 17
- ND_WHILE = 18
- ND_NOT = 19
- ND_AND = 20
- ND_OR = 21
- ND_BREAK = 22
- ND_CONTINUE = 23
- ND_FN = 24
- ND_RETURN = 25
- ND_CALL = 26
- ND_EXPR_STMT = 27
- ND_STR = 28
- ND_READ = 29
- ND_PUTCHAR = 30
- ND_GETCHAR = 31

Storage model & compile-time limits (exact values in flint.s)
- MAXTOK = 8192 — maximum number of tokens parsed from a source file.
- MAXNODE = 8192 — maximum AST nodes.
- MAXSYM = 256 — maximum distinct symbol names tracked globally (identifier names).
- MAXFN = 64 — maximum registered functions.
- MAXPARAMS = 8 — maximum parameters per function.
- MAXFRAMES = 256 — maximum call stack depth / activation frames.
- MAXSTR = 512 — maximum distinct string entries in the string pool.
- STRPOOL_SIZE = 65536 — bytes reserved for string pool.

Key arrays (defined in .bss in flint.s)
- src_buf (65536 bytes) — raw program text.
- src_len — length of the loaded source.
- tok_type[MAXTOK], tok_val[MAXTOK], tok_line[MAXTOK] — token arrays.
- cur_tok — parser cursor into token arrays.
- node_type[MAXNODE], node_a[MAXNODE], node_b[MAXNODE], node_c[MAXNODE], node_next[MAXNODE], node_n — AST storage.
- sym_name_ptr[MAXSYM], sym_name_len[MAXSYM], sym_n — symbol table pointers and lengths.
- fn_sym[MAXFN], fn_param_count[MAXFN], fn_param_syms[MAXFN * MAXPARAMS], fn_body[MAXFN], fn_n — function registry.
- call_depth, call_stack[MAXFRAMES * MAXSYM] — call stack storage: each frame has slots for MAXSYM variables (8 bytes each).
- str_pool_buf[STRPOOL_SIZE], str_pool_pos, str_n, str_pool_ptr/MAXSTR — string pool.

Error messages
- "usage: flint <program.fl>\n" — usage printed for incorrect invocation.
- "flint: cannot open file\n" — when the filename cannot be opened.
- "flint: parse error on line <N>" — syntax errors report the offending line number; printed from die_parse_error.
- "flint: division by zero\n" — runtime error on division/modulo by zero.
- "flint: undefined function\n" — call to an unregistered function.
- "flint: stack overflow\n" — call depth exceeded MAXFRAMES.

Examples
- Factorial (recursive)
```
fn fact(n) {
  if (n <= 1) {
    return 1;
  }
  return n * fact(n - 1);
}
print fact(5);
```

- GCD (iterative)
```
fn gcd(a, b) {
  while (b != 0) {
    t = b;
    b = a % b;
    a = t;
  }
  return a;
}
print gcd(48, 18);
```

Implementation notes & extension ideas
- The interpreter implements a full lexer and parser in assembly; the lexer tokenizes the entire source into tok_* arrays, then the parser constructs the AST in node_* arrays.
- The symbol table stores pointers into src_buf instead of copying names; this reduces memory churn.
- All memory is statically allocated with fixed sizes. To support larger programs, increase the MAX* constants in flint.s and rebuild. Be careful: many arrays are sized from these constants and layout assumptions are used throughout the code.

Common extensions:
- Add string literal parsing and runtime string operations (concatenation, substrings). You already have a string pool — extend lexer and AST nodes for ND_STR.
- Expand MAXTOK / MAXNODE / MAXSYM / MAXFRAMES to support larger programs (update comments and tests accordingly).
- Add a small heap allocator (sys_brk/sys_mmap) for dynamic arrays.
- Implement additional built-ins (rand, time, file I/O wrappers) and a tiny standard library.

Notes about `read()` and EOF behavior
- read() uses a simple ascii-integer scanner implemented in read_int in flint.s. It skips whitespace and parses a signed decimal integer.
- EOF handling returns control to the caller; tests that depend on interactive behavior should be aware of this limited input model.

Appendix: where to look in flint.s
- Search for the token/AST .equ definitions near the top for exact numerical constants.
- Look at sections labeled "load_source", "tokenize", "classify_word", "resolve_symbol", the parser functions, and the evaluator (eval/exec_stmt/exec_list) to follow control flow.

If you want, I will also add an annotated walk-through of flint.s explaining key routines (lexer, parser entrypoint, eval loop) with line/offset references.
