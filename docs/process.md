# 10 プロセス

教材：[プロセス | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/10-process)

## この章で答えたい問い

<!-- 例：1つの CPU で、複数のプログラムが同時に動いているように見せるには、何を保存して何を切り替えればよいのか -->

## プロセスとは

<!-- 自分の言葉で。この教材では 1 プロセス = 1 スレッド -->

## プロセス管理構造体

<!-- struct process（pid / state / sp / stack）、procs[PROCS_MAX]。メモリ上のどこにあるか（図） -->

## コンテキストスイッチ

<!-- switch_context。保存するのは ra と s0〜s11 だけ。なぜ s のレジスタだけで足りるのか。08 章の kernel_entry（31 個）との比較 -->

## 誰が誰に制御を渡すか

### 疑問：無限ループの関数が2つとも動くのはなぜか

`proc_a_entry` と `proc_b_entry` は、どちらも `putchar`、`switch_context`、`delay` を繰り返す無限ループ。それなのに、画面の表示が `A` と `B` で切り替わるのが不思議だった。

### proc_b_entry は誰も呼んでいない

`kernel_main` が呼んでいるのは `proc_a_entry()` だけ。コードのどこにも `proc_b_entry()` を呼ぶ行はない。それでも B が動くのは、`switch_context` の最後の `ret` が `proc_b_entry` に「戻った」から。

### CPU から見た「関数が動いている」とは

CPU は「今どの関数を実行中か」を覚えていない。持っているのは次の3つだけ。

| CPU が持っているもの | 意味 |
| --- | --- |
| `pc` | 次に実行する命令の番地 |
| `sp` | 今使っているスタック |
| `ra`、`s0`〜`s11` などのレジスタ | 計算途中の値、戻り先 |

「`proc_a_entry` のループの途中にいる」という状態は、この3つの値の組み合わせにすぎない。中でも大事なのが `sp`。スタックには「どの関数から呼ばれて、どこへ戻るか」の記録が積まれている。

### switch_context がやっていること

```
               procs[0].stack (A)        procs[1].stack (B)
               +------------------+      +------------------+
               | ...              |      | ...              |
               | A's saved state  |      | B's saved state  |
               | ra = A's return  |      | ra = B's return  |
               +------------------+      +------------------+
                        ^                         ^
                        |                         |
CPU sp  ----------------+   -- lw sp, (a1) -->    +
```

1. A の `ra` と `s0`〜`s11` を、A のスタックに保存する。これで A の「続きの状態」が A のスタックに残る。
2. `sp` を B のスタックに付け替える（`sw sp, (a0)` と `lw sp, (a1)`）。
3. B のスタックから `ra` と `s0`〜`s11` を読み戻す。
4. `ret` で `ra` の番地へ飛ぶ。そこは B が前に止まった場所の続き。初回だけは、`create_process` が仕込んだ `proc_b_entry` の先頭。

- CPU は「関数から戻った」つもりで `ret` を実行しているだけ。`sp` が付け替わっているので、戻った先が別のプロセスになる。
- A のループは止まったのではなく、A のスタックに「ここまで実行した」記録を残して凍結されている。B が `switch_context` を呼ぶと、A は続きから動き出す。
- 2つの無限ループが同時に動いているのではなく、1つの CPU が2本のスタックを交互に付け替えている。
- ただし、このテストでは A のスタックは `procs[0].stack` ではなく、`boot` が設定したスタック（`__stack_top` の下）だった（「観察結果」の `sp` の表示）。図の「A」は、A が使っているスタックと読み替える。

### 実行結果との対応

「観察結果」の出力は、この順で説明できる。

1. `kernel_main` が `proc_a_entry()` を直接呼ぶ。`starting process A` を出してから `A` を出す。
2. A が `switch_context` を呼ぶ。`ret` の行き先は B のスタックに仕込んだ `ra`（`proc_b_entry` の先頭）。B は初めて動くので `starting process B` を出す。`A` の直後で改行されずに続くのはこのため。
3. B が `B` を出して A に切り替える。A は前に `switch_context` を呼んだ直後（`delay()`）から再開し、ループを回って `A` を出す。
4. あとは 3. の繰り返しで `BABA...` と続く。

## create_process：最初の切り替えをどう成り立たせるか

<!-- 最初に ra を仕込んだスタックを作る理由 -->

## スケジューラ（yield）

```c
struct process *current_proc; // 現在実行中のプロセス
struct process *idle_proc;    // アイドルプロセス

void yield(void) {
    struct process *next = idle_proc;
    for (int i = 0; i < PROCS_MAX; i++) {
        struct process *proc = &procs[(current_proc->pid + i) % PROCS_MAX];
        if (proc->state == PROC_RUNNABLE && proc->pid > 0) {
            next = proc;
            break;
        }
    }
    if (next == current_proc)
        return;

    struct process *prev = current_proc;
    current_proc = next;
    switch_context(&prev->sp, &next->sp);
}
```

