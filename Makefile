TARGET := blaze
SRC := $(wildcard *.s)
OBJ := $(SRC:.s=.o)

CFLAGS := -g

$(TARGET): $(OBJ)
	gcc -g -nostdlib -o $@ $^

%.o: %.s
	as -g -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(OBJ) $(TARGET)

.PHONY: run clean
