OUTPUT_ARCH(i386)
ENTRY(_loader_start)

SECTIONS
{
    . = 0x00100000;

    .text :
    {
        *(.multiboot)
        *(.text)
    } :code

    .data :
    {
        *(.data)
    } :data

    .bss :
    {
        *(.bss)
        *(COMMON)
    } :data
}

PHDRS
{
    code PT_LOAD FLAGS(5); /* RX */
    data PT_LOAD FLAGS(6); /* RW */
}