- 今のプロセスの次の枠から順に `procs` を見て、動かせるプロセスを探す（ラウンドロビン）。`pid` は枠の番号 + 1 なので、`procs[current_proc->pid]` は今のプロセスの次の枠。
- `pid > 0` で idle（pid 0）を候補から外し、ほかに動かせるプロセスがなければ idle に切り替える。
- 相手を自分で指定していた `switch_context(&proc_a->sp, &proc_b->sp)` の代わりに、`proc_a_entry` と `proc_b_entry` は `yield()` を呼ぶだけになった。
- プロセスが自分から `yield()` を呼ばない限り、切り替わらない（協調的マルチタスク）。
- 教材の `yield` には `sscratch` に書き込む行もあるが、「例外ハンドラの修正」とセットなので、ここではまだ書いていない。

`kernel_main` は、idle プロセスを作って `current_proc` にし、A と B を作ってから `yield()` を呼ぶ。`proc_a_entry()` を直接呼ぶ行はなくなった。

```c
idle_proc = create_process((uint32_t) NULL);
idle_proc->pid = 0; // idle
current_proc = idle_proc;

proc_a = create_process((uint32_t) proc_a_entry);
proc_b = create_process((uint32_t) proc_b_entry);

yield();
```

### 最初の yield で kernel_main はどうなるか（推論）

1. `kernel_main` が `yield()` を呼ぶ。`current_proc` は idle なので、`prev` = idle、`next` = A。
2. `switch_context(&idle_proc->sp, &proc_a->sp)` で、`kernel_main` の `sp`（`boot` のスタック上の位置）が `idle_proc->sp` に保存される。
3. `boot` のスタックが、そのまま idle プロセスのスタックになる。`create_process` が `procs[0].stack` に用意したスタックは、idle では使われない（前のテストの A と同じ構図）。

## 例外ハンドラの修正：なぜスタックポインタを設定し直すのか

08 章の `kernel_entry` は、例外が起きたときの `sp` をそのまま使ってレジスタを保存していた（`exception.md`）。その `sp` が壊れていると、保存の `sw` でまた例外が起きる。そこで、例外が起きたら、まず信用できるカーネルスタックに切り替えるように直した。

### yield：次のプロセスのカーネルスタックを sscratch に入れておく

```c
__asm__ __volatile__(
    "csrw sscratch, %[sscratch]\n"
    :
    : [sscratch] "r" ((uint32_t) &next->stack[sizeof(next->stack)])
);
```

切り替える直前に、次のプロセスの `stack` の上端を `sscratch` に入れておく。これで、どのプロセスの実行中に例外が起きても、`sscratch` を見ればそのプロセスのカーネルスタックが分かる。

### kernel_entry の流れ

```
 csrrw sp, sscratch, sp     sp と sscratch を入れ替える
                            sp = カーネルスタックの上端、sscratch = 例外前の sp
 addi sp, sp, -4 * 31       レジスタを保存（ra 〜 s11）
 csrr a0, sscratch          ┐ 例外前の sp を trap_frame の sp の欄に保存
 sw a0,  4 * 30(sp)         ┘
 addi a0, sp, 4 * 31        ┐ カーネルスタックの上端を sscratch に戻す
 csrw sscratch, a0          ┘ （次の例外に備える）
 mv a0, sp
 call handle_trap
 （レジスタを復元）
 lw sp,  4 * 30(sp)         例外前の sp に戻す
 sret
```

| | 08 章 | 10 章 |
| --- | --- | --- |
| 先頭の命令 | `csrw sscratch, sp`（例外前の `sp` を退避するだけ） | `csrrw sp, sscratch, sp`（カーネルスタックに切り替える） |
| レジスタを保存する場所 | 例外前の `sp` の下 | そのプロセスのカーネルスタック |
| 例外前の `sp` が壊れていたら | 保存の `sw` でまた例外になる | 影響を受けない（値として保存されるだけ） |

- `handle_trap` を呼ぶ前に `sscratch` をカーネルスタックの上端に戻すのは、`sscratch` には先頭の `csrrw` で例外前の `sp` が入っているから。戻しておかないと、次の例外で、壊れているかもしれない `sp` に切り替えてしまう。
- 最初に書いたときは、`csrr a0, sscratch` から `csrw sscratch, a0` までの2つのブロックを、レジスタの復元のあと（`sret` の直前）に置いていた。`lw sp` で例外前の `sp` に戻したあとに書き込むことになり、`a0` も壊すので、`handle_trap` の前に移した。
- 推論：今はカーネルの中（S-mode）で例外が起きるだけなので、`sp` が壊れるのは実験のときくらい。U-mode のアプリを動かすようになると、アプリの `sp` は信用できないので、この切り替えが欠かせなくなる。

## 観察結果

2026-11-22、ホストの Arch で観察。

### コンテキストスイッチのテスト（./run.sh）

`kernel_main` で `proc_a` と `proc_b` を `create_process` で作り、`proc_a_entry()` を直接呼んだ。

```
starting process A
Astarting process B
BABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB...
```

`ABAB...` が止まらず続くので、QEMU を止めて終了した。

### それぞれのプロセスの sp

`proc_a_entry` と `proc_b_entry` のループの中で、今の `sp` を表示した。

```c
uint32_t sp;
__asm__ __volatile__("mv %0, sp" : "=r"(sp));
printf("A sp=%x\n", sp);
```

```
A sp=802308c4
B sp=80204874
A sp=802308c4
B sp=80204874
...
```

`llvm-nm -S kernel.elf` で見た番地と比べた（`procs` は `0x8020_086c` から `0x10060` バイト。`struct process` 1つは `0x200c` バイトで、`stack` はその先頭から 12 バイト目から）。

| 範囲 | 番地 |
| --- | --- |
| `procs[0].stack` | `0x8020_0878`〜`0x8020_2878` |
| `procs[1].stack` | `0x8020_2884`〜`0x8020_4884` |
| `__stack_top`（`boot` が設定したスタックの上端） | `0x8023_08d4` |

読み取り：

- `sp` は A と B で交互に変わる。2本のスタックを付け替えていることが見えた。
- B の `0x8020_4874` は `procs[1].stack` の中。予想どおり。
- A の `0x8023_08c4` は `procs[0].stack` の中ではなく、`__stack_top` のすぐ下（`0x10` バイト下）。`boot` が設定したスタック（`kernel_main` が使っているスタック）だった。予想と違った。

A だけ自分のスタックを使っていない理由（推論）：

- B は `switch_context` の `ret` で始まった。そのとき `sp` は `procs[1].stack` に付け替わっていたので、B はずっとそのスタックで動く。
- A は `kernel_main` が `proc_a_entry()` を普通の関数として直接呼んだので、`sp` は `boot` のスタックのまま。`create_process` が `procs[0].stack` に仕込んだ `ra` は一度も使われていない。
- A が初めて `switch_context` を呼んだとき、`proc_a->sp` には「`boot` のスタック上の今の位置」が書き込まれ、最初に仕込んだ値は上書きされる。

`__stack_top` が 09 章の観察（`0x8022_0390`）から大きく動いたのは、`procs`（64KB 余り）が `.bss` に入り、その後ろのスタックが押し出されたため（`llvm-nm` の記号は `B`）。

### スケジューラ（yield）を入れたあとの sp

`kernel_main` から `yield()` で始めるように変えて、同じく `sp` を表示した。

```
starting process A
A sp=80204af8
starting process B
B sp=80206b04
A sp=80204af8
B sp=80206b04
...
```

`llvm-nm -S kernel.elf` では、`procs` は `0x8020_0af0` から始まっていた。

| 枠 | プロセス | `stack` の範囲 | 表示された `sp` |
| --- | --- | --- | --- |
| `procs[0]` | idle | `0x8020_0afc`〜`0x8020_2afc` | （表示なし） |
| `procs[1]` | A | `0x8020_2b08`〜`0x8020_4b08` | `0x8020_4af8` |
| `procs[2]` | B | `0x8020_4b14`〜`0x8020_6b14` | `0x8020_6b04` |

読み取り：

- A の `sp` は `procs[1].stack` の中に入った。前のテストでは `boot` のスタックだったが、`yield` の `switch_context` で始まるようになったので、自分のスタックで動く。
- A も B も、`sp` はスタックの上端からちょうど `0x10` バイト下。同じ形（`switch_context` の `ret` で入口に入る）で始まったので、同じ位置になった。
- idle が `procs[0]` を使うので、A と B は1枠ずつ後ろにずれた。
### sp を壊して unimp する実験

`proc_a_entry` の `printf("starting process A\n")` の直後に、次の2行を入れた。`sscratch` に A のカーネルスタックが入るのは `yield` で A に切り替えたあとなので、`kernel_main` ではなく `proc_a_entry` に入れた。

```c
__asm__ __volatile__(
    "li sp, 0xdeadbeef\n"  // sp をありえない番地にする
    "unimp\n"              // 例外を起こす
);
```

#### 10 章の kernel_entry（csrrw sp, sscratch, sp）

```
PANIC: kernel.c:196: unexpected trap scause=00000002, stval=00000000, sepc=80200332
```

