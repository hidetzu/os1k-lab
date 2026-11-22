# 04 ブート

教材：[ブート | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/04-boot)

## この章で答えたい問い

カーネルを誰がメモリに配置し、CPU はどうやって自分が書いた最初の命令に到達するのか。

## はじめての起動：OpenSBI だけを動かす

この時点ではカーネルはまだなく、QEMU で OpenSBI だけを起動する。

### run.sh（初版）

```bash
#!/bin/bash
QEMU=qemu-system-riscv32
$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot
```

| オプション | 意味 |
| --- | --- |
| `-machine virt` | 仮想専用ボード `virt` を使う（`riscv-intro.md` 参照） |
| `-bios default` | QEMU に付属するデフォルトのファームウェア（OpenSBI）を使う |
| `-nographic` | ウィンドウを開かない |
| `-serial mon:stdio` | 端末の入出力を仮想マシンのシリアルポートにつなぐ。`mon:` を付けると QEMU モニターにも切り替えられる |
| `--no-reboot` | 仮想マシンがクラッシュしたら再起動せずに止める（デバッグ用） |

### 何が起きるか（教材より）

- OpenSBI の大きなバナーと、実行環境の情報が表示される。
- キーを打っても何も表示されない。入力はシリアル経由で仮想マシンに届いているが、受け取る OS がまだなく、OpenSBI も入力を無視するため。

### QEMU モニターと `Ctrl-A` の操作

`Ctrl-A` を押して離してから、次のキーを押す。日本語入力（IME）がオンだと効かないことがある。

| キー | 動作 |
| --- | --- |
| `c` | シリアル ⇔ QEMU モニターを切り替える |
| `x` | QEMU を即座に終了する |
| `h` | このキー一覧を表示する |
| `t` | コンソールのタイムスタンプ表示を切り替える |
| `b` | ブレーク信号を送る |
| `s` | ディスクの内容をファイルに書き戻す（`-snapshot` 使用時） |
| `Ctrl-A` | `Ctrl-A` そのものを仮想マシンに送る |

モニターで `q` を実行しても QEMU を終了できる。

### 教材との違い

教材の出力例は QEMU 8.0.2。手元は 11.1.3 なので、バナーや表示される情報が違っていてもおかしくない。

### 最初の問いとの関係

この時点での制御の流れは「QEMU（MROM）→ OpenSBI → 次に渡す相手がいない」。カーネルを置くと、この最後の矢印の先ができる。

## 誰が誰に制御を渡すか


ここまでの理解（QEMU のソースと教材から）。`boot` 以降と、OpenSBI から S-mode で `boot` に来たことは、下の「観察結果」で確かめた。MROM が OpenSBI（`0x8000_0000`）へジャンプすることと、カーネルの番地と次のモードが `0x1028` の構造体で OpenSBI に渡ることも `xp` で確かめた。OpenSBI の中の処理（構造体を読んで `mret` するまで）はまだ観察していない。

```
 [QEMU の起動準備]  OpenSBI を 0x8000_0000 に、kernel.elf を 0x8020_0000 に書き込む
        │           （riscv_find_and_load_firmware / riscv_load_kernel）
        ▼
 0x0000_1000  MROM のリセットコード          M-mode
        │  a0 = hart 番号、a1 = デバイスツリーの番地、a2 = 0x1028（情報の構造体）
        │  を用意して jr で 0x8000_0000 へ
        │  0x1028 の構造体：next_addr = 0x8020_0000、next_mode = 1（S-mode）
        ▼
 0x8000_0000  OpenSBI                        M-mode
        │  初期化のあと、S-mode に降りてジャンプ
        ▼
 0x8020_0000  boot（.text.boot）             S-mode
        │  sp = __stack_top、j kernel_main
        ▼
              kernel_main                    S-mode
              .bss を0クリア → 無限ループ
```

## kernel.ld

リンカスクリプトは、コンパイル済みの各ファイルの中身（セクション）を、メモリのどの番地にどの順で並べるかをリンカ（`ld.lld`）に指示するファイル。

```ld
ENTRY(boot)

SECTIONS {
    . = 0x80200000;

    .text :{
        KEEP(*(.text.boot));
        *(.text .text.*);
    }

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*);
    }

    .data : ALIGN(4) {
        *(.data .data.*);
    }

    .bss : ALIGN(4) {
        __bss = .;
        *(.bss .bss.* .sbss .sbss.*);
        __bss_end = .;
    }

    . = ALIGN(4);
    . += 128 * 1024; /* 128KB */
    __stack_top = .;
}
```

### 1行ずつ

| 記述 | 意味 |
| --- | --- |
| `ENTRY(boot)` | ELF ヘッダのエントリポイントを `boot` 関数にする |
| `. = 0x80200000;` | `.`（ロケーションカウンタ＝今の配置位置）を `0x8020_0000` にする。ここから並べ始める |
| `.text` | 機械語を置く。`KEEP(*(.text.boot))` で `.text.boot` セクション（`boot` 関数）を**必ず先頭に**置き、残りの関数を後ろに続ける |
| `KEEP(...)` | 誰からも参照されていなくても、リンカに捨てさせない |
| `.rodata` | 読み出し専用データ（文字列リテラル、`const` 変数など） |
| `.data` | 初期値を持つ変数 |
| `.bss` | 初期値0の変数。前後に `__bss` と `__bss_end` を置き、C から範囲を参照できるようにする（`boot` 後に0クリアするため） |
| `ALIGN(4)` | 4バイト境界にそろえる |
| `. += 128 * 1024;` | `.bss` の後ろに 128KB の空きを確保する。これがカーネルのスタック |
| `__stack_top = .;` | スタック領域の終わりの番地。スタックは番地の大きい方から小さい方へ伸びるので、ここが初期値になる |

`__bss`、`__bss_end`、`__stack_top` は変数ではなく番地に付けた名前（シンボル）。C からは `extern char __bss[];` のように宣言して番地として使う。

### 作られるメモリ配置

```
0x8000_0000  ┌──────────────────┐
             │ OpenSBI          │  QEMU が置く（-bios default）
0x8020_0000  ├──────────────────┤ ← kernel.ld の起点
             │ .text.boot (boot)│ ← カーネルの先頭
             │ .text            │
             ├──────────────────┤
             │ .rodata          │
             ├──────────────────┤
             │ .data            │
             ├──────────────────┤ ← __bss
             │ .bss             │
             ├──────────────────┤ ← __bss_end
             │ スタック 128KB   │ ↑ 下に向かって伸びる
             ├──────────────────┤ ← __stack_top
             │ （空き）         │
0x87e0_0000  ├──────────────────┤
             │ デバイスツリー   │  QEMU が置く（観察結果を参照）
0x87ff_ffff  └──────────────────┘  RAM の終わり（128MiB）
```

### 最初の問いとの関係：QEMU はどこへジャンプさせるか

QEMU v11.1.3 のソースで確認したこと（未観察）：

- `-kernel` で ELF を渡すと、QEMU は ELF に書かれた番地にそのまま読み込む（[`riscv_load_kernel()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L266)）。つまり **カーネルを置く番地を決めているのは `kernel.ld`**、実際にメモリへ書き込むのは QEMU。
- ジャンプ先には ELF のエントリポイントではなく、**読み込んだイメージの一番低い番地**を使う（[`boot.c` L279-L285 のコメント](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L279-L285)、[`virt.c` L1272 `kernel_entry = boot_info.image_low_addr;`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/virt.c#L1272)）。この番地は MROM のリセットコード経由で OpenSBI に伝えられ、OpenSBI が S-mode でそこへジャンプする。

推論：この構成では `ENTRY(boot)` ではなく、`.text.boot` を先頭に置いていることで CPU が `boot` に到達している。`ENTRY` は ELF としての正しさや、ほかのローダー向けの意味が中心。

### 疑問

- [ ] なぜ `0x8020_0000` なのか。OpenSBI が使う範囲はどこまでで、余裕はどれくらいあるか（材料は「OpenSBI の起動バナー」に記録済み。OpenSBI の範囲の終わりと `0x8020_0000` の間を計算する）
- [x] `.text.boot` を先頭以外に置いたら本当に起動しなくなるか（`ENTRY` が使われていないことの実験）→ 起動しなくなった。OpenSBI の `Domain0 Next Address` は一番低い番地のままだった（「.text.boot を先頭から外す実験」）

## 最小限のカーネル（kernel.c）

```c
typedef unsigned char uint8_t;
typedef unsigned int uint32_t;
typedef uint32_t size_t;

extern char __bss[], __bss_end[], __stack_top[];

void *memset(void *buf, char c, size_t n) {
    uint8_t *p = (uint8_t *) buf;
    while (n--)
        *p++ = c;
    return buf;
}

void kernel_main(void) {
    memset(__bss, 0, (size_t) __bss_end - (size_t) __bss);

    for (;;);
}

__attribute__((section(".text.boot")))
__attribute__((naked))
void boot(void) {
    __asm__ __volatile__(
        "mv sp, %[stack_top]\n"
        "j kernel_main\n"
        :
        : [stack_top] "r" (__stack_top)
    );
}
```

### 部品ごとに

| 部分 | 何をしているか |
| --- | --- |
| `typedef ... uint8_t` など | libc を使わない（`-nostdlib`）ので、`<stdint.h>` も使えない。型を自分で定義する |
| `extern char __bss[], ...` | `kernel.ld` で定義したシンボルを C から参照する。配列として宣言すると、名前がそのまま**番地**として使える（`char __bss;` だと、その番地にある**値**の意味になってしまう） |
| `memset` | libc の `memset` もないので自作する |
| `kernel_main` | `.bss` を0で埋めてから、無限ループで止まる |
| `boot` | カーネルの入口。スタックポインタを設定して `kernel_main` へジャンプする |

### boot 関数の2つの属性

- `section(".text.boot")`：`boot` を `.text.boot` セクションに入れる。`kernel.ld` がこのセクションを `0x8020_0000` の先頭に置くので、OpenSBI からのジャンプ先が `boot` になる。
- `naked`：コンパイラが関数の前後に付ける処理（プロローグ・エピローグ）を出さない。ふつうの関数はスタックに値を積む処理から始まるが、この時点ではまだ `sp` を自分で設定していないので、スタックを使う命令を1つでも出されると困る。

### インラインアセンブリ

```c
__asm__ __volatile__(
    "mv sp, %[stack_top]\n"   // sp = __stack_top
    "j kernel_main\n"         // kernel_main へジャンプ（戻ってこない）
    :                         // 出力：なし
    : [stack_top] "r" (__stack_top)  // 入力：__stack_top の値を何かのレジスタに入れて渡す
);
```

- `call` ではなく `j`（ジャンプ）なのは、`kernel_main` から `boot` に戻る必要がないから。
- `__volatile__` は、コンパイラに「この命令を最適化で消したり動かしたりしない」よう指示する。

### なぜ .bss を0クリアするのか

`.bss` は「初期値0の変数」の置き場だが、ELF ファイルの中には実体がなく、大きさだけが記録されている。読み込む側がその範囲を0にしてくれる保証はないので、カーネル自身が最初に0で埋める。

### crt0 との対応

ふつうの C プログラムでは、`main` の前に crt0（スタートアップコード）がスタックの準備や `.bss` のクリアをしてくれる。`-nostdlib` で crt0 がないこのカーネルでは、`boot`（スタックの設定）と `kernel_main` の冒頭（`.bss` のクリア）がその代わりをしている。

## ビルド（run.sh に追加）

```bash
CC=clang
CFLAGS="-std=c11 -O2 -g3 -Wall -Wextra --target=riscv32-unknown-elf -fuse-ld=lld -fno-stack-protector -ffreestanding -nostdlib"

$CC $CFLAGS -Wl,-Tkernel.ld -Wl,-Map=kernel.map -o kernel.elf \
    kernel.c

$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
    -kernel kernel.elf
```

| オプション | 意味 |
| --- | --- |
| `--target=riscv32-unknown-elf` | 32ビット RISC-V、OS なし（`unknown`）、ELF 形式向けにコンパイルする |
| `-fuse-ld=lld` | リンカに `ld.lld` を使う |
| `-ffreestanding` | OS も標準ライブラリもない環境だとコンパイラに伝える |
| `-nostdlib` | libc と crt0 をリンクしない |
| `-fno-stack-protector` | スタック保護のコードを入れない（それを支えるライブラリがないため） |
| `-O2` / `-g3` | 最適化と、デバッグ情報（マクロ情報まで）を付ける |
| `-Wl,-Tkernel.ld` | リンカに `kernel.ld` を使わせる |
| `-Wl,-Map=kernel.map` | どのシンボルがどの番地に置かれたかをマップファイルに出す |
| `-kernel kernel.elf` | QEMU にカーネルとして `kernel.elf` を読み込ませる |

## 観察結果

2026-11-21、手元の Arch Linux（clang / lld 23.1.5、QEMU 11.1.3）で観察。

### 逆アセンブル（ホストの Arch）

```
$ llvm-objdump -d kernel.elf

kernel.elf: file format elf32-littleriscv

Disassembly of section .text:

80200000 <boot>:
80200000: 80220537 lui a0, 0x80220
80200004: 04c50513 addi a0, a0, 0x4c
80200008: 812a mv sp, a0
8020000a: 01a0006f j 0x80200024 <kernel_main>

8020000e <memset>:
8020000e: ca11 beqz a2, 0x80200022 <memset+0x14>
80200010: 962a add a2, a2, a0
80200012: 86aa mv a3, a0
80200014: 00168713 addi a4, a3, 0x1
80200018: 00b68023 sb a1, 0x0(a3)
8020001c: 86ba mv a3, a4
8020001e: fec71be3 bne a4, a2, 0x80200014 <memset+0x6>
80200022: 8082 ret

80200024 <kernel_main>:
80200024: 802005b7 lui a1, 0x80200
80200028: 04c58593 addi a1, a1, 0x4c
8020002c: 80200537 lui a0, 0x80200
80200030: 04c50513 addi a0, a0, 0x4c
80200034: 40b50633 sub a2, a0, a1
80200038: ca01 beqz a2, 0x80200048 <kernel_main+0x24>
8020003a: 00158613 addi a2, a1, 0x1
8020003e: 00058023 sb zero, 0x0(a1)
80200042: 85b2 mv a1, a2
80200044: fea61be3 bne a2, a0, 0x8020003a <kernel_main+0x16>
80200048: a001 j 0x80200048 <kernel_main+0x24>
```

### シンボルと ELF ヘッダ（ホストの Arch）

```
$ llvm-nm kernel.elf
8020004c B __bss
8020004c B __bss_end
8022004c B __stack_top
80200000 T boot
80200024 T kernel_main
8020000e T memset

$ llvm-readelf -h -l kernel.elf   # 抜粋
  Entry point address:               0x80200000
  LOAD           0x001000 0x80200000 0x80200000 0x0004a 0x0004a R E 0x1000
```

### レジスタ（QEMU モニター）

起動後、無限ループで止まっているところで `info registers` を実行（抜粋）。

```
(qemu) info registers

CPU#0
priv S
pc 80200048
stvec 80200000
satp 00000000
mstatus 80006080
medeleg 00f4b509
mideleg 00001666
mepc 80200000
mcause 00000002
mtval 32102573
x0/zero 00000000 x1/ra 800043fe x2/sp 8022004c ...
```

### 読み取り

予想と一致したこと：

| 観察 | 意味 |
| --- | --- |
| `boot` が `0x8020_0000`、先頭にある | `kernel.ld` の `. = 0x80200000` と `KEEP(*(.text.boot))` のとおり |
| `pc 80200048` | `kernel_main` 末尾の `j 0x80200048`（自分自身へのジャンプ＝`for (;;);`）で回っている |
| `priv S` | カーネルは S-mode で動いている。モードの図のとおり |
| `sp 8022004c` | `__stack_top` と一致。`boot` の `lui a0, 0x80220` + `addi a0, a0, 0x4c` → `mv sp, a0` で設定された値 |
| `__stack_top − __bss_end = 0x20000` | 128KB のスタック領域 |
| `sp` が `__stack_top` から1バイトも動いていない | `kernel_main` は関数を呼ばず、スタックを使わない（逆アセンブルに `addi sp, sp, -N` がない）。`boot` が入れた値がそのまま残っている |
| `mepc 80200000` | M-mode が最後に戻り先として設定した番地が `boot`。OpenSBI が `mret` で `boot` へ降りてきた跡 |
| `medeleg` / `mideleg` | OpenSBI の起動バナーと同じ値 |
| `satp 00000000` | ページングはまだ無効 |

予想していなかったこと：

- `__bss` と `__bss_end` が同じ番地（`.bss` が空）。グローバル変数がまだないため。だから `kernel_main` の `beqz a2, 0x80200048` で 0 クリアのループを丸ごと飛ばしている。
- `-O2` のため、`kernel_main` の中の `memset` 呼び出しはインライン展開され、`memset` 関数は呼ばれていない。
- ELF のエントリポイント（`0x80200000`）と、読み込んだイメージの一番低い番地が同じなので、この構成ではどちらが使われているかは区別できない（`kernel.ld` の疑問の実験で区別する）。
- QEMU モニターでは `priv S` と現在のモードが直接見える。RISC-V のソフトウェアからは現在のモードを読めないが、エミュレータは CPU の内部状態として知っている。

推論（未検証）：

- `stvec 80200000`：S-mode のトラップの飛び先が `boot` を指している。カーネルはまだ `stvec` を設定していないので、OpenSBI が S-mode に降りるときに次の番地と同じ値を入れたのだと思われる。
- `mcause 00000002`（不正命令）と `mtval 32102573`：カーネルではなく、OpenSBI が初期化中に CSR の有無を調べたときの M-mode のトラップの名残だと思われる。
- `ra 800043fe` など、`0x8000_xxxx` を指すレジスタは OpenSBI が使っていた値の残り。

### MROM の中身（QEMU モニター）

MROM（Mask ROM）は、実機では製造時に中身が焼き込まれる書き換え不能な ROM で、電源投入直後に最初に動くコードが入る。QEMU の `virt` では `0x1000` からの小さな ROM 領域（`info mtree` の `riscv_virt_board.mrom`）がこれに当たり、中身は QEMU が起動準備のときに書き込む（[`riscv_setup_rom_reset_vec()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L483)）。

