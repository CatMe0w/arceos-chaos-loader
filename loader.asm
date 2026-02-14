section .text
global _loader_start

KERNEL_PHYS_VIRT_OFFSET_HI equ 0xFFFFFF80 ; 0xffffff80_00000000 >> 32

_loader_start:
    ; 1. Verify multiboot magic
    cmp eax, 0x2BADB002
    jne hang            ; Halt if magic is incorrect

    ; We keep interrupts disabled until the kernel installs a valid IDT
    cli

    ; 2. Extract module information from multiboot_info
    mov edi, [ebx + 20] ; mods_count (number of modules)
    mov esi, [ebx + 24] ; mods_addr (address of module descriptors)

    ; Verify that at least one module is loaded
    cmp edi, 0          ; mods_count > 0?
    je hang             ; Halt if no modules are loaded

    ; 2.1. Parse kernel module ELF64 Program Headers and load PT_LOAD segments
    mov edx, [esi]      ; mod_start
    mov ecx, [esi + 4]  ; mod_end
    cmp ecx, edx
    jbe hang
    mov [kernel_mod_start], edx
    sub ecx, edx
    mov [kernel_mod_size], ecx
    call load_kernel_elf64_segments

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
    or eax, 0xA0        ; CR4.PAE | CR4.PGE
    mov cr4, eax

    ; 6. Enable long mode
    mov ecx, 0xC0000080 ; IA32_EFER MSR
    rdmsr
    or eax, 0x900       ; EFER.LME | EFER.NXE
    wrmsr

    ; 7. Enable paging
    mov eax, cr0
    or eax, 0x80010000  ; CR0.PG | CR0.WP
    mov cr0, eax

    ; 8. Into 64-bit code segment
    jmp 0x08:long_mode_entry

hang:
    ; Infinite loop if an error occurs
    cli
hang_loop:
    hlt
    jmp hang_loop

; ---------------------------
; Load ELF64 PT_LOAD segments
; ---------------------------
; Input:
;   [kernel_mod_start] = module start physical address
;   [kernel_mod_size]  = module size in bytes
; Output:
;   [kernel_phys_base] = minimum physical load address among PT_LOAD segments
load_kernel_elf64_segments:
    pushad

    mov esi, [kernel_mod_start]

    ; ELF magic / class / endianness / machine checks
    cmp dword [esi], 0x464C457F ; 0x7F 'E' 'L' 'F'
    jne .error
    cmp byte [esi + 4], 2       ; ELFCLASS64
    jne .error
    cmp byte [esi + 5], 1       ; little-endian
    jne .error
    cmp word [esi + 0x12], 0x3E ; EM_X86_64
    jne .error

    ; e_entry (must stay in the kernel higher-half region)
    mov eax, [esi + 0x18]
    mov edx, [esi + 0x1C]
    cmp edx, KERNEL_PHYS_VIRT_OFFSET_HI
    jne .error
    mov [kernel_entry_low], eax
    mov [kernel_entry_high], edx

    ; e_phoff (must fit in 32 bits in this loader)
    mov eax, [esi + 0x20]
    mov edx, [esi + 0x24]
    test edx, edx
    jnz .error
    mov [elf_phoff], eax

    ; e_phentsize / e_phnum
    movzx eax, word [esi + 0x36]
    mov [elf_phentsize], eax
    cmp eax, 56                 ; sizeof(Elf64_Phdr)
    jb .error

    movzx eax, word [esi + 0x38]
    mov [elf_phnum], eax

    ; Bounds-check: e_phoff + e_phnum * e_phentsize <= module size
    mov eax, [elf_phnum]
    mul dword [elf_phentsize]
    test edx, edx
    jnz .error
    add eax, [elf_phoff]
    jc .error
    cmp eax, [kernel_mod_size]
    ja .error

    mov eax, [kernel_mod_start]
    add eax, [elf_phoff]
    mov [elf_phdr_ptr], eax

    mov eax, [elf_phnum]
    mov [elf_phnum_left], eax
    mov dword [kernel_phys_base], 0xFFFFFFFF

.ph_loop:
    cmp dword [elf_phnum_left], 0
    je .done

    mov ebx, [elf_phdr_ptr]
    cmp dword [ebx + 0x00], 1   ; PT_LOAD
    jne .next_ph

    ; p_offset (must fit in 32 bits)
    mov eax, [ebx + 0x08]
    mov edx, [ebx + 0x0C]
    test edx, edx
    jnz .error
    mov [ph_offset], eax

    ; p_paddr (high dword is either 0 or phys-virt offset high dword)
    mov eax, [ebx + 0x18]
    mov edx, [ebx + 0x1C]
    mov [ph_paddr_low], eax
    mov [ph_paddr_high], edx
    cmp edx, 0
    je .paddr_ok
    cmp edx, KERNEL_PHYS_VIRT_OFFSET_HI
    jne .error
.paddr_ok:
    mov [ph_dst], eax

    ; p_filesz (must fit in 32 bits)
    mov eax, [ebx + 0x20]
    mov edx, [ebx + 0x24]
    test edx, edx
    jnz .error
    mov [ph_filesz], eax

    ; p_memsz:
    ; - normal case: true size in low 32 bits, high == 0
    ; - ArceOS percpu/bss case: encoded as end address with same high dword as p_paddr
    mov eax, [ebx + 0x28]
    mov edx, [ebx + 0x2C]
    test edx, edx
    jz .memsz_ready
    cmp edx, [ph_paddr_high]
    jne .error
    cmp eax, [ph_paddr_low]
    jb .error
    sub eax, [ph_paddr_low]
