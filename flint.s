#
# flint.s — the Flint programming language, implemented entirely in x86-64
# assembly. No libc, no external runtime: just Linux syscalls.
#
# Pipeline:  source text -> lexer -> tokens -> recursive-descent parser
#            -> AST (flat arrays, index-linked) -> tree-walking evaluator
#
# Build:  as --64 flint.s -o flint.o && ld -o flint flint.o
# Run:    ./flint program.fl
#
.intel_syntax noprefix

# ---------------------------------------------------------------- syscalls --
.equ SYS_READ,   0
.equ SYS_WRITE,  1
.equ SYS_OPEN,   2
.equ SYS_CLOSE,  3
.equ SYS_EXIT,   60

# ------------------------------------------------------------- token kinds --
.equ TOK_EOF,      0
.equ TOK_NUM,      1
.equ TOK_IDENT,    2
.equ TOK_PLUS,     3
.equ TOK_MINUS,    4
.equ TOK_STAR,     5
.equ TOK_SLASH,    6
.equ TOK_PERCENT,  7
.equ TOK_ASSIGN,   8
.equ TOK_EQEQ,     9
.equ TOK_NE,       10
.equ TOK_LT,       11
.equ TOK_GT,       12
.equ TOK_LE,       13
.equ TOK_GE,       14
.equ TOK_LPAREN,   15
.equ TOK_RPAREN,   16
.equ TOK_LBRACE,   17
.equ TOK_RBRACE,   18
.equ TOK_SEMI,     19
.equ TOK_IF,       20
.equ TOK_ELSE,     21
.equ TOK_WHILE,    22
.equ TOK_PRINT,    23
.equ TOK_LOGAND,   24
.equ TOK_LOGOR,    25
.equ TOK_BANG,     26
.equ TOK_BREAK,    27
.equ TOK_CONTINUE, 28
.equ TOK_FN,       29
.equ TOK_RETURN,   30
.equ TOK_COMMA,    31
.equ TOK_STR,      32
.equ TOK_READ,     33
.equ TOK_PUTCHAR,  34
.equ TOK_GETCHAR,  35

# -------------------------------------------------------------- AST kinds --
.equ ND_NUM,       1
.equ ND_VAR,       2
.equ ND_NEG,       3
.equ ND_ADD,       4
.equ ND_SUB,       5
.equ ND_MUL,       6
.equ ND_DIV,       7
.equ ND_MOD,       8
.equ ND_EQ,        9
.equ ND_NE,        10
.equ ND_LT,        11
.equ ND_GT,        12
.equ ND_LE,        13
.equ ND_GE,        14
.equ ND_ASSIGN,    15
.equ ND_PRINT,     16
.equ ND_IF,        17
.equ ND_WHILE,     18
.equ ND_NOT,       19
.equ ND_AND,       20
.equ ND_OR,        21
.equ ND_BREAK,     22
.equ ND_CONTINUE,  23
.equ ND_FN,        24
.equ ND_RETURN,    25
.equ ND_CALL,      26
.equ ND_EXPR_STMT, 27
.equ ND_STR,       28
.equ ND_READ,      29
.equ ND_PUTCHAR,   30
.equ ND_GETCHAR,   31

.equ MAXTOK,       8192
.equ MAXNODE,      8192
.equ MAXSYM,       256
.equ MAXFN,        64
.equ MAXPARAMS,    8
.equ MAXFRAMES,    256
.equ MAXSTR,       512
.equ STRPOOL_SIZE, 65536

# =============================================================== storage ==
.section .bss
src_buf:        .skip 65536       # raw source text
src_len:        .skip 8

tok_type:       .skip MAXTOK*8    # parallel token arrays
tok_val:        .skip MAXTOK*8
tok_line:       .skip MAXTOK*8    # source line number per token
cur_tok:        .skip 8           # parser cursor into tok_* arrays

# AST: parallel arrays, node 0 is reserved as the "null" node.
node_type:      .skip MAXNODE*8
node_a:         .skip MAXNODE*8
node_b:         .skip MAXNODE*8
node_c:         .skip MAXNODE*8
node_next:      .skip MAXNODE*8
node_n:         .skip 8

sym_name_ptr:   .skip MAXSYM*8    # symbol table: pointer into src_buf per name
sym_name_len:   .skip MAXSYM*8
sym_n:          .skip 8
digitbuf:       .skip 32          # scratch for integer -> decimal
program_root:   .skip 8

# Functions & Call Stack
fn_sym:         .skip MAXFN*8
fn_param_count: .skip MAXFN*8
fn_param_syms:  .skip MAXFN*MAXPARAMS*8
fn_body:        .skip MAXFN*8
fn_n:           .skip 8

call_depth:     .skip 8
call_stack:     .skip MAXFRAMES*MAXSYM*8 # 256 frames x 256 variables x 8 bytes
return_val:     .skip 8

# String Pool & Character I/O
str_pool_buf:   .skip STRPOOL_SIZE
str_pool_ptr:   .skip MAXSTR*8
str_pool_len:   .skip MAXSTR*8
str_pool_pos:   .skip 8
str_n:          .skip 8
char_io_buf:    .skip 16

.section .data
msg_usage:          .ascii "usage: flint <program.fl>\n"
msg_usage_len = . - msg_usage
msg_open:           .ascii "flint: cannot open file\n"
msg_open_len = . - msg_open
msg_parse_p1:       .ascii "flint: parse error on line "
msg_parse_p1_len = . - msg_parse_p1
msg_divzero:        .ascii "flint: division by zero\n"
msg_divzero_len = . - msg_divzero
msg_undef_fn:       .ascii "flint: undefined function\n"
msg_undef_fn_len = . - msg_undef_fn
msg_stackoverflow:  .ascii "flint: stack overflow\n"
msg_stackoverflow_len = . - msg_stackoverflow

# ================================================================= code ===
.section .text
.global _start

# ---------------------------------------------------------------- write_str
# rdi=ptr rsi=len
write_str:
    push rax
    push rdi
    push rsi
    push rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, 1
    mov rax, SYS_WRITE
    syscall
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

# ---------------------------------------------------------------------- die
# rdi=ptr rsi=len ; prints message to stdout and exits with status 1
die:
    call write_str
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

# ------------------------------------------------------------ die_parse_err
# Uses tok_line[cur_tok*8] to print "flint: parse error on line <N>\n" and exit 1
die_parse_error:
    lea rdi, [msg_parse_p1]
    mov rsi, msg_parse_p1_len
    call write_str
    mov rax, [cur_tok]
    mov rdi, [tok_line + rax*8]
    test rdi, rdi
    jnz die_parse_error_num
    mov rdi, 1
die_parse_error_num:
    call print_int
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

# ---------------------------------------------------------------- print_int
# rdi = signed 64-bit value; writes decimal representation + newline
print_int:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    lea r13, [digitbuf + 31]
    mov byte ptr [r13], 10
    mov r14, 1
    mov rax, r12
    test rax, rax
    jns print_int_mag_ok
    neg rax
