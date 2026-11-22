# 13 ユーザーモード

教材：[ユーザーモード | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/13-user-mode)

## この章で答えたい問い

<!-- 例：カーネルは、埋め込んだアプリをどうやってメモリに置き、CPU はどうやってアプリの最初の命令に U-mode で到達するのか -->

## 誰が誰に制御を渡すか

04 章の「誰が誰に制御を渡すか」（`boot.md`）を、カーネルの先のアプリまで延ばした。

```
 MROM (0x1000)                                                         M-mode
   |  jr t0
   v
 OpenSBI (0x8000_0000)                                                 M-mode
   |  mret   (mepc = 0x8020_0000, mstatus.MPP = S)
   v
 boot (0x8020_0000) -> kernel_main                                     S-mode
   |  create_process(shell)  ra = user_entry
   |  yield -> switch_context
   |  ret    (ra = user_entry)
   v
 user_entry                                                            S-mode
   |  sret   (sepc = USER_BASE = 0x0100_0000, sstatus.SPP = 0 = U)
   v
 start (0x0100_0000) -> jal main                                       U-mode
   v
 main (0x0100_000e)                                                    U-mode
```

- カーネルにとっての MROM と OpenSBI の役割を、アプリにとってはカーネルが担っている。
- 下のモードへ移るのは、どちらも「戻り先の CSR とモードの欄を書いてから、例外から戻る命令を実行する」形（`mret` / `sret`）。

## 実行ファイルの展開

`kernel.h` に `USER_BASE` を足した。`user.ld` の先頭の番地と合わせる。

```c
#define USER_BASE 0x1000000 // ユーザ空間が利用するアドレスの先頭
```

`create_process` は、アプリの中身（`image`）と大きさ（`image_size`）を受け取るようになった。

```c
struct process *create_process(const void *image, size_t image_size) {
  ...
  *--sp = (uint32_t)user_entry; // ra
  ...
  // ユーザーのページをマッピングする
  for (uint32_t off = 0; off < image_size; off += PAGE_SIZE) {
    paddr_t page = alloc_pages(1);

    // コピーするデータがページサイズより小さい場合を考慮
    size_t remaining = image_size - off;
    size_t copy_size = PAGE_SIZE <= remaining ? PAGE_SIZE : remaining;

    // 確保したページにデータをコピー
    memcpy((void *)page, image + off, copy_size);

    // ページテーブルにマッピング
    map_page(page_table, USER_BASE + off, page,
             PAGE_U | PAGE_R | PAGE_W | PAGE_X);
  }
  ...
}
```

- 1 ページずつ `alloc_pages(1)` で確保し、アプリの中身を `memcpy` で写し、`USER_BASE + off` の仮想アドレスに対応させる。
- 印に `PAGE_U` を付ける。カーネルのページには付けない。
- 最後のページが半端なとき（`image_size` が 4KB の倍数でないとき）は、残りの分だけ写す。
- 新しいプロセスが最初に入る `ra` は `user_entry`。
- `kernel_main` は、`create_process(_binary_shell_bin_start, (size_t)_binary_shell_bin_size)` でシェルのプロセスを作る。12 章のシンボルは、ここでカーネルが使う（`application.md`）。前の章の A と B はコメントにした。
- 教材によると、写さずに埋め込んだ中身をそのまま表に載せると、同じアプリのプロセスどうしが同じ物理ページを共有してしまう。

```
 virtual (shell's page table)        physical
 0x0100_0000 +-----------+           0x8020_09fc +--------------------+
             | start ... | <-----.               | _binary_shell_bin  |  embedded in kernel .data
 0x0100_1000 +-----------+       |               |  (source of copy)  |
             |   ...     | <--.  |   memcpy      +--------------------+
             |  stack    |    |  |   ------>     ...
 0x0101_1000 +-----------+    |  `-------------  0x8026_5000 (1st page)
                              `----------------  0x8026_7000- (2nd page and later)
```

## ユーザーモードへの移行

```c
#define SSTATUS_SPIE (1 << 5)

__attribute__((naked)) void user_entry(void) {
  __asm__ __volatile__("csrw sepc, %[sepc]\n"
                       "csrw sstatus, %[sstatus]\n"
                       "sret\n"
                       :
                       : [sepc] "r"(USER_BASE), [sstatus] "r"(SSTATUS_SPIE));
}
```

