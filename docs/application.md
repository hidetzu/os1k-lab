# 12 アプリケーション

教材：[アプリケーション | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/12-application)

## この章で答えたい問い

<!-- 例：カーネルとは別に作ったアプリは、どんな形でカーネルに渡され、どの番地で動く前提で作られるのか -->

## メモリレイアウト

### user.ld

アプリのリンカスクリプト。

```
ENTRY(start)

SECTIONS {
    . = 0x1000000;

    .text :{
        KEEP(*(.text.start));
        *(.text .text.*);
    }

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*);
    }

    .data : ALIGN(4) {
        *(.data .data.*);
    }

    .bss : ALIGN(4) {
        *(.bss .bss.* .sbss .sbss.*);

        . = ALIGN(16);
        . += 64 * 1024; /* 64KB */
        __stack_top = .;

       ASSERT(. < 0x1800000, "too large executable");
    }
}
```

- `. = 0x1000000;`：アプリを `0x100_0000` から並べる。カーネル（`0x8020_0000`〜）とは重ならない番地。
- `KEEP(*(.text.start))`：`start` を先頭に置く。カーネルの `.text.boot` と同じ考え方。
- スタック 64KB を `.bss` の中に置き、その上端を `__stack_top` とする。`start` がこれを `sp` に設定する。
- `ASSERT(. < 0x1800000, ...)`：アプリが `0x180_0000` を超えたらリンクでエラーにする。アプリに使える範囲は `0x100_0000`〜`0x180_0000` の 8MB。

### 補足：ASSERT

```
ASSERT(. < 0x1800000, "too large executable");
```

- 書き方は `ASSERT(式, メッセージ)`。リンカスクリプトの命令で、リンクするときに式を評価する。式が 0（偽）なら、リンカはメッセージを出してエラーで止まり、ELF を作らない（一般知識。GNU ld の文書の「ASSERT」の項目。ld.lld も同じ書き方に対応している）。
- C の `assert()` とは別物。C の `assert()` は実行中に条件を確かめるが、リンカの `ASSERT` はビルドの時点で確かめる。実行する前に、まずいレイアウトを見つけられる。
- ここでは `.bss` の最後、スタックの 64KB を足したあとに置いている。この時点の `.`（ロケーションカウンタ）は、アプリ全体の終わりの番地。それが `0x180_0000` 未満であることを確かめている。
- つまり「`.text` から スタックまでの全部が、`0x100_0000`〜`0x180_0000` の 8MB に収まること」の確認。プログラムやグローバル変数が大きくなりすぎると、ここで気づける。
- 推論：8MB という範囲は、カーネルがアプリのために用意する仮想アドレスの範囲と合わせてあるはず（13 章で確かめる）。

### kernel.ld との違い

| | `kernel.ld` | `user.ld` |
| --- | --- | --- |
| 先頭の番地 | `0x8020_0000`（OpenSBI が飛んでくる物理アドレス） | `0x100_0000`（アプリが動く仮想アドレス） |
| 最初に置くもの | `.text.boot`（`boot`） | `.text.start`（`start`） |
| スタック | `.bss` の外に `. += 128KB` | `.bss` の中に `. += 64KB` |
| `.bss` の範囲の名前 | `__bss`、`__bss_end`（`memset` で 0 にするため） | なし（0 にしない） |
| 大きさの上限 | なし | `ASSERT(. < 0x1800000, ...)`（8MB まで） |

- `kernel.ld` の `0x8020_0000` は、ページングが無効な状態で QEMU が実際に置く物理アドレスだった（`boot.md`）。カーネルは恒等マッピングなので、ページングを有効にしたあとも同じ番地のまま。
- `user.ld` の `0x100_0000` は、アプリから見える仮想アドレス。QEMU virt の RAM は `0x8000_0000` からなので、`0x100_0000` に RAM はない（`riscv-intro.md`）。推論：ページテーブルで、`0x100_0000` を RAM のどこかに対応させる必要がある。

```
 app's view (virtual)                    physical
 0x0100_0000 +-----------+               0x8000_0000 +-----------+
             | app       |  --(page        | OpenSBI   |
             | .text ... |     table)-->   | kernel    |
             | stack     |      ?          | free RAM  |  <- somewhere here? (inference)
 0x0180_0000 +-----------+               0x8800_0000 +-----------+
```

### 考えどころ：なぜスタックを .bss の中に置くのか

- `.bss` はふつう、ファイルに中身を持たない（`NOBITS`。`memory-allocation.md`）。
- 教材の `run.sh` では `llvm-objcopy --set-section-flags .bss=alloc,contents` として、`.bss` に中身を持たせてから `shell.bin` を作る。スタックも `.bss` の中なので、64KB 分の 0 がファイルに入ることになる（推論）。
- 予想：`shell.bin` の大きさは 64KB を少し超える。なぜわざわざ 0 をファイルに入れるのかは、アプリをメモリに置く方法（13 章）と関係がありそう（推論）。

## ユーザーランド用ライブラリ

### user.c / user.h

```c
// user.h
#pragma once
#include "common.h"

__attribute__((noreturn)) void exit(void);
void putchar(char ch);
```

```c
// user.c
#include "user.h"

extern char __stack_top[];

__attribute__((noreturn)) void exit(void) {
  for (;;)
    ;
}

void putchar(char ch) {
  // 後で実装する
}

__attribute__((section(".text.start"))) __attribute__((naked)) void
start(void) {
  __asm__ __volatile__("mv sp, %[stack_top]\n"
                       "call main\n"
                       "call exit\n" ::[stack_top] "r"(__stack_top));
}
```

| 関数 | 役割 |
| --- | --- |
| `start` | アプリの入口。`.text.start` に置かれるので、`user.ld` によってアプリの先頭（`0x100_0000`）に来る。`sp` を `__stack_top` に設定し、`main` を呼び、戻ってきたら `exit` を呼ぶ |
| `exit` | 今は無限ループするだけ。`noreturn` で「戻ってこない」ことをコンパイラに伝える |
| `putchar` | 今は中身なし。`common.c` の `printf` が `putchar` を呼ぶので、リンクを通すために置いてある |

- `user.h` は `common.h` を読み込む。`common.c`（`printf`、`memset` など）は、カーネルとアプリの両方に、それぞれ別にリンクされる。
- `putchar` の引数 `ch` を使っていないので、`-Wextra` の警告（`unused parameter 'ch'`）が出るはず。カーネルの `handle_trap` の `f` と同じで、今は害はない。

### カーネルの boot との比較

| | カーネルの `boot`（`kernel.c`） | アプリの `start`（`user.c`） |
| --- | --- | --- |
| 置き場所 | `.text.boot`（`kernel.ld` が先頭に置く） | `.text.start`（`user.ld` が先頭に置く） |
| 属性 | `naked` | `naked` |
| `sp` の設定 | `mv sp, __stack_top` | `mv sp, __stack_top` |
| 本体の呼び方 | `j kernel_main`（ジャンプするだけ） | `call main` のあと `call exit` |
| `.bss` を 0 で埋める | `kernel_main` の最初の `memset` | しない |

04 章で、`boot` と `.bss` のクリアは C の起動コード（crt0）の代わりだと書いた（`boot.md`）。`start` は、アプリ版の crt0 に当たる。

### 考えどころ

1. `j` か `call` か：`kernel_main` は最後に止まって戻ってこないが、アプリの `main` は戻ってくることがある。`start` は `call main` で呼び、戻ってきたら `call exit` する。推論：`call exit` がなければ、`main` から戻ったあと CPU は `start` の後ろのメモリをそのまま実行してしまう（`naked` なので `ret` もない）。
2. `.bss` を 0 で埋めない理由：教材では、カーネルの `alloc_pages` が 0 で埋めたメモリを返すから、としている。推論：アプリの `.bss` が置かれるメモリは `alloc_pages` で確保される。「アプリの `0x100_0000` を RAM のどこに対応させるか」の答えにつながりそう（13 章で確かめる）。

## 最初のアプリケーション

```c
#include "user.h"

void main(int argc, char *argv[]) {
  for (;;)
    ;
}
```

- 今は無限ループするだけ。出力はまだできない（`putchar` が空）。
- 教材は `void main(void)`。自分のコードは `argc` と `argv` を受け取る形にしたので、`-Wextra` で `unused parameter` の警告が出る。`start` は `call main` で何も渡さないので、`argc` と `argv` には、そのとき `a0` と `a1` に入っていた値が入る（推論）。今は使っていないので害はない。