print_int_mag_ok:
print_int_loop:
    xor rdx, rdx
    mov rcx, 10
    div rcx
    add dl, '0'
    dec r13
    mov [r13], dl
    inc r14
    test rax, rax
    jnz print_int_loop
    cmp r12, 0
    jge print_int_out
    dec r13
    mov byte ptr [r13], '-'
    inc r14
print_int_out:
    mov rdi, r13
    mov rsi, r14
    call write_str
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ----------------------------------------------------------------- read_int
# Reads signed 64-bit decimal integer from stdin (fd 0)
read_int:
    push rbx
    push r12
    push r13
    push r14
    xor r12, r12            # accumulated number
    xor r13, r13            # sign (0 = pos, 1 = neg)
    xor r14, r14            # digits seen count
read_int_skip_ws:
    lea rsi, [char_io_buf]
    mov rdx, 1
    xor rdi, rdi            # stdin
    mov rax, SYS_READ
    syscall
    cmp rax, 1
    jl read_int_done        # EOF reached
    movzx ebx, byte ptr [char_io_buf]
    cmp bl, ' '
    je read_int_skip_ws
    cmp bl, 9
    je read_int_skip_ws
    cmp bl, 10
    je read_int_skip_ws
    cmp bl, 13
    je read_int_skip_ws
    cmp bl, '-'
    jne read_int_check_digit
    mov r13, 1              # negative
    jmp read_int_digits
read_int_check_digit:
    cmp bl, '+'
    je read_int_digits
    cmp bl, '0'
    jl read_int_done
    cmp bl, '9'
    jg read_int_done
    sub bl, '0'
    movzx r12, bl
    mov r14, 1
read_int_digits:
    lea rsi, [char_io_buf]
    mov rdx, 1
    xor rdi, rdi            # stdin
    mov rax, SYS_READ
    syscall
    cmp rax, 1
    jl read_int_done        # EOF reached
    movzx ebx, byte ptr [char_io_buf]
    cmp bl, '0'
    jl read_int_done
    cmp bl, '9'
    jg read_int_done
    imul r12, r12, 10
    sub bl, '0'
    movzx rbx, bl
    add r12, rbx
    inc r14
    jmp read_int_digits
read_int_done:
    mov rax, r12
    test r13, r13
    jz read_int_out
    neg rax
read_int_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# -------------------------------------------------------------- putchar_int
# rdi = char code -> writes 1 byte to stdout, returns char code
putchar_int:
    push rbx
    mov rbx, rdi
    mov [char_io_buf], bl
    lea rsi, [char_io_buf]
    mov rdx, 1
    mov rdi, 1
    mov rax, SYS_WRITE
    syscall
    mov rax, rbx
    pop rbx
    ret

# -------------------------------------------------------------- getchar_int
# Returns: rax = byte code (0..255) or -1 on EOF
getchar_int:
    lea rsi, [char_io_buf]
    mov rdx, 1
    xor rdi, rdi
    mov rax, SYS_READ
    syscall
    cmp rax, 1
    jl getchar_eof
    movzx eax, byte ptr [char_io_buf]
    ret
getchar_eof:
    mov rax, -1
    ret

# -------------------------------------------------------------- load_source
# rdi = pointer to NUL-free filename
load_source:
    push r12
    xor rsi, rsi          # O_RDONLY
    xor rdx, rdx
    mov rax, SYS_OPEN
    syscall
    cmp rax, 0
    jl load_source_err
    mov r12, rax
    mov rdi, r12
    lea rsi, [src_buf]
    mov rdx, 65536
    mov rax, SYS_READ
    syscall
    cmp rax, 0
    jl load_source_err
    mov [src_len], rax
    mov rdi, r12
    mov rax, SYS_CLOSE
    syscall
    pop r12
    ret
load_source_err:
    lea rdi, [msg_open]
    mov rsi, msg_open_len
    call die

# ------------------------------------------------------------- resolve_symbol
# rsi=ptr rdx=len -> rax=symbol index
resolve_symbol:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi
    mov r15, rdx
    xor rbx, rbx
    mov r13, [sym_n]
resolve_symbol_loop:
    cmp rbx, r13
    jge resolve_symbol_new
    mov rax, [sym_name_len + rbx*8]
    cmp rax, r15
    jne resolve_symbol_next
    mov r12, [sym_name_ptr + rbx*8]
    xor rcx, rcx
resolve_symbol_cmp:
    cmp rcx, r15
    jge resolve_symbol_match
    mov al, [r12 + rcx]
    mov dl, [r14 + rcx]
    cmp al, dl
    jne resolve_symbol_next
    inc rcx
    jmp resolve_symbol_cmp
resolve_symbol_match:
    mov rax, rbx
    jmp resolve_symbol_done
resolve_symbol_next:
    inc rbx
    jmp resolve_symbol_loop
resolve_symbol_new:
    cmp r13, MAXSYM
    jge die_parse_error
    mov [sym_name_ptr + r13*8], r14
    mov [sym_name_len + r13*8], r15
    mov rax, r13
    inc r13
    mov [sym_n], r13
resolve_symbol_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------- classify_word
# rsi=ptr to word start, rdx=length -> rax=token type, rcx=value.
classify_word:
    cmp rdx, 2
    jne classify_word_try4
    mov al, [rsi]
    cmp al, 'i'
    je classify_word_if
    cmp al, 'f'
    je classify_word_fn
    jmp classify_word_ident
classify_word_if:
    mov al, [rsi+1]
    cmp al, 'f'
    jne classify_word_ident
    mov rax, TOK_IF
    ret
classify_word_fn:
    mov al, [rsi+1]
    cmp al, 'n'
    jne classify_word_ident
    mov rax, TOK_FN
    ret
classify_word_try4:
    cmp rdx, 4
    jne classify_word_try5
    mov al, [rsi]
    cmp al, 'e'
    je classify_word_else
    cmp al, 't'
    je classify_word_true
    cmp al, 'r'
    je classify_word_read
    jmp classify_word_ident
classify_word_else:
    mov al, [rsi+1]
    cmp al, 'l'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 's'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'e'
    jne classify_word_ident
    mov rax, TOK_ELSE
    ret
classify_word_true:
    mov al, [rsi+1]
    cmp al, 'r'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'u'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'e'
    jne classify_word_ident
    mov rax, TOK_NUM
    mov rcx, 1
    ret
classify_word_read:
    mov al, [rsi+1]
    cmp al, 'e'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'a'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'd'
    jne classify_word_ident
    mov rax, TOK_READ
    ret
classify_word_try5:
    cmp rdx, 5
    jne classify_word_try6
    mov al, [rsi]
    cmp al, 'w'
    je classify_word_while
    cmp al, 'p'
    je classify_word_print
    cmp al, 'f'
    je classify_word_false
    cmp al, 'b'
    je classify_word_break
    jmp classify_word_ident
