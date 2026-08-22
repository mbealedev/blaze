// ---------------------------------------------------------------------------
// Linux/aarch64 syscall numbers and related constants shared by main.s and
// lex2.s.
// ---------------------------------------------------------------------------
.equ SYS_read,    63
.equ SYS_write,   64
.equ SYS_openat,  56
.equ SYS_close,   57
.equ SYS_lseek,   62
.equ SYS_mmap,    222
.equ SYS_mremap,  216
.equ SYS_munmap,  215
.equ SYS_exit,    93

.equ AT_FDCWD,      -100
.equ O_RDONLY,      0
.equ SEEK_SET,      0
.equ SEEK_END,      2
.equ PROT_READ,     1
.equ PROT_WRITE,    2
.equ MAP_PRIVATE,   2
.equ MAP_ANONYMOUS, 0x20
.equ MREMAP_MAYMOVE,1
