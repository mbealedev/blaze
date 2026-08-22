// =============================================================================
// main.s -- entry point for the lexer driver.
//
// Parses argv, builds the classifier table, and lexes each file named on
// the command line via lex2.s. Split out of the original blah.s.
// =============================================================================
.include "common.inc"
.include "syscalls.inc"

.text
.global _start

// =============================================================================
// _start
// =============================================================================
_start:
    ldr  x19, [sp]              // x19 = argc
    add  x20, sp, #8            // x20 = &argv[0]

    bl   build_table            // build the 256-entry classifier table once
    bl   init_storage           // allocate the dynamic token array

    cmp  x19, #2
    b.ge .Lstart_run
    adr  x1, msg_usage
    mov  x2, #msg_usage_len
    bl   write_stderr
    mov  x0, #1
    b    .Lstart_exit

.Lstart_run:
    mov  x21, #1                 // i = argv index, starts at 1
    mov  x23, #0                 // file_index = 0-based file counter
.Lstart_loop:
    cmp  x21, x19
    b.ge .Lstart_done
    ldr  x0, [x20, x21, lsl #3]  // argv[i]
    mov  x1, x23                 // file_index
    bl   process_file
    add  x21, x21, #1
    add  x23, x23, #1
    b    .Lstart_loop
.Lstart_done:
    mov  x0, #0
.Lstart_exit:
    mov  x8, #SYS_exit
    svc  #0

.section .rodata

msg_usage:     .ascii "usage: blz <file> [file...]\n"
msg_usage_end:
.equ msg_usage_len, msg_usage_end - msg_usage
