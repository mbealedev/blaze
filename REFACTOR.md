## Subroutines need to check

blaze.s:
    Call to l_do_lex, l_do_parse

blex.s:
    l_do_lex
    various, convert to macros?

bparse.s
    l_do_parse
    various, convert to macros?

utils.s:
    l_int_to_str

rt0.s:
    l_rt0

print.s:
    l_print_error
    