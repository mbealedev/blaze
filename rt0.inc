.macro RT0_START
    mov x29, sp           // XP points at argc
    ldr x0, [x29]
    cbnz x0, l_rt0_cont
    mov x8, #93
    svc 0
l_rt0_cont:
.endm


