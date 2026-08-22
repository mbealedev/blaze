// =============================================================================
// lex2.s -- ARM64 (AArch64) Linux lexer for a C-like invented language
//
// v2 changes from the previous draft:
//   - fixed two addressing-mode bugs (32-bit offset without extend, and
//     extend applied to a 64-bit register) that `as` correctly rejected
//   - identifiers are now checked against keyword and type tables and
//     tagged TOK_KEYWORD / TOK_TYPE (with a numeric subtype = which
//     keyword/type matched) instead of always being TOK_IDENT
//   - '@' is now a valid identifier-start character (for @var/@property/...)
//   - tokens are stored into a growable, mmap-backed array instead of only
//     being printed, so a later parsing stage can walk them
//
// Reads one or more source files given as command-line arguments, mmaps
// each one (no read() copies), scans it with a table-driven classifier,
// stores every token into a dynamic array, and also prints each one as it
// is found:
//
//     line:col TYPE lexeme
//
// Token types:
//   IDENT     [A-Za-z_@][A-Za-z0-9_@]*  not matching a keyword/type
//   KEYWORD   identifier matching keywords_table  (subtype = index)
//   TYPE      identifier matching types_table     (subtype = index)
//   INT       [0-9]+
//   FLOAT     [0-9]+ '.' [0-9]+
//   STRING    "..."  (backslash-escaped, no embedded raw newline)
//   OP        one or two char operator: + - * / % = < > ! & | ^ ~
//             plus += -= *= /= %= == != <= >= && ||
//   PUNCT     ( ) { } [ ] ; , . :
//   UNKNOWN   anything else (single byte, reported so you notice it)
//
// // line comments and /* block */ comments are skipped (not emitted).
//
// TOKEN STORAGE
//   Each stored token is a fixed 32-byte record:
//     +0  i32 type       (TOK_*)
//     +4  i32 subtype    (keyword/type table index, or -1)
//     +8  i32 file_index (0-based, in argv order)
//     +12 i32 line
//     +16 i32 col
//     +20 i32 length
//     +24 i64 ptr         (pointer into that file's mmap'd source buffer)
//   The array lives at [token_base], holds [token_count] records, grows via
//   mremap() when [token_count] reaches [token_capacity]. Source file
//   buffers are intentionally NOT munmap'd after lexing (see process_file)
//   so that `ptr` fields in already-stored tokens remain valid for a later
//   parser. Call munmap yourself, once parsing is fully done, using the
//   file_table entries if you want the memory back before the process exits.
//
// entry point / argv handling lives in main.s; this file provides
// build_table, init_storage and process_file (all .global, called from
// main.s), plus everything else the lexer needs internally.
// =============================================================================
.include "common.inc"
.include "syscalls.inc"

.equ INITIAL_TOKEN_CAP, 65536      // records; 65536*32 = 2 MiB initial arena
.equ MAX_FILES,         64

// ---------------------------------------------------------------------------
// character-class bit flags (one byte per possible input byte in char_table)
// ---------------------------------------------------------------------------
.equ F_ALPHA, 1     // bit0: a-z A-Z _ @
.equ F_DIGIT, 2     // bit1: 0-9
.equ F_SPACE, 4     // bit2: space, tab, CR
.equ F_NL,    8     // bit3: '\n'
.equ F_QUOTE, 16    // bit4: '"'
.equ F_OPCH,  32    // bit5: operator character
.equ F_PUNCT, 64    // bit6: punctuation character

// ---------------------------------------------------------------------------
// token type IDs (index into type_names table)
// ---------------------------------------------------------------------------
.equ TOK_EOF,     0
.equ TOK_IDENT,   1
.equ TOK_INT,     2
.equ TOK_FLOAT,   3
.equ TOK_STRING,  4
.equ TOK_OP,      5
.equ TOK_PUNCT,   6
.equ TOK_UNKNOWN, 7
.equ TOK_KEYWORD, 8
.equ TOK_TYPE,    9

.text
.global build_table, init_storage, process_file, write_stderr

// =============================================================================
// build_table: fill char_table[0..255] with F_* classification flags.
// =============================================================================
build_table:
    FUNC_PROLOGUE

    adr  x9, char_table
    mov  w8, #0                  // c = 0
