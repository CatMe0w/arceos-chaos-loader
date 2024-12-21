OUTPUT_ARCH(i386)
ENTRY(_loader_start)

SECTIONS
{
    . = 0x00100000;

    .text :
    {
        *(.multiboot)
        *(.text)
    }

    .data :
    {
        *(.data)
    }

    .bss :
    {
        *(.bss)
        *(COMMON)
    }
}
