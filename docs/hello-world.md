# 05 Hello World!

教材：[Hello World! | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/05-hello-world)

## この章で答えたい問い

S-mode で動くカーネルは、どうやって画面（シリアル）に文字を出すのか。

## 誰が誰に制御を渡すか

<!-- kernel_main → ecall → OpenSBI（M-mode）→ UART → 戻る、の流れを図にする。矢印ごとに、対応するコード・命令・ログを添える -->

## sbi_call：OpenSBI を呼び出す関数

S-mode のカーネルは UART を自分で操作せず、M-mode の OpenSBI に「この文字を出して」と頼む。その呼び出し口が `sbi_call`。

```c
struct sbiret {
    long error;
    long value;
};

struct sbiret sbi_call(long arg0, long arg1, long arg2, long arg3, long arg4,
                       long arg5, long fid, long eid) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a2 __asm__("a2") = arg2;
    register long a3 __asm__("a3") = arg3;
    register long a4 __asm__("a4") = arg4;
    register long a5 __asm__("a5") = arg5;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = eid;

    __asm__ __volatile__("ecall"
                         : "=r"(a0), "=r"(a1)
                         : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5),
                           "r"(a6), "r"(a7)
                         : "memory");
    return (struct sbiret){.error = a0, .value = a1};
}

void putchar(char ch) {
    sbi_call(ch, 0, 0, 0, 0, 0, 0, 1 /* Console Putchar */);
}
```

### SBI の呼び出し規約

SBI 仕様で、どのレジスタに何を入れるかが決まっている。

| レジスタ | 役割 | `putchar` での値 |
| --- | --- | --- |
| `a7` | EID（Extension ID）：どの機能群か | `1`（Console Putchar） |
| `a6` | FID（Function ID）：機能群の中のどの関数か | `0` |
| `a0`〜`a5` | 引数 | `a0` = 出したい文字、残りは `0` |
| `a0`（戻り） | エラーコード | `sbiret.error` |
| `a1`（戻り） | 戻り値 | `sbiret.value` |

EID `1` の Console Putchar は、SBI の古い版からある「レガシー拡張」。新しい SBI では Debug Console 拡張（DBCN）が後継とされている（一般知識、仕様では未確認）。

自分の環境の OpenSBI v1.8.1 は、起動バナーの `Standard SBI Extensions` に `dbcn` と `legacy` の両方を出している（2026-11-21 観察）。古い呼び方も新しい呼び方も使える状態。

### register 変数とインラインアセンブリ

- `register long a0 __asm__("a0") = arg0;`：この変数を必ずレジスタ `a0` に置くようコンパイラに指示する。ふつうの変数はどのレジスタに置かれるかコンパイラ任せだが、`ecall` の前には決まったレジスタに決まった値が入っている必要がある。
- `: "=r"(a0), "=r"(a1)`：出力。`ecall` から戻ったあと、`a0` と `a1` が書き換わっていることを伝える。
- `: "r"(a0), ... "r"(a7)`：入力。`ecall` の時点で、これらのレジスタの値が使われることを伝える。
- `: "memory"`：`ecall` がメモリを読み書きするかもしれないので、前後でメモリへのアクセスを並べ替えたり省略したりしないよう伝える。
- `__volatile__`：結果を使っていなくても（`putchar` は戻り値を捨てている）、`ecall` を消さないようにする。

### ecall で何が起きるか

```
kernel_main / putchar（S-mode）
   │  a7 = 1, a0 = 文字 をセットして ecall
   ▼
OpenSBI のトラップハンドラ（M-mode）       ← トラップでモードが上がる
   │  a7 を見て Console Putchar と判断し、UART（0x1000_0000）に文字を書く
   │  mepc を ecall の次の命令に進めて mret
   ▼
ecall の次の命令（S-mode）に戻る           ← mret でモードが下がる
```

S-mode の `ecall` が S-mode のトラップハンドラではなく M-mode の OpenSBI に届く理由は、`medeleg` の設定にある（「次に試すこと」の宿題）。

OpenSBI が UART にどう書いているかは、まだ確かめていない（推論：起動時にデバイスツリーから UART を見つけ、`0x1000_0000` の 16550 互換 UART のレジスタに書いている）。

