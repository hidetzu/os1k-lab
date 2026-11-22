#!/bin/bash

# QEMUのファイルパス
QEMU=qemu-system-riscv32

# clangのパス (Ubuntuの場合は CC=clang)
CC=clang
CFLAGS="-std=c11 -O2 -g3 -Wall -Wextra --target=riscv32-unknown-elf -fuse-ld=lld -fno-stack-protector -ffreestanding -nostdlib"

OBJCOPY=llvm-objcopy

# シェルをビルド
$CC $CFLAGS -Wl,-Tuser.ld -Wl,-Map=shell.map -o shell.elf shell.c user.c common.c
$OBJCOPY --set-section-flags .bss=alloc,contents -O binary shell.elf shell.bin
$OBJCOPY -Ibinary -Oelf32-littleriscv shell.bin shell.bin.o

# カーネルをビルド
$CC $CFLAGS -Wl,-Tkernel.ld -Wl,-Map=kernel.map -o kernel.elf \
    kernel.c common.c shell.bin.o

# QEMUを起動
# -bios default: デフォルトのBIOS (ここではOpenSBI) を使用する。
# -nographic: QEMUをウィンドウなしで起動する。
# -serial mon:stdio: QEMUの標準入出力を仮想マシンのシリアルポートに接続する。mon:を指定することで、QEMUモニターへの切り替えも可能になる。
# --no-reboot: 仮想マシンがクラッシュしたら、再起動せずに停止させる (デバッグに便利)。
$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
    -drive id=drive0,file=lorem.txt,format=raw,if=none \
    -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
    -kernel kernel.elf
