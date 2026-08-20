.include "common.inc"

.bss
.align 3
_argv_ptr: .skip 8
.global _argv_ptr

.text
.global l_rt0
l_rt0:
    FUNC_PROLOGUE
    ldr x0, [sp]
    ldr x1, =_argv_ptr
    str x0, [x1]
    FUNC_EPILOGUE
    ret
