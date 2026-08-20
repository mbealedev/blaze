.include "common.inc"

.data
colon: .asciz ":"
nl: .asciz "\r\n"
.text
.global l_print_error

l_print_error:
    FUNC_PROLOGUE
    bl l_int_to_str
    ldr x8, =number_buffer
    bl l_print_til_z
    ldr x8, =colon
    bl l_print_til_z
    mov x8, x5
    bl l_print_til_z
    ldr x8, =nl
    bl l_print_til_z
    FUNC_EPILOGUE
    ret
l_print_til_z:
    FUNC_PROLOGUE
    // ptr = x8
    mov x12, x4
l_find_length:
    ldrb w11, [x12], #1      // Load one byte, increment pointer
    cbz w11, l_done_length    // If byte is zero, length calculation is done
    b l_find_length
l_done_length:
    sub sp, sp, #16      // Decrement stack pointer for 16 bytes
    stp x0, x1, [sp]     // Store x0 and x1 onto the stack
    sub sp, sp, #16      // Decrement stack pointer for 16 bytes
    stp x2, x8, [sp]     // Store x0 and x1 onto the stack

    sub x2, x12, x8     // Calculate length , x12
    mov x0, #1
    mov x1, x8
    mov x8, #64
    svc 0
    ldp x2, x8, [sp]     // Restore x2 and x8
    add sp, sp, #16      // Increment stack pointer for 16 bytes
    ldp x0, x1, [sp]     // Restore x0 and x1
    add sp, sp, #16      // Increment stack pointer for 16 bytes
    FUNC_EPILOGUE
    ret
