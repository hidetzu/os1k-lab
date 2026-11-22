# 14 システムコール

教材：[システムコール | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/14-system-call)

## この章で答えたい問い

<!-- 例：U-mode のアプリは、どうやってカーネルに仕事を頼み、どうやって元の場所へ戻ってくるのか -->

## どこから入り、どこへ戻るか

```
 app (U-mode)                       kernel (S-mode)
 printf -> putchar('H')
   -> syscall: a3 = SYS_PUTCHAR, a0 = 'H'
   -> ecall (address X)  ------------> kernel_entry (stvec)
                                         save registers to trap_frame
                                       handle_trap
                                         scause == 8 (ecall from U)
                                         handle_syscall(f): f->a3 -> putchar(f->a0)
                                         user_pc = sepc + 4   (= X + 4)
                                         sepc = user_pc
                                       kernel_entry: restore registers, sret
   next instruction (X + 4) <---------
```

1 文字出すたびに、2 段の `ecall` を通っている。05 章の「1 文字ごとに M-mode と行き来する」（`hello-world.md`）と同じことが、U-mode と S-mode の間でも起きる。

```
 app (U-mode)    -- ecall -->   kernel (S-mode)    -- ecall -->   OpenSBI (M-mode)
   putchar('H')                   handle_syscall                    write 'H' to UART
                                   -> putchar -> sbi_call
```

## システムコール呼び出し関数（ユーザーランド側）

`common.h` にシステムコールの番号を、`user.c` に呼び出し関数を足した。

```c
// common.h
#define SYS_PUTCHAR 1
```

```c
// user.c
int syscall(int sysno, int arg0, int arg1, int arg2) {
  register int a0 __asm__("a0") = arg0;
  register int a1 __asm__("a1") = arg1;
  register int a2 __asm__("a2") = arg2;
  register int a3 __asm__("a3") = sysno;

  __asm__ __volatile__("ecall"
                       : "=r"(a0)
                       : "r"(a0), "r"(a1), "r"(a2), "r"(a3)
                       : "memory");

  return a0;
}

void putchar(char ch) { syscall(SYS_PUTCHAR, ch, 0, 0); }
```

- `syscall` がやっているのは、「決めたレジスタに値を入れて `ecall` を実行し、`a0` を戻り値として受け取る」ことだけ。
- `putchar` は、`SYS_PUTCHAR` の番号と文字を渡して `syscall` を呼ぶ。12 章では空だった（`application.md`）。
- 番号を `common.h` に置くのは、アプリ（`user.c`）とカーネル（`handle_syscall`）の両方が同じ番号を使うため。

### 05 章の sbi_call との比較

| | 05 章の `sbi_call`（カーネル -> OpenSBI） | 14 章の `syscall`（アプリ -> カーネル） |
| --- | --- | --- |
| 呼ぶ側のモード | S-mode | U-mode |
| 番号を入れるレジスタ | `a7`（EID）、`a6`（FID） | `a3`（`sysno`） |
| 引数 | `a0`〜`a5` | `a0`〜`a2` |
| 戻り値 | `a0`（error）、`a1`（value） | `a0` |
| 命令 | `ecall` | `ecall` |
| 受け取る側 | OpenSBI（M-mode） | `kernel_entry` -> `handle_trap`（S-mode） |

- どのレジスタに何を入れるかは、呼ぶ側と受け取る側の約束でしかない。SBI は仕様で約束を決めていて（`hello-world.md`）、この OS のシステムコールは教材が独自に決めた約束。
- register 変数とインラインアセンブリの書き方は、`sbi_call` と同じ（`hello-world.md` の「register 変数とインラインアセンブリ」）。

### ecall 自体がしていること

- `ecall` は「今のモードより上のモードへ、例外として入る」命令。08 章の `unimp` と同じく例外を起こすが、`scause` には「どのモードからの `ecall` か」を表す番号が入る。
- 呼ぶ側は、`ecall` のあとに何が起きるかを知らない。実際の仕事は、受け取る側（この章ではカーネルの `handle_syscall`）がする。この章の大部分は、受け取る側を作る話。

