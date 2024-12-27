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

    ; 4. Set up a 4-level paging structure
    call setup_paging

    ; 5. Enable PAE
    mov eax, cr4
    or eax, 0x20        ; CR4.PAE = 1
    mov cr4, eax

    ; 6. Enable long mode
    mov ecx, 0xC0000080 ; IA32_EFER MSR
    rdmsr
    or eax, 0x100       ; Set LME (Long Mode Enable) bit
    wrmsr

    ; 7. Enable paging
    mov eax, cr0
    or eax, 0x80000000  ; CR0.PG = 1
    mov cr0, eax

    ; 8. Into 64-bit code segment
    jmp 0x08:long_mode_entry

hang:
    ; Infinite loop if an error occurs
    cli
hang_loop:
    hlt
    jmp hang_loop

; -------------------------------
; Set up 4-level paging structure
; -------------------------------
setup_paging:
    pushad              ; Save registers (32-bit)

    ; 1. CLEAR all entries in each 512-entry table

    ; Clear PML4 (512 entries * 8 bytes = 4096 bytes)
    xor eax, eax
    mov edi, pml4_table
    mov ecx, 512
.zero_pml4:
    mov dword [edi], eax     ; low 4 bytes
    mov dword [edi + 4], eax ; high 4 bytes
    add edi, 8
    loop .zero_pml4

    ; Clear PDP
    mov edi, pdp_table
    mov ecx, 512
.zero_pdp:
    mov dword [edi], eax
    mov dword [edi + 4], eax
    add edi, 8
    loop .zero_pdp

    ; Clear PD
    mov edi, pd_table
    mov ecx, 512
.zero_pd:
    mov dword [edi], eax
    mov dword [edi + 4], eax
    add edi, 8
    loop .zero_pd

    ; Clear PT
    mov edi, pt_table
    mov ecx, 512 * 16
.zero_pt:
    mov dword [edi], eax
    mov dword [edi + 4], eax
    add edi, 8
    loop .zero_pt

    ; 2. MAP KERNEL: 0xFFFFFF8000200000 -> kernel_phys_base
    ;    We'll use these indices:
    ;      PML4[511] -> PDP
    ;      PDP[0]    -> PD
    ;      PD[1]     -> PT
    ;      PT[0]     -> kernel_phys_base
    ;    To get this:
    ;      va = 0xFFFFFF8000200000
    ;      pml4_index = (va >> 39) & 0x1FF = 511
    ;      pdp_index  = (va >> 30) & 0x1FF = 0
    ;      pd_index   = (va >> 21) & 0x1FF = 1
    ;      pt_index   = (va >> 12) & 0x1FF = 0
    ;      offset     = va & 0xFFF = 0

    ; PML4[511] = &pdp_table | 0x03 (Present + RW)
    mov eax, pdp_table  ; low 32 bits of address
    mov edx, 0          ; high 32 bits (assuming <4GB)
    or  eax, 0x3        ; set Present + RW
    mov dword [pml4_table + (511 * 8)], eax
    mov dword [pml4_table + (511 * 8) + 4], edx

    ; PDP[0] = &pd_table | 0x03
    mov eax, pd_table
    mov edx, 0
    or  eax, 0x3
    mov dword [pdp_table + (0 * 8)], eax
    mov dword [pdp_table + (0 * 8) + 4], edx


    ; Load the kernel physical address from .bss
    mov ebx, [kernel_phys_base]

    ; Map 32 MB for the kernel
    ; 16 PD entries (16 * 2MB = 32MB), with 512 PT entries each (512 * 4KB = 2MB)
    lea edi, [pd_table + 8]     ; Skip 1 PD entry
    mov esi, pt_table
    mov ecx, 16
