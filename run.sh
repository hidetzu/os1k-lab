#!/bin/bash

# QEMUのファイルパス
QEMU=qemu-system-riscv32

# clangのパス (Ubuntuの場合は CC=clang)
CC=clang
CFLAGS="-std=c11 -O2 -g3 -Wall -Wextra --target=riscv32-unknown-elf -fuse-ld=lld -fno-stack-protector -ffreestanding -nostdlib"

OBJCOPY=llvm-objcopy

# ソースは src/ に置く。ビルドの成果物と disk.tar は、このスクリプトと同じ場所にできる
SRC=src

# シェルをビルド
$CC $CFLAGS -Wl,-T$SRC/user.ld -Wl,-Map=shell.map -o shell.elf \
    $SRC/shell.c $SRC/user.c $SRC/common.c
$OBJCOPY --set-section-flags .bss=alloc,contents -O binary shell.elf shell.bin
$OBJCOPY -Ibinary -Oelf32-littleriscv shell.bin shell.bin.o

# カーネルをビルド
$CC $CFLAGS -Wl,-T$SRC/kernel.ld -Wl,-Map=kernel.map -o kernel.elf \
    $SRC/kernel.c $SRC/common.c shell.bin.o

# --format=ustar: ustar形式のtarファイルを作成する
(cd disk && tar cf ../disk.tar --format=ustar *.txt)

# QEMUを起動
# -bios default: デフォルトのBIOS (ここではOpenSBI) を使用する。
# -nographic: QEMUをウィンドウなしで起動する。
# -serial mon:stdio: QEMUの標準入出力を仮想マシンのシリアルポートに接続する。mon:を指定することで、QEMUモニターへの切り替えも可能になる。
# --no-reboot: 仮想マシンがクラッシュしたら、再起動せずに停止させる (デバッグに便利)。
$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
    -d unimp,guest_errors,int,cpu_reset -D qemu.log \
    -drive id=drive0,file=disk.tar,format=raw,if=none \
    -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
    -kernel kernel.elf
