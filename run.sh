#!/bin/bash

# QEMUのファイルパス
QEMU=qemu-system-riscv32

# clangのパス (Ubuntuの場合は CC=clang)
CC=clang
CFLAGS="-std=c11 -O2 -g3 -Wall -Wextra --target=riscv32-unknown-elf -fuse-ld=lld -fno-stack-protector -ffreestanding -nostdlib"

# カーネルをビルド
$CC $CFLAGS -Wl,-Tkernel.ld -Wl,-Map=kernel.map -o kernel.elf \
    kernel.c common.c

# QEMUを起動
# -bios default: デフォルトのBIOS (ここではOpenSBI) を使用する。
# -nographic: QEMUをウィンドウなしで起動する。
# -serial mon:stdio: QEMUの標準入出力を仮想マシンのシリアルポートに接続する。mon:を指定することで、QEMUモニターへの切り替えも可能になる。
# --no-reboot: 仮想マシンがクラッシュしたら、再起動せずに停止させる (デバッグに便利)。
$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
    -kernel kernel.elf