.fill_kernel_pd:
    mov eax, esi
    or eax, 0x3
    mov [edi], eax
    mov dword [edi + 4], 0
    add esi, 0x1000             ; Next PT
    add edi, 8                  ; Next PD entry
    loop .fill_kernel_pd

    ; For each PD entry:
    ; PT[0] = kernel_phys_base | 0x03
    ; PT[...] = kernel_phys_base + ...
    ; PT[511] = kernel_phys_base + 511 * 4KB | 0x03
    xor edi, edi                ; i = 0
    mov edx, 16                 ; 16 PD entries
.fill_kernel_pt:
    push edx

    mov eax, pt_table
    add eax, edi
    mov esi, eax                ; PT[i]

    mov eax, ebx
    add eax, edi                ; kernel_phys_base + (i * 2MB)

    mov ecx, 512
.fill_kernel_pt_inner:
    mov ebp, eax
    or ebp, 0x3
    mov [esi], ebp
    mov dword [esi + 4], 0
    add eax, 0x1000             ; Next page
    add esi, 8                  ; Next PT entry
    loop .fill_kernel_pt_inner

    add edi, 0x1000             ; Next 2MB
    pop edx
    dec edx
    jnz .fill_kernel_pt

    ; 3. IDENTITY-MAP the Loader @ 0x00100000
    ;    We'll do PML4[0], PDP[0], PD[0], PT[256]

    ; Zero out pdp_table_low, pd_table_low, pt_table_low
    mov edi, pdp_table_low
    mov ecx, 512
.zero_pdp_low:
    mov dword [edi], eax
    mov dword [edi+4], eax
    add edi, 8
    loop .zero_pdp_low

    mov edi, pd_table_low
    mov ecx, 512
.zero_pd_low:
    mov dword [edi], eax
    mov dword [edi+4], eax
    add edi, 8
    loop .zero_pd_low

    mov edi, pt_table_low
    mov ecx, 512
.zero_pt_low:
    mov dword [edi], eax
    mov dword [edi+4], eax
    add edi, 8
    loop .zero_pt_low

    ; PML4[0] = &pdp_table_low | 0x03
    mov eax, pdp_table_low
    mov edx, 0
    or  eax, 0x3
    mov dword [pml4_table + (0 * 8)], eax
    mov dword [pml4_table + (0 * 8) + 4], edx

    ; PDP[0] = &pd_table_low | 0x03
    mov eax, pd_table_low
    mov edx, 0
    or  eax, 0x3
    mov dword [pdp_table_low + (0 * 8)], eax
    mov dword [pdp_table_low + (0 * 8) + 4], edx

    ; PD[0] = &pt_table_low | 0x03
    mov eax, pt_table_low
    mov edx, 0
    or  eax, 0x3
    mov dword [pd_table_low + (0 * 8)], eax
    mov dword [pd_table_low + (0 * 8) + 4], edx

    ; PT[256] = 0x00100000 | 0x3
    ; (256 * 4K = 0x100000)
    mov eax, 0x00100000
    mov edx, 0
    or  eax, 0x3
    mov dword [pt_table_low + (256 * 8)], eax
    mov dword [pt_table_low + (256 * 8) + 4], edx

    ; 4. LOAD pml4_table into CR3
    mov eax, pml4_table
    mov cr3, eax

    popad
    ret

[bits 64]
long_mode_entry:
    ; Now we are in 64-bit long mode (in a 64-bit code segment)

    mov edi, 0x2BADB002 ; set multiboot magic, rust_entry() expects this
    mov esi, 0          ; clear multiboot info, as current ArceOS doesn't use it

    ; Mock bsp_entry32
    ; Copied from /arceos/modules/axhal/src/platform/x86_pc/multiboot.S
    lgdt [gdt_mock_descriptor]
    ; set data segment selectors
    mov     ax, 0x18
    mov     ss, ax
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax

    ; set PAE, PGE bit in CR4
    ; mov     eax, {cr4}
    ; mov     cr4, eax

    ; load the temporary page table
    ; lea     eax, [.Ltmp_pml4 - {offset}]
    ; mov     cr3, eax

    ; set LME, NXE bit in IA32_EFER
    ; mov     ecx, {efer_msr}
    ; mov     edx, 0
    ; mov     eax, {efer}
    ; wrmsr

    ; set protected mode, write protect, paging bit in CR0
    ; mov     eax, {cr0}
    ; mov     cr0, eax

    ; Hello, ArceOS!
    mov rax, 0xffffff80002000b7 ; bsp_entry64
    jmp rax
    ; FIXME: ArceOS dies at init_memory_management(), the new page table set up by rust part is broken

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