classify_word_while:
    mov al, [rsi+1]
    cmp al, 'h'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'i'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'l'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'e'
    jne classify_word_ident
    mov rax, TOK_WHILE
    ret
classify_word_print:
    mov al, [rsi+1]
    cmp al, 'r'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'i'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'n'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 't'
    jne classify_word_ident
    mov rax, TOK_PRINT
    ret
classify_word_false:
    mov al, [rsi+1]
    cmp al, 'a'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'l'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 's'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'e'
    jne classify_word_ident
    mov rax, TOK_NUM
    xor rcx, rcx
    ret
classify_word_break:
    mov al, [rsi+1]
    cmp al, 'r'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'e'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'a'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'k'
    jne classify_word_ident
    mov rax, TOK_BREAK
    ret
classify_word_try6:
    cmp rdx, 6
    jne classify_word_try7
    mov al, [rsi]
    cmp al, 'r'
    jne classify_word_ident
    mov al, [rsi+1]
    cmp al, 'e'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 't'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'u'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'r'
    jne classify_word_ident
    mov al, [rsi+5]
    cmp al, 'n'
    jne classify_word_ident
    mov rax, TOK_RETURN
    ret
classify_word_try7:
    cmp rdx, 7
    jne classify_word_try8
    mov al, [rsi]
    cmp al, 'p'
    je classify_word_putchar
    cmp al, 'g'
    je classify_word_getchar
    jmp classify_word_ident
classify_word_putchar:
    mov al, [rsi+1]
    cmp al, 'u'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 't'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'c'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'h'
    jne classify_word_ident
    mov al, [rsi+5]
    cmp al, 'a'
    jne classify_word_ident
    mov al, [rsi+6]
    cmp al, 'r'
    jne classify_word_ident
    mov rax, TOK_PUTCHAR
    ret
classify_word_getchar:
    mov al, [rsi+1]
    cmp al, 'e'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 't'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 'c'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'h'
    jne classify_word_ident
    mov al, [rsi+5]
    cmp al, 'a'
    jne classify_word_ident
    mov al, [rsi+6]
    cmp al, 'r'
    jne classify_word_ident
    mov rax, TOK_GETCHAR
    ret
classify_word_try8:
    cmp rdx, 8
    jne classify_word_ident
    mov al, [rsi]
    cmp al, 'c'
    jne classify_word_ident
    mov al, [rsi+1]
    cmp al, 'o'
    jne classify_word_ident
    mov al, [rsi+2]
    cmp al, 'n'
    jne classify_word_ident
    mov al, [rsi+3]
    cmp al, 't'
    jne classify_word_ident
    mov al, [rsi+4]
    cmp al, 'i'
    jne classify_word_ident
    mov al, [rsi+5]
    cmp al, 'n'
    jne classify_word_ident
    mov al, [rsi+6]
    cmp al, 'u'
    jne classify_word_ident
    mov al, [rsi+7]
    cmp al, 'e'
    jne classify_word_ident
    mov rax, TOK_CONTINUE
    ret
classify_word_ident:
    call resolve_symbol
    mov rcx, rax
    mov rax, TOK_IDENT
    ret

# ------------------------------------------------------------------ tokenize
# Reads src_buf/src_len, fills tok_type/tok_val/tok_line, ends with TOK_EOF.
tokenize:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor rbx, rbx            # rbx = source index
    xor r12, r12            # r12 = token index
    mov r13, [src_len]      # r13 = source length
    mov r11, 1              # r11 = source line number
tokenize_main:
tokenize_ws:
    cmp rbx, r13
    jge tokenize_emit_eof
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, ' '
    je tokenize_ws_next
    cmp al, 9
    je tokenize_ws_next
    cmp al, 10
    jne tokenize_ws_try_cr
    inc r11
    jmp tokenize_ws_next
tokenize_ws_try_cr:
    cmp al, 13
    je tokenize_ws_next
    cmp al, '#'
    je tokenize_comment
    jmp tokenize_tok_start
tokenize_ws_next:
    inc rbx
    jmp tokenize_ws
tokenize_comment:
    inc rbx
tokenize_comment_loop:
    cmp rbx, r13
    jge tokenize_emit_eof
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, 10
    jne tokenize_comment_next
    inc r11
    inc rbx
    jmp tokenize_ws
tokenize_comment_next:
    inc rbx
    jmp tokenize_comment_loop

tokenize_tok_start:
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '"'
    je tokenize_str
    cmp al, '0'
    jl tokenize_try_alpha
    cmp al, '9'
    jg tokenize_try_alpha
    xor rcx, rcx
tokenize_num_loop:
    cmp rbx, r13
    jge tokenize_num_done
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '0'
    jl tokenize_num_done
    cmp al, '9'
    jg tokenize_num_done
    imul rcx, rcx, 10
    sub al, '0'
    movzx rdx, al
    add rcx, rdx
    inc rbx
    jmp tokenize_num_loop
tokenize_num_done:
    mov qword ptr [tok_type + r12*8], TOK_NUM
    mov [tok_val + r12*8], rcx
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main

tokenize_str:
    inc rbx                   # skip opening quote
    mov r14, [str_n]
    cmp r14, MAXSTR
    jge die_parse_error
    mov r15, [str_pool_pos]   # start pos in str_pool_buf
    lea rdi, [str_pool_buf + r15]
    mov [str_pool_ptr + r14*8], rdi
    xor rcx, rcx              # string byte length
tokenize_str_loop:
    cmp rbx, r13
    jge die_parse_error       # unterminated string
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '"'
    je tokenize_str_done
    cmp al, 10
    je die_parse_error        # newline inside string without \n
    cmp al, '\\'
    je tokenize_str_escape
    lea rdx, [str_pool_buf + r15]
    mov [rdx + rcx], al
    inc rcx
    inc rbx
    jmp tokenize_str_loop
tokenize_str_escape:
    inc rbx
    cmp rbx, r13
    jge die_parse_error
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, 'n'
    je tokenize_str_esc_n
    cmp al, 't'
    je tokenize_str_esc_t
    cmp al, 'r'
    je tokenize_str_esc_r
    cmp al, '0'
    je tokenize_str_esc_0
    cmp al, '\\'
    je tokenize_str_esc_slash
    cmp al, '"'
    je tokenize_str_esc_quote
    jmp tokenize_str_esc_store
tokenize_str_esc_n:
    mov al, 10
    jmp tokenize_str_esc_store
tokenize_str_esc_t:
    mov al, 9
    jmp tokenize_str_esc_store
tokenize_str_esc_r:
    mov al, 13
    jmp tokenize_str_esc_store
tokenize_str_esc_0:
    mov al, 0
    jmp tokenize_str_esc_store
tokenize_str_esc_slash:
    mov al, '\\'
    jmp tokenize_str_esc_store
tokenize_str_esc_quote:
    mov al, '"'
