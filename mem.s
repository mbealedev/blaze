.equ MEM_POOL_SIZE, 0x20000
.equ TOKEN_BUFFER_SIZE, 0x4000

.bss
.align 4
mem_pool: .space MEM_POOL_SIZE
token_buffer: .space TOKEN_BUFFER_SIZE
token_count: .space 4
.align 3
mem_ptr: .space 8
token_ptr: .space 8
.global mem_pool, token_buffer, token_count, mem_ptr, token_ptr