.memsz_ready:
    mov [ph_memsz], eax

    ; p_memsz must be >= p_filesz
    mov eax, [ph_memsz]
    cmp eax, [ph_filesz]
    jb .error

    ; Bounds-check source: p_offset + p_filesz <= module size
    mov eax, [ph_offset]
    add eax, [ph_filesz]
    jc .error
    cmp eax, [kernel_mod_size]
    ja .error

    ; Track minimum destination physical address
    mov eax, [ph_dst]
    cmp eax, [kernel_phys_base]
    jae .keep_base
    mov [kernel_phys_base], eax
.keep_base:

    ; Copy segment file bytes
    mov esi, [kernel_mod_start]
    add esi, [ph_offset]
    mov edi, [ph_dst]
    mov ecx, [ph_filesz]
    mov edx, ecx
    shr ecx, 2
    rep movsd
    mov ecx, edx
    and ecx, 3
    rep movsb

    ; Zero-fill .bss tail: [p_filesz, p_memsz)
    mov ecx, [ph_memsz]
    sub ecx, [ph_filesz]
    jz .next_ph
    xor eax, eax
    mov edx, ecx
    shr ecx, 2
    rep stosd
    mov ecx, edx
    and ecx, 3
    rep stosb

.next_ph:
    mov eax, [elf_phdr_ptr]
    add eax, [elf_phentsize]
    mov [elf_phdr_ptr], eax
    dec dword [elf_phnum_left]
    jmp .ph_loop

.done:
    cmp dword [kernel_phys_base], 0xFFFFFFFF
    je .error
    popad
    ret

.error:
    popad
    jmp hang

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
    xor ebx, ebx                ; physical address offset
    mov edx, 16                 ; 16 PD entries
.fill_kernel_pt:
    push edx

    mov eax, pt_table
    add eax, edi
    mov esi, eax                ; PT[i]

    mov eax, [kernel_phys_base]
    add eax, ebx                ; kernel_phys_base + (i * 2MB)

    mov ecx, 512
.fill_kernel_pt_inner:
    mov ebp, eax
    or ebp, 0x3
    mov [esi], ebp
    mov dword [esi + 4], 0
    add eax, 0x1000             ; Next page
    add esi, 8                  ; Next PT entry
    loop .fill_kernel_pt_inner

    add edi, 0x1000             ; Next 4KB for PD entry
    add ebx, 0x200000           ; Next 2MB for physical address offset
    pop edx
    dec edx
    jnz .fill_kernel_pt

    ; 3. IDENTITY-MAP low memory for the loader (first 2MB).
    ;    We'll do PML4[0], PDP[0], PD[0], and fill PT[0..511].

    ; Zero out pdp_table_low, pd_table_low, pt_table_low
    xor eax, eax
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

    ; IDENTITY-MAP the low 2MB so loader code/data/stack are all reachable
    ; after entering long mode
    mov eax, 0x00000000
    mov edi, pt_table_low
    mov ecx, 512
.fill_pt_low:
    mov ebx, eax
    or  ebx, 0x3
    mov dword [edi], ebx
    mov dword [edi + 4], 0
    add eax, 0x1000
    add edi, 8
    loop .fill_pt_low

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
    lgdt [rel gdt_mock_descriptor]
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

    ; Resolve bsp_entry64 from loaded kernel code
resolve_bsp_entry64:
    ; Build canonical 64-bit _start VA from saved ELF e_entry
    mov eax, [rel kernel_entry_low]
    mov edx, [rel kernel_entry_high]
    cmp edx, KERNEL_PHYS_VIRT_OFFSET_HI
    jne hang
    shl rdx, 32
    or  rax, rdx
    mov rsi, rax

    ; _start usually jumps into bsp_entry32. Follow if present
    cmp byte [rsi], 0xEB
    je .follow_short
    cmp byte [rsi], 0xE9
    je .follow_near
    jmp .scan_far

.follow_short:
    movsx rcx, byte [rsi + 1]
    lea rsi, [rsi + rcx + 2]
    jmp .scan_far

.follow_near:
    movsxd rcx, dword [rsi + 1]
    lea rsi, [rsi + rcx + 5]

    ; Find far jump (EA ptr16:32) in early bsp_entry32 code and use its 32-bit target
.scan_far:
    mov ecx, 512
.find_far:
    cmp byte [rsi], 0xEA
    je .found
    inc rsi
    dec ecx
    jnz .find_far
    jmp hang

.found:
    mov eax, dword [rsi + 1]
    mov edx, [rel kernel_entry_high]
    shl rdx, 32
    or  rax, rdx
    ; Hello, ArceOS!
    jmp rax

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

; ELF loader state
kernel_mod_start: resd 1
kernel_mod_size:  resd 1
kernel_entry_low: resd 1
kernel_entry_high: resd 1
elf_phoff:        resd 1
elf_phentsize:    resd 1
elf_phnum:        resd 1
elf_phdr_ptr:     resd 1
elf_phnum_left:   resd 1
ph_offset:        resd 1
ph_paddr_low:     resd 1
ph_paddr_high:    resd 1
ph_dst:           resd 1
ph_filesz:        resd 1
ph_memsz:         resd 1

; Don't ask
magic_padding: resb 487424