tokenize_str_esc_store:
    lea rdx, [str_pool_buf + r15]
    mov [rdx + rcx], al
    inc rcx
    inc rbx
    jmp tokenize_str_loop
tokenize_str_done:
    inc rbx                   # skip closing quote
    mov [str_pool_len + r14*8], rcx
    add [str_pool_pos], rcx
    mov qword ptr [tok_type + r12*8], TOK_STR
    mov [tok_val + r12*8], r14
    mov [tok_line + r12*8], r11
    inc r14
    mov [str_n], r14
    inc r12
    jmp tokenize_main

tokenize_try_alpha:
    cmp al, 'a'
    jl tokenize_try_upper
    cmp al, 'z'
    jle tokenize_is_ident_start
tokenize_try_upper:
    cmp al, 'A'
    jl tokenize_try_under
    cmp al, 'Z'
    jle tokenize_is_ident_start
tokenize_try_under:
    cmp al, '_'
    je tokenize_is_ident_start
    jmp tokenize_try_op

tokenize_is_ident_start:
    mov r14, rbx             # word start
    xor r15, r15             # word length
tokenize_word_loop:
    cmp rbx, r13
    jge tokenize_word_done
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, 'a'
    jl tokenize_word_chk_upper
    cmp al, 'z'
    jle tokenize_word_char_ok
tokenize_word_chk_upper:
    cmp al, 'A'
    jl tokenize_word_chk_digit
    cmp al, 'Z'
    jle tokenize_word_char_ok
tokenize_word_chk_digit:
    cmp al, '0'
    jl tokenize_word_chk_under
    cmp al, '9'
    jle tokenize_word_char_ok
tokenize_word_chk_under:
    cmp al, '_'
    je tokenize_word_char_ok
    jmp tokenize_word_done
tokenize_word_char_ok:
    inc rbx
    inc r15
    cmp r15, 63
    jl tokenize_word_loop
tokenize_word_done:
    lea rsi, [src_buf + r14]
    mov rdx, r15
    call classify_word
    mov [tok_type + r12*8], rax
    mov [tok_val + r12*8], rcx
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main

tokenize_try_op:
    cmp al, '('
    jne tokenize_op2
    mov qword ptr [tok_type + r12*8], TOK_LPAREN
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op2:
    cmp al, ')'
    jne tokenize_op3
    mov qword ptr [tok_type + r12*8], TOK_RPAREN
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op3:
    cmp al, '{'
    jne tokenize_op4
    mov qword ptr [tok_type + r12*8], TOK_LBRACE
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op4:
    cmp al, '}'
    jne tokenize_op5
    mov qword ptr [tok_type + r12*8], TOK_RBRACE
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op5:
    cmp al, ';'
    jne tokenize_op6
    mov qword ptr [tok_type + r12*8], TOK_SEMI
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op6:
    cmp al, ','
    jne tokenize_op7
    mov qword ptr [tok_type + r12*8], TOK_COMMA
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op7:
    cmp al, '+'
    jne tokenize_op8
    mov qword ptr [tok_type + r12*8], TOK_PLUS
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op8:
    cmp al, '-'
    jne tokenize_op9
    mov qword ptr [tok_type + r12*8], TOK_MINUS
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op9:
    cmp al, '*'
    jne tokenize_op10
    mov qword ptr [tok_type + r12*8], TOK_STAR
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op10:
    cmp al, '/'
    jne tokenize_op11
    mov qword ptr [tok_type + r12*8], TOK_SLASH
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op11:
    cmp al, '%'
    jne tokenize_op_and
    mov qword ptr [tok_type + r12*8], TOK_PERCENT
    mov [tok_line + r12*8], r11
    inc rbx
    inc r12
    jmp tokenize_main
tokenize_op_and:
    cmp al, '&'
    jne tokenize_op_or
    inc rbx
    cmp rbx, r13
    jge tokenize_bad_char
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '&'
    jne tokenize_bad_char
    inc rbx
    mov qword ptr [tok_type + r12*8], TOK_LOGAND
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_op_or:
    cmp al, '|'
    jne tokenize_op12
    inc rbx
    cmp rbx, r13
    jge tokenize_bad_char
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '|'
    jne tokenize_bad_char
    inc rbx
    mov qword ptr [tok_type + r12*8], TOK_LOGOR
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_op12:
    cmp al, '='
    jne tokenize_op13
    inc rbx
    cmp rbx, r13
    jge tokenize_assign_only
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '='
    jne tokenize_assign_only
    inc rbx
    mov qword ptr [tok_type + r12*8], TOK_EQEQ
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_assign_only:
    mov qword ptr [tok_type + r12*8], TOK_ASSIGN
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_op13:
    cmp al, '!'
    jne tokenize_op14
    inc rbx
    cmp rbx, r13
    jge tokenize_bang_only
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '='
    jne tokenize_bang_only
    inc rbx
    mov qword ptr [tok_type + r12*8], TOK_NE
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_bang_only:
    mov qword ptr [tok_type + r12*8], TOK_BANG
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_op14:
    cmp al, '<'
    jne tokenize_op15
    inc rbx
    cmp rbx, r13
    jge tokenize_lt_only
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '='
    jne tokenize_lt_only
    inc rbx
    mov qword ptr [tok_type + r12*8], TOK_LE
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_lt_only:
    mov qword ptr [tok_type + r12*8], TOK_LT
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_op15:
    cmp al, '>'
    jne tokenize_bad_char
    inc rbx
    cmp rbx, r13
    jge tokenize_gt_only
    movzx eax, byte ptr [src_buf + rbx]
    cmp al, '='
    jne tokenize_gt_only
    inc rbx
    mov qword ptr [tok_type + r12*8], TOK_GE
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_gt_only:
    mov qword ptr [tok_type + r12*8], TOK_GT
    mov [tok_line + r12*8], r11
    inc r12
    jmp tokenize_main
tokenize_bad_char:
    mov [tok_line + r12*8], r11
    mov [cur_tok], r12
    jmp die_parse_error
tokenize_emit_eof:
    mov qword ptr [tok_type + r12*8], TOK_EOF
    mov [tok_line + r12*8], r11
    inc r12
    mov qword ptr [cur_tok], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------------ new_node
# rdi=type rsi=a rdx=b rcx=c -> rax = new node index
new_node:
    mov r8, [node_n]
    mov [node_type + r8*8], rdi
    mov [node_a + r8*8], rsi
    mov [node_b + r8*8], rdx
    mov [node_c + r8*8], rcx
    mov qword ptr [node_next + r8*8], 0
    mov rax, r8
    inc r8
    mov [node_n], r8
    ret

# ----------------------------------------------------------- token cursor --
peek_type:
    mov rax, [cur_tok]
    mov rax, [tok_type + rax*8]
    ret

advance_tok:
    mov rcx, [cur_tok]
    mov rax, [tok_type + rcx*8]
    mov rdx, [tok_val + rcx*8]
    inc rcx
    mov [cur_tok], rcx
    ret

