 .macro FUNC_PROLOGUE, locals=0
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    .if \locals > 0
        sub sp, sp, \locals
    .endif
.endm

    .macro FUNC_EPILOGUE, locals=0
        .if \locals > 0
            add sp, sp, \locals
        .endif
        ldp x29, x30, [sp], #16
        ret
    .endm

.macro DELTA_LOCAL offset, tmp, amount
    ldr \tmp, [x29, #\offset]
    add \tmp, \tmp, \amount
    str \tmp, [x29, #\offset]
.endm