- `sepc` に `USER_BASE` を書く。`sret` の飛び先になる。
- `sstatus` に `SSTATUS_SPIE`（ビット 5）だけを書く。SPP（ビット 8）は 0 になる。
- `sret` で、`sepc` の番地へ、SPP が示すモード（0 = U）で飛ぶ。
- コードに「U-mode にする」と明示する行はない。SPP を 0 にしたまま `sret` することで U-mode になる（一般知識。仕様の `sstatus` と `sret` の説明で確かめる）。
- 教材によると、SPIE を立てるのは U-mode で割り込みを許可するため。この OS は割り込みを使わないので、なくても動く。

### OpenSBI の mret との比較

| | OpenSBI -> カーネル（`boot.md`） | カーネル -> アプリ（`user_entry`） |
| --- | --- | --- |
| 命令 | `mret` | `sret` |
| 飛び先を入れる CSR | `mepc` | `sepc`（`USER_BASE` を書く） |
| 飛んだ先のモードを決めるもの | `mstatus` の MPP | `sstatus` の SPP |
| 飛んだ先のモード | S-mode | U-mode |

### sret が sstatus をどう書き換えるか

一般知識（仕様の `sret` の説明で確かめる）。観察した `sstatus` の値（「観察結果」）と合う。

| `sret` の動き | 今回 |
| --- | --- |
| `SIE` <- `SPIE`（例外前の割り込み許可を戻す） | `SPIE` が 1 なので `SIE` = 1 |
| `SPIE` <- 1 | 1 |
| モード <- `SPP`、そのあと `SPP` <- 0（U） | `SPP` が 0 なので U-mode へ |
| `pc` <- `sepc` | `0x0100_0000` |

## 動作テスト

`shell.c` の `main` で、カーネルの番地 `0x8020_0000` に書き込んでみた。

```c
void main(int argc, char *argv[]) {
  *((volatile int *)0x80200000) = 0x1234;
  for (;;)
    ;
}
```

- `0x8020_0000` は、シェルの表にも載っている。カーネルは、どのプロセスの表にも恒等マッピングで載せているから（`page-table.md`）。
- ただし、カーネルのページの印に `U` はない。`info mem` でも、カーネルの行は `rwx--a-` で `u` がなかった（「観察結果」）。
- U-mode から `U` のないページに触れると、表に載っていても、権限が足りずにページフォールトになる。仕様の変換手順の「`pte.u` で今のモードからのアクセスが許されるか確かめ、だめならページフォールト」に当たる（`page-table.md` の「仕様の変換手順」の先の手順）。
- これで、`PAGE_U` によって、アプリからカーネルのメモリを守れている。結果は「観察結果」の「カーネルの番地に書き込む」。

## 観察結果

2026-11-22、ホストの Arch で観察。この時点の `user_entry` は、教材の最初の段階（中身が `PANIC` だけ）。

### ./run.sh

```
PANIC: kernel.c:37: not yet implemented
```

`kernel_main` がシェルのプロセスを作って `yield()` すると、シェルの表に `satp` を切り替えて `switch_context` し、`ret` で `user_entry` に入って `PANIC` する。この段階の正しい結果。

### info mem（QEMU モニター）

`PANIC` で止まった状態で見た。`satp` はシェルの表になっている。

```
vaddr    paddr            size     attr
01000000 0000000080265000 00001000 rwxu---
01001000 0000000080267000 00010000 rwxu---
80200000 0000000080200000 00001000 rwx--a-
...
```

- 仮想アドレス `0x0100_0000`（`USER_BASE`）から、`u` の付いたページが載っている。カーネルの行（`0x8020_0000`〜）には `u` がない。
- 物理アドレスは free RAM の中（`__free_ram` は `0x8024_1000`）。アプリの中身は、`alloc_pages` が配ったページに写されている。12 章で推論したとおり（`application.md`）。
- ページ数は 1 + `0x10000`（16 ページ）= 17 ページ。`shell.bin` は 66128 バイトで、66128 / 4096 を切り上げると 17。合う。
- 仮想アドレスは連続しているが、物理アドレスは `0x8026_5000` の次が `0x8026_7000` で、`0x8026_6000` が飛ばされている。

`0x8026_6000` が飛んだ理由（推論）：`create_process` の中で `alloc_pages` が呼ばれる順番。