```
(qemu) xp /8i 0x1000
0x00001000: 00000297 auipc t0,0 # 0x1000
0x00001004: 02828613 addi a2,t0,40
0x00001008: f1402573 csrrs a0,mhartid,zero
0x0000100c: 0202a583 lw a1,32(t0)
0x00001010: 0182a283 lw t0,24(t0)
0x00001014: 00028067 jr t0
0x00001018: 0000 illegal
0x0000101a: 8000 c.lbu s0,0(s0)
```

QEMU のソースのコメントと突き合わせた読み取り：

| 番地 | 命令 | 意味 |
| --- | --- | --- |
| `0x1000` | `auipc t0,0` | `t0` = 今の番地（`0x1000`） |
| `0x1004` | `addi a2,t0,40` | `a2` = `0x1028`。OpenSBI に渡す情報の構造体（`fw_dynamic_info`）の番地 |
| `0x1008` | `csrrs a0,mhartid,zero` | `a0` = この CPU の hart 番号（`csrr a0, mhartid` と同じ） |
| `0x100c` | `lw a1,32(t0)` | `a1` = `0x1020` に置かれた値（デバイスツリーの番地） |
| `0x1010` | `lw t0,24(t0)` | `t0` = `0x1018` に置かれた値（ジャンプ先） |
| `0x1014` | `jr t0` | `t0` へジャンプ |
| `0x1018` | `illegal` / `c.lbu ...` | **命令ではなくデータ**。逆アセンブラが無理に命令として解釈している。リトルエンディアンで `0000` `8000` → 値は `0x8000_0000`（OpenSBI の先頭） |

