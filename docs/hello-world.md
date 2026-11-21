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

## 観察結果

<!-- 実行したコマンド（ホスト / QEMU モニター / 自作OSのシェルを区別）と出力 -->

## 次に試すこと

- [ ] 関数呼び出しが増えたあとの `sp` を `info registers` で見て、前の章（`__stack_top` から動いていなかった）と比べる
- [ ] 「S-mode の `ecall` は M-mode へ行く」ことが、`medeleg 00f4b509` のどこに表れているか確かめる（`riscv-intro.md` の宿題）

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
