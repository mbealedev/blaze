.include "common.inc"
.include "rt0.inc"
.include "mem.inc"

.data
filename: .asciz "main.blz"

.text
.global _start

_start:
    RT0_START

    INIT_MEM mem_pool, mem_ptr
    INIT_MEM token_buffer, token_ptr

    bl l_init_keywords
    
    sub sp, sp, #16
    str xzr, [x29, #-8] // total_tokens = 0
    add x0, x29, #16
    str x0, [x29, #-16] // argv_ptr = argv[1]
    ldr x1, [x0]
l_lex_file:
    bl l_do_lex   // x0 = token count
    ldr x1, [x29, #-16] // argv_ptr
    add x1, x1, #8 // argv_ptr+=8
    str x1, [x29, #-16] // argv_ptr
    ldr x2, [x29, #-8] // total_tokens
    add x2, x2, x0 // total_tokens+=token_count
    str x2, [x29, #-8] // total_tokens
    ldr x0, [x1]
    cbz x0, l_end_lex 
    b l_lex_file    // x0 returns token count
l_end_lex:
    bl l_do_parse
l_end_all:
    add sp, sp , #16

l_do_nothing:
    mov x8, #93
    svc 0