.Lbt_loop:
    mov  w1, #0                  // flags accumulator for this byte

    // --- alpha: a-z / A-Z / _ / @ ---
    cmp  w8, #'a'
    b.lt .Lbt_notlower
    cmp  w8, #'z'
    b.gt .Lbt_notlower
    orr  w1, w1, #F_ALPHA
.Lbt_notlower:
    cmp  w8, #'A'
    b.lt .Lbt_notupper
    cmp  w8, #'Z'
    b.gt .Lbt_notupper
    orr  w1, w1, #F_ALPHA
.Lbt_notupper:
    cmp  w8, #'_'
    b.ne .Lbt_notunderscore
    orr  w1, w1, #F_ALPHA
.Lbt_notunderscore:
    cmp  w8, #'@'
    b.ne .Lbt_notat
    orr  w1, w1, #F_ALPHA
.Lbt_notat:

    // --- digit: 0-9 ---
    cmp  w8, #'0'
    b.lt .Lbt_notdigit
    cmp  w8, #'9'
    b.gt .Lbt_notdigit
    orr  w1, w1, #F_DIGIT
.Lbt_notdigit:

    // --- space: ' ' (32) tab (9) CR (13) ---
    cmp  w8, #32
    b.eq .Lbt_isspace
    cmp  w8, #9
    b.eq .Lbt_isspace
    cmp  w8, #13
    b.ne .Lbt_notspace
.Lbt_isspace:
    orr  w1, w1, #F_SPACE
.Lbt_notspace:

    // --- newline ---
    cmp  w8, #10
    b.ne .Lbt_notnl
    orr  w1, w1, #F_NL
.Lbt_notnl:

    // --- quote ---
    cmp  w8, #'"'
    b.ne .Lbt_notquote
    orr  w1, w1, #F_QUOTE
.Lbt_notquote:

    // --- operator character set ---
    adr  x2, opchars
    mov  w3, #opchars_len
    bl   .Lcontains
    cbz  w0, .Lbt_notop
    orr  w1, w1, #F_OPCH
.Lbt_notop:

    // --- punctuation character set ---
    adr  x2, punctchars
    mov  w3, #punctchars_len
    bl   .Lcontains
    cbz  w0, .Lbt_notpunct
    orr  w1, w1, #F_PUNCT
.Lbt_notpunct:

    strb w1, [x9, w8, uxtw]
    add  w8, w8, #1
    cmp  w8, #256
    b.lt .Lbt_loop

    FUNC_EPILOGUE
    ret

// helper: is char (w8) present in set at x2, length w3? -> w0 = 1/0
.Lcontains:
    mov  w5, #0
.Lcont_loop:
    cmp  w5, w3
    b.ge .Lcont_no
    ldrb w4, [x2, w5, uxtw]
    cmp  w4, w8
    b.eq .Lcont_yes
    add  w5, w5, #1
    b    .Lcont_loop
.Lcont_no:
    mov  w0, #0
    ret
.Lcont_yes:
    mov  w0, #1
    ret

// =============================================================================
// lookup_word(x0 = word ptr, x1 = word len, x2 = NUL-separated table,
//             double-NUL terminated) -> x0 = index of match, or -1
// Leaf function: does not touch x19-x28, no stack frame needed.
// =============================================================================
lookup_word:
    mov  x3, x2                  // cursor into the table
    mov  x4, #0                  // entry index
.Llw_loop:
    ldrb w5, [x3]
    cbz  w5, .Llw_notfound       // empty entry -> end of table

    mov  x6, x3
.Llw_strlen:
    ldrb w7, [x6]
    cbz  w7, .Llw_strlen_done
    add  x6, x6, #1
    b    .Llw_strlen
.Llw_strlen_done:
    sub  x6, x6, x3              // x6 = length of this entry
    cmp  x6, x1
    b.ne .Llw_next

    mov  x8, #0
.Llw_cmp:
    cmp  x8, x6
    b.ge .Llw_match
    ldrb w9, [x0, x8]
    ldrb w10, [x3, x8]
    cmp  w9, w10
    b.ne .Llw_next
    add  x8, x8, #1
    b    .Llw_cmp