section .data
align 16

; GDT: Null descriptor, Code descriptor, Data descriptor
gdt_data:
    dq 0x0000000000000000 ; NULL descriptor
    dq 0x00AF9A000000FFFF ; Code descriptor (64-bit)
    dq 0x00CF92000000FFFF ; Data descriptor (32-bit)
    dq 0x00CF9A000000FFFF ; Code descriptor (32-bit)
gdt_data_end:

gdt_descriptor:
    dw (gdt_data_end - gdt_data - 1)
    dd gdt_data

; bsp_entry32 GDT and paging structures
; Copied from /arceos/modules/axhal/src/platform/x86_pc/multiboot.S
gdt_mock_data:
    dq 0x0000000000000000
    dq 0x00cf9b000000ffff
    dq 0x00af9b000000ffff
    dq 0x00cf93000000ffff
gdt_mock_data_end:

gdt_mock_descriptor:
    dw (gdt_mock_data_end - gdt_mock_data - 1)
    dd gdt_mock_data

; align 4096
; Ltmp_pml4:
;     # 0x0000_0000 ~ 0xffff_ffff
;     .quad .Ltmp_pdpt_low - {offset} + 0x3   # PRESENT | WRITABLE | paddr(tmp_pdpt)
;     .zero 8 * 255
;     # 0xffff_8000_0000_0000 ~ 0xffff_8000_ffff_ffff
;     .quad .Ltmp_pdpt_high - {offset} + 0x3  # PRESENT | WRITABLE | paddr(tmp_pdpt)
;     .zero 8 * 255

; Ltmp_pdpt_low:
;     .quad 0x0000 | 0x83         # PRESENT | WRITABLE | HUGE_PAGE | paddr(0x0)
;     .quad 0x40000000 | 0x83     # PRESENT | WRITABLE | HUGE_PAGE | paddr(0x4000_0000)
;     .quad 0x80000000 | 0x83     # PRESENT | WRITABLE | HUGE_PAGE | paddr(0x8000_0000)
;     .quad 0xc0000000 | 0x83     # PRESENT | WRITABLE | HUGE_PAGE | paddr(0xc000_0000)
;     .zero 8 * 508

; Ltmp_pdpt_high:
;     .quad 0x0000 | 0x83         # PRESENT | WRITABLE | HUGE_PAGE | paddr(0x0)
;     .quad 0x40000000 | 0x83     # PRESENT | WRITABLE | HUGE_PAGE | paddr(0x4000_0000)
;     .quad 0x80000000 | 0x83     # PRESENT | WRITABLE | HUGE_PAGE | paddr(0x8000_0000)
;     .quad 0xc0000000 | 0x83     # PRESENT | WRITABLE | HUGE_PAGE | paddr(0xc000_0000)
;     .zero 8 * 508

; IDT: Empty (placeholder, will do nothing, let it reset if interrupts occur)
idt_data:
    times 256 dq 0        ; 256 empty entries
idt_data_end:

idt_descriptor:
    dw (idt_data_end - idt_data - 1)
    dd idt_data

section .bss
align 4096

; Top-level PML4 table
pml4_table: resq 512

; For high addresses (kernel)
pdp_table: resq 512
pd_table: resq 512
pt_table: resq 16 * 512 * 8 ; Map many pages (32 MB) for the kernel

; For low addresses (loader)
pdp_table_low: resq 512
pd_table_low: resq 512
pt_table_low: resq 512

; Kernel physical base (set by loader)
kernel_phys_base: resd 1

; Don't ask
magic_padding: resb 487424