わかったこと：

- リセット直後の CPU は `0x1000` から始まり、6命令で OpenSBI（`0x8000_0000`）へジャンプする。
- その前に `a0`（hart 番号）、`a1`（デバイスツリーの番地）、`a2`（情報の構造体の番地）を用意している。これが OpenSBI への引数になる。
- カーネルの番地 `0x8020_0000` は、MROM の命令には直接出てこない。

#### MROM の命令を詳しく読む

`0x1000` からの領域は、前半が命令、後半がデータ。QEMU がまとめて書き込む。

```
0x1000 ┌────────────────────────────┐
       │ auipc t0, 0                │
0x1004 │ addi  a2, t0, 40           │
0x1008 │ csrrs a0, mhartid, zero    │  命令（6個 × 4バイト = 24バイト）
0x100c │ lw    a1, 32(t0)           │
0x1010 │ lw    t0, 24(t0)           │
0x1014 │ jr    t0                   │
0x1018 ├────────────────────────────┤ ← t0 + 24
       │ 0x8000_0000（ジャンプ先）  │
0x1020 ├────────────────────────────┤ ← t0 + 32
       │ デバイスツリーの番地       │  データ
0x1028 ├────────────────────────────┤ ← t0 + 40
       │ 構造体 fw_dynamic_info     │
       │  magic / version /         │
       │  next_addr = 0x8020_0000   │
       │  next_mode = 1 (S) / ...   │
       └────────────────────────────┘
```

**① `auipc t0, 0`：自分の番地を知る**

```
t0 = pc + (0 << 12) = 0x1000
```

`auipc`（Add Upper Immediate to PC）は `pc + (即値 << 12)` を計算する。即値が 0 なので、今実行している命令の番地がそのまま入る。逆アセンブル結果の `# 0x1000` は計算結果のコメント。以降は `t0` を基準点に、後ろのデータを相対位置で指す。

番地を `li t0, 0x1000` のように直接書かないのは、どの番地に置かれても動くコードにするため。QEMU のソースのコメントにある `%pcrel_hi` / `%pcrel_lo` のとおり、`auipc` で上位、続く `addi` や `lw` で下位を足すのが、RISC-V で PC 相対の番地を作る定番のパターン。