## 例外ハンドラの更新

```c
// kernel.h
#define SCAUSE_ECALL 8
```

```c
// kernel.c
void handle_trap(struct trap_frame *f) {
  uint32_t scause = READ_CSR(scause);
  uint32_t stval = READ_CSR(stval);
  uint32_t user_pc = READ_CSR(sepc);

  if (scause == SCAUSE_ECALL) {
    handle_syscall(f);
    user_pc += 4;
  } else {
    PANIC("unexpected trap scause=%x, stval=%x, sepc=%x\n", scause, stval,
          user_pc);
  }

  WRITE_CSR(sepc, user_pc);
}
```

- `scause` が 8（U-mode からの `ecall`）なら `handle_syscall` を呼ぶ。それ以外は今までどおり `PANIC`。
- `handle_trap` の引数 `f`（`trap_frame`）が、ここで初めて使われる。08 章からずっと出ていた `unused parameter 'f'` の警告がなくなる。

### sepc を 4 進める理由

最初は `user_pc += 4;` を書き忘れて、`H` が止まらずに出続けた（「観察結果」）。

```
ecall at address X        <- sepc points here (the instruction that raised the exception)
next instruction at X+4   <- user_pc += 4 returns here
```

- 08 章で確かめたとおり、`sepc` は例外を起こした命令そのものを指す（`exception.md`）。`unimp` のような、やり直したいフォールトには都合がよい。
- `ecall` は「頼みごとをしたら次へ進みたい」命令。戻る前に `sepc` を次の命令へ進めないと、`sret` で同じ `ecall` に戻り、もう一度システムコールが起きる。
- `user_pc += 4` で次の命令を取りにいく。アプリから見ると、`ecall` が普通の関数呼び出しのように「実行して、次へ進む」動きになる。
- `ecall` は 4 バイトの命令。圧縮命令（2 バイト）の `ecall` はないので、いつも 4 で済む（一般知識）。
- 486 本の分類では、`ecall` はトラップ（`INT` 命令の仲間）。486 ではトラップは CPU が自動で次の命令から再開するが、RISC-V では OS が自分で `sepc` を進める（`exception.md` の「トラップ・フォールト・アボートの違い」）。

## システムコールハンドラ

```c
void handle_syscall(struct trap_frame *f) {
  switch (f->a3) {
  case SYS_PUTCHAR:
    putchar(f->a0);
    break;
  default:
    PANIC("unexpected syscall a3=%x\n", f->a3);
  }
}
```

- `trap_frame` の `a3`（システムコールの番号）で振り分ける。引数は `a0` にある。
- 例外が起きた瞬間のレジスタは、`kernel_entry` が `trap_frame` に保存している（`process.md`）。アプリが `ecall` の前に `a0`〜`a3` に入れた値を、カーネルはここから読む。
- `SYS_PUTCHAR` のとき、カーネルの `putchar`（`sbi_call` で OpenSBI に頼む）を呼ぶ。

## 文字入力システムコール（getchar）

```c
// common.h
#define SYS_GETCHAR 2

// user.c / user.h
int getchar(void) { return syscall(SYS_GETCHAR, 0, 0, 0); }
```

```c
// kernel.c
long getchar(void) {
  struct sbiret ret = sbi_call(0, 0, 0, 0, 0, 0, 0, 2);
  return ret.error;
}

void handle_syscall(struct trap_frame *f) {
  switch (f->a3) {
  ...
  case SYS_GETCHAR:
    while (1) {
      long ch = getchar();
      if (ch >= 0) {
        f->a0 = ch;
        break;
      }
      yield();
    }
    break;
  ...
```

### カーネルの getchar は SBI のレガシー拡張の EID 2

- 05 章で使った EID 1（Console Putchar）の隣の、EID 2（Console Getchar）。入力がなければ -1 が返る（一般知識）。
- レガシー拡張では読んだ文字が `a0` に返るので、`sbiret` の `error`（`a0`）の欄から取り出している。手元の OpenSBI には `legacy` 拡張がある（`hello-world.md`）。