## アプリケーションのビルド

`run.sh` に、カーネルより先にシェルをビルドする手順を足した。

```sh
OBJCOPY=llvm-objcopy

# シェルをビルド
$CC $CFLAGS -Wl,-Tuser.ld -Wl,-Map=shell.map -o shell.elf shell.c user.c common.c
$OBJCOPY --set-section-flags .bss=alloc,contents -O binary shell.elf shell.bin
$OBJCOPY -Ibinary -Oelf32-littleriscv shell.bin shell.bin.o

# カーネルをビルド
$CC $CFLAGS -Wl,-Tkernel.ld -Wl,-Map=kernel.map -o kernel.elf \
    kernel.c common.c shell.bin.o
```

```
shell.c user.c common.c
   | clang + ld.lld (user.ld)
   v
shell.elf                      ELF (addresses from 0x0100_0000)
   | llvm-objcopy -O binary    (.bss gets contents)
   v
shell.bin                      raw bytes only, no ELF headers
   | llvm-objcopy -Ibinary -Oelf32-littleriscv
   v
shell.bin.o                    object file wrapping the bytes
   |                           symbols: _binary_shell_bin_start / _end / _size
   v
kernel.c common.c shell.bin.o
   | clang + ld.lld (kernel.ld)
   v
kernel.elf                     kernel with the app bytes inside its .data
```

| 手順 | 何をしているか |
| --- | --- |
| `-O binary` | ELF のヘッダなどを捨てて、メモリに置く中身のバイト列だけを取り出す |
| `--set-section-flags .bss=alloc,contents` | `.bss` に中身（0）を持たせる。これがないと、`.bss` とその中のスタックは `shell.bin` に入らない |
| `-Ibinary -Oelf32-littleriscv` | ただのバイト列を、リンクできるオブジェクトファイルに包む。先頭・終わり・大きさのシンボルが自動で付く |

- カーネルとアプリで、`common.c` をそれぞれ別にコンパイルしてリンクしている（`overview.md` の疑問の答え）。

Arch での違い：教材の `run.sh` は `OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy`（macOS の Homebrew のパス）。Arch では `/opt/homebrew` は存在せず、`llvm-objcopy` は `/usr/bin/llvm-objcopy` にある（`llvm` パッケージ）。最初は教材のパスのまま書いていたので、`OBJCOPY=llvm-objcopy` に直した。`run.sh` はビルドに失敗しても QEMU を起動するので、古い `kernel.elf` で動いてしまい、失敗に気づきにくい。

## 誰がアプリをメモリに置くのか

04 章の最初の問い「カーネルを誰がメモリに配置し、CPU はどうやって最初の命令に到達するのか」を、アプリについて考える。

| | カーネル | アプリ（12 章の時点） |
| --- | --- | --- |
| 動く前提の番地 | `0x8020_0000`（`kernel.ld`） | `0x0100_0000`（`user.ld`） |
| 中身を物理メモリに置いたのは | QEMU（`-kernel kernel.elf`） | QEMU（カーネルの `.data` の一部として、`0x8020_09fc` から） |
| 置かれた番地 = 動く前提の番地か | 同じ | 違う |
| 最初の命令に到達させるのは | MROM → OpenSBI → `boot`（`boot.md`） | まだない（13 章） |

- アプリの中身は、すでに物理メモリ上にある。ただし、アプリは `0x0100_0000` で動く前提で作られているので、物理アドレス `0x8020_09fc` に置かれたままでは動けない。
- 推論：13 章で、カーネルがこの中身を、ページテーブルで `0x0100_0000` から見えるようにする。カーネルにとっての QEMU と OpenSBI の役割を、アプリにとってはカーネルが担う。

## 観察結果

2026-11-22、ホストの Arch で観察。

### shell.bin の大きさ

```
$ ls -l shell.bin
-rwxr-xr-x 1 ... 66128 ... shell.bin
```

`66128` バイト = `0x10250`。64KB（65536 = `0x10000`）より `0x250`（592）バイト大きい。予想どおり。

```
$ llvm-readelf -S shell.elf
  [ 1] .text    PROGBITS  01000000 ... 00023a
  [ 2] .rodata  PROGBITS  0100023c ... 000011
  [ 3] .bss     NOBITS    01000250 ... 010000

$ llvm-nm -n shell.elf
01000000 T start
0100000e T main
01000010 T exit
01010250 B __stack_top
```

