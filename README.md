# ArceOS Chaos Loader

ArceOS Chaos Loader is a specialized bootloader designed to fill the gap in x86 systems where [ArceOS](https://github.com/arceos-org/arceos) could previously only boot on QEMU. ArceOS places all its code in high memory addresses, and Chaos Loader enables it to boot on real hardware without requiring any modifications to the kernel code.

This project is particularly useful for [ArceOS-Hypervisor](https://github.com/arceos-hypervisor). Previously, due to the lack of virtualization instruction emulation in QEMU (and no nested virtualization support for Windows with Hyper-V), development had to be done exclusively on Intel machines. With Chaos Loader, ArceOS and the Hypervisor can now be run and debugged in [Bochs](https://github.com/bochs-emu/Bochs), making it accessible not only to AMD users but also to Apple Silicon users!

## Why the Name?

As the name suggests, Chaos Loader is highly specialized and "chaotic" in design—it only serves one purpose: enabling high memory and booting ArceOS. It's not a general-purpose bootloader, but it does its job well.

## How It Works

1. Initializes the system (sets up GDT, IDT, basic paging, etc.).
2. Maps the high memory addresses used by ArceOS to their corresponding physical locations.
3. Boots ArceOS in a way similar to QEMU's `-kernel` flag.

## Quick Start (Windows)

Download `disk_bochs.img.xz` (remember to decompress, please) and `bochsrc` from the [releases page](https://github.com/CatMe0w/arceos-chaos-loader/releases) and run:

```powershell
C:\path\to\bochsdbg.exe -f .\bochsrc
```

## Full Manual (Linux)

### Build

Requires `nasm` and `make`.

```bash
# Make Chaos Loader
cd /path/to/arceos-chaos-loader/
make

# Make ArceOS Hypervisor
cd /path/to/arceos-umhv/arceos-vmm/
make ACCEL=y ARCH=x86_64 [LOG=warn|info|debug|trace] VM_CONFIGS=/PATH/TO/CONFIG/FILE run
# Follow arceos-umhv/README.md for more details
```

### Set up disk image

Note: Fedora uses `grub2` instead of `grub`, your system may vary.

```bash
# Create a 100MB disk image
dd if=/dev/zero of=disk_bochs.img bs=1M count=100

# Partition and format the disk
parted disk_bochs.img --script mklabel msdos
parted disk_bochs.img --script mkpart primary fat32 1MiB 100%

# Mount the loop device, format, and copy the kernel
sudo losetup -fP disk_bochs.img
sudo mkfs.fat -F 32 /dev/loop0p1
sudo mount /dev/loop0p1 /mnt
sudo mkdir -p /mnt/boot/grub2
sudo cp /path/to/loader.elf /mnt/boot/loader.elf
sudo cp /path/to/arceos-vmm_x86_64-qemu-q35.elf /mnt/boot/kernel.elf

# Install GRUB
sudo nano /mnt/boot/grub2/grub.cfg # Follow the example below
sudo grub2-install --target=i386-pc --boot-directory=/mnt/boot /dev/loop0

# Unmount the loop device
sudo umount /mnt
sudo losetup -d /dev/loop0
```

### Example `grub.cfg`

```
set default=0
set timeout=30
menuentry "ArceOS" {
    multiboot /boot/loader.elf
    module /boot/kernel.elf
}
```

### Example `bochsrc`

```
megs: 128
cpu: count=1
ata0-master: type=disk, path="disk_bochs.img", mode=flat, translation=lba
boot: disk
magic_break: enabled=1
com1: enabled=1, mode=file, dev="serial.log"
panic: action=report
error: action=report
info: action=report
display_library: x, options="gui_debug"
```

### Run

```bash
bochs -f bochsrc
```

### Update an existing disk image

```bash
# Make the new kernel
cd /path/to/arceos-umhv/arceos-vmm/
make ACCEL=y ARCH=x86_64 [LOG=warn|info|debug|trace] VM_CONFIGS=/PATH/TO/CONFIG/FILE run

# Mount the loop device
sudo losetup -fP disk_bochs.img
sudo mount /dev/loop0p1 /mnt

# Copy the new kernel
sudo cp /path/to/arceos-vmm_x86_64-qemu-q35.elf /mnt/boot/kernel.elf

# Unmount the loop device
sudo umount /mnt
sudo losetup -d /dev/loop0
```

## License

MIT License