### f->a0 = ch がアプリの戻り値になる

```
kernel:  f->a0 = ch;               write to the a0 slot of trap_frame
  |
kernel_entry: "lw a0, 4 * 10(sp)"  restore a0 from trap_frame
  | sret
app:     syscall's "=r"(a0)        receives a0 as the return value
```

- `trap_frame` は、例外が起きた瞬間のアプリのレジスタの控え。カーネルがそこに書き込むと、戻ったときにアプリのレジスタの値が変わる。カーネルは、こうしてアプリに値を返す。

### 入力がないときの yield

- 入力がなければ `yield()` して、ほかのプロセスに CPU を譲る。
- 推論：今動かせるプロセスはシェルだけなので、`yield` は「自分以外に動かせるプロセスがない」と判断してすぐ戻る（`if (next == current_proc) return;`）。今は実質、キーが押されるまで回り続ける待ち方。

## シェル

```c
#include "user.h"

void main(int argc, char *argv[]) {

  while (1) {
  prompt:
    printf("> ");
    char cmdline[128];
    for (int i = 0;; i++) {
      char ch = getchar();
      putchar(ch);
      if (i == sizeof(cmdline) - 1) {
        printf("command line too long\n");
        goto prompt;
      } else if (ch == '\r') {
        printf("\n");
        cmdline[i] = '\0';
        break;
      } else {
        cmdline[i] = ch;
      }
    }

    if (strcmp(cmdline, "hello") == 0)
      printf("Hello world from shell!\n");
    else if (strcmp(cmdline, "exit") == 0)
      exit();
    else
      printf("unknown command: %s\n", cmdline);
  }
}
```

- `> ` を出し、`getchar` で 1 文字ずつ読んで `cmdline` に貯める。
- Enter で入ってくるのは `\n` ではなく `\r`。`\r` で 1 行の終わりと判断する。
- 読んだ文字は、シェルが自分で `putchar(ch)` で出し直している（エコーバック）。推論：`-nographic` の QEMU は入力をそのままゲストに渡すだけなので、出し直さないと打った文字が見えない。
- 06 章で書いた `strcmp` を、ここで初めて使う（`libc.md`）。

1 文字打つたびに起きていること：

```
getchar()   -- ecall -->  kernel: read 1 char via SBI (yield and retry if none)
                           f->a0 = ch
            <-- sret --
putchar(ch) -- ecall -->  kernel: write 1 char via SBI (echo back)
            <-- sret --
```

## プロセスの終了（exit）

```c
// common.h
#define SYS_EXIT 3

// kernel.h
#define PROC_EXITED 2

// user.c
__attribute__((noreturn)) void exit(void) {
  syscall(SYS_EXIT, 0, 0, 0);
  for (;;)
    ;
}

// kernel.c の handle_syscall
  case SYS_EXIT:
    printf("process %d exited\n", current_proc->pid);
    current_proc->state = PROC_EXITED;
    yield();
    PANIC("unreachable");
```

- アプリの `exit` は、`SYS_EXIT` のシステムコールを呼ぶ。戻ってくることはないはずだが、念のため無限ループを残している。
- カーネルは、状態を `PROC_EXITED` にして `yield` する。`yield` は `PROC_RUNNABLE` のプロセスしか選ばないので、終わったプロセスには二度と戻らない。`handle_syscall` の `PANIC("unreachable")` には到達しない。
- 教材によると、終わったプロセスの管理構造体やページテーブル、メモリは解放せず、印を付けるだけ。

### 最後に idle に戻って PANIC する理由

```
shell:  exit() -> ecall
kernel: handle_syscall SYS_EXIT
          state = PROC_EXITED
          yield(): no RUNNABLE process with pid > 0 -> next = idle
          switch_context to idle
idle:   returns from the first yield() (inside kernel_main)
          -> the next line: PANIC("unreachable here!")
```

- idle は、`kernel_main` が最初に `yield()` を呼んだところで止まっていた（`boot` のスタックをそのまま使っている。`page-table.md`、`process.md`）。動かせるプロセスがなくなって idle に戻ると、`kernel_main` の `yield()` の次の行に進み、そこの `PANIC` に当たる。
- 教材の `PANIC` のメッセージは `switched to idle process`。自分のコードは 10 章のときの `unreachable here!` のまま。同じ場所の `PANIC` で、メッセージが違うだけ。実際には到達する行なので、教材のメッセージのほうが実態に合っている。

## medeleg：ecall はどのモードに届くか

02 章から持ち越していた宿題（`riscv-intro.md`、`hello-world.md`）を、2026-11-22 に解いた。

### scause の番号

特権仕様の `scause` の値の表で調べた。

| 原因 | `scause` |
| --- | --- |
| Environment call from U-mode（U-mode からの `ecall`） | 8 |
| Environment call from S-mode（S-mode からの `ecall`） | 9 |

`kernel.h` の `SCAUSE_ECALL` が 8 なのは、アプリからのシステムコールを受け取るため。

### medeleg のビット 8 と 9

`medeleg` のビット n が 1 なら、原因の番号 n の例外を、M-mode ではなく S-mode に任せる（委譲する）。

```
MEDELEG = 0x00f4b509
0x509 = 0101 0000 1001
        ^^^^
        bit 11 10 9 8
         0  1  0  1
               ^  ^
           bit 9  bit 8
             = 0    = 1
```

| 原因 | `scause` | `medeleg` のビット | 届く先 |
| --- | --- | --- | --- |
| U-mode からの `ecall` | 8 | 1（委譲する） | S-mode：カーネルの `kernel_entry` |
| S-mode からの `ecall` | 9 | 0（委譲しない） | M-mode：OpenSBI |

観察とも合う：

1. アプリの `ecall` は、ビット 8 が 1 なので S-mode に委譲され、カーネルの `kernel_entry` に届いた。`handle_trap` で `scause` が 8 になったのはこのため。
2. カーネルの `sbi_call` の `ecall` は、ビット 9 が 0 なので M-mode の OpenSBI に届く。もし S-mode に届いていたら、`handle_trap` が `scause=9` を想定外として `PANIC` していたはず。文字がちゃんと出ているのが、M-mode に届いている証拠。

同じ `ecall` 命令でも、どのモードから実行したかで `scause` の番号が変わる。そして `medeleg` のビットで、どのモードが受け取るかが決まる。

### medeleg を設定しているのは OpenSBI（OpenSBI v1.8.1 のソース）