```
$ llvm-objdump -d kernel.elf
8020032a: deadc137   lui  sp, 0xdeadc        ┐ li sp, 0xdeadbeef が
8020032e: eef10113   addi sp, sp, -0x111     ┘ 2 命令に分かれたもの
80200332: 0000       unimp                    ← sepc

$ llvm-addr2line -e kernel.elf 80200332
.../kernel.c:152
```

- `scause=2`（不正な命令）、`stval=0`（16 ビット版 `unimp` の中身）、`sepc` は実験で入れた `unimp`。08 章と同じ形で `PANIC` まで届いた。
- 先頭の `csrrw` で A のカーネルスタックに切り替わったので、壊れた `0xdeadbeef` には一度も書き込んでいない。
- `li sp, 0xdeadbeef` は `lui` と `addi` の 2 命令に分かれた。32 ビットの値は 1 命令に入らないので、上位 20 ビットと下位 12 ビットに分けて入れている（`0xdeadc000 - 0x111 = 0xdeadbeef`）。

#### 08 章の形に一時的に戻した場合（csrw sscratch, sp）

`kernel_entry` の先頭の1行だけを `csrw sscratch, sp` に戻して実行した。

- `./run.sh`：`starting process A` のあと何も出ず、固まったように見えた。
- 固まっている間に QEMU モニターの `info registers` を見ると、`pc 802003fe`、`scause 00000007`。
- `0x802003fe` は、`kernel_entry` ではなく `handle_trap` の `PANIC` の `while (1) {}`（`j 0x802003fe`）だった。

そこで、同じ `kernel.elf` を Claude が疑似端末（pty）で 150 秒動かした。

```
starting process A
（約 33 秒、何も出ない）
PANIC: kernel.c:196: unexpected trap scause=00000007, stval=88000000, sepc=80200422
```

| 値 | 読み方 |
| --- | --- |
| `scause=7` | ストアのアクセスフォールト。存在しない番地に書き込もうとした |
| `stval=88000000` | 書き込もうとした番地。RAM の終わり（`0x8800_0000`）のちょうど上 |
| `sepc=80200422` | `kernel_entry` の範囲にある命令（レジスタを保存する `sw` だと思われる） |

何が起きていたか（推論）：

```
sp = 0xdeadbeef で unimp
  -> kernel_entry: sp -= 124 -> sw で例外（scause=7）
  -> kernel_entry: sp -= 124 -> sw で例外
  -> ...（例外のたびに sp が 124 バイトずつ下がる）
  -> 約 1200 万回くり返して、sp が RAM の上端（0x8800_0000）付近まで下がる
  -> 保存先が RAM に収まり、handle_trap まで届いて PANIC
```

- 例外の処理を始めようとして、また例外が起きている。486 本でいうダブルフォールトに近い状況（`exception.md` の疑問）。RISC-V の S-mode には、それを捕まえる専用の仕組みは見当たらない（推論）。
- `0xdeadbeef` から RAM の上端までは約 1.4GB。124 バイトずつ下がると約 1200 万回で、それに約 33 秒かかった計算。
- 教材は「固まる」と書いている。30 秒待たずに止めれば、確かにそう見える。`sp` の値しだいでは本当に終わらないこともありそう（推論）。
- `PANIC` まで届いた時点で、`trap_frame` は RAM の一番上、デバイスツリーの置き場所（`0x87e0_0000`〜）を上書きしていると思われる（推論）。

## 次に試すこと

- [x] `proc_a_entry` と `proc_b_entry` のループの中で今の `sp` を表示し、A は `procs[0].stack`、B は `procs[1].stack` の範囲にあるか確かめる → B は予想どおり。A は `boot` のスタックだった（「それぞれのプロセスの sp」）
- [x] スケジューラ（`yield`）と idle プロセスを入れたあと、A も自分のスタックで動くようになるか、同じ方法で確かめる → idle が `procs[0]` を使い、A は `procs[1].stack` で動いた（「スケジューラ（yield）を入れたあとの sp」）
- [x] `sp` を壊して `unimp` を実行し、10 章と 08 章の `kernel_entry` を比べる → 10 章は `PANIC`、08 章は約 33 秒の入れ子の例外のあと `scause=7` で `PANIC`（「sp を壊して unimp する実験」）
- [ ] 08 章の形で、`sepc=80200422` が `kernel_entry` のどの `sw` かを逆アセンブルで確かめる
- [ ] 08 章の形で固まっている間に `info registers` を何回か見て、`sp` が減っていくことを確かめる
- [ ] QEMU モニターの `xp` で `idle_proc->sp`（`procs[0]` の先頭から 8 バイト目）を読み、`boot` のスタック（`__stack_top` の近く）の番地が入っているか確かめる
- [ ] QEMU モニターの `info registers` で `pc` と `sp` を何度か見て、2本のスタックを行き来していることを確かめる

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