### 逆アセンブルで見えたこと（ホストの Arch）

2026-11-21、`llvm-objdump -d kernel.elf` で観察。

```
80200024 <sbi_call>:
80200024: 00000073     	ecall
80200028: 8082         	ret
```

- `sbi_call` 本体は `ecall` と `ret` の2命令だけになった。引数の並び（`arg0`〜`arg5`、`fid`、`eid`）が、RISC-V の関数呼び出し規約で引数を渡すレジスタの順（`a0`〜`a7`）とちょうど一致しているので、値を移し替える命令が要らない。戻り値の `struct sbiret`（`long` 2個）も、呼び出し規約で `a0` と `a1` に入って返る。
- `-O2` で `putchar` と `sbi_call` は `kernel_main` にインライン展開され、`kernel_main` のループの中で `ecall` を直接実行している（`80200080: ecall`）。そのため、まだスタックは使われていない。

## printf関数

`putchar` で1文字ずつ出せるようになったので、その上に `printf` を作る。`-nostdlib` なので libc の `printf` は使えず、`common.c` に自分で書く。

### 誰が誰を呼ぶか

```
kernel_main（kernel.c）
   │  printf("1 + 2 = %d, %x\n", 1 + 2, 0x1234abcd)
   ▼
printf（common.c）           書式を読み、1文字ずつに分解する
   │  putchar('1') ...
   ▼
putchar（kernel.c）
   │  sbi_call(ch, 0, 0, 0, 0, 0, 0, 1)
   ▼
sbi_call（kernel.c）         a7 = 1, a0 = 文字 で ecall
   │  ecall
   ▼
OpenSBI（M-mode）            UART に1文字書いて mret
```

`printf` は1文字ごとに `ecall` する。1回の呼び出しで、文字数と同じ回数だけ M-mode との行き来が起きる。

### ファイルをまたぐ呼び出し

`printf` は `common.c`、`putchar` は `kernel.c` にある。clang はファイルを1つずつ別々にコンパイルするので、`common.c` をコンパイルしている間は `putchar` が見えない。

- 宣言を書かないと、`call to undeclared function 'putchar'` というエラーになった（2026-11-21、ホストの Arch で確認）。
- `common.c` の先頭に `void putchar(char ch);` という宣言を書くと通った。宣言から「この名前と型の関数がどこかにある」と分かるので、clang は呼び出しの命令を作れる。
- 実際の番地を埋めるのは、リンク時の ld.lld。

```
kernel.c ──clang──▶ kernel.o（putchar の本体、printf を呼ぶ）  ┐
                                                              ├─ld.lld─▶ kernel.elf
common.c ──clang──▶ common.o（printf の本体、putchar を呼ぶ）  ┘
```

（`run.sh` は `clang ... kernel.c common.c` と1行でコンパイルとリンクをしている。`.o` は途中で作られて消える。）

### 処理の流れ

`fmt` を先頭から1文字ずつ読む。

```
'%' 以外 ──▶ そのまま putchar
'%'      ──▶ 次の1文字を見て分岐
             ├ '\0'  : '%' を出して終わる（書式文字列の末尾が '%' だった場合）
             ├ '%'   : '%' を出す（"%%"）
             ├ 's'   : va_arg で文字列を取り出し、'\0' まで出す
             ├ 'd'   : va_arg で int を取り出し、10進で出す
             ├ 'x'   : va_arg で unsigned を取り出し、16進8桁で出す
             └ それ以外 : 何も出さない（引数も取り出さない）
```

| 書式 | 取り出す型 | 出し方 |
| --- | --- | --- |
| `%s` | `const char *` | `'\0'` まで1文字ずつ |
| `%d` | `int` | 負なら `'-'` を出してから絶対値を上の桁から |
| `%x` | `unsigned` | 4ビットずつ、上の桁から8桁（`0x1234` → `00001234`） |
| `%%` | なし | `'%'` |

### %d：10進数を上の桁から出す

1. `divisor` を 1, 10, 100, ... と増やしていき、値の桁数に合った大きさにする（`magnitude / divisor > 9` の間増やす）。
2. `magnitude / divisor` がいちばん上の桁。`'0'` を足して文字にして出す。
3. `magnitude %= divisor` で出した桁を取り除き、`divisor /= 10` で次の桁へ進む。

`1234` の場合：`divisor = 1000` → `1`、`234` → `2`、`34` → `3`、`4` → `4`。

負の数を `unsigned` に移してから反転している理由：`int` の最小値 `-2147483648` は、`int` のまま符号を反転すると `2147483648` になり、`int` の範囲（最大 `2147483647`）を超える。C ではこれは未定義動作。`unsigned` の反転は「2^32 で割った余り」として定義されているので、正しく `2147483648` になる（教材の issue #64 の件）。

### %x：4ビットずつ取り出す

16進の1桁は2進の4ビットにちょうど対応する。`(value >> (i * 4)) & 0xf` で、`i = 7` から `0` まで上の桁から4ビットずつ取り出し、`"0123456789abcdef"[nibble]` で文字に変える。桁数を数えずに常に8桁出すので、上の桁が `0` で埋まる。

### 呼び出しと出力

`kernel_main` から2回呼んだ。

```c
printf("\n\nHello %s\n", "World!");
printf("1 + 2 = %d, %x\n", 1 + 2, 0x1234abcd);
```

教材の出力例は `Hello World!` と `1 + 2 = 3, 1234abcd`。

2026-11-21、ホストの Arch で `./run.sh` を実行した結果（OpenSBI の起動メッセージのあと）：

```


Hello World!
1 + 2 = 3, 1234abcd
```

教材の出力例と一致した。

- `%s`：`"World!"` がそのまま埋め込まれた。
- `%d`：`1 + 2` はコンパイル時に `3` になり、`3` と出た。
- `%x`：`0x1234abcd` は8桁ちょうどなので、`0` 埋めは見えず、`1234abcd` と出た。

### この printf の制限（推論、未確認）

- `%c`、`%u`、桁数の指定（`%08x` など）は使えない。知らない書式は何も出さず、引数も取り出さないので、その後の書式とずれる。
- `%s` に `NULL` を渡すと、番地 0 を読みにいく。
- 戻り値がない（標準の `printf` は出力した文字数を返す）。

## 可変長引数：va_list はどこから来るのか

`va_start` などは C の規格で `<stdarg.h>` に定められたマクロだが、そのヘッダを用意するのは libc ではなくコンパイラ。

| 層 | 誰が用意するか | 例 |
| --- | --- | --- |
| C 言語の規格 | 規格書 | 「`<stdarg.h>` に `va_start` がある」と決める |
| コンパイラ付属のヘッダ | clang | `stdarg.h`、`stddef.h`、`stdint.h` など |
| C 標準ライブラリ（libc） | glibc、newlib など | `printf`、`memcpy` など関数の本体 |

C の規格では、OS もライブラリもない環境（freestanding）でも `<stdarg.h>` は使えることになっている（一般知識、規格の条文は未確認）。可変長引数の取り出し方は CPU の呼び出し規約で決まるので、それを知っているコンパイラが受け持つのが自然。

2026-11-21、ホストの Arch で clang のヘッダを確認した（`clang -print-resource-dir` の下の `include/__stdarg_va_arg.h`）。

```c
#define va_start(ap, param) __builtin_va_start(ap, param)
#define va_arg(ap, type) __builtin_va_arg(ap, type)
```

clang の `stdarg.h` も中身は `__builtin_va_*` への置き換えだけ。`common.h` はこのヘッダを読み込まず、同じ置き換えを自分で書いている。

`-nostdlib` はリンク時に libc と起動コード（crt0）を使わない指定で、ヘッダの読み込みには関係しない。なので `#include <stdarg.h>` も使えるはず（推論、未確認）。

### printf の先頭で起きていること（ホストの Arch）

2026-11-21、`llvm-objdump -d kernel.elf` で `printf` の先頭を観察した（抜粋）。

