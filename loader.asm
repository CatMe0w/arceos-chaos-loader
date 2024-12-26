section .text
global _loader_start

_loader_start:
    ; 1. Verify multiboot magic
    cmp eax, 0x2BADB002
    jne hang            ; Halt if magic is incorrect

    ; 2. Extract module information from multiboot_info
    mov edi, [ebx + 20] ; mods_count (number of modules)
    mov esi, [ebx + 24] ; mods_addr (address of module descriptors)

    ; Verify that at least one module is loaded
    cmp edi, 0          ; mods_count > 0?
    je hang             ; Halt if no modules are loaded

    ; Read module (ArceOS kernel) start address
    mov edx, [esi]      ; mod_start (physical start of kernel)

    ; Workaround: edx will be 0x109000 (physical address) and first executable code is at 0x10a000 (phy. address)
    ; At this moment we will simply +0x1000 to get the first executable code
    add edx, 0x1000

    ; Store mod_start as the kernel physical base address
    ; (we'll map this to 0xFFFFFF8000200000 later)
    mov dword [kernel_phys_base], edx

    ; 3. Set up a minimal GDT and IDT
    ; Load a minimal GDT
    lgdt [gdt_descriptor]

    ; Load an empty IDT
    lidt [idt_descriptor]

    ; Set all segment registers to the data segment selector
    mov ax, 0x10        ; Data segment selector
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; 4. Set up paging structure
    call setup_paging

    ; 5. Enable paging
    mov eax, cr0
    or eax, 0x80000000  ; CR0.PG = 1
    mov cr0, eax

    ; 6. Jump to the kernel
    jmp 0x08:0x00200000

hang:
    ; Infinite loop if an error occurs
    cli
hang_loop:
    hlt
    jmp hang_loop

; -------------------------------
; Set up paging structure
; -------------------------------
setup_paging:
    pushad               ; Save registers

    ; 1. CLEAR all entries in each 1024-entry table

    ; Clear PD
    xor eax, eax
    mov edi, pd_table
    mov ecx, 1024
.zero_pd:
    mov dword [edi], eax
    add edi, 4
    loop .zero_pd

    ; Clear PT
    mov edi, pt_table
    mov ecx, 1024
.zero_pt:
    mov dword [edi], eax
    add edi, 4
    loop .zero_pt

    ; 2. MAP PD[0] -> PT[0] (0x00000000 -> 0x00000000)
    mov eax, pt_table    ; No need to shift, as pt_table is 4KB-aligned
    or eax, 0x3          ; Present + RW
    mov dword [pd_table], eax

    ; 3. MAP KERNEL: 0x00200000 -> kernel_phys_base
    ;    We will identity-map the first 2MB of memory
    mov ebx, [kernel_phys_base]
    mov edi, pt_table
    add edi, (0x200 * 4) ; PT[0x200]
    mov ecx, 512         ; 512 * 4KB = 2MB
.fill_kernel:
    mov eax, ebx
    shr eax, 12          ; Truncate lower 12 bits
    shl eax, 12
    or eax, 0x3          ; Present + RW
    mov dword [edi], eax
    add ebx, 0x1000      ; Next page
    add edi, 4           ; Next PT entry
    loop .fill_kernel

    ; 4. IDENTITY-MAP the Loader @ 0x00100000
    mov eax, 0x00100000  ; No need to shift
    or eax, 0x3          ; Present + RW
    mov edi, pt_table
    add edi, (0x100 * 4) ; PT[0x100]
    mov dword [edi], eax

    ; 5. LOAD pd_table into CR3
    mov eax, pd_table
    mov cr3, eax

    popad
    ret

; -------------------------------
; Data and paging structures
; -------------------------------

; Multiboot header
section .multiboot
align 4
    ; Multiboot magic number
    dd 0x1BADB002              ; magic
    ; Flags (request memory map from GRUB)
    dd 0x00000001              ; flags = 1 (request memory info)
    ; Checksum (magic + flags + checksum = 0)
    dd -(0x1BADB002 + 0x00000001)

section .rodata
align 16

; GDT: Null descriptor, Code descriptor, Data descriptor
gdt_data:
    dq 0x0000000000000000 ; NULL descriptor
    dq 0x00CF9A000000FFFF ; Code descriptor (32-bit)
    dq 0x00CF92000000FFFF ; Data descriptor (32-bit)
gdt_data_end:

gdt_descriptor:
    dw (gdt_data_end - gdt_data - 1)
    dd gdt_data

; IDT: Empty (placeholder, will do nothing, let it reset if interrupts occur)
idt_data:
    times 256 dq 0        ; 256 empty entries
idt_data_end:

idt_descriptor:
    dw (idt_data_end - idt_data - 1)
    dd idt_data

section .bss
align 4096

pd_table: resd 1024
pt_table: resd 1024

; Kernel physical base (set by loader)
kernel_phys_base: resd 1
