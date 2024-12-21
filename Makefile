ASM = nasm
LD = ld
ASFLAGS = -f elf32
LDFLAGS = -m elf_i386

all: loader.elf

loader.o: loader.asm
	$(ASM) $(ASFLAGS) loader.asm -o loader.o

loader.elf: loader.o loader.ld
	$(LD) $(LDFLAGS) -T loader.ld loader.o -o loader.elf

clean:
	rm -f *.o *.elf