| 命令 | 計算 | 性質 | 例 |
| --- | --- | --- | --- |
| `lui` | 即値 << 12 | 絶対番地。リンク時に決めた番地を埋め込む | カーネルの `boot`（`lui a0, 0x80220`） |
| `auipc` | `pc` + (即値 << 12) | 今いる場所からの相対番地 | MROM |

x86 との比較：x86-32 には `EIP` を直接読む命令がなく、`call` で次の命令へ飛んで、積まれた戻り番地を `pop` で取り出す回り道をする。RISC-V は `auipc` 1命令で済む。

**② `addi a2, t0, 40`：構造体の番地を a2 に入れる**

```
a2 = t0 + 40 = 0x1000 + 0x28 = 0x1028
```

足し算だけで、メモリは読まない。`a2` には**番地そのもの**が入り、構造体へのポインタになる。

**③ `csrrs a0, mhartid, zero`：CPU 番号を a0 に入れる**

```
a0 = mhartid = 0
```

`csrrs` は CSR（制御・状態レジスタ）を読み書きする命令で、`zero` と組み合わせると読むだけになる（`csrr a0, mhartid` と同じ）。`mhartid` は「この CPU が何番目の hart か」を表す、M-mode でだけ読める CSR。

**④ `lw a1, 32(t0)`：デバイスツリーの番地を a1 に入れる**

```
a1 = メモリ[t0 + 32] = メモリ[0x1020]
```

`lw`（Load Word）はメモリから4バイト読む。`32(t0)` は「`t0 + 32` の番地」という書き方。

| 命令 | 結果 |
| --- | --- |
| `addi a2, t0, 40` | `a2` = **番地** `0x1028` |
| `lw a1, 32(t0)` | `a1` = 番地 `0x1020` に**置かれている値** |

**⑤ `lw t0, 24(t0)`：ジャンプ先を t0 に入れる**

```
t0 = メモリ[0x1018] = 0x8000_0000
```

`t0` を基準に読み、結果で `t0` 自身を上書きする。基準点としての役目はここで終わり。

**⑥ `jr t0`：ジャンプ**

```
pc = t0 = 0x8000_0000 → OpenSBI へ
```

`jr`（Jump Register）はレジスタの値の番地へ飛ぶ。戻ってこない。

**実行し終えた時点のレジスタ**

| レジスタ | 値 | 意味 | OpenSBI から見ると |
| --- | --- | --- | --- |
| `a0` | `0` | hart 番号 | 第1引数 |
| `a1` | `0x87e0_0000` | デバイスツリーの番地（下の観察で確認） | 第2引数 |
| `a2` | `0x1028` | 構造体の番地 | 第3引数 |
| `pc` | `0x8000_0000` | OpenSBI の先頭 | ここから実行 |

`a0`〜`a2` は RISC-V で関数の引数を渡すレジスタ。MROM は OpenSBI を「引数3つの関数」のように呼び出している。

**最後の2行が変な理由**

`xp /8i` は「8個を命令として表示」なので、`0x1018` 以降のデータも命令として読もうとする。`0x8000_0000` はメモリ上にリトルエンディアンで `00 00 00 80` と並んでおり、逆アセンブラはこれを2バイトの圧縮命令として解釈してしまう。

QEMU のソースでは、ジャンプ先とデバイスツリーの番地はどちらも8バイトの場所に置かれる。32ビットの CPU は `lw` で下位4バイトだけを読む。

### OpenSBI に渡す情報の構造体（QEMU モニター）

`a2` が指す `0x1028` を32ビットずつ6個見た。

```
(qemu) xp /6wx 0x1028
00001028: 0x4942534f 0x00000002 0x80200000 0x00000001
00001038: 0x00000000 0x00000000
```