| 順番 | 何を確保したか | 物理アドレス |
| --- | --- | --- |
| 1 | アプリの 1 ページ目（`memcpy` で写す先） | `0x8026_5000` |
| 2 | `map_page(USER_BASE, ...)` の中で、2 段目の表 | `0x8026_6000` |
| 3〜 | アプリの 2 ページ目以降 | `0x8026_7000`〜 |

- `0x0100_0000` の `VPN[1]` は `0x004`。カーネルの範囲（`VPN[1]` が `0x200` 台）とは違うので、最初の `map_page` で、その範囲の 2 段目の表がまだない。ループの 1 回目だけ、アプリのページを確保したあとに、`map_page` が 2 段目の表を確保した。
- 物理アドレスがばらばらでも、ページテーブルが仮想アドレスを連続に見せている。486 本 p.85 の「虫食いのメモリを、番地の変換でつなげて見せる」話そのもの（`memory-allocation.md`）。

### 写したページの中身（QEMU モニターの xp）

```
(qemu) xp /32b 0x80265000
80265000: 0x37 0x05 0x01 0x01 0x13 0x05 0x05 0x25
80265008: 0x2a 0x81 0x11 0x20 0x11 0x20 0x01 0xa0
80265010: 0x01 0xa0 0x82 0x80 0x09 0xce 0x2a 0x96
80265018: 0xaa 0x86 0x03 0xc7 0x05 0x00 0x85 0x05
```

```
$ llvm-objdump -d shell.elf
01000000 <start>:
 1000000: 01010537   lui  a0, 0x1010
 1000004: 25050513   addi a0, a0, 0x250
 1000008: 812a       mv   sp, a0
 100000a: 2011       jal  0x100000e <main>
 100000c: 2011       jal  0x1000010 <exit>
```

| 番地 | `xp` のバイト | 後ろから読むと | `llvm-objdump` の命令 |
| --- | --- | --- | --- |
| `+0x0` | `37 05 01 01` | `0x01010537` | `lui a0, 0x1010` |
| `+0x4` | `13 05 05 25` | `0x25050513` | `addi a0, a0, 0x250` |
| `+0x8` | `2a 81` | `0x812a` | `mv sp, a0`（2 バイトの圧縮命令） |
| `+0xa` | `11 20` | `0x2011` | `jal main` |
| `+0xc` | `11 20` | `0x2011` | `jal exit` |
| `+0xe` | `01 a0` | `0xa001` | `main`：自分自身へのジャンプ（無限ループ） |
| `+0x10` | `01 a0` | `0xa001` | `exit`：自分自身へのジャンプ |

- 物理アドレス `0x8026_5000` の中身が、仮想アドレス `0x0100_0000` の `start` と同じ。カーネルが `memcpy` で写したものが、表を通して `USER_BASE` に見えている。
- `xp /4x 0x80265000` は 1 バイトずつ表示された。推論：大きさの指定（`b` / `h` / `w`）を省くと、直前の大きさ（`/32b` の `b`）が使われる。4 バイト単位なら `xp /4wx`。
- `xp /4x 80265000`（`0x` なし）は何も表示しなかった。推論：`0x` がないので、番地の値の解釈が変わった。

QEMU モニターの `xp /8i` でも見た。04 章で MROM を見たときと同じ方法（`boot.md`）。QEMU が逆アセンブルするので、エンディアンを気にせず、命令の境目も正しく読める。

```
(qemu) xp /8i 0x80265000
0x80265000: 01010537  lui  a0,4112
0x80265004: 25050513  addi a0,a0,592
0x80265008: 812a      mv   sp,a0
0x8026500a: 2011      jal  ra,4  # 0x8026500e
0x8026500c: 2011      jal  ra,4  # 0x80265010
0x8026500e: a001      j    0     # 0x8026500e
0x80265010: a001      j    0     # 0x80265010
0x80265012: 8082      ret
```

`llvm-objdump -d shell.elf` との違い：

1. 即値は 10 進数で表示される。

| QEMU | llvm-objdump | 同じ値 |
| --- | --- | --- |
| `lui a0,4112` | `lui a0, 0x1010` | 4112 = `0x1010` |
| `addi a0,a0,592` | `addi a0, a0, 0x250` | 592 = `0x250` |

`0x1010 << 12` + `0x250` = `0x0101_0250` で、`user.ld` の `__stack_top`。

2. ジャンプ先の番地が違って見える。

| QEMU | llvm-objdump |
| --- | --- |
| `jal ra,4  # 0x8026500e` | `jal 0x100000e <main>` |

- `jal` の中身は、どちらも同じ `2011`。命令に書かれているのは「今の番地から +4」という相対的な距離だけ。
- `llvm-objdump` は `shell.elf` の番地（`0x0100_000a`）を基準に計算して `0x0100_000e` と表示し、QEMU は `xp` で読んだ物理アドレス（`0x8026_500a`）を基準に計算して `0x8026_500e` と表示している。
- 実際に実行するときは仮想アドレス `0x0100_000a` で実行されるので、飛び先は `0x0100_000e`（`main`）。距離で書かれた命令なので、置かれた場所が変わっても、中身を書き換えずにそのまま動く。04 章で見た `auipc`（`pc` からの相対）と `lui`（絶対値）の違いと同じ話（`boot.md`）。

3. 最後の `ret` は `putchar`。`0x8026_5012` の `8082 ret` は、`exit` の次の関数。`llvm-objdump -d shell.elf` で確かめると、`0x0100_0012` は `putchar` だった。`user.c` で中身を空にした `putchar` が、`ret` だけの関数になっている。

```
$ llvm-objdump -d shell.elf
01000012 <putchar>:
 1000012: 8082   ret
```

ここまでで、12 章の推論「カーネルがアプリの中身を `alloc_pages` のページへ写し、`0x100_0000` で見えるようにする」が、次の3つで確かめられた。

1. `info mem`：`0x0100_0000` -> `0x8026_5000`、`u` 付き。
2. ページ数が 17 で、`shell.bin` の大きさと合う。
3. `xp` の中身が `shell.elf` の命令と一致する。

### user_entry を実装したあと（./run.sh と info registers）

`./run.sh` では、OpenSBI の起動メッセージのあと何も出ずに止まって見えた。シェルの `main` は無限ループするだけで、まだ何も出力しないので、予想どおり。`not yet implemented` の `PANIC` も消えた。

止まって見える状態で、QEMU モニターの `info registers` を見た（抜粋）。

```
CPU#0
 priv     U
 V        0
 pc       0100000e
 x1/ra    0100000c   x2/sp 01010250
 sstatus  00000022
 sepc     01000000
 scause   00000000
 satp     80080253
```

| レジスタ | 値 | 読み方 |
| --- | --- | --- |
| `priv` | `U` | U-mode で実行中。`boot.md` で見たときは `S` だった |
| `pc` | `0100000e` | `main`（自分自身へのジャンプの無限ループ）。仮想アドレスのまま表示されている |
| `x2/sp` | `01010250` | `start` が設定した `__stack_top`（`user.ld`） |
| `x1/ra` | `0100000c` | `start` の `jal main`（`0x0100_000a` の 2 バイトの命令）の次の番地。`main` から戻る先 |
| `sepc` | `01000000` | `user_entry` が書いた `USER_BASE`。`sret` はここへ飛んだ |
| `satp` | `80080253` | PPN `0x80253` -> 表は `0x8025_3000`。推論：idle の 18 ページ（`__free_ram` = `0x8024_1000` から）のすぐ後ろで、シェルの 1 段目の表 |
| `sstatus` | `00000022` | `SPIE`（ビット 5）と `SIE`（ビット 1） |

`sstatus` が `0x20` ではなく `0x22` なのはなぜか：

```
0x22 = 0010 0010
         ^     ^
       bit 5   bit 1
       SPIE    SIE
```

- `user_entry` が書いたのは `SSTATUS_SPIE`（`0x20`）だけ。ビット 1（`SIE`）を立てたのは `sret`。`sret` は戻るときに `SIE` <- `SPIE` とするので、`SPIE` の 1 が `SIE` に写り、`SPIE` も 1 のまま（「sret が sstatus をどう書き換えるか」）。

### カーネルの番地に書き込む（動作テスト）

```
PANIC: kernel.c:256: unexpected trap scause=0000000f, stval=80200000, sepc=01000018
```

`PANIC` で止まったあとの `info registers` では `pc 80200626`。

どの命令で止まったか：

```
$ llvm-objdump -d shell.elf
0100000e <main>:
 100000e: 6505       lui  a0, 0x1
 1000010: 23450513   addi a0, a0, 0x234     <- a0 = 0x1234
 1000014: 802005b7   lui  a1, 0x80200       <- a1 = 0x8020_0000
 1000018: c188       sw   a0, 0x0(a1)       <- sepc: exception here
 100001a: a001       j    0x100001a

$ llvm-addr2line -e shell.elf 01000018
.../shell.c:4
```

| 値 | 読み方 |
| --- | --- |
| `scause=0000000f` | 15 = ストアのページフォールト（Store/AMO page fault） |
| `stval=80200000` | 書き込もうとした番地。カーネルの先頭（`boot`） |
| `sepc=01000018` | 例外を起こした `sw` 命令そのもの（`exception.md` で確かめたとおり、次の命令ではない）。`shell.c` の 4 行目 |
| `kernel.c:256` | `handle_trap` の `PANIC`。推論：整形で `PANIC(...)` が 2 行に分かれたので、閉じかっこのある 2 行目の番号が出ている |
| `pc 80200626` | `handle_trap`（`0x8020_0600`〜）の中。`PANIC` の `while (1) {}` で回っている |

- 教材の出力例は `kernel.c:71`、`sepc=0100001a`。番号と番地は自分のコードで変わる。`scause` と `stval` は同じ。

10 章の実験との違い：

| | `scause` | 原因 |
| --- | --- | --- |
| 10 章：`sp` を壊し、`0x8800_0000` に書き込み（`process.md`） | 7（ストアのアクセスフォールト） | その番地には RAM も機器もない |
| 13 章：`0x8020_0000` に書き込み | 15（ストアのページフォールト） | 番地はあるが、ページテーブルの権限（`U` がない）で拒否された |

推論：同じ「書き込めない」でも、物理的に存在しないのか、ページテーブルで許されていないのかで、例外の種類が分かれる（仕様の `scause` の表で確かめる）。

### 補足：リトルエンディアン（37 05 01 01 -> 0x01010537）

32 ビットの値は、4 つのバイトに分けてメモリに置かれる。

```
0x 01 01 05 37
   ^^ ^^ ^^ ^^
   upper      lower
```

どちらの端から置くかの決まりが2通りある。

| 方式 | 小さい番地に置くバイト | 置き方 |
| --- | --- | --- |
| リトルエンディアン（RISC-V、x86） | 下位のバイト（`37`） | `37 05 01 01` |
| ビッグエンディアン | 上位のバイト（`01`） | `01 01 05 37` |

```
address      0x80265000  0x80265001  0x80265002  0x80265003
content           37          05          01          01
position         lower                                upper
                 bits 7-0   bits 15-8   bits 23-16  bits 31-24
```

読み戻すときは、逆の順番に並べ直す。

```
xp output:   37  05  01  01
reversed:    01  01  05  37
joined:      0x01010537
```

- 2 バイトの圧縮命令も同じ。`2a 81` を逆にすると `0x812a`。
- `xp /2wx 0x80265000` のように `w`（4 バイト）を付けると、QEMU が並べ直して値の形で表示する。ただし、圧縮命令が混ざる部分では、4 バイトの区切りが命令の境目とずれて、2 つの命令がくっついた値になる。命令ごとに読むなら `llvm-objdump` が確実。
- x86 もリトルエンディアン。486 と RISC-V は、この点では共通（一般知識）。

## 次に試すこと

- [ ] `xp /2wx 0x80265000` で、`0x01010537` と `0x25050513` が値の形で出るか確かめる
- [x] `user_entry` を実装し、U-mode で `start` に入ることを確かめる → `priv U`、`pc 0100000e`（「user_entry を実装したあと」）
- [ ] 仕様の `sret` と `sstatus` の説明で、SPP と SIE / SPIE の書き換えを確かめる
- [x] 教材の動作テスト：`shell.c` からカーネルの番地 `0x8020_0000` に書き込み、ページフォールトになるか確かめる → `scause=0xf`、`stval=0x80200000`（「カーネルの番地に書き込む」）
- [ ] 仕様の `scause` の表で、7（アクセスフォールト）と 15（ページフォールト）の違いを確かめる
- [ ] カーネルの範囲に `PAGE_U` を付けたら、同じ書き込みが通ってしまうか試す（試したら元に戻す）

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
