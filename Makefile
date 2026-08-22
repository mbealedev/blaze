TARGET := blz
# SRC := $(wildcard *.s)
SRC := main.s lex.s
OBJ := $(SRC:.s=.o)

CFLAGS := -g

$(TARGET): $(OBJ)
	ld -o $@ $^
#gcc -g -nostdlib -o $@ $^

%.o: %.s
	as -g -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(OBJ) $(TARGET)

.PHONY: run clean