# rdi = expected token type; consumes it or dies with a parse error
expect_tok:
    push rdi
    call peek_type
    pop rdi
    cmp rax, rdi
    jne die_parse_error
    call advance_tok
    ret

# ------------------------------------------------------- expression parser --
# Precedence climbing:
# logical_or (||) -> logical_and (&&) -> equality (==, !=) -> relational (<, >, <=, >=)
# -> additive (+, -) -> mult (*, /, %) -> unary (-, !) -> primary

parse_primary:
    call peek_type
    cmp rax, TOK_NUM
    jne parse_primary_try_str
    call advance_tok
    mov rdi, ND_NUM
    mov rsi, rdx
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_primary_try_str:
    cmp rax, TOK_STR
    jne parse_primary_try_read
    call advance_tok
    mov rdi, ND_STR
    mov rsi, rdx              # str_id
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_primary_try_read:
    cmp rax, TOK_READ
    jne parse_primary_try_putchar
    call advance_tok
    mov rdi, TOK_LPAREN
    call expect_tok
    mov rdi, TOK_RPAREN
    call expect_tok
    mov rdi, ND_READ
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_primary_try_putchar:
    cmp rax, TOK_PUTCHAR
    jne parse_primary_try_getchar
    call advance_tok
    mov rdi, TOK_LPAREN
    call expect_tok
    call parse_expr
    push rax
    mov rdi, TOK_RPAREN
    call expect_tok
    pop rax
    mov rdi, ND_PUTCHAR
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_primary_try_getchar:
    cmp rax, TOK_GETCHAR
    jne parse_primary_try_ident
    call advance_tok
    mov rdi, TOK_LPAREN
    call expect_tok
    mov rdi, TOK_RPAREN
    call expect_tok
    mov rdi, ND_GETCHAR
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_primary_try_ident:
    cmp rax, TOK_IDENT
    jne parse_primary_try_lparen
    call advance_tok
    mov r8, rdx               # symbol ID (caller-saved r8)
    call peek_type
    cmp rax, TOK_LPAREN
    je parse_call
    mov rdi, ND_VAR
    mov rsi, r8
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_primary_try_lparen:
    cmp rax, TOK_LPAREN
    jne die_parse_error
    call advance_tok
    call parse_expr
    push rax
    mov rdi, TOK_RPAREN
    call expect_tok
    pop rax
    ret

# parse_call: r8 = function name symbol index
parse_call:
    call advance_tok          # consume '('
    push r8                   # save fn sym id
    push r12                  # save caller's r12
    push r13                  # save caller's r13
    call peek_type
    cmp rax, TOK_RPAREN
    je parse_call_no_args
    call parse_expr
    mov r12, rax              # r12 = first arg node
    mov r13, rax              # r13 = tail of arg list
parse_call_args_loop:
    call peek_type
    cmp rax, TOK_COMMA
    jne parse_call_args_done
    call advance_tok
    call parse_expr
    mov [node_next + r13*8], rax
    mov r13, rax
    jmp parse_call_args_loop
parse_call_args_done:
    mov rdi, TOK_RPAREN
    call expect_tok
    mov rdx, r12              # rdx = first arg node
    jmp parse_call_mk
parse_call_no_args:
    mov rdi, TOK_RPAREN
    call expect_tok
    xor rdx, rdx              # rdx = 0
parse_call_mk:
    pop r13                   # restore caller's r13
    pop r12                   # restore caller's r12
    pop rsi                   # restore fn sym id into rsi
    mov rdi, ND_CALL
    xor rcx, rcx
    call new_node
    ret

parse_unary:
    call peek_type
    cmp rax, TOK_MINUS
    je parse_unary_neg
    cmp rax, TOK_BANG
    je parse_unary_not
    jmp parse_primary
parse_unary_neg:
    call advance_tok
    call parse_unary
    mov rdi, ND_NEG
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_unary_not:
    call advance_tok
    call parse_unary
    mov rdi, ND_NOT
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret

parse_mult:
    push rbx
    push r15
    call parse_unary
    mov rbx, rax
parse_mult_loop:
    call peek_type
    mov r15, rax
    cmp r15, TOK_STAR
    je parse_mult_op
    cmp r15, TOK_SLASH
    je parse_mult_op
    cmp r15, TOK_PERCENT
    je parse_mult_op
    jmp parse_mult_done
parse_mult_op:
    call advance_tok
    call parse_unary
    mov rdi, ND_MUL
    cmp r15, TOK_STAR
    je parse_mult_settype
    mov rdi, ND_DIV
    cmp r15, TOK_SLASH
    je parse_mult_settype
    mov rdi, ND_MOD
parse_mult_settype:
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    mov rbx, rax
    jmp parse_mult_loop
parse_mult_done:
    mov rax, rbx
    pop r15
    pop rbx
    ret

parse_additive:
    push rbx
    push r15
    call parse_mult
    mov rbx, rax
parse_additive_loop:
    call peek_type
    mov r15, rax
    cmp r15, TOK_PLUS
    je parse_additive_op
    cmp r15, TOK_MINUS
    je parse_additive_op
    jmp parse_additive_done
parse_additive_op:
    call advance_tok
    call parse_mult
    mov rdi, ND_ADD
    cmp r15, TOK_PLUS
    je parse_additive_settype
    mov rdi, ND_SUB
parse_additive_settype:
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    mov rbx, rax
    jmp parse_additive_loop
parse_additive_done:
    mov rax, rbx
    pop r15
    pop rbx
    ret

parse_relational:
    push rbx
    push r15
    call parse_additive
    mov rbx, rax
parse_relational_loop:
    call peek_type
    mov r15, rax
    cmp r15, TOK_LT
    je parse_relational_op
    cmp r15, TOK_GT
    je parse_relational_op
    cmp r15, TOK_LE
    je parse_relational_op
    cmp r15, TOK_GE
    je parse_relational_op
    jmp parse_relational_done
parse_relational_op:
    call advance_tok
    call parse_additive
    mov rdi, ND_LT
    cmp r15, TOK_LT
    je parse_relational_settype
    mov rdi, ND_GT
    cmp r15, TOK_GT
    je parse_relational_settype
    mov rdi, ND_LE
    cmp r15, TOK_LE
    je parse_relational_settype
    mov rdi, ND_GE
parse_relational_settype:
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    mov rbx, rax
    jmp parse_relational_loop
parse_relational_done:
    mov rax, rbx
    pop r15
    pop rbx
    ret

parse_equality:
    push rbx
    push r15
    call parse_relational
    mov rbx, rax
parse_equality_loop:
    call peek_type
    mov r15, rax
    cmp r15, TOK_EQEQ
    je parse_equality_op
    cmp r15, TOK_NE
    je parse_equality_op
    jmp parse_equality_done
parse_equality_op:
    call advance_tok
    call parse_relational
    mov rdi, ND_EQ
    cmp r15, TOK_EQEQ
    je parse_equality_settype
    mov rdi, ND_NE