.Llw_match:
    mov  x0, x4
    ret
.Llw_next:
    add  x3, x3, x6
    add  x3, x3, #1              // skip this entry's NUL
    add  x4, x4, #1
    b    .Llw_loop
.Llw_notfound:
    mov  x0, #-1
    ret

// =============================================================================
// init_storage: allocate the initial token array via anonymous mmap.
// =============================================================================
init_storage:
    FUNC_PROLOGUE
    mov  x0, #0
    mov  x1, #(INITIAL_TOKEN_CAP * 32)
    mov  x2, #(PROT_READ | PROT_WRITE)
    mov  x3, #(MAP_PRIVATE | MAP_ANONYMOUS)
    mov  x4, #-1
    mov  x5, #0
    mov  x8, #SYS_mmap
    svc  #0
    cmp  x0, #0
    b.lt .Linit_fail

    adr  x1, token_base
    str  x0, [x1]
    adr  x1, token_capacity
    mov  x2, #INITIAL_TOKEN_CAP
    str  x2, [x1]
    adr  x1, token_count
    str  xzr, [x1]
    adr  x1, file_count
    str  xzr, [x1]

    FUNC_EPILOGUE
    ret
.Linit_fail:
    adr  x1, err_mmap
    mov  x2, #err_mmap_len
    bl   write_stderr
    mov  x0, #1
    mov  x8, #SYS_exit
    svc  #0

// =============================================================================
// grow_tokens: double the token array capacity via mremap (MAYMOVE).
// =============================================================================
grow_tokens:
    FUNC_PROLOGUE

    adr  x4, token_base
    ldr  x0, [x4]                 // old_address
    adr  x5, token_capacity
    ldr  x6, [x5]                 // old_capacity (records)
    lsl  x1, x6, #5                // old_size = old_capacity * 32
    lsl  x2, x6, #6                // new_size = old_capacity * 64 (2x)
    mov  x3, #MREMAP_MAYMOVE
    mov  x8, #SYS_mremap
    svc  #0
    cmp  x0, #0
    b.lt .Lgrow_fail

    str  x0, [x4]
    lsl  x6, x6, #1
    str  x6, [x5]

    FUNC_EPILOGUE
    ret
.Lgrow_fail:
    adr  x1, err_grow
    mov  x2, #err_grow_len
    bl   write_stderr
    mov  x0, #1
    mov  x8, #SYS_exit
    svc  #0

