.macro INIT_MEM mem_pool, mem_ptr
    // Initialize mem_pool and mem_ptr
    adrp x0, \mem_pool
    add  x0, x0, :lo12:\mem_pool

    adrp x1, \mem_ptr
    add  x1, x1, :lo12:\mem_ptr
    str  x0, [x1]
.endm

.macro ALLOC_MEM size_reg
    adrp    x1, mem_ptr
    add     x1, x1, :lo12:mem_ptr

    ldr     x0, [x1]
    add     x2, x0, \size_reg, uxtw
    str     x2, [x1]
.endm

// w0 token type + subtype, 8 reach.
// w1 line number
// w2 column number
// w3 lexeme size
// x4 lexeme in buffer - will copy to mem_pool and reference
.macro ALLOC_STORE_TOKEN
    adrp    x5, token_ptr
    add     x5, x5, :lo12:token_ptr
    ldr     x6, [x5]        // x6 = token_ptr
    strb    w0, [x6]        // start of token frame
    strb    w1, [x6, #1]
    strb    w2, [x6, #2]
    strb    w3, [x6, #3]
    cbz     w3, 2f      // if lexeme size is 0, skip copying
    adrp    x7, mem_ptr
    ldr     x8, [x7, :lo12:mem_ptr]
    str     x8, [x6, #8]  // Store current mem_ptr in token frame
    mov     x9, x8     // Start of mem_ptr
    mov     w10, #0 
    add     x8, x8, w3, uxtw
    str     x8, [x7, :lo12:mem_ptr]   // Advance mem_ptr by lexeme size
    add     x6, x6, #16
    MEM_CPY x4, x9, w10, w3, w11
2:
    str     x6, [x5]
.endm

.macro MEM_CPY src_reg, dst_reg, index_reg, limit_reg, tmp_reg
    cbz \limit_reg, 2f
    mov \index_reg, #0
1:
    ldrb \tmp_reg, [\src_reg, \index_reg, uxtw]
    strb \tmp_reg, [\dst_reg, \index_reg, uxtw]
    add \index_reg, \index_reg, #1
    cmp \index_reg, \limit_reg
    b.ne 1b
2:
.endm
