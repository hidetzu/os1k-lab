# ビルドと起動の手順。ソースは src/、ディスクの中身は disk/ に置く。
# ビルドの成果物（*.elf、*.bin、*.o、*.map）と disk.tar は、この Makefile と同じ場所にできる。
#
#   make        カーネルとディスクイメージをビルドする
#   make run    ビルドして QEMU で起動する
#   make clean  ビルドの成果物を消す

CC      := clang
OBJCOPY := llvm-objcopy
QEMU    := qemu-system-riscv32
SRC     := src

CFLAGS := -std=c11 -O2 -g3 -Wall -Wextra --target=riscv32-unknown-elf \
          -fuse-ld=lld -fno-stack-protector -ffreestanding -nostdlib

# -bios default: デフォルトのBIOS (ここではOpenSBI) を使用する。
# -nographic: QEMUをウィンドウなしで起動する。
# -serial mon:stdio: QEMUの標準入出力を仮想マシンのシリアルポートに接続する。mon:を指定することで、QEMUモニターへの切り替えも可能になる。
# --no-reboot: 仮想マシンがクラッシュしたら、再起動せずに停止させる (デバッグに便利)。
# -d ... -D qemu.log: 未実装の機能、ゲストの誤り、割り込みと例外、CPU のリセットを qemu.log に記録する。
# -drive / -device: disk.tar を virtio-blk のディスクとしてつなぐ。
QEMUFLAGS := -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
             -d unimp,guest_errors,int,cpu_reset -D qemu.log \
             -drive id=drive0,file=disk.tar,format=raw,if=none \
             -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0

SHELL_SRCS  := $(SRC)/shell.c $(SRC)/user.c $(SRC)/common.c
KERNEL_SRCS := $(SRC)/kernel.c $(SRC)/common.c
HEADERS     := $(wildcard $(SRC)/*.h)

.PHONY: all run clean FORCE

all: kernel.elf disk.tar

# シェルをビルド
shell.elf: $(SHELL_SRCS) $(HEADERS) $(SRC)/user.ld
	$(CC) $(CFLAGS) -Wl,-T$(SRC)/user.ld -Wl,-Map=shell.map -o $@ $(SHELL_SRCS)

shell.bin: shell.elf
	$(OBJCOPY) --set-section-flags .bss=alloc,contents -O binary $< $@

# シンボル名（_binary_shell_bin_start など）は入力のファイル名から決まるので、
# このディレクトリで shell.bin という名前のまま変換する。
shell.bin.o: shell.bin
	$(OBJCOPY) -Ibinary -Oelf32-littleriscv $< $@

# カーネルをビルド
kernel.elf: $(KERNEL_SRCS) $(HEADERS) $(SRC)/kernel.ld shell.bin.o
	$(CC) $(CFLAGS) -Wl,-T$(SRC)/kernel.ld -Wl,-Map=kernel.map -o $@ $(KERNEL_SRCS) shell.bin.o

# ディスクイメージ。QEMU の中で writefile すると disk.tar が書き換わるので、
# 以前の run.sh と同じく、起動のたびに disk/ から作り直す（FORCE）。
# --format=ustar: ustar形式のtarファイルを作成する
disk.tar: FORCE
	(cd disk && tar cf ../disk.tar --format=ustar *.txt)

run: kernel.elf disk.tar
	$(QEMU) $(QEMUFLAGS) -kernel kernel.elf

clean:
	rm -f kernel.elf kernel.map shell.elf shell.map shell.bin shell.bin.o disk.tar qemu.log

FORCE:
