# 06 C標準ライブラリ

教材：[C標準ライブラリ | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/06-libc)

## この章で答えたい問い

`-nostdlib` の環境で、型の定義や `memcpy` のような「当たり前にある関数」は誰が用意するのか。

`printf` の本体は前の章（05 Hello World! の「printf関数」）で書く。この章は、型・メモリ操作・文字列操作を `common.c` / `common.h` にそろえる章。

答え：自分で用意する。普段は libc（glibc など）とコンパイラ付属のヘッダが用意しているものを、`common.h` と `common.c` に必要な分だけ書く。

## ファイルとビルドの関係

```
common.h ─── 型・マクロ・関数の宣言
   │ #include              │ #include
   ▼                       ▼
kernel.c                 common.c
（boot, sbi_call,        （memcpy, memset, strcpy,
  putchar, kernel_main）   strcmp, printf）
   │                       │
   └──────clang + ld.lld───┘
               ▼
          kernel.elf
```

- 04 章で `kernel.c` に書いていた `memset` と型の定義は、`common.c` / `common.h` に移した。
- `run.sh` のコンパイル対象に `common.c` を足した（`kernel.c common.c`）。
- `common.c` には、`kernel.c` にある `putchar` の宣言だけを書いている（`printf` が使うため）。

2026-11-21、ホストの Arch で `llvm-objdump -d kernel.elf` を見ると、関数は `kernel.c` の分、`common.c` の分の順に並んでいた。

```
80200000 <boot>:          ┐
8020000e <sbi_call>:      │ kernel.c
80200014 <putchar>:       │
80200028 <kernel_main>:   ┘
80200058 <memcpy>:        ┐
80200074 <memset>:        │ common.c
8020008a <strcpy>:        │
802000aa <strcmp>:        │
802000ce <printf>:        ┘
```

- `boot` は `.text.boot` に入っているので、ファイルが増えても先頭（`0x8020_0000`）のまま。
- まだ使っていない `memcpy`、`strcpy`、`strcmp` も `kernel.elf` に入っている。推論：使われない関数を取り除くリンカの指定（`--gc-sections` など）をしていないため。

## common.h：基本的な型とマクロ

| 名前 | 中身 | なぜ必要か |
| --- | --- | --- |
| `bool`、`true`、`false` | `int` と `1` / `0` | `<stdbool.h>` を使わずに真偽値を書くため |
| `uint8_t`〜`uint64_t` | `unsigned char`〜`unsigned long long` | 大きさが決まった整数。ハードウェアやメモリを扱うとき、何バイトかをはっきりさせたい |
| `size_t` | `uint32_t` | 大きさや個数。32 ビット環境なので 32 ビット |
| `paddr_t` | `uint32_t` | 物理アドレス |
| `vaddr_t` | `uint32_t` | 仮想アドレス。中身は `paddr_t` と同じだが、名前で区別する（ページングの章で効いてくるはず、推論） |
| `NULL` | `((void *) 0)` | ヌルポインタ |
| `align_up`、`is_aligned` | `__builtin_align_up` など | 番地を境界に切り上げる・境界にそろっているか調べる |
| `offsetof` | `__builtin_offsetof` | 構造体の中で、メンバが先頭から何バイト目にあるか |
| `va_list`、`va_start`、`va_end`、`va_arg` | `__builtin_va_*` | 可変長引数（`hello-world.md` の「可変長引数」を参照） |

- `__builtin_` で始まるものは、ライブラリではなくコンパイラの機能。clang がその場で命令に変える。
- `uint32_t` を `unsigned int` にしているのは、この環境（32 ビット RISC-V）で `int` が 32 ビットだから。別の環境では、そのまま使えるとは限らない。
- 今の `common.h` には `#pragma once` がない。今は各ファイルから1回ずつしか読まれないので困らない。

## メモリ操作

```c
void *memcpy(void *dst, const void *src, size_t n);  // src から dst へ n バイト写す
void *memset(void *buf, char c, size_t n);           // buf から n バイトを c で埋める
```

- どちらも1バイトずつ（`uint8_t *` で）処理する、いちばん素直な書き方。
- 戻り値は、標準の関数と同じく先頭の番地（`dst` / `buf`）を返す。
- `memset` は `kernel_main` の最初で `.bss` を 0 で埋めるのに使っている（04 章）。

2026-11-21、`memset` を逆アセンブルした結果（`-O2`）：

```
80200074: beqz a2, 0x80200088     ← n が 0 なら何もしない
80200076: add  a2, a2, a0         ← 終わりの番地 = buf + n
80200078: mv   a3, a0
8020007a: addi a4, a3, 0x1        ┐
8020007e: sb   a1, 0x0(a3)        │ 1バイト書いて次へ。終わりの番地に着くまで繰り返す
80200082: mv   a3, a4             │
80200084: bne  a4, a2, 0x8020007a ┘
80200088: ret
```

`while (n--)` の数え下げは、「終わりの番地と比べる」形に書き換えられていた。

## 文字列操作

```c
char *strcpy(char *dst, const char *src);       // src を '\0' まで dst に写す
int strcmp(const char *s1, const char *s2);     // 等しければ 0、s1 が小さければ負、大きければ正
```

### strcpy の危険性

`strcpy` は `dst` の大きさを知らない。`src` が `dst` より長いと、`dst` の後ろのメモリを上書きしてしまう（バッファオーバーフロー）。カーネルの中でこれが起きると、ほかのデータや戻り先の番地を壊すことになる。

### strcmp で unsigned char にキャストする理由

最後の `*(unsigned char *)s1 - *(unsigned char *)s2` は、異なった最初の文字の差を返す。

- C の規格では、`strcmp` は文字を `unsigned char` として比べることになっている（一般知識、規格の条文は未確認）。
- `char` に符号があるかどうかは環境によって違う。符号付きだと、`0x80` 以上の文字（UTF-8 の日本語など）が負の数になり、大小の向きが逆になる。

2026-11-21、ホストの Arch で clang の定義済みマクロを確かめた。

```
$ echo | clang --target=riscv32-unknown-elf -dM -E - | grep CHAR_UNSIGNED
#define __CHAR_UNSIGNED__ 1
$ echo | clang --target=x86_64-linux-gnu -dM -E - | grep -c CHAR_UNSIGNED
0
```

32 ビット RISC-V では `char` は符号なし、x86-64 の Linux では符号付き。この OS ではキャストがなくても同じ結果になるが、キャストしておけばどちらの環境でも規格どおりに動く。

## 観察結果

上の各見出しに日付と実行環境つきで記録した。

- 関数の並び（`llvm-objdump -d kernel.elf`、ホストの Arch）
- `memset` の逆アセンブル（同上）
- `char` の符号（`clang -dM -E`、同上）

`./run.sh` の実行結果は `hello-world.md` の「呼び出しと出力」を参照。

## 次に試すこと

- [ ] `common.c` が両方で使われる仕組みを確かめ、`overview.md` の疑問を閉じる（今はカーネルにだけリンクされている。アプリの章で、アプリ側にどう入るか見る）
- [ ] `strcpy` で `dst` より長い文字列を写し、後ろのデータが壊れる様子を見る
- [ ] リンカに `--gc-sections` を渡すと、使っていない `memcpy` などが `kernel.elf` から消えるか確かめる

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
