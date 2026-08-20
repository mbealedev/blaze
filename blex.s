.equ BUFFER_SIZE, 4096
.equ WS_MODE, 0
.equ STRING_MODE, 1
.equ NUMBER_MODE, 2
.equ WORD_MODE, 3

.equ KEYWORD_BUCKET_COUNT, 54

.include "mem.inc"

.macro IS_ALPHANUM char_reg, result_reg
    mov     \result_reg, #0
.endm

.macro IS_WHITESPACE char_reg, result_reg
    cmp     \char_reg, #' '
    beq     1f
    cmp     \char_reg, #'\n'
    beq     2f
    cmp     \char_reg, #'\t'
    beq     1f
    mov     \result_reg, #0
    b       3f
1:
    mov     \result_reg, #1
    b       3f
2:
    mov     \result_reg, #1
    ldr x28, [x29, #-16] // line number
    add x28, x28, #1
    str x28, [x29, #-16] // line number
3:
.endm

.macro IS_DOUBLE_QUOTE char_reg, result_reg
    cmp  \char_reg, #0x22
    cset \result_reg, eq
.endm

.macro IS_SYMBOL char_reg, result_reg
    mov     \result_reg, #0

    // Range 0x21 - 0x2F (excluding 0x22)
    cmp     \char_reg, #0x21
    b.lo    1f
    cmp     \char_reg, #0x2F
    b.hi    1f
    cmp     \char_reg, #0x22           // check if it's '"'
    b.eq    7f
    b       6f

1:  // Range 0x3A - 0x40
    cmp     \char_reg, #0x3A
    b.lo    2f
    cmp     \char_reg, #0x40
    b.ls    6f

2:  // Range 0x5B - 0x60
    cmp     \char_reg, #0x5B
    b.lo    3f
    cmp     \char_reg, #0x60
    b.ls    6f

3:  // Range 0x7B - 0x7E
    cmp     \char_reg, #0x7B
    b.lo    7f
    cmp     \char_reg, #0x7E
    b.hi    7f

6:  
    mov     \result_reg, #1

7:
.endm

.macro POSSIBLE_NUMBER char_reg, result_reg
    mov \result_reg ,#0
    cmp \char_reg, #'0'
    b.lo 1f
    cmp \char_reg, #'9'
    b.ls 3f

    1:
    cmp \char_reg, #'-'
    b.eq 3f
    cmp \char_reg, #'+'
    b.ne 4f
    3:
    mov \result_reg, #1
    4:
.endm

.macro POSSIBLE_WORD char_reg, result_reg
    mov \result_reg ,#0
    cmp \char_reg, #'A'
    b.lo 1f
    cmp \char_reg, #'Z'
    b.ls 3f

    1:
    cmp \char_reg, #'a'
    b.lo 2f
    cmp \char_reg, #'z'
    b.ls 3f
    2:
    cmp \char_reg, #'_'
    b.eq 3f
    cmp \char_reg, #'@'
    b.ne 4f
    3:
    mov \result_reg, #1
    4:
.endm

.include "tokens.inc"
.include "common.inc"

.data
// <keyword length><type><subtype>keyword<keyword length><type><subtype>...\0
// Pass one. Sum of lengths with data for a, b, etc. e.g eventual b->511break421bool422byte
// would first have b->(3+5)+(3+4)+(3+4) = block of 22 bytes + 1 for null terminator for b etc. 
keywords: .ascii "concurrent\0let\0in\0if\0then\0else\0while\0do\0skip\0\for\0break\0@var\0@property\0@function\0\0"
types: .ascii "Object\0Lamba\0Int\0Bool\0Char\0String\0FloatingPoint\0Json\0\0"
err: .asciz "Error\n"

keyword_list:
    .byte 5, 1, 1
    .ascii "break"
    .byte 4, 1, 1
    .ascii "bool"
    .byte 4, 1, 1
    .ascii "byte"
    .byte 3, 1, 1
    .ascii "int"
    .byte 3, 1, 1
    .ascii "var"
    .byte 3, 1, 1
    .ascii "let"
    .byte 3, 1, 1
    .ascii "for"
    .byte 2, 1, 1
    .ascii "if"
    .byte 2, 1, 1
    .ascii "do"
    .byte 2, 1, 1
    .ascii "in"
    .byte 5, 1, 1
    .ascii "while"
    .byte 4, 1, 1
    .ascii "skip"
    .byte 4, 1, 1
    .ascii "else"
    .byte 4, 1, 1
    .ascii "then"
    .byte 10, 1, 1
    .ascii "concurrent"
    .byte 8, 1, 1
    .ascii "property"
    .byte 8, 1, 1
    .ascii "function"
    .byte 4, 1, 1
    .ascii "json"
    .byte 6, 1, 1
    .ascii "object"
    .byte 6, 1, 1
    .ascii "lambda"
    .byte 6, 1, 1
    .ascii "string"
    .byte 4, 1, 1
    .ascii "char"
    .byte 5, 1, 1
    .ascii "float"
    .byte 6, 1, 1
    .ascii "double"
    .byte 4, 1, 1
    .ascii "json"
    .byte 0
    
.bss
buffer: .skip BUFFER_SIZE
keywords_pass_0: .skip 56   // counts actually need 52 + 2 = 54 but round up.  _@abcdef....ABCDEF....Z
keywords_hash: .skip 864   // 2 * Pointers for each of the 54 keywords. 16 bytes each. (buffer, current ptr)

.text
.global l_do_lex, l_init_keywords
l_init_keywords:
    FUNC_PROLOGUE
    // 1. Iterate keyword_list and put in keywords_pass_0
    adrp x0, keyword_list
    add x0, x0, :lo12:keyword_list
    adrp x4, keywords_pass_0
    add x4, x4, :lo12:keywords_pass_0
l_init_kw_pass0_loop:
    ldrb w1, [x0] // length of keyword
    cbz w1, l_init_kw_pass_1
    ldrb w2, [x0, #3] // First char of keyword
    
    bl L_get_kw_bucket    // w3 will hold the bucket

    add     x5, x4, w3, uxtw
    ldrb    w6, [x5]
    add     w6, w6, w1
    strb    w6, [x5]
    add     w2, w1, #3
    add x0, x0, w2, uxtw
    b l_init_kw_pass0_loop
l_init_kw_pass_1:
    // 2. Iterate buckets, allocate memory blocks
    mov x3, #0    // Bucket count
    adrp x4, keywords_pass_0
    add x4, x4, :lo12:keywords_pass_0
    adrp x5, keywords_hash
    add x5, x5, :lo12:keywords_hash
l_init_kw_pass1_loop:
    ldrb w7, [x4, x3]  // length of keyword bucket required
    cbz w7, l_init_kw_pass_1_cont  // Empty bucket
    ALLOC_MEM w7  // x0 will hold 
    str x0, [x5] // Store memory ptr. // new memory block
    str x0, [x5, #8] // Store current ptr
l_init_kw_pass_1_cont:
    add x5, x5, #16 // Move to next bucket
    add w3,w3, #1
    cmp w3, #KEYWORD_BUCKET_COUNT
    b.lt l_init_kw_pass1_loop
    // 3. Iterate keyword_list and copy to keywords_hash
    adrp x0, keyword_list
    add x0, x0, :lo12:keyword_list
    adrp x1, keywords_hash
    add x1, x1, :lo12:keywords_hash
l_init_kw_pass_2_loop:
    ldrb w4, [x0] // length of keyword
    cbnz w4, l_init_kw_pass_2_end
    add w4, w4, #3 // How much to copy.
    ldrb w2, [x0, #3] // First char of keyword
    bl L_get_kw_bucket    // w3 will hold the bucket
    uxtw x3, w3
    lsl x5, x3, #4
    add x5, x5, x1
    ldr x6, [x5, #8] // Current ptr in memory block
    MEM_CPY x0, x6, w7, w4, w8
    add x6, x6, w4, uxtw
    str x6, [x5, #8] // Store current ptr
    add x0, x0, w4, uxtw
    b l_init_kw_pass_2_loop
l_init_kw_pass_2_end:
    FUNC_EPILOGUE
    ret

// x1 = string filename.
l_do_lex:
    FUNC_PROLOGUE 2
    str xzr, [x29, #-8] // tokens = 0
    mov w0, #1
    str w0, [x29, #-16] // line number

    // Step 1: Open the existing file
    mov x0, #-100                    // AT_FDCWD for current directory               
    mov x2, #0                       // O_RDONLY (read-only access)
    mov x3, #0                       // Mode is ignored for O_RDONLY
    mov w8, #56                      // NR for openat
    svc 0                            // Perform the syscall
    cmp x0, #0                       // Check if file descriptor is valid
    b.lt l_handle_error                 // Branch to error handler if invalid
    mov x4, x0
l_read_buffer:
    // Step 2: Read from the file
    mov x0, x4                      // Restore file descriptor
    adr x1, buffer                  // Pointer to buffer
    add x1, x1, :lo12:buffer 
    mov x2, #BUFFER_SIZE                     // Number of bytes to read
    mov w8, #63                      // NR for read
    svc 0                            // Perform the syscall
    cmp x0, #0                       // Check if read was successful
    b.lt l_handle_error                 // Branch to error handler if failed
    b.eq l_close_file              
l_lex_buffer:
    // Step 3: Lex the buffer
    uxtw x2, w0  // x2 has number of chars.
    mov x4, #0  // Char index
    /**
        x1 = buffer start
        x2 = character count
        x3 = char read
        x4 = char index
        x5 - token start
     */
l_lex_loop:
    cmp x2, x4
    b.ls l_read_buffer
l_inderterminate_mode:
    ldrb w3, [x1, x4]
    IS_WHITESPACE w3, w0
    cbnz w0, l_next_char
    POSSIBLE_WORD w3, w0
    cbnz w0, l_collect_word
    POSSIBLE_NUMBER w3, w0
    cbnz w0, l_collect_number
    IS_DOUBLE_QUOTE w3, w0
    cbnz w0, l_collect_string
    IS_SYMBOL w3, w0
    cbnz w0, l_collect_symbol
    // TODO handle error
    b l_lex_loop
l_next_char:
    add x4, x4, #1
    b l_lex_loop
l_collect_word:
    add x4, x4, #1  // Increment char index
    cmp x2, x4
    b.ls l_collected_word_eob
    ldrb w3, [x1, x4]
    IS_ALPHANUM w3, w0
    cbnz w0, l_collect_word
    ALLOC_STORE_TOKEN
    b l_lex_loop
  
l_collected_word_eob:
l_collect_number:
l_collect_string:
l_collect_symbol:
    // TODO handle collection of tokens
    b l_lex_loop

l_handle_error:
    // Error handling: Write error message to stdout
    mov x0, #1                       // Stdout file descriptor for error message
    ldr x1, =err                     // Pointer to error message
    mov x2, #6                       // Length of the error message
    mov w8, #64                      // NR for write
    svc 0                            // Perform the syscall
    mov x0, #1                       // Exit code 1 (error)
l_close_file:
    // Step 3: Close the file
    mov x0, x4                      // Restore file descriptor
    mov w8, #57                      // NR for close
    svc 0                            // Perform the syscall
    mov x0, #0
 //   b l_end_lex
L_get_kw_bucket:    // w2 is first char, w3 returned is bucket
    FUNC_PROLOGUE
    cmp w2, '@'
    b.ne l_kw_underscore
    mov w3, 0     // First index 0
    b l_kw_bucket_end
l_kw_underscore:
    cmp w2 ,'_'
    b.ne l_kw_check_upper
    mov w3, 1     // First index 1
    b l_kw_bucket_end
l_kw_check_upper:
    cmp w2, #91
    b.lt l_kw_is_upper
    sub w3, w2, #95  // 'a' = 2, 'b' = 3, 'c' = 4, etc.
    b l_kw_bucket_end
l_kw_is_upper:
    sub w3, w2, #37  // 'A' = 28, 'B' = 29, 'C' = 30, etc.
l_kw_bucket_end:
    FUNC_EPILOGUE
    ret

///////////////////////////////////////////////////////////////////////
/** 
l_do_lex:
    // X29-8 = token_count
    // x16 = token_buffer
    // x7 = line number
    // global token_count token_buffer

    FUNC_PROLOGUE 2
    str xzr, [x29, #-8] // tokens = 0
    ldr x15, =token_buffer
    mov x16, x15
    mov w7, 1                        // Line number
    // Step 1: Open the existing file
    mov x0, #-100                    // AT_FDCWD for current directory               
    mov x2, #0                       // O_RDONLY (read-only access)
    mov x3, #0                       // Mode is ignored for O_RDONLY
    mov w8, #56                      // NR for openat
    svc 0                            // Perform the syscall
    cmp x0, #0                       // Check if file descriptor is valid
    b.lt l_handle_error                 // Branch to error handler if invalid
    mov x19, x0                      // Save the file descriptor in x19
l_read_buffer:
    // Step 2: Read from the file
    mov x0, x19                      // Restore file descriptor
    ldr x1, =buffer                  // Pointer to buffer
    mov x2, #BUFFER_SIZE                     // Number of bytes to read
    mov w8, #63                      // NR for read
    svc 0                            // Perform the syscall
    cmp x0, #0                       // Check if read was successful
    b.lt l_handle_error                 // Branch to error handler if failed
    cmp x0, #0                         // Length of the read buffer
    b.eq l_close_file
    mov w4, WS_MODE                     
l_lex_buffer:
    // Step 3: Lex the buffer
    ldr x1, =buffer
    uxtw x2, w0
l_lex_loop:
    subs w2, w2, #1
    b.lt l_read_buffer
    ldrb w3, [x1], #1
    cbnz w4, l_non_ws_mode
    bl l_is_whitespace
    cmp w0, #1
    b.eq l_lex_loop
        // Check for (
    cmp w3, OPEN_PAREN_TOKEN
    b.eq l_single_char_token
    // Check for )
    cmp w3, CLOSE_PAREN_TOKEN
    b.eq l_single_char_token
    // Check for {
    cmp w3, OPEN_BRACE_TOKEN
    b.eq l_single_char_token
    // Check for }
    cmp w3, CLOSE_BRACE_TOKEN
    b.eq l_single_char_token
    // Check for comma
    cmp w3, COMMA_TOKEN
    b.eq l_single_char_token
    // Check for start of string
    cmp w3, #0x22
    b.eq l_string_mode
    // Check for start of number
    bl l_is_digit
    cmp W0, #1
    b.eq l_new_number
    // Check for start of word
    bl l_is_word_char
    cmp W0, #1
    b.eq l_new_word
    // TODO handle error
    b l_lex_loop
l_is_whitespace:
    cmp w3, #0x20
    b.eq l_yes_is_ws
    cmp w3, #0x09
    b.eq l_yes_is_ws
    cmp w3, #0x0A
    b.eq l_is_newline
    cmp w3, #0x0D
    b.eq l_is_newline
    mov w0, #0
    ret
l_is_newline:
    add w7, w7, #1
l_yes_is_ws:
    mov w0, #1
    ret
l_new_word:
    mov w4, WORD_MODE
    sub x1, x1, #1
    mov x9, x1
    b l_lex_loop
l_non_ws_mode:
    cmp w4, STRING_MODE
    b.eq l_in_string_mode
    cmp w4, NUMBER_MODE
    b.eq l_in_number_mode
    cmp w4, WORD_MODE
    b.eq l_in_word_mode
    // TODO handle error mode
    b l_lex_loop
l_string_mode:
    mov w4, STRING_MODE
    mov x9,x1 
    b l_lex_loop
l_new_number:
    mov w4, NUMBER_MODE
    mov x9,x1
    sub x1, x1, #1
    b l_lex_loop
l_single_char_token:
    mov w4, WS_MODE  // Back to ws mode
    strb w7, [x15], #1 // line number
    strb w3, [x15], #1
    DELTA_LOCAL -8, x1, #1 // Inc Token count
    b l_lex_loop
l_in_number_mode:
    bl l_is_digit
    cmp w0, #0
    b.eq l_end_of_sequence
    mov w14, NUMBER_TOKEN
    b l_lex_loop
l_end_of_sequence:
// Need to check for keywords and types BEFORE copying the characters...
    sub x11, x1, x9
    sub x11, x11, #1
    ldr x0, =keywords
    bl l_reserved_compare
    cmp w20, #-1
    b.eq l_step_compare_types
    // Handle keyword
    mov w14, KEYWORD_TOKEN
    strb w7, [x15], #1   // line number
    str w14, [x15], #1   // keyword
    str w0, [x15], #1    // which
    DELTA_LOCAL -8, x1, #1
    mov w4, WS_MODE
    sub x1, x1, #1
    b l_lex_loop
l_step_compare_types:
    ldr x0, =types
    bl l_reserved_compare
    cmp w20, #-1
    b.eq l_identifier
    // Handle type
    mov w14, TYPE_TOKEN
    strb w7, [x15], #1   // line number
    str w14, [x15], #1   // type
    str w0, [x15], #1    // which
    DELTA_LOCAL -8, x1, #1
    mov w4, WS_MODE
    sub x1, x1, #1
    b l_lex_loop
l_identifier:
    mov w14, IDENTIFIER_TOKEN
    strb w7, [x15], #1   // line number
    str w14, [x15], #1   // type
    strh w11, [x15], #2  // length
    DELTA_LOCAL -8, x1, #1
l_copy_loop:
    ldrb w13, [x9], #1
    strb w13, [x15], #1
    cmp x9, x1
    b.ne l_copy_loop
    mov w4, WS_MODE
    sub x1, x1, #1
    b l_lex_loop
l_in_string_mode:
    mov w14, STRING_TOKEN
    // Check if ending quote
    cmp w3, #0x22
    b.eq l_end_of_sequence
    b l_lex_loop
l_in_word_mode:
    // Check if not word token.
    bl l_is_word_char
    cmp w0, #0
    b.eq l_end_of_sequence
    b l_lex_loop
l_close_file:
    // Step 3: Close the file
    mov x0, x19                      // Restore file descriptor
    mov w8, #57                      // NR for close
    svc 0                            // Perform the syscall
    mov x0, #0
    b l_end_lex
l_is_digit:
    // Compare the character with '0' (ASCII 48)
    mov w0, #'0'                // Load ASCII value of '0'
    cmp w3, w0                  // Compare W0 with '0'
    b.lt l_not_digit               // If W0 < '0', it’s not a digit

    // Compare the character with '9' (ASCII 57)
    mov w0, #'9'                // Load ASCII value of '9'
    cmp w3,  w0                  // Compare W0 with '9'
    b.gt l_not_digit               // If W0 > '9', it’s not a digit

    // The character is a digit
    mov w0, #1                  // Return 1 (true)
    ret                   // Return from subroutine

l_not_digit:
    mov w0, #0                  // Return 0 (false)
    ret                         // Return from subroutine

l_is_word_char:
    // Check if the character is between 'a' and 'z' (ASCII 97-122)
    cmp     w3, #'a'            // Compare with 'a' (ASCII 97)
    blt     l_not_valid_word_char           // If character < 'a', it's invalid
    cmp     x0, #'z'            // Compare with 'z' (ASCII 122)
    b.gt     l_not_valid_word_char           // If character > 'z', it's invalid

    // If the character is between 'a' and 'z', return valid
    mov     x0, #1              // Set x0 = 1 (valid)
    ret

l_not_valid_word_char:
    // Check if the character is between 'A' and 'Z' (ASCII 65-90)
    cmp    w3, #'A'            // Compare with 'A' (ASCII 65)
    b.lt     l_check_underscore // If character < 'A', it's invalid
    cmp     w3, #'Z'            // Compare with 'Z' (ASCII 90)
    b.gt     l_check_underscore // If character > 'Z', it's invalid

    // If the character is between 'A' and 'Z', return valid
    mov     x0, #1              // Set x0 = 1 (valid)
    ret

l_check_underscore:
    // Check if the character is an underscore ('_')
    cmp     w3, #'_'            // Compare with '_'
    b.ne     l_not_a_word_char        // If not equal to '_', it's invalid

    // If it is an underscore, return valid
    mov     x0, #1              // Set x0 = 1 (valid)
    ret

l_not_a_word_char:
    // If none of the conditions matched, return invalid (0)
    mov     x0, #0              // Set x0 = 0 (invalid)
    ret

l_handle_error:
    // Error handling: Write error message to stdout
    mov x0, #1                       // Stdout file descriptor for error message
    ldr x1, =err                     // Pointer to error message
    mov x2, #6                       // Length of the error message
    mov w8, #64                      // NR for write
    svc 0                            // Perform the syscall
    mov x0, #1                       // Exit code 1 (error)

l_end_lex:
    ldr x0, [x29, #-8] // Load the total token count
    FUNC_EPILOGUE 2
    ret

l_reserved_compare:
    // X0 Pointer to the reference words
    // X9 Pointer to the input word
    // W11 Length of the input string
    // Return: W20 = index of the matching word, -1 if no match
        
    // Initialize a counter for reserved index (start from 0)
        mov     w20, 0              // reserved index = 0
        mov     X21, X0             // X21 points to the first reserved
        mov     w23, 0              // Reset the character index
l_reserved_next_keyword:
        // Load the current reserved
        mov     X22, X9             // X22 points to the input string

l_reserved_compare_characters:
    // Check if input string length is exceeded
    cmp     W23, W11                // Compare character index with input string length
    b.eq   l_reserved_equal
    b.gt    l_reserved_not_match    // If input string is exhausted, no match

    ldrb    W25, [X21]         // Load character from reserved
    cmp     W25, #0                 // Check for null terminator in reserved
    b.eq     l_reserved_length_check // If null byte, proceed to length check
    ldrb    W26, [X22]         // Load character from input
    cmp     W25, W26                // Compare characters
    b.ne    l_reserved_not_match    // If mismatch, go to next reserved

    add     x21, x21, #1
    add     x22, x22, #1
    add     w23, w23, #1
    b       l_reserved_compare_characters

l_reserved_equal:
    ret
l_reserved_length_check:
        // Check if we have checked all characters in the input string
        cmp     w23, W11
        b.ne    l_reserved_not_match          // If lengths don't match, continue checking next reserved
        ret

l_reserved_not_match:
        // Move to the next reserved in the list
        add     X21, X21, #1       // Move to the next reserved
        ldrb    W5, [X21]         // Load the next reserved character
        cmp     W5, #0  // Check if we've reached the end of the list
        b.eq     l_reserved_no_match           // If no more reserved, return -1
        add     w20, w20, #1         // Increment the reserved index
        b       l_reserved_next_keyword

l_reserved_no_match:
        // If no match is found, return -1
        mov     w20, #-1            // Return -1
        ret
        */