[`lib/sbi/sbi_hart.c` L212-L249](https://github.com/riscv-software-src/opensbi/v1.8.1/lib/sbi/sbi_hart.c#L212-L249) の `delegate_traps`：

```c
/* Send M-mode interrupts and most exceptions to S-mode */
...
exceptions = (1U << CAUSE_MISALIGNED_FETCH) | (1U << CAUSE_BREAKPOINT) |
             (1U << CAUSE_USER_ECALL);
if (sbi_platform_has_mfaults_delegation(plat))
    exceptions |= (1U << CAUSE_FETCH_PAGE_FAULT) |
                  (1U << CAUSE_LOAD_PAGE_FAULT) |
                  (1U << CAUSE_STORE_PAGE_FAULT) |
                  (1U << CAUSE_SW_CHECK_EXCP);
if (misa_extension('H')) {
    exceptions |= (1U << CAUSE_VIRTUAL_SUPERVISOR_ECALL);
    ... (guest page faults etc.)
}
csr_write(CSR_MEDELEG, exceptions);
```

立てているビットを足すと、ちょうど `0x00f4b509` になる。

| ビット | 原因 | 足した値 |
| --- | --- | --- |
| 0、3 | 命令の番地がずれている、ブレークポイント | `0x9` |
| 8 | U-mode からの `ecall` | `0x100` |
| 10 | VS-mode からの `ecall`（H 拡張） | `0x400` |
| 12、13、15 | 命令、読み込み、書き込みのページフォールト | `0xb000` |
| 18 | ソフトウェアチェック | `0x4_0000` |
| 20〜23 | ゲストのページフォールトなど（H 拡張） | `0xf0_0000` |
| 合計 | | `0x00f4_b509` |

- 起動メッセージの `Boot HART Base ISA : rv32imafdch` に `h` があるので、H 拡張の分も足されている。
- ビット 9（S-mode からの `ecall`）は立てていない。S-mode からの `ecall` は、OpenSBI 自身が SBI の呼び出しとして受ける（[`sbi_trap.c` L342-L344](https://github.com/riscv-software-src/opensbi/v1.8.1/lib/sbi/sbi_trap.c#L342-L344) の `CAUSE_SUPERVISOR_ECALL` -> `sbi_ecall_handler`）。
- OpenSBI は、起動時に `medeleg` をこの値に設定して、「アプリのシステムコールはカーネルに任せ、カーネルからの SBI 呼び出しは自分で受ける」という分担を作っている。
- ビット 2（不正な命令）も立てていない。08 章の `unimp` がどう届いたかは `exception.md` の「medeleg：例外はどのモードに届くか」。
- 13 章の動作テストの `scause=15`（ストアのページフォールト）は、ビット 15 が 1 なので、委譲されてカーネルに直接届いた（`user-mode.md`）。

## 観察結果

2026-11-22、ホストの Arch で観察。

### システムコールのテスト（./run.sh）

`shell.c` の `main` を `printf("Hello World from shell!\n");` だけにして動かした。13 章で入れた、カーネルの番地に書き込む行は外した。

`user_pc += 4;` を書き忘れていたとき：

```
HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH...
```

- `printf` の最初の `putchar('H')` で `ecall` し、カーネルが `H` を出したあと、`sepc` を進めずに同じ `ecall` に戻った。そのため、`H` のシステムコールが繰り返され、次の文字へ進めなかった。

`user_pc += 4;` を足したあと：

```
Hello World from shell!
```

- `printf` が 1 文字ごとに `putchar` -> `ecall` を繰り返し、そのたびにカーネルで 1 文字出して、次の命令へ進んだ。
- `main` から戻ったあとは、`start` が `call exit` で `exit` に入る。`exit` はまだ無限ループするだけなので、そこで止まる。

### シェル（./run.sh）

`getchar`、シェル、`exit` まで入れて動かした。Claude が疑似端末（pty）から `hello`、`foo`、`exit` を打ち込んで確かめた結果も同じ。

```
> hello
Hello world from shell!
> foo
unknown command: foo
> exit
process 2 exited
PANIC: kernel.c:397: unreachable here!
```

`process 2 exited`：シェルの pid が 2 である理由。`create_process` は、`procs[]` の何番目の枠かで `pid = i + 1` を付ける。

| 枠 | 作った順 | pid |
| --- | --- | --- |
| `procs[0]` | idle | 1 が付いたあと、`kernel_main` で 0 に書き換え |
| `procs[1]` | シェル | 2 |

`PANIC: kernel.c:397: unreachable here!`：動かせるプロセスがなくなって idle に戻り、`kernel_main` の `yield()` の次の行の `PANIC` に当たった（「最後に idle に戻って PANIC する理由」）。教材の出力例は `PANIC: kernel.c:333: switched to idle process` で、行番号とメッセージ以外は同じ。

## 次に試すこと

- [x] `kernel_main` の最後の `PANIC` のメッセージを、教材と同じ `switched to idle process` に直すか決める → 直した（`kernel.c` の 397 行目）
- [x] `medeleg` の宿題：U-mode の `ecall` と S-mode の `ecall` の `scause` の番号を調べ、`MEDELEG 0x00f4b509` のそのビットを確かめる → 8 と 9。ビット 8 は 1、ビット 9 は 0（「medeleg：ecall はどのモードに届くか」）

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
