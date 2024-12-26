OUTPUT_ARCH(i386)
ENTRY(_loader_start)

SECTIONS
{
    . = 0x00100000;

    .text :
    {
        *(.text)
    } :code

    .rodata :
    {
        *(.multiboot)
    } :rodata

    .data :
    {
        *(.data)
    } :data

    .bss :
    {
        *(.bss)
    } :data
}

PHDRS
{
    code PT_LOAD FLAGS(5);   /* RX */
    data PT_LOAD FLAGS(6);   /* RW */
    rodata PT_LOAD FLAGS(4); /* R */
}