QEMU の [`include/hw/riscv/boot_opensbi.h`](https://github.com/qemu/qemu/blob/v11.1.3/include/hw/riscv/boot_opensbi.h) の `struct fw_dynamic_info32` と突き合わせた：

| 番地 | フィールド | 値 | 意味 |
| --- | --- | --- | --- |
| `0x1028` | `magic` | `0x4942534f` | ASCII の `'OSBI'`（リトルエンディアンで `4f 53 42 49`）。正しい構造体かの目印 |
| `0x102c` | `version` | `0x2` | 構造体の版 |
| `0x1030` | `next_addr` | `0x80200000` | **次に起動するもの＝カーネルの番地** |
| `0x1034` | `next_mode` | `0x1` | **次のモード＝ S-mode**（U = 0、S = 1、M = 3） |
| `0x1038` | `options` | `0x0` | OpenSBI へのオプション |
| `0x103c` | `boot_hart` | `0x0` | 起動を担当する hart |

わかったこと：

- カーネルの番地 `0x8020_0000` は、MROM の命令ではなく、この構造体の `next_addr` で OpenSBI に渡されている。
- 「S-mode で起動せよ」という指示も、同じ構造体の `next_mode` で渡されている。前に観察した `priv S` と `mepc 80200000` は、OpenSBI がこの2つの値どおりに `mret` した結果と考えられる。
- `next_addr` の値は、QEMU が ELF の一番低い番地（`image_low_addr`）から決めたもの（`kernel.ld` 節のソース参照）。つまり「`kernel.ld` の `0x80200000` → QEMU がその番地に読み込み、構造体に書く → MROM が `a2` で渡す → OpenSBI が読んでジャンプ」とつながる。

### MROM のデータ部分（QEMU モニター）

```
(qemu) xp /2wx 0x1018
00001018: 0x80000000 0x00000000
(qemu) xp /2wx 0x1020
00001020: 0x87e00000 0x00000000
```

| 番地 | 値 | 意味 |
| --- | --- | --- |
| `0x1018` | `0x80000000`（上位4バイトは `0`） | ジャンプ先。OpenSBI の先頭 |
| `0x1020` | `0x87e00000`（上位4バイトは `0`） | デバイスツリー（DTB）の番地。`a1` に入る値 |

わかったこと：

- どちらも8バイトの場所に置かれ、上位4バイトは `0`。32ビットの CPU は `lw` で下位4バイトだけを読んでいる（ソースどおり）。
- デバイスツリーは RAM の終わり近く（RAM は `0x8000_0000`〜`0x87ff_ffff`）に置かれている。

QEMU のソース（[`riscv_compute_fdt_addr()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L350)）によると、デバイスツリーはカーネルに上書きされないよう、なるべく RAM の後ろに置く。RAM の終わり（`0x8800_0000`）からデバイスツリーの大きさを引き、2MiB 境界に切り下げた番地になる。

```
0x8800_0000 − DTB の大きさ → 2MiB 境界に切り下げ → 0x87e0_0000
```

推論（未検証）：`info registers` で見た `x20/s4 87e00000` は、OpenSBI がデバイスツリーの番地を `s4` に持っていた名残だと思われる。

### OpenSBI の起動バナー（ホストの Arch で ./run.sh）

2026-11-21、05 章の `printf` まで入れたカーネルで `./run.sh` を実行したときの起動メッセージ（抜粋）。

```
OpenSBI v1.8.1
...
Platform Console Device     : uart8250
Firmware Base               : 0x80000000
Firmware Size               : 317 KB
Firmware RW Offset          : 0x40000
Firmware RW Size            : 61 KB
...
Domain0 Region00            : 0x80040000-0x8004ffff M: (F,R,W) S/U: ()
Domain0 Region01            : 0x80000000-0x8003ffff M: (F,R,X) S/U: ()
Domain0 Region02            : 0x00100000-0x00100fff M: (I,R,W) S/U: (R,W)
Domain0 Region03            : 0x10000000-0x10000fff M: (I,R,W) S/U: (R,W)
Domain0 Region04            : 0x02000000-0x0200ffff M: (I,R,W) S/U: ()
Domain0 Region05            : 0x0c400000-0x0c5fffff M: (I,R,W) S/U: (R,W)
Domain0 Region06            : 0x0c000000-0x0c3fffff M: (I,R,W) S/U: (R,W)
Domain0 Region07            : 0x00000000-0xffffffff M: () S/U: (R,W,X)
Domain0 Next Address        : 0x80200000
Domain0 Next Arg1           : 0x87e00000
Domain0 Next Mode           : S-mode
...
Boot HART MIDELEG           : 0x00001666
Boot HART MEDELEG           : 0x00f4b509
```

読み取り：

| バナーの行 | 前に観察した値 | 一致 |
| --- | --- | --- |
| `Domain0 Next Address : 0x80200000` | `fw_dynamic_info` の `next_addr` = `0x8020_0000` | 一致 |
| `Domain0 Next Mode : S-mode` | `fw_dynamic_info` の `next_mode` = `1`（S） | 一致 |
| `Domain0 Next Arg1 : 0x87e00000` | MROM が `a1` に入れたデバイスツリーの番地 `0x87e0_0000` | 一致 |

- QEMU 側（MROM と構造体）で見た値を、OpenSBI 側も同じように受け取っていることが、OpenSBI 自身の表示で確かめられた。
- OpenSBI は `0x8000_0000` から置かれ、`Region00` と `Region01` を合わせた `0x8000_0000`〜`0x8004_ffff` を自分用にしている。どちらも `S/U: ()` で、S-mode と U-mode からは読み書きも実行もできない。
- `Region03`（`0x1000_0000`〜、UART）は `S/U: (R,W)`。推論：S-mode のカーネルも UART を直接触ることは許されている。05 章では、あえて SBI 経由で出力していることになる。
- `Region07` は全空間で `S/U: (R,W,X)`。推論：上の Region に当てはまらない番地は S/U に開放されている（Region が上から順に照合されるのかは未確認）。

## まとめ：0x80200000 のリレー

観察では、`0x80200000` という同じ数字が4か所に現れた。この数字が受け渡される過程が、そのまま「誰が誰に制御を渡すか」になっている。

| # | どこで見たか | 何として現れたか | 調べ方 |
| --- | --- | --- | --- |
| ① | `kernel.ld` | `. = 0x80200000;`（自分で書いた） | ファイルを読む |
| ② | `kernel.elf` | `boot` の番地 | `llvm-objdump` / `llvm-nm`（ホスト） |
| ③ | メモリの `0x1030` | 構造体の `next_addr` | `xp /6wx 0x1028`（QEMU モニター） |
| ④ | CPU の `mepc` | M-mode が最後に設定した戻り先 | `info registers`（QEMU モニター） |

### 時間の順に

**0. ビルド時：数字が ELF に入る（① → ②）**

`kernel.ld` で起点を `0x80200000` にし、`.text.boot` を先頭に置いた。リンカがそのとおりに番地を決めて `kernel.elf` に書く。

- 根拠（観察）：`llvm-objdump` で `80200000 <boot>` が先頭にある。

**1. QEMU の起動準備：CPU が動く前に QEMU がメモリを用意する（② → ③）**

CPU ではなく、エミュレータのプログラムである QEMU 自身の仕事。

- `kernel.elf` を読み、中身を RAM の `0x80200000` に書き込む
- OpenSBI を RAM の `0x80000000` に書き込む
- デバイスツリーを RAM の終わり近く（`0x87e00000`）に書き込む
- MROM（`0x1000`）に、6命令のプログラム、データ（ジャンプ先 `0x80000000`、デバイスツリーの番地）、構造体（`next_addr = 0x80200000`、`next_mode = S`）を書き込む

根拠：

- ソース：`riscv_load_kernel()`、`riscv_setup_rom_reset_vec()`、`riscv_compute_fdt_addr()`
- 観察：`xp /6wx 0x1028` で構造体に `0x80200000` が入っている。`xp /8i 0x1000` で見えた命令の16進数（`00000297`、`02828613` …）は、QEMU のソースに定数として書かれた値と同じ。

**2. CPU のリセット：MROM から始まる（M-mode）**

CPU は `0x1000` から実行を始める。6命令で `a0`（hart 番号）、`a1`（デバイスツリーの番地）、`a2`（構造体の番地 `0x1028`）を用意し、`0x1018` に置かれた `0x80000000` へジャンプする。

- 根拠（観察）：`xp /8i 0x1000`、`xp /2wx 0x1018`、`xp /2wx 0x1020`

**3. OpenSBI：構造体を読んでカーネルへ（③ → ④）**

OpenSBI は `a2` を手がかりに構造体を読み、「次は `0x80200000` へ、S-mode で」と知る。`mepc` に `0x80200000` を入れ、`mret` で S-mode に降りる。

- 根拠（観察、ただし間接的）：`mepc` が `80200000`、今のモードが `priv S`。OpenSBI の中の処理は直接は見ていない。

**4. カーネル：boot → kernel_main（S-mode）**

`boot` が `sp` を設定して `kernel_main` へジャンプし、無限ループで止まる。

- 根拠（観察）：`sp 8022004c` が `__stack_top` と一致。`pc 80200048` が無限ループの命令。

### 最初の問いへの答え

- **カーネルを誰がメモリに配置するのか**：番地は自分で書いた `kernel.ld` が決め、実際に書き込むのは QEMU。
- **CPU はどうやって自分が書いた最初の命令に到達するのか**：QEMU が用意した MROM と構造体を使い、MROM → OpenSBI → `boot` と番地とモードがリレーされて到達する。

### まだ確かめていないこと

- OpenSBI の中で、構造体を読んで `mret` するまでの処理（今回は `mepc` と `priv S` から外側の結果として確かめただけ）。
- ~~QEMU がジャンプ先に ELF のエントリポイントではなく一番低い番地を使う点~~ → 2026-11-22 に実験で確かめた（「.text.boot を先頭から外す実験」）。

### 次に掘るところ

実機では、1番（QEMU の起動準備）の役割を ROM やブートローダーが担う。ブートローダーに興味があるなら、次はここを掘る。

## .text.boot を先頭から外す実験

2026-11-22、ホストの Arch で実験した。この時点のコードは `src/` に移したあと（`Makefile` でビルド）。

### 何を確かめたいか

QEMU のソースでは、ジャンプ先に ELF のエントリポイントではなく、読み込んだイメージの一番低い番地を使うと読んだ（「最初の問いとの関係：QEMU はどこへジャンプさせるか」）。ふだんは `boot` がエントリポイントで、しかも一番低い番地（`0x8020_0000`）にあるので、どちらが使われているか区別できない。

| どこから見た番地か | ふだんの値 |
| --- | --- |
| OpenSBI の `Domain0 Next Address` | `0x80200000` |
| `kernel.elf` の `<boot>`（`llvm-nm -n`） | `0x80200000` |
| ELF のエントリポイント（`llvm-readelf -h`） | `0x80200000` |
| 一番低い LOAD セグメント（`llvm-readelf -l`） | `0x80200000` |

そこで、`boot` だけを先頭から外して、エントリポイントと一番低い番地をずらした。

### kernel.ld の変え方

`.text` の中の2行を入れ替えた。

```
before                              after
.text :{                            .text :{
    KEEP(*(.text.boot));                *(.text .text.*);
    *(.text .text.*);                   KEEP(*(.text.boot));
}                                   }
```

- `*(.text .text.*)` の `.text.*` は、`.text.boot` にも当てはまる。リンカは、入力のセクションを、スクリプトの上から見て最初に当てはまった行に置く（一般知識）。入れ替えると、`.text.boot` は `*(.text .text.*)` の側で、ファイルの中の順番どおりに置かれ、後ろの `KEEP(*(.text.boot))` には何も残らない。
- `kernel.o` の中では `.text`（ほかの関数全部）が先、`.text.boot` が後ろに並んでいる（`llvm-readelf -S`）。そのため `boot` は `kernel.c` の関数の一番後ろに移った。
- 1 回目は、入れ替える前の配置のまま動かしてしまった（`boot` が `0x8020_0000` のまま）。入れ替えて保存し、`make` し直してから、`llvm-nm -n` で `boot` が先頭から外れたことを確かめた。

```
$ llvm-nm -n kernel.elf
80200000 T __kernel_base
80200000 T alloc_pages        <- another function is now first
80200050 T virtio_reg_read32
...
80201298 T boot               <- boot moved here
$ llvm-readelf -h kernel.elf
  Entry point address:  0x80201298
```

### 結果

| | 値 |
| --- | --- |
| ELF のエントリポイント（`boot`） | `0x8020_1298` |
| 一番低い番地（`alloc_pages`） | `0x8020_0000` |
| OpenSBI の `Domain0 Next Address` | `0x8020_0000` |

- `Domain0 Next Address` は、エントリポイントではなく一番低い番地になった（Claude がスクラッチパッドで同じ `kernel.elf` を動かして確かめた）。
- `./run.sh` では、`PANIC: ` が大量に表示され、カーネルは起動しなかった。
- `ENTRY(boot)` でエントリポイントを `boot` にしても、QEMU は一番低い番地を OpenSBI に渡し、CPU は `alloc_pages` の先頭から動き出した。`boot` を `.text` の先頭に置く `KEEP(*(.text.boot))` が、起動のために本当に必要な行。QEMU のソースで読んだこと（`image_low_addr` を使う）が、実験で確かめられた。

### 起動しなかった理由（qemu.log）

`Makefile` で `-d ... int -D qemu.log` を有効にしていたので、`qemu.log` に例外の記録が残っていた。カーネルの番地で最初に起きた例外の付近：

```
riscv_cpu_do_interrupt: hart:0, async:0, cause:00000007, epc:0xffffffff80200002, tval:0x80044e7c, desc=fault_store
riscv_cpu_do_interrupt: hart:0, async:0, cause:00000007, epc:0xffffffff80200002, tval:0x80044e6c, desc=fault_store
riscv_cpu_do_interrupt: hart:0, async:0, cause:00000007, epc:0xffffffff80200002, tval:0x80044e5c, desc=fault_store
...（tval が 0x10 ずつ減りながら続く）
```

`0x8020_0000` から始まった `alloc_pages`：

```
80200000: addi sp, sp, -0x10     reserve 16 bytes on the stack
80200002: sw   ra, 0xc(sp)       <- store access fault (scause 7)
```

1. `sp` が設定されていない：本来は `boot` が `sp` を `__stack_top` に設定するが、`boot` を通らなかったので、`sp` は OpenSBI が使っていた値（`0x8004_4e8x` 付近）のままだった。
2. 書き込めない：そこは OpenSBI の領域（起動メッセージの `Region00 : 0x80040000-0x8004ffff ... S/U: ()`）なので、S-mode からは書けない。書き込みのアクセスフォールトになる。
3. また先頭に戻る：`medeleg` のビット 7 は 0 なので、この例外はまず OpenSBI に届き、OpenSBI が S-mode の `stvec` へ転送する（`exception.md` の `sbi_trap_redirect`）。`stvec` は `0x8020_0000` のままだった。OpenSBI v1.8.1 の `sbi_hart_switch_mode` が、カーネルに渡すときに `csr_write(CSR_STVEC, next_addr)` で `stvec` を飛び先の番地に設定している（[`lib/sbi/sbi_hart.c` L817](https://github.com/riscv-software-src/opensbi/blob/v1.8.1/lib/sbi/sbi_hart.c#L817)）。カーネルは `kernel_main` に着く前なので、`stvec` を書き換えていない。
4. `sp` が下がり続ける：転送されるたびに `alloc_pages` の先頭からやり直し、`addi sp, sp, -0x10` で `sp` が 16 バイトずつ下がる。`tval` が `0x10` ずつ減っているのはこのため。10 章で `sp` を壊したときと同じ形の「入れ子の例外で `sp` が下がり続ける」状態（`process.md`）。

- `sp` が OpenSBI の領域を抜けて書き込める場所に着いたあと、`PANIC: ` だけが大量に出る仕組みは、まだ追えていない。推論：`alloc_pages` の中の「足りなくなったら `PANIC`」の道に入り、`printf` の途中で、また例外と転送を繰り返している。`qemu.log` は約 150MB あるので、追うならログの後半を見る。
- 試し終わったら、`kernel.ld` の 2 行を元の順番に戻す。

### 分かったこと

- OpenSBI が飛ぶ先は、QEMU が渡した「一番低い番地」。`kernel.ld` の `ENTRY` ではない。
- カーネルの最初の命令は、`kernel.ld` で必ずイメージの先頭に置く必要がある。`KEEP(*(.text.boot))` を `.text` の最初に書くのは、そのため。
- OpenSBI は、カーネルに渡すときに `stvec` を飛び先の番地に設定している。カーネルが自分の `stvec` を設定するまでに例外が起きると、カーネルの先頭に戻ってくる。

## 次に試すこと

- [x] `./run.sh` の起動バナーで、OpenSBI のバージョンを確かめる → `v1.8.1`（`setup-arch.md` に記録）
- [ ] カーネルがないとき、OpenSBI は最後にどこへジャンプしようとしているか（バナーの `Domain0 Next Address` などの行を見る）
- [x] カーネルを起動して無限ループで止まったところで、QEMU モニターの `info registers` で `pc` と `sp` を見る。`pc` が `kernel_main` の中、`sp` が `__stack_top` 付近になっているか（`llvm-nm kernel.elf` の番地と比べる）→ 観察結果を参照

- [x] ホストで `llvm-objdump -d kernel.elf | head` を実行し、先頭の命令の番地を確かめる → `0x8020_0000` が `boot`
- [x] QEMU モニターで `xp /8i 0x1000` を実行し、リセット直後の命令がどこへ飛ぶかを見る → `0x8000_0000`（OpenSBI）
- [x] QEMU モニターで `xp /6wx 0x1028` を実行し、`fw_dynamic_info` の中身（`magic`、`version`、次の番地、次のモードなど）を見る。カーネルの番地 `0x8020_0000` と S-mode を表す値がどれか → `next_addr` と `next_mode`
- [x] QEMU モニターで `xp /2wx 0x1018` と `xp /2wx 0x1020` を実行し、ジャンプ先とデバイスツリーの番地を数値で見る（`a1` に入る値）→ `0x8000_0000` と `0x87e0_0000`

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