parse_equality_settype:
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    mov rbx, rax
    jmp parse_equality_loop
parse_equality_done:
    mov rax, rbx
    pop r15
    pop rbx
    ret

parse_logical_and:
    push rbx
    push r15
    call parse_equality
    mov rbx, rax
parse_logical_and_loop:
    call peek_type
    cmp rax, TOK_LOGAND
    jne parse_logical_and_done
    call advance_tok
    call parse_equality
    mov rdi, ND_AND
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    mov rbx, rax
    jmp parse_logical_and_loop
parse_logical_and_done:
    mov rax, rbx
    pop r15
    pop rbx
    ret

parse_logical_or:
    push rbx
    push r15
    call parse_logical_and
    mov rbx, rax
parse_logical_or_loop:
    call peek_type
    cmp rax, TOK_LOGOR
    jne parse_logical_or_done
    call advance_tok
    call parse_logical_and
    mov rdi, ND_OR
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    mov rbx, rax
    jmp parse_logical_or_loop
parse_logical_or_done:
    mov rax, rbx
    pop r15
    pop rbx
    ret

parse_expr:
    jmp parse_logical_or

# --------------------------------------------------------- statement parser
# rdi = terminator token type -> rax = index of first stmt (0 if none).
# Links statements via node_next; does not consume the terminator.
parse_stmts_until:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor rbx, rbx
    xor r13, r13
parse_stmts_until_loop:
    call peek_type
    cmp rax, r12
    je parse_stmts_until_done
    cmp rax, TOK_EOF
    je parse_stmts_until_done
    call parse_stmt
    test rbx, rbx
    jnz parse_stmts_until_link
    mov rbx, rax
    mov r13, rax
    jmp parse_stmts_until_loop
parse_stmts_until_link:
    mov [node_next + r13*8], rax
    mov r13, rax
    jmp parse_stmts_until_loop
parse_stmts_until_done:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

parse_block:
    mov rdi, TOK_LBRACE
    call expect_tok
    mov rdi, TOK_RBRACE
    call parse_stmts_until
    push rax
    mov rdi, TOK_RBRACE
    call expect_tok
    pop rax
    ret

parse_program:
    mov rdi, TOK_EOF
    call parse_stmts_until
    ret

parse_stmt:
    call peek_type
    cmp rax, TOK_IF
    je parse_stmt_if
    cmp rax, TOK_WHILE
    je parse_stmt_while
    cmp rax, TOK_PRINT
    je parse_stmt_print
    cmp rax, TOK_BREAK
    je parse_stmt_break
    cmp rax, TOK_CONTINUE
    je parse_stmt_continue
    cmp rax, TOK_FN
    je parse_stmt_fn
    cmp rax, TOK_RETURN
    je parse_stmt_return
    cmp rax, TOK_IDENT
    je parse_stmt_ident
    # Fallback to expression statement
    call parse_expr
    push rax
    mov rdi, TOK_SEMI
    call expect_tok
    pop rax
    mov rdi, ND_EXPR_STMT
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_stmt_if:
    jmp parse_if
parse_stmt_while:
    jmp parse_while
parse_stmt_print:
    jmp parse_print
parse_stmt_break:
    jmp parse_break
parse_stmt_continue:
    jmp parse_continue
parse_stmt_fn:
    jmp parse_fn
parse_stmt_return:
    jmp parse_return
parse_stmt_ident:
    mov rax, [cur_tok]
    mov rcx, [tok_type + rax*8 + 8] # peek next token
    cmp rcx, TOK_ASSIGN
    je parse_assign
    # Expression statement
    call parse_expr
    push rax
    mov rdi, TOK_SEMI
    call expect_tok
    pop rax
    mov rdi, ND_EXPR_STMT
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret

# fn ident ( [param, ...] ) block
parse_fn:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call advance_tok          # consume 'fn'
    call peek_type
    cmp rax, TOK_IDENT
    jne die_parse_error
    call advance_tok
    mov rbx, rdx              # function name sym id
    mov rdi, TOK_LPAREN
    call expect_tok
    xor r14, r14              # param count
    mov r15, [fn_n]
    cmp r15, MAXFN
    jge die_parse_error
    imul r13, r15, MAXPARAMS  # r13 = base index in fn_param_syms
    call peek_type
    cmp rax, TOK_RPAREN
    je parse_fn_params_done
parse_fn_params_loop:
    call peek_type
    cmp rax, TOK_IDENT
    jne die_parse_error
    call advance_tok          # rdx = param sym id
    cmp r14, MAXPARAMS
    jge die_parse_error
    lea r8, [r13 + r14]
    mov [fn_param_syms + r8*8], rdx
    inc r14
    call peek_type
    cmp rax, TOK_COMMA
    jne parse_fn_params_done
    call advance_tok
    jmp parse_fn_params_loop
parse_fn_params_done:
    mov rdi, TOK_RPAREN
    call expect_tok
    call parse_block
    mov r12, rax              # body AST node
    # Register function
    mov [fn_sym + r15*8], rbx
    mov [fn_param_count + r15*8], r14
    mov [fn_body + r15*8], r12
    inc r15
    mov [fn_n], r15
    # Return ND_FN node
    mov rdi, ND_FN
    mov rsi, r15
    dec rsi
    mov rdx, r12
    xor rcx, rcx
    call new_node
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# return [expr] ;
parse_return:
    call advance_tok          # consume 'return'
    call peek_type
    cmp rax, TOK_SEMI
    je parse_return_empty
    call parse_expr
    push rax
    mov rdi, TOK_SEMI
    call expect_tok
    pop rax
    mov rdi, ND_RETURN
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret
parse_return_empty:
    call advance_tok          # consume ';'
    mov rdi, ND_RETURN
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret

# if ( expr ) block [else block]
parse_if:
    push rbx
    push r14
    push r15
    call advance_tok
    mov rdi, TOK_LPAREN
    call expect_tok
    call parse_expr
    mov rbx, rax
    mov rdi, TOK_RPAREN
    call expect_tok
    call parse_block
    mov r14, rax
    xor r15, r15
    call peek_type
    cmp rax, TOK_ELSE
    jne parse_if_mk
    call advance_tok
    call parse_block
    mov r15, rax
parse_if_mk:
    mov rdi, ND_IF
    mov rsi, rbx
    mov rdx, r14
    mov rcx, r15
    call new_node
    pop r15
    pop r14
    pop rbx
    ret

# while ( expr ) block
parse_while:
    push rbx
    call advance_tok
    mov rdi, TOK_LPAREN
    call expect_tok
    call parse_expr
    mov rbx, rax
    mov rdi, TOK_RPAREN
    call expect_tok
    call parse_block
    mov rdi, ND_WHILE
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    pop rbx
    ret

# print expr ;
parse_print:
    call advance_tok
    call parse_expr
    push rax
    mov rdi, TOK_SEMI
    call expect_tok
    pop rax
    mov rdi, ND_PRINT
    mov rsi, rax
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret

# break ;
parse_break:
    call advance_tok
    mov rdi, TOK_SEMI
    call expect_tok
    mov rdi, ND_BREAK
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret

# continue ;
parse_continue:
    call advance_tok
    mov rdi, TOK_SEMI
    call expect_tok
    mov rdi, ND_CONTINUE
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call new_node
    ret

# ident = expr ;
parse_assign:
    push rbx
    call peek_type
    cmp rax, TOK_IDENT
    je parse_assign_ok
    jmp die_parse_error
parse_assign_ok:
    call advance_tok
    mov rbx, rdx
    mov rdi, TOK_ASSIGN
    call expect_tok
    call parse_expr
    push rax
    mov rdi, TOK_SEMI
    call expect_tok
    pop rax
    mov rdi, ND_ASSIGN
    mov rsi, rbx
    mov rdx, rax
    xor rcx, rcx
    call new_node
    pop rbx
    ret

# ------------------------------------------------------------- evaluator --
# cmp_helper: r12 = comparison node (set by caller). Evaluates node_a and
# node_b and leaves FLAGS set from `cmp left, right`.
cmp_helper:
    push rbx
    mov rdi, [node_a + r12*8]
    call eval
    mov rbx, rax
    mov rdi, [node_b + r12*8]
    call eval
    cmp rbx, rax
    pop rbx
    ret

# eval: rdi = node index -> rax = value
eval:
    push rbx
    push r12
    mov r12, rdi
    mov rax, [node_type + r12*8]
    cmp rax, ND_NUM
    je eval_num
    cmp rax, ND_VAR
    je eval_var
    cmp rax, ND_NEG
    je eval_neg
    cmp rax, ND_ADD
    je eval_add
    cmp rax, ND_SUB
    je eval_sub
    cmp rax, ND_MUL
    je eval_mul
    cmp rax, ND_DIV
    je eval_div
    cmp rax, ND_MOD
    je eval_mod
    cmp rax, ND_EQ
    je eval_eq
    cmp rax, ND_NE
    je eval_ne
    cmp rax, ND_LT
    je eval_lt
    cmp rax, ND_GT
    je eval_gt
    cmp rax, ND_LE
    je eval_le
    cmp rax, ND_GE
    je eval_ge
    cmp rax, ND_NOT
    je eval_not
    cmp rax, ND_AND
    je eval_and
    cmp rax, ND_OR
    je eval_or
    cmp rax, ND_CALL
    je eval_call
    cmp rax, ND_STR
    je eval_str
    cmp rax, ND_READ
    je eval_read
    cmp rax, ND_PUTCHAR
    je eval_putchar
    cmp rax, ND_GETCHAR
    je eval_getchar
    jmp die_parse_error

eval_num:
    mov rax, [node_a + r12*8]
    jmp eval_out

eval_str:
    mov rax, [node_a + r12*8]
    jmp eval_out

eval_read:
    call read_int
    jmp eval_out

eval_putchar:
    mov rdi, [node_a + r12*8]
    call eval
    mov rdi, rax
    call putchar_int
    jmp eval_out

eval_getchar:
    call getchar_int
    jmp eval_out

eval_var:
    mov rax, [node_a + r12*8]     # sym_id
    mov rbx, [call_depth]
    imul rcx, rbx, MAXSYM
    add rcx, rax
    mov rax, [call_stack + rcx*8]
    jmp eval_out

eval_neg:
    mov rdi, [node_a + r12*8]
    call eval
    neg rax
    jmp eval_out

eval_not:
    mov rdi, [node_a + r12*8]
    call eval
    test rax, rax
    setz al
    movzx rax, al
    jmp eval_out

eval_add:
    mov rdi, [node_a + r12*8]
    call eval
    mov rbx, rax
    mov rdi, [node_b + r12*8]
    call eval
    add rax, rbx
    jmp eval_out

eval_sub:
    mov rdi, [node_a + r12*8]
    call eval
    mov rbx, rax
    mov rdi, [node_b + r12*8]
    call eval
    mov rcx, rax
    mov rax, rbx
    sub rax, rcx
    jmp eval_out

eval_mul:
    mov rdi, [node_a + r12*8]
    call eval
    mov rbx, rax
    mov rdi, [node_b + r12*8]
    call eval
    imul rax, rbx
    jmp eval_out

eval_div:
    mov rdi, [node_a + r12*8]
    call eval
    mov rbx, rax
    mov rdi, [node_b + r12*8]
    call eval
    test rax, rax
    jnz eval_div_ok
    lea rdi, [msg_divzero]
    mov rsi, msg_divzero_len
    call die
eval_div_ok:
    mov rcx, rax
    mov rax, rbx
    cqo
    idiv rcx
    jmp eval_out

eval_mod:
    mov rdi, [node_a + r12*8]
    call eval
    mov rbx, rax
    mov rdi, [node_b + r12*8]
    call eval
    test rax, rax
    jnz eval_mod_ok
    lea rdi, [msg_divzero]
    mov rsi, msg_divzero_len
    call die
eval_mod_ok:
    mov rcx, rax
    mov rax, rbx
    cqo
    idiv rcx
    mov rax, rdx
    jmp eval_out

eval_eq:
    call cmp_helper
    sete al
    movzx rax, al
    jmp eval_out

eval_ne:
    call cmp_helper
    setne al
    movzx rax, al
    jmp eval_out

eval_lt:
    call cmp_helper
    setl al
    movzx rax, al
    jmp eval_out

eval_gt:
    call cmp_helper
    setg al
    movzx rax, al
    jmp eval_out

eval_le:
    call cmp_helper
    setle al
    movzx rax, al
    jmp eval_out

eval_ge:
    call cmp_helper
    setge al
    movzx rax, al
    jmp eval_out

eval_and:
    mov rdi, [node_a + r12*8]
    call eval
    test rax, rax
    jz eval_and_false
    mov rdi, [node_b + r12*8]
    call eval
    test rax, rax
    setnz al
    movzx rax, al
    jmp eval_out
eval_and_false:
    xor rax, rax
    jmp eval_out

eval_or:
    mov rdi, [node_a + r12*8]
    call eval
    test rax, rax
    jnz eval_or_true
    mov rdi, [node_b + r12*8]
    call eval
    test rax, rax
    setnz al
    movzx rax, al
    jmp eval_out
eval_or_true:
    mov rax, 1
    jmp eval_out

# eval_call: node_a = fn_sym_id, node_b = first arg node (0 if none)
eval_call:
    push rbx
    push r13
    push r14
    push r15
    push rbp
    mov r14, [node_a + r12*8] # function symbol ID
    xor rbx, rbx
    mov r15, [fn_n]
eval_call_lookup:
    cmp rbx, r15
    jge die_undef_fn
    cmp [fn_sym + rbx*8], r14
    je eval_call_found
    inc rbx
    jmp eval_call_lookup