```
0x0100_0000  +----------------------+  <- start
             | .text   0x23a        |
0x0100_023c  +----------------------+
             | .rodata 0x11         |
0x0100_0250  +----------------------+
             | .bss    0x10000      |  <- almost all is the 64KB stack (zeros)
0x0101_0250  +----------------------+  <- __stack_top
```

- `--set-section-flags .bss=alloc,contents` で `.bss` に中身を持たせたので、64KB 分の 0 が `shell.bin` に入った。
- `start` がアプリの先頭 `0x0100_0000` にある。`user.ld` の `KEEP(*(.text.start))` のとおり。

### shell.bin.o のシンボル

```
$ llvm-nm shell.bin.o
00010250 D _binary_shell_bin_end
00010250 A _binary_shell_bin_size
00000000 D _binary_shell_bin_start
```

- `_binary_shell_bin_size` は `0x10250` = 66128 で、`ls -l` の大きさと一致した。
- 記号が `A`（絶対値）なので、番地ではなく値そのものが大きさ。
- 教材の例は `00010260`。自分の環境は `00010250`。`shell.c` などの中身が少し違うので、大きさも少し変わる。

### このシンボルを使えるのは誰か

疑問：`_binary_shell_bin_start` などを読む例があるが、これはユーザー空間のアプリから使えるということか。

答え：使えるのはカーネルのほう。アプリではない。

- `shell.bin.o` は、`run.sh` でカーネルと一緒にリンクしている（`kernel.c common.c shell.bin.o`）。シンボルは `kernel.elf` の中にでき、アプリ（`shell.elf`）には入っていない。
- 教材で `printf` を使ってこれらを表示している例は、カーネル側のコード（`kernel_main` など）。アプリの `main`（`shell.c`）ではない。

```
kernel.elf
+------------------------------------------+
| kernel.c: extern char _binary_shell_bin_start[];   <- usable from kernel code
|                                          |
| .data:                                   |
|   _binary_shell_bin_start  0x8020_09fc   |
|   +------------------------------+       |
|   | contents of shell.bin (app)  |       |  <- the app itself does not know these names
|   +------------------------------+       |
|   _binary_shell_bin_end    0x8021_0c4c   |
+------------------------------------------+
```

| シンボル | カーネルから見た意味 |
| --- | --- |
| `_binary_shell_bin_start` | 埋め込んだアプリの中身の先頭の番地 |
| `_binary_shell_bin_end` | その終わりの番地 |
| `_binary_shell_bin_size` | 大きさ（番地ではなく値。記号が `A`） |

推論：13 章で、カーネルがこれらを使ってアプリの中身を見つけ、`alloc_pages` で確保したページへ写し、`0x0100_0000` から見えるように表に載せる。

### カーネルの中のどこに入ったか

```
$ llvm-nm kernel.elf | grep _binary
802009fc D _binary_shell_bin_start
80210c4c D _binary_shell_bin_end
00010250 A _binary_shell_bin_size
```

- アプリの中身は、カーネルの `.data`（`D`）として、物理アドレス `0x8020_09fc` から埋め込まれた。QEMU が `kernel.elf` を読み込むときに、アプリの中身も一緒にメモリに置かれる。
- 推論：`.data` に 64KB 余りが入ったので、その後ろの `.bss`（`procs` など）や `__free_ram` の番地も後ろにずれている。

## 次に試すこと

- [ ] `user.ld` のスタックを `64 * 1024` から `16 * 1024 * 1024`（16MB）に一時的に変えてビルドし、`ASSERT` のメッセージ（`too large executable`）でリンクが止まるか確かめる
- [x] `shell.bin` の大きさを `ls -l` で見て、64KB を少し超えるか確かめる → 66128 バイト（`0x10250`）。予想どおり（「shell.bin の大きさ」）
- [ ] `--set-section-flags .bss=alloc,contents` を外してビルドし、`shell.bin` の大きさがどう変わるか見る
- [ ] `llvm-objdump -d shell.elf` で `start`、`main`、`exit` の命令を見る（教材の「逆アセンブリを見てみる」）
- [ ] `main` の引数を `void main(void)` に戻すか決める

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
