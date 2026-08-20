.bss
number_buffer: .skip 20

.section .text
.global l_int_to_str, number_buffer
l_int_to_str:
    ldr x3, =number_buffer
    stp wzr, wzr, [x3]    // Null-terminate the buffer
    str wzr, [x3, #16]     // Null-terminate the buffer
    mov x2, x7            // Copy the integer value to x2 (working register)
    add x4, x3, #20       // End of the buffer
    sub x4, x4, #1        // Reserve space for null terminator
    mov w5, #'0'          // ASCII '0'

    // Handle zero as a special case
    cmp x2, #0
    b.ne l_int_to_str_convert_loop
    mov w6, #'0'          // ASCII '0'
    strb w6, [x3]         // Store '0' in the buffer
    strb wzr, [x3, #1]    // Null terminator
    ret

l_int_to_str_convert_loop:
    // Extract digits in reverse order
    mov x6, x2
    mov x18, #10       // Load the divisor (10) into a register (e.g., x3)
    udiv x2, x2, x18   // Perform integer division: x2 = x2 / 10
    msub x6, x2, x18, x6  // Calculate the remainder: x6 = x6 - (x2 * x3)
    add x6, x6, x5        // Convert remainder to ASCII ('0' + remainder)
    strb w6, [x4], #-1    // Store digit and decrement buffer pointer

    cmp x2, #0            // Check if we are done
    b.ne l_int_to_str_convert_loop

    // Reverse the string
    mov x7, x3            // Start of the buffer
l_int_to_str_reverse_loop:
    cmp x7, x4
    b.ge l_int_to_str_finish           // Exit loop if start >= end
    ldrb w6, [x7]         // Load byte from start
    ldrb w8, [x4]         // Load byte from end
    strb w8, [x7]         // Swap bytes
    strb w6, [x4]         // Swap bytes
    add x7, x7, #1        // Move start forward
    sub x4, x4, #1        // Move end backward
    b l_int_to_str_reverse_loop

l_int_to_str_finish:
    strb wzr, [x4, #1]    // Null terminator
    ret