eval_call_found:
    # rbx = function index
    mov r13, [node_b + r12*8] # first arg node
    xor rbp, rbp              # number of arguments pushed
eval_call_eval_args:
    test r13, r13
    jz eval_call_args_done
    mov rdi, r13
    call eval
    push rax                  # push evaluated argument
    inc rbp
    mov r13, [node_next + r13*8]
    jmp eval_call_eval_args
eval_call_args_done:
    # Check max call depth
    mov rax, [call_depth]
    cmp rax, MAXFRAMES - 1
    jge die_stackoverflow
    inc rax
    mov [call_depth], rax     # rax = new depth D
    # Zero out new frame variable storage
    imul rdi, rax, MAXSYM*8
    lea rdi, [call_stack + rdi]
    xor rax, rax
    mov rcx, MAXSYM
    rep stosq
    # Pop evaluated arguments into new frame
    mov rcx, rbp
eval_call_pop_args:
    test rcx, rcx
    jz eval_call_pop_done
    dec rcx
    pop rax                   # rax = argument value
    cmp rcx, [fn_param_count + rbx*8]
    jge eval_call_pop_args    # ignore excess args
    imul r8, rbx, MAXPARAMS
    add r8, rcx
    mov r8, [fn_param_syms + r8*8] # r8 = param symbol ID
    mov r9, [call_depth]
    imul r9, r9, MAXSYM
    add r9, r8
    mov [call_stack + r9*8], rax
    jmp eval_call_pop_args
eval_call_pop_done:
    mov qword ptr [return_val], 0
    mov rdi, [fn_body + rbx*8]
    call exec_list
    dec qword ptr [call_depth]
    mov rax, [return_val]
    pop rbp
    pop r15
    pop r14
    pop r13
    pop rbx
    jmp eval_out

die_undef_fn:
    lea rdi, [msg_undef_fn]
    mov rsi, msg_undef_fn_len
    call die

die_stackoverflow:
    lea rdi, [msg_stackoverflow]
    mov rsi, msg_stackoverflow_len
    call die

eval_out:
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------- executor --
# exec_list: rdi = index of first statement in a block (0 = empty)
# Returns rax: 0 = OK, 1 = BREAK, 2 = CONTINUE, 3 = RETURN
exec_list:
    push rbx
    mov rbx, rdi
    xor rax, rax
exec_list_loop:
    test rbx, rbx
    jz exec_list_done
    mov rdi, rbx
    call exec_stmt
    test rax, rax
    jnz exec_list_done
    mov rbx, [node_next + rbx*8]
    jmp exec_list_loop
exec_list_done:
    pop rbx
    ret

# exec_stmt: rdi = statement node index
# Returns rax: 0 = OK, 1 = BREAK, 2 = CONTINUE, 3 = RETURN
exec_stmt:
    push rbx
    push r12
    mov r12, rdi
    mov rax, [node_type + r12*8]
    cmp rax, ND_ASSIGN
    je exec_stmt_assign
    cmp rax, ND_PRINT
    je exec_stmt_print
    cmp rax, ND_IF
    je exec_stmt_if
    cmp rax, ND_WHILE
    je exec_stmt_while_check
    cmp rax, ND_BREAK
    je exec_stmt_break
    cmp rax, ND_CONTINUE
    je exec_stmt_continue
    cmp rax, ND_FN
    je exec_stmt_fn
    cmp rax, ND_RETURN
    je exec_stmt_return
    cmp rax, ND_EXPR_STMT
    je exec_stmt_expr
    xor rax, rax
    jmp exec_stmt_done

exec_stmt_assign:
    mov rdi, [node_b + r12*8]
    call eval
    mov rcx, [node_a + r12*8]
    mov r8, [call_depth]
    imul rdx, r8, MAXSYM
    add rdx, rcx
    mov [call_stack + rdx*8], rax
    xor rax, rax
    jmp exec_stmt_done

exec_stmt_print:
    mov rdi, [node_a + r12*8]
    mov rax, [node_type + rdi*8]
    cmp rax, ND_STR
    je exec_stmt_print_str
    call eval
    mov rdi, rax
    call print_int
    xor rax, rax
    jmp exec_stmt_done
exec_stmt_print_str:
    mov rdx, [node_a + rdi*8] # str_id
    mov rsi, [str_pool_len + rdx*8]
    mov rdi, [str_pool_ptr + rdx*8]
    call write_str
    xor rax, rax
    jmp exec_stmt_done

exec_stmt_if:
    mov rdi, [node_a + r12*8]
    call eval
    test rax, rax
    jz exec_stmt_else
    mov rdi, [node_b + r12*8]
    call exec_list
    jmp exec_stmt_done
exec_stmt_else:
    mov rdi, [node_c + r12*8]
    call exec_list
    jmp exec_stmt_done

exec_stmt_while_check:
    mov rdi, [node_a + r12*8]
    call eval
    test rax, rax
    jz exec_stmt_while_done_ok
    mov rdi, [node_b + r12*8]
    call exec_list
    cmp rax, 1                 # STATUS_BREAK
    je exec_stmt_while_done_ok
    cmp rax, 3                 # STATUS_RETURN
    je exec_stmt_done          # propagate return out of while immediately
    # STATUS_CONTINUE (2) or STATUS_OK (0): loop again
    jmp exec_stmt_while_check
exec_stmt_while_done_ok:
    xor rax, rax
    jmp exec_stmt_done

exec_stmt_break:
    mov rax, 1
    jmp exec_stmt_done

exec_stmt_continue:
    mov rax, 2
    jmp exec_stmt_done

exec_stmt_fn:
    xor rax, rax
    jmp exec_stmt_done

exec_stmt_return:
    mov rdi, [node_a + r12*8]
    test rdi, rdi
    jz exec_stmt_return_zero
    call eval
    mov [return_val], rax
    mov rax, 3                 # STATUS_RETURN
    jmp exec_stmt_done
exec_stmt_return_zero:
    mov qword ptr [return_val], 0
    mov rax, 3                 # STATUS_RETURN
    jmp exec_stmt_done

exec_stmt_expr:
    mov rdi, [node_a + r12*8]
    call eval
    xor rax, rax
    jmp exec_stmt_done

exec_stmt_done:
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- _start --
_start:
    mov qword ptr [node_n], 1      # node 0 is reserved as "null"
    mov qword ptr [call_depth], 0
    mov qword ptr [fn_n], 0
    mov qword ptr [str_n], 0
    mov qword ptr [str_pool_pos], 0
    mov rax, [rsp]                 # argc
    cmp rax, 2
    jl start_usage
    mov rdi, [rsp + 16]            # argv[1]
    call load_source
    call tokenize
    call parse_program
    mov [program_root], rax
    mov rdi, [program_root]
    call exec_list
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall
start_usage:
    lea rdi, [msg_usage]
    mov rsi, msg_usage_len
    call die