// =============================================================================
// store_token(w0=type, x1=ptr, x2=len, w3=line, w4=col, x9=subtype[-1=none])
// Appends a 32-byte record to the dynamic token array (growing it if full),
// tagged with the current file index, then also prints the token.
// =============================================================================
store_token:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    str  w0, [sp, #16]            // type
    str  x1, [sp, #24]            // ptr
    str  x2, [sp, #32]            // len
    str  w3, [sp, #40]            // line
    str  w4, [sp, #44]            // col
    str  x9, [sp, #48]            // subtype

    adr  x10, token_count
    ldr  x11, [x10]
    adr  x12, token_capacity
    ldr  x13, [x12]
    cmp  x11, x13
    b.lt .Lst_have_room
    bl   grow_tokens
    adr  x10, token_count
    ldr  x11, [x10]
.Lst_have_room:
    adr  x14, token_base
    ldr  x15, [x14]
    lsl  x16, x11, #5              // byte offset = count * 32
    add  x16, x15, x16              // record address

    ldr  w0, [sp, #16]
    str  w0, [x16, #0]              // type
    ldr  x9, [sp, #48]
    str  w9, [x16, #4]              // subtype
    adr  x17, cur_file_index
    ldr  x0, [x17]
    str  w0, [x16, #8]              // file_index
    ldr  w0, [sp, #40]
    str  w0, [x16, #12]             // line
    ldr  w0, [sp, #44]
    str  w0, [x16, #16]             // col
    ldr  x2, [sp, #32]
    str  w2, [x16, #20]             // length
    ldr  x1, [sp, #24]
    str  x1, [x16, #24]             // ptr

    add  x11, x11, #1
    adr  x10, token_count
    str  x11, [x10]

    // also print a human-readable line
    ldr  w0, [sp, #16]
    ldr  x1, [sp, #24]
    ldr  x2, [sp, #32]
    ldr  w3, [sp, #40]
    ldr  w4, [sp, #44]
    bl   print_token

    ldp x29, x30, [sp], #64
    ret

// =============================================================================
// process_file(x0 = filename ptr, x1 = file_index)
// =============================================================================
process_file:
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]     // x19=filename, x20=fd
    stp  x21, x22, [sp, #32]     // x21=namelen, x22=size / mmap ptr
    mov  x29, sp
    mov  x19, x0

    // record this file's index and name for later stages
    mov  x2, x1
    adr  x3, cur_file_index
    str  x2, [x3]
    adr  x3, file_table
    str  x19, [x3, x2, lsl #3]
    add  x4, x2, #1
    adr  x3, file_count
    str  x4, [x3]

    adr  x1, hdr_prefix
    mov  x2, #hdr_prefix_len
    bl   write_stdout
    mov  x0, x19
    bl   strlen
    mov  x21, x0
    mov  x1, x19
    mov  x2, x21
    bl   write_stdout
    adr  x1, hdr_suffix
    mov  x2, #hdr_suffix_len
    bl   write_stdout

    // openat(AT_FDCWD, filename, O_RDONLY, 0)
    mov  x1, x19
    mov  x0, #AT_FDCWD
    mov  x2, #O_RDONLY
    mov  x3, #0
    mov  x8, #SYS_openat
    svc  #0
    cmp  x0, #0
    b.lt .Lpf_openfail
    mov  x20, x0

    // size = lseek(fd, 0, SEEK_END); lseek(fd, 0, SEEK_SET)
    mov  x0, x20
    mov  x1, #0
    mov  x2, #SEEK_END
    mov  x8, #SYS_lseek
    svc  #0
    cmp  x0, #0
    b.lt .Lpf_sizefail
    mov  x22, x0
    mov  x0, x20
    mov  x1, #0
    mov  x2, #SEEK_SET
    mov  x8, #SYS_lseek
    svc  #0

    cbnz x22, .Lpf_domap
    mov  w0, #TOK_EOF
    mov  x1, x19
    mov  x2, #0
    mov  w3, #1
    mov  w4, #1
    mov  x9, #-1
    bl   store_token
    b    .Lpf_close

.Lpf_domap:
    mov  x0, #0
    mov  x1, x22
    mov  x2, #PROT_READ
    mov  x3, #MAP_PRIVATE
    mov  x4, x20
    mov  x5, #0
    mov  x8, #SYS_mmap
    svc  #0
    cmp  x0, #0
    b.lt .Lpf_mmapfail

    mov  x21, x0                  // x21 = mapped buffer pointer
    mov  x0, x21
    mov  x1, x22
    bl   lex_buffer

    // NOTE: deliberately NOT munmap'd here -- stored tokens hold pointers
    // into this buffer, and those must stay valid for a later parser.
    // Free it yourself (via the file_table) once parsing is complete.

.Lpf_close:
    mov  x0, x20
    mov  x8, #SYS_close
    svc  #0
    b    .Lpf_ret

.Lpf_openfail:
    adr  x1, err_open
    mov  x2, #err_open_len
    bl   write_stderr
    b    .Lpf_ret

.Lpf_sizefail:
    mov  x0, x20
    mov  x8, #SYS_close
    svc  #0
    adr  x1, err_size
    mov  x2, #err_size_len
    bl   write_stderr
    b    .Lpf_ret

.Lpf_mmapfail:
    mov  x0, x20
    mov  x8, #SYS_close
    svc  #0
    adr  x1, err_mmap
    mov  x2, #err_mmap_len
    bl   write_stderr

.Lpf_ret:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// =============================================================================
// lex_buffer(x0 = buffer ptr, x1 = length)
//   x19 = cursor    x20 = end       x21 = line     x22 = line-start ptr
//   x24 = char_table base
//   x23, x25, x26 are used as extra scratch within this function; nothing
//   outside lex_buffer relies on their value across this call.
// =============================================================================
lex_buffer:
    stp  x29, x30, [sp, #-64]!
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x29, sp

    mov  x19, x0
    add  x20, x0, x1
    mov  x21, #1
    mov  x22, x19
    adr  x24, char_table

.Llex_top:
    cmp  x19, x20
    b.ge .Llex_finish
    ldrb w0, [x19]
    ldrb w1, [x24, w0, uxtw]

    tbnz w1, #3, .Lnewline
    tbnz w1, #2, .Lspace
    cmp  w0, #'/'
    b.eq .Lmaybe_comment
    tbnz w1, #0, .Lident
    tbnz w1, #1, .Lnumber
    tbnz w1, #4, .Lstring
    tbnz w1, #5, .Loperator
    tbnz w1, #6, .Lpunct
    b    .Lunknown

.Lnewline:
    add  x19, x19, #1
    add  x21, x21, #1
    mov  x22, x19
    b    .Llex_top

.Lspace:
    add  x19, x19, #1
    b    .Llex_top

.Lmaybe_comment:
    add  x2, x19, #1
    cmp  x2, x20
    b.ge .Loperator
    ldrb w3, [x2]
    cmp  w3, #'/'
    b.eq .Lline_comment
    cmp  w3, #'*'
    b.eq .Lblock_comment
    b    .Loperator

.Lline_comment:
    add  x19, x19, #2
.Lline_comment_loop:
    cmp  x19, x20
    b.ge .Llex_top
    ldrb w0, [x19]
    cmp  w0, #10
    b.eq .Llex_top
    add  x19, x19, #1
    b    .Lline_comment_loop

.Lblock_comment:
    add  x19, x19, #2
.Lblock_loop:
    cmp  x19, x20
    b.ge .Llex_top
    ldrb w0, [x19]
    cmp  w0, #10
    b.ne .Lblock_checkstar
    add  x21, x21, #1
    add  x19, x19, #1
    mov  x22, x19
    b    .Lblock_loop
.Lblock_checkstar:
    cmp  w0, #'*'
    b.ne .Lblock_adv1
    add  x2, x19, #1
    cmp  x2, x20
    b.ge .Lblock_adv1
    ldrb w3, [x2]
    cmp  w3, #'/'
    b.ne .Lblock_adv1
    add  x19, x19, #2
    b    .Llex_top
.Lblock_adv1:
    add  x19, x19, #1
    b    .Lblock_loop

// --- identifier / keyword / type ---
.Lident:
    mov  x1, x19
    sub  x5, x1, x22
    add  w4, w5, #1                // col
    mov  w3, w21                  // line
.Lident_loop:
    add  x19, x19, #1
    cmp  x19, x20
    b.ge .Lident_end
    ldrb w0, [x19]
    ldrb w2, [x24, w0, uxtw]
    and  w6, w2, #(F_ALPHA | F_DIGIT)
    cbnz w6, .Lident_loop
.Lident_end:
    sub  x26, x19, x1              // x26 = length (persists across bl below)
    mov  x25, x1                   // x25 = start ptr (persists across bl below)

    mov  x0, x25
    mov  x1, x26
    adr  x2, keywords_table
    bl   lookup_word
    cmp  x0, #-1
    b.eq .Lident_checktype
    mov  x9, x0
    mov  w0, #TOK_KEYWORD
    mov  x1, x25
    mov  x2, x26
    bl   store_token
    b    .Llex_top

.Lident_checktype:
    mov  x0, x25
    mov  x1, x26
    adr  x2, types_table
    bl   lookup_word
    cmp  x0, #-1
    b.eq .Lident_plain
    mov  x9, x0
    mov  w0, #TOK_TYPE
    mov  x1, x25
    mov  x2, x26
    bl   store_token
    b    .Llex_top

.Lident_plain:
    mov  x9, #-1
    mov  w0, #TOK_IDENT
    mov  x1, x25
    mov  x2, x26
    bl   store_token
    b    .Llex_top

// --- number: INT or FLOAT ---
.Lnumber:
    mov  x1, x19
    sub  x5, x1, x22
    add  w4, w5, #1
    mov  w3, w21
    mov  w6, #TOK_INT
.Lnum_intloop:
    add  x19, x19, #1
    cmp  x19, x20
    b.ge .Lnum_checkfrac
    ldrb w0, [x19]
    ldrb w2, [x24, w0, uxtw]
    tbnz w2, #1, .Lnum_intloop
.Lnum_checkfrac:
    cmp  x19, x20
    b.ge .Lnum_done
    ldrb w0, [x19]
    cmp  w0, #'.'
    b.ne .Lnum_done
    add  x7, x19, #1
    cmp  x7, x20
    b.ge .Lnum_done
    ldrb w0, [x7]
    ldrb w2, [x24, w0, uxtw]
    tbz  w2, #1, .Lnum_done
    mov  w6, #TOK_FLOAT
    add  x19, x19, #1
.Lnum_fracloop:
    cmp  x19, x20
    b.ge .Lnum_done
    ldrb w0, [x19]
    ldrb w2, [x24, w0, uxtw]
    tbz  w2, #1, .Lnum_done
    add  x19, x19, #1
    b    .Lnum_fracloop
.Lnum_done:
    sub  x2, x19, x1
    mov  w0, w6
    mov  x9, #-1
    bl   store_token
    b    .Llex_top

// --- string literal ---
.Lstring:
    mov  x1, x19
    sub  x5, x1, x22
    add  w4, w5, #1
    mov  w3, w21
    add  x19, x19, #1
.Lstr_loop:
    cmp  x19, x20
    b.ge .Lstr_unterminated
    ldrb w0, [x19]
    cmp  w0, #10
    b.eq .Lstr_unterminated
    cmp  w0, #'"'
    b.eq .Lstr_close
    cmp  w0, #'\\'
    b.ne .Lstr_adv1
    add  x19, x19, #1
    cmp  x19, x20
    b.ge .Lstr_unterminated
    add  x19, x19, #1
    b    .Lstr_loop
.Lstr_adv1:
    add  x19, x19, #1
    b    .Lstr_loop
.Lstr_close:
    add  x19, x19, #1
    sub  x2, x19, x1
    mov  w0, #TOK_STRING
    mov  x9, #-1
    bl   store_token
    b    .Llex_top
.Lstr_unterminated:
    sub  x2, x19, x1
    mov  w0, #TOK_UNKNOWN
    mov  x9, #-1
    bl   store_token
    b    .Llex_top

// --- operator: greedy 1-2 char match ---
.Loperator:
    mov  x1, x19
    sub  x5, x1, x22
    add  w4, w5, #1
    mov  w3, w21
    ldrb w0, [x19]
    add  x2, x19, #1
    cmp  x2, x20
    b.ge .Lop_single
    ldrb w6, [x2]
    cmp  w6, #'='
    b.ne .Lop_andor
    adr  x7, eqset
    mov  w8, #eqset_len
    mov  w9, #0
.Lop_eqscan:
    cmp  w9, w8
    b.ge .Lop_single
    ldrb w10, [x7, w9, uxtw]
    cmp  w10, w0
    b.eq .Lop_double
    add  w9, w9, #1
    b    .Lop_eqscan
.Lop_andor:
    cmp  w0, #'&'
    b.ne .Lop_checkor
    cmp  w6, #'&'
    b.eq .Lop_double
    b    .Lop_single
.Lop_checkor:
    cmp  w0, #'|'
    b.ne .Lop_single
    cmp  w6, #'|'
    b.eq .Lop_double
    b    .Lop_single
.Lop_double:
    add  x19, x19, #2
    b    .Lop_emit
.Lop_single:
    add  x19, x19, #1
.Lop_emit:
    sub  x2, x19, x1
    mov  w0, #TOK_OP
    mov  x9, #-1
    bl   store_token
    b    .Llex_top

// --- single-char punctuation ---
.Lpunct:
    mov  x1, x19
    sub  x5, x1, x22
    add  w4, w5, #1
    mov  w3, w21
    add  x19, x19, #1
    mov  x2, #1
    mov  w0, #TOK_PUNCT
    mov  x9, #-1
    bl   store_token
    b    .Llex_top

// --- unrecognised byte ---
.Lunknown:
    mov  x1, x19
    sub  x5, x1, x22
    add  w4, w5, #1
    mov  w3, w21
    add  x19, x19, #1
    mov  x2, #1
    mov  w0, #TOK_UNKNOWN
    mov  x9, #-1
    bl   store_token
    b    .Llex_top

.Llex_finish:
    mov  w0, #TOK_EOF
    mov  x1, x20
    mov  x2, #0
    mov  w3, w21
    sub  x5, x20, x22
    add  w4, w5, #1
    mov  x9, #-1
    bl   store_token

    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// =============================================================================
// print_token(w0=type, x1=lexeme ptr, x2=lexeme len, w3=line, w4=col)
// =============================================================================
print_token:
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    sub  sp, sp, #256

    mov  x19, sp
    mov  x20, x19
    mov  w21, w0
    mov  x22, x1
    mov  x23, x2
    cmp  x23, #200
    b.le .Lpt_lenok
    mov  x23, #200
.Lpt_lenok:

    mov  w0, w3
    mov  x1, x20
    bl   int_to_dec
    add  x20, x20, x0

    mov  w0, #':'
    strb w0, [x20]
    add  x20, x20, #1

    mov  w0, w4
    mov  x1, x20
    bl   int_to_dec
    add  x20, x20, x0

    mov  w0, #' '
    strb w0, [x20]
    add  x20, x20, #1

    cmp  x21, #TOK_TYPE
    b.le .Lpt_typeok
    mov  x21, #TOK_UNKNOWN
.Lpt_typeok:
    adr  x1, type_names
    mov  x2, x21
    lsl  x2, x2, #4
    add  x1, x1, x2
    ldr  x3, [x1]
    ldr  x4, [x1, #8]
    mov  x5, #0
.Lpt_copyname:
    cmp  x5, x4
    b.ge .Lpt_nameend
    ldrb w6, [x3, x5]
    strb w6, [x20, x5]
    add  x5, x5, #1
    b    .Lpt_copyname
.Lpt_nameend:
    add  x20, x20, x4

    mov  w0, #' '
    strb w0, [x20]
    add  x20, x20, #1

    mov  x5, #0
.Lpt_copylex:
    cmp  x5, x23
    b.ge .Lpt_lexend
    ldrb w6, [x22, x5]
    strb w6, [x20, x5]
    add  x5, x5, #1
    b    .Lpt_copylex
.Lpt_lexend:
    add  x20, x20, x23

    mov  w0, #10
    strb w0, [x20]
    add  x20, x20, #1

    sub  x2, x20, x19
    mov  x1, x19
    bl   write_stdout

    add  sp, sp, #256
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret

// =============================================================================
// int_to_dec(w0 = unsigned value, x1 = dest ptr) -> w0 = digits written
// =============================================================================
int_to_dec:
    FUNC_PROLOGUE 16
    mov  x9, x1
    mov  w10, w0
    mov  w11, #0

    cbnz w10, .Litd_extract
    mov  w12, #'0'
    strb w12, [x9]
    mov  w0, #1
    FUNC_EPILOGUE 16
    ret

.Litd_extract:
    mov  x15, sp
.Litd_loop:
    cbz  w10, .Litd_reverse
    mov  w12, #10
    udiv w13, w10, w12
    msub w14, w13, w12, w10
    add  w14, w14, #'0'
    strb w14, [x15, w11, uxtw]
    mov  w10, w13
    add  w11, w11, #1
    b    .Litd_loop

.Litd_reverse:
    mov  w12, #0
.Litd_copy:
    cmp  w12, w11
    b.ge .Litd_done
    sub  w13, w11, w12
    sub  w13, w13, #1
    ldrb w14, [x15, w13, uxtw]
    strb w14, [x9, w12, uxtw]
    add  w12, w12, #1
    b    .Litd_copy
.Litd_done:
    mov  w0, w11
    FUNC_EPILOGUE 16
    ret

// =============================================================================
// small leaf helpers
// =============================================================================
strlen:
    mov  x1, x0
.Lsl_loop:
    ldrb w2, [x1]
    cbz  w2, .Lsl_done
    add  x1, x1, #1
    b    .Lsl_loop
.Lsl_done:
    sub  x0, x1, x0
    ret

write_stdout:                        // x1 = ptr, x2 = len
    mov  x0, #1
    mov  x8, #SYS_write
    svc  #0
    ret

write_stderr:                        // x1 = ptr, x2 = len
    mov  x0, #2
    mov  x8, #SYS_write
    svc  #0
    ret

// =============================================================================
// data
// =============================================================================
.bss
.align 3
char_table:      .skip 256

token_base:      .skip 8
token_count:     .skip 8
token_capacity:  .skip 8
cur_file_index:  .skip 8
file_table:      .skip 8 * MAX_FILES
file_count:      .skip 8

.section .rodata

opchars:       .ascii "+-*/%=<>!&|^~"
opchars_end:
.equ opchars_len, opchars_end - opchars

punctchars:    .ascii "(){}[];,.:"
punctchars_end:
.equ punctchars_len, punctchars_end - punctchars

eqset:         .ascii "+-*/%=!<>"
eqset_end:
.equ eqset_len, eqset_end - eqset

// NUL-separated, double-NUL terminated. Edit these to change your grammar's
// keywords/types; lookup_word() walks them without needing a fixed count.
// (fixed a stray backslash before "for" from the pasted version -- that
// would have assembled as an escaped form-feed glued onto "or")
keywords_table:
    .ascii "concurrent\0let\0in\0if\0then\0else\0while\0do\0skip\0for\0break\0@var\0@property\0@function\0\0"
types_table:
    .ascii "Object\0\Map\0Byte\0Int\0Bool\0Char\0String\0FloatingPoint\0Json\0\0"

hdr_prefix:    .ascii "\n--- "
hdr_prefix_end:
.equ hdr_prefix_len, hdr_prefix_end - hdr_prefix
hdr_suffix:    .ascii " ---\n"
hdr_suffix_end:
.equ hdr_suffix_len, hdr_suffix_end - hdr_suffix

err_open:      .ascii "error: could not open file\n"
err_open_end:
.equ err_open_len, err_open_end - err_open
err_size:      .ascii "error: could not determine file size\n"
err_size_end:
.equ err_size_len, err_size_end - err_size
err_mmap:      .ascii "error: mmap failed\n"
err_mmap_end:
.equ err_mmap_len, err_mmap_end - err_mmap
err_grow:      .ascii "error: could not grow token array\n"
err_grow_end:
.equ err_grow_len, err_grow_end - err_grow

// type_names[type] = { name_ptr, name_len }, 16 bytes/entry, indexed by TOK_*
type_names:
    .quad tn_eof,     3
    .quad tn_ident,   5
    .quad tn_int,     3
    .quad tn_float,   5
    .quad tn_string,  6
    .quad tn_op,      2
    .quad tn_punct,   5
    .quad tn_unknown, 7
    .quad tn_keyword, 7
    .quad tn_type,    4
tn_eof:     .ascii "EOF"
tn_ident:   .ascii "IDENT"
tn_int:     .ascii "INT"
tn_float:   .ascii "FLOAT"
tn_string:  .ascii "STRING"
tn_op:      .ascii "OP"
tn_punct:   .ascii "PUNCT"
tn_unknown: .ascii "UNKNOWN"
tn_keyword: .ascii "KEYWORD"
tn_type:    .ascii "TYPE"

// =============================================================================
// NOTES FOR YOUR NEXT STEP (a parser)
//
// * Walk [token_base] as an array of [token_count] 32-byte records (layout
//   documented at the top of this file). `ptr`/`length` give you the raw
//   source text of a token if you need it again (e.g. converting an INT's
//   text into an actual integer value).
// * `file_index` + `file_table[file_index]` gets you back to the filename
//   for diagnostics ("error in foo.mylang line 12").
// * `subtype` on a KEYWORD/TYPE token is that word's position in
//   keywords_table/types_table (0 = first entry, 1 = second, ...) -- handy
//   for a switch in your parser instead of re-comparing strings.
// * Source buffers are kept mapped for the whole run so token pointers
//   never dangle; that also means memory usage is roughly proportional to
//   total source size, which is normally fine for a compiler front end.
// =============================================================================
