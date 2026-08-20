.include "common.inc"

.bss
    ast_buffer: .skip 16384

.data
err_expected_type: .ascii "Expected Type"
err_expected_object: .ascii "Expected Object"
err_expected_object_name: .asciz "Expected Object Name but got nothing."
err_expected_object_name_but_got: .asciz "Expected Object Name but got "
err_expected_block_start: .asciz "Expected Block Start '{' "

.text
.global l_do_parse

.include "tokens.inc"

.equ OBJECT_TYPE, 0x0
.equ LAMBDA_TYPE, 0x1
.equ INT_TYPE, 0x2
.equ BOOL_TYPE, 0x3
.equ CHAR_TYPE, 0x4
.equ STRING_TYPE, 0x5
.equ FLOATING_POINT_TYPE, 0x6
.equ JSON_TYPE, 0x7

l_do_parse:
    FUNC_PROLOGUE

    // X1 = filename
    mov x5, x1   // Filename
    ldr x0, =token_buffer
    ldr x1, =token_count
    ldr w13, [x1] // Token count
    mov w3, #0 // Tokens parsed
l_parse_object:
    ldrb w7, [x0], #1   // Line number
    ldrb w1, [x0], #1
    cmp w1, TYPE_TOKEN
    b.eq l_parse_object_check_type
    ldr x4, =err_expected_type
    bl l_parse_error    // Expected Type
l_parse_object_check_type:
    ldr w1, [x0], #1
    cmp w1, OBJECT_TYPE
    b.eq l_parse_object_step_1
    ldr x4, =err_expected_object
    bl l_parse_error    // Expected Object
l_parse_object_step_1:
    add x3, x3, #1
    cmp x3, x2
    b.lt l_parse_object_step_2
    ldr x4, =err_expected_object_name
    bl l_parse_error    // Expected Object Name but got nothing.
l_parse_object_step_2:
    ldrb w1, [x0], #1
    cmp w1, IDENTIFIER_TOKEN
    b.eq l_parse_object_step_3
    ldr x4, =err_expected_object_name_but_got
    bl l_parse_error    // Expected Object Name but got 
l_parse_object_step_3:
    // Store param AST
    bl l_parse_block
    // Store block AST
    FUNC_EPILOGUE
    ret
l_parse_error:
    // w1 = token
    // w7 = line number
    // x4 = error message
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl l_print_error
    ldp x29, x30, [sp], #16
    ret
l_parse_params:
    ret
l_parse_var:
    ret
l_parse_property:
    ret
l_parse_function:
    ret
l_parse_block:
    ldrb w1, [x0], #1
    cmp w1, OPEN_BRACE_TOKEN
    b.eq l_parse_block_step_1
    ldr x4, =err_expected_block_start
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl l_parse_error
    ldp x29, x30, [sp], #16
    ret
l_parse_block_step_1:
   stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl l_parse_statements
    // Check return.
    ldp x29, x30, [sp], #16
    ret
l_parse_statements:
    ret