```
802000ce: 711d   addi sp, sp, -0x60     ← スタックを 0x60（96）バイト確保
802000d0: de06   sw   ra, 0x3c(sp)      ← 戻り先を保存
802000d2: dc22   sw   s0, 0x38(sp)      ┐
   ...                                  │ s0〜s11 を保存
802000e8: c66e   sw   s11, 0xc(sp)      ┘
802000ea: 842a   mv   s0, a0            ← fmt を s0 に退避
802000ec: cabe   sw   a5, 0x54(sp)      ┐
802000ee: ccc2   sw   a6, 0x58(sp)      │
802000f0: cec6   sw   a7, 0x5c(sp)      │ a1〜a7（... の引数）を
802000f2: 00c8   addi a0, sp, 0x44      │ 0x44〜0x5c に連続して並べる
802000f4: c2ae   sw   a1, 0x44(sp)      │
802000f6: c4b2   sw   a2, 0x48(sp)      │
802000f8: c6b6   sw   a3, 0x4c(sp)      │
802000fa: c8ba   sw   a4, 0x50(sp)      ┘
802000fc: c42a   sw   a0, 0x8(sp)       ← vargs = sp+0x44（最初の可変長引数の番地）
```

`printf` の中のスタックの並び（番地の大きい方が上）：

```
呼び出し元の sp → +0x60 ┬──────────────────┐
                        │ a7               │ +0x5c ┐
                        │ a6               │ +0x58 │
                        │ a5               │ +0x54 │ ... で渡された引数
                        │ a4               │ +0x50 │ （va_arg はここを下から順に読む）
                        │ a3               │ +0x4c │
                        │ a2               │ +0x48 │
                        │ a1               │ +0x44 ┘ ← vargs が指す
                        │ （未使用）       │ +0x40
                        │ ra               │ +0x3c
                        │ s0〜s11          │ +0x0c〜+0x38
                        │ vargs            │ +0x08
printf の sp     →  +0  └──────────────────┘
```

読み取れたこと：

- `a0` は固定の引数 `fmt` なので `s0` に移し、`a1`〜`a7` だけを 4 バイトずつ連続してスタックに書いている。レジスタで渡された引数を、メモリ上の配列に変えている。
- `va_start(vargs, fmt)` は、`vargs` に「`a1` を置いた番地（`sp+0x44`）」を入れる命令になった。この環境では `va_list` は実質ただのポインタ（観察から）。
- `a7` の置き場所（`+0x5c`）のすぐ上が、呼び出し元の `sp`（`+0x60`）。推論：引数が 8 個を超えると、9 個目以降は呼び出し元がスタックに積む。そこと続けて並べることで、`va_arg` はポインタを 4 バイトずつ進めるだけで全部の引数を読める。この推論は RISC-V の呼び出し規約（psABI）で確かめる。
- 前の章までは `sp` が `__stack_top` のままだったが、`printf` は普通の関数として呼ばれるので、ここで初めてスタックを使う。

続く `li s1, 0x25` は `'%'` の文字コード。`lui s6, 0xccccd` と `addi s6, s6, -0x333` で作られる `0xcccccccd` は、10 で割る計算を掛け算に置き換えるための定数だと思われる（推論、未確認）。

## 観察結果

<!-- 実行したコマンド（ホスト / QEMU モニター / 自作OSのシェルを区別）と出力 -->

## 次に試すこと

- [ ] 関数呼び出しが増えたあとの `sp` を `info registers` で見て、前の章（`__stack_top` から動いていなかった）と比べる
- [x] `printf` の先頭を `llvm-objdump` で見て、可変長引数がスタックに積まれる様子を確かめる（「printf の先頭で起きていること」に記録）
- [ ] 9 個目以降の引数が呼び出し元のスタックに積まれ、`a7` の置き場所と続くことを確かめる（引数の多い `printf` 呼び出しを逆アセンブルする、または psABI を読む）
- [ ] `0xcccccccd` を掛けて 10 で割る仕組みを確かめる
- [ ] `common.h` の `va_*` の定義をやめて `#include <stdarg.h>` にしても、`-nostdlib` のままビルドできるか試す
- [ ] 「S-mode の `ecall` は M-mode へ行く」ことが、`medeleg 00f4b509` のどこに表れているか確かめる（`riscv-intro.md` の宿題）

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
