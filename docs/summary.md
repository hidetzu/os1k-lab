# ここまでのまとめ（01〜17 章）

2026-11-21〜22 に、『1000行でOSを作ってみよう』（[OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/)）を全 17 章通した。各章のノートは [index.md](index.md) から辿れる。

- 環境：ホストは Arch Linux、clang / lld / LLVM 23.1.5、QEMU 11.1.3（同梱の OpenSBI v1.8.1）、32 ビット RISC-V の virt マシン（`setup-arch.md`）。
- 実験を再現できるコミット：教材の 16 章まで実装し、すべての観察を記録した時点は [`2e09668`](https://github.com/hidetzu/my-os/tree/2e09668)。この後、コードの配置の整理（`src/` への移動）と実験コードの片付けをした。各章の実装のコミットは「章ごとの到達点」の表。

## 最初の問いへの答え

問い：カーネルを誰がメモリに配置し、CPU はどうやって自分が書いた最初の命令に到達するのか。

- 置く番地を決めたのは自分で書いた `kernel.ld`（`. = 0x80200000`）。実際にメモリへ書き込んだのは QEMU（`-kernel kernel.elf`）。
- CPU は、QEMU が用意した MROM のリセットコードと、OpenSBI に渡す構造体（`fw_dynamic_info`）を経由して、番地とモードをリレーされて最初の命令（`boot`）に到達する。
- 同じ問いをアプリについても考えた。アプリの中身を物理メモリに置いたのは QEMU（カーネルの `.data` の一部として）、`0x0100_0000` で見えるように写して表に載せ、U-mode で最初の命令に飛ばしたのはカーネル。カーネルにとっての MROM と OpenSBI の役割を、アプリにとってはカーネルが担う。

```
 MROM (0x1000)                                         M-mode
   |  jr t0   (a0 = hartid, a1 = DTB 0x87e0_0000, a2 = fw_dynamic_info 0x1028)
   v
 OpenSBI (0x8000_0000)                                 M-mode
   |  mret   (mepc = next_addr = 0x8020_0000, MPP = S)
   v
 boot (0x8020_0000) -> kernel_main                     S-mode
   |  create_process(shell): copy pages, ra = user_entry
   |  yield -> switch_context -> ret
   v
 user_entry                                            S-mode
   |  sret   (sepc = USER_BASE = 0x0100_0000, SPP = U)
   v
 start (0x0100_0000) -> main (shell)                   U-mode
```

根拠：

- `llvm-objdump` で `boot` が `0x8020_0000` の先頭にあること、QEMU モニターの `xp /8i 0x1000`（MROM）、`xp /6wx 0x1028`（`fw_dynamic_info`）、`info registers` の `pc` と `priv S`（`boot.md`）。
- QEMU v11.1.3 のソース：ジャンプ先は ELF のエントリポイントではなく、読み込んだイメージの一番低い番地（`hw/riscv/boot.c`、`hw/riscv/virt.c`。`boot.md`）。`boot` を `.text` の先頭から外す実験で、`Domain0 Next Address` が一番低い番地のままになり、カーネルが起動しなくなることも確かめた（`boot.md` の「.text.boot を先頭から外す実験」）。
- OpenSBI の起動メッセージの `Domain0 Next Address : 0x80200000`、`Next Mode : S-mode`（`boot.md`）。
- アプリ側：`info mem` で `0x0100_0000` -> `0x8026_5000`（`u` 付き）、`xp /8i` の中身が `shell.elf` の命令と一致、`info registers` の `priv U`（`user-mode.md`）。

## 今回わかったこと

### モードの境界と、誰が例外を受け取るか

- RISC-V の CPU は M / S / U のモードを持ち、例外で上がり、`mret` / `sret` で下がる（`riscv-intro.md`）。
- `medeleg` のビット n が 1 なら、原因番号 n の例外は S-mode に委譲される。`0x00f4b509` は OpenSBI の `delegate_traps` が設定した値で、立てたビットを足すとちょうどこの値になる（`system-call.md`）。
  - U-mode の `ecall`（`scause` 8）：ビット 8 が 1 なのでカーネルへ。アプリのシステムコール。
  - S-mode の `ecall`（`scause` 9）：ビット 9 が 0 なので OpenSBI へ。カーネルの SBI 呼び出し。
  - 不正な命令（`scause` 2）：ビット 2 が 0 なので OpenSBI に届き、OpenSBI が `sbi_trap_redirect` でカーネルへ転送していた。カーネルからは委譲と区別がつかない（`exception.md`）。
- `sepc` は例外を起こした命令そのものを指す。`unimp` ではやり直せる形、`ecall` では OS が `sepc += 4` して次へ進める（`exception.md`、`system-call.md`）。

### ページテーブル

- Sv32 は 2 段の表で、仮想アドレスを 10 / 10 / 12 ビットに分ける。486 のページングとほぼ同じ骨格（`page-table.md`）。
- 表が指す先は 4KB 境界なので、下位 12 ビットは常に 0。`satp` と PTE は PPN（22 ビット）だけを持ち、空いたビットを印や `MODE` / `ASID` に使う。そのおかげで物理アドレスは 34 ビット（`page-table.md`）。
- `satp` から表を手でたどり、`0x8020_0000` が `0x8020_0000` に対応する（恒等マッピング）ことを確かめた（`page-table.md`）。
- PTE の `A` / `D` は、OpenSBI が `menvcfg.ADUE` を立て、QEMU が表を引くときに自動で立てる（Svadu）。`A` / `D` は PTE ごとに記録されるので、プロセスごとの表で違う値になる。`yield` が `procs[]` の全部の枠を読んだ跡まで `info mem` に表れた（`page-table.md`、`file-system.md`）。
- `U` の印を境に、U-mode はカーネルのページに、S-mode は（SUM が 0 なら）アプリのページに触れない。どちらもページフォールト（`scause` 15 と 13）になる（`user-mode.md`、`file-system.md`）。

### 例外の入口とスタック

- RISC-V の CPU は、例外のときスタックに触らず CSR に記録するだけ。保存は OS の `kernel_entry` が行う。486 は CPU がスタックに積む（`exception.md`）。
- `kernel_entry` の先頭の `csrrw sp, sscratch, sp` で、壊れているかもしれない `sp` を使わずにカーネルスタックへ切り替える。08 章の形に戻して `sp` を壊すと、入れ子の例外で `sp` が 124 バイトずつ下がり、約 33 秒後に RAM の上端に届いて `scause=7` で `PANIC` した（`process.md`）。

### プロセスとコンテキストスイッチ

- `switch_context` は `ra` と `s0`〜`s11` だけを保存し、`sp` を付け替えて `ret` する。`ret` の行き先が別のプロセスになる。Linux の `__switch_to` も同じ形で、486 の TSS によるハードウェアの切り替えは使っていない（`process.md`）。

### 機器とファイル

- virtio-blk のドライバで、カーネルが初めて機器を直接操作した。機器に渡す番地は物理アドレス（DMA）。QEMU 11.1.3 の virtio-mmio は既定でレガシー（`force-legacy = true`）（`virtio-blk.md`）。
- tar（ustar）をそのままファイルシステムとして使い、シェルの `writefile` で書いた内容を、ホストの `tar xf` で取り出せた（`file-system.md`）。

## 章ごとの到達点

| 章 | ノート | 実装のコミット | 確かめたこと |
| --- | --- | --- | --- |
| 01 開発環境 | [setup-arch.md](setup-arch.md) | ― | Arch のパッケージ、OpenSBI v1.8.1 |
| 02 RISC-V 入門 | [riscv-intro.md](riscv-intro.md) | ― | `info mtree` のメモリマップ、M / S / U |
| 03 OS の全体像 | [overview.md](overview.md) | ― | 作るもの / 作らないもの |
| 04 ブート | [boot.md](boot.md) | `9bb80e4` | `0x8020_0000` へのリレー |
| 05 Hello World! | [hello-world.md](hello-world.md) | `c9fa63c`、`8616116` | SBI、`printf`、`wfi` と CPU 使用率 |
| 06 C 標準ライブラリ | [libc.md](libc.md) | `8616116` | `.data` / `.bss`、`char` の符号 |
| 07 カーネルパニック | [kernel-panic.md](kernel-panic.md) | `9ffff6c` | `__LINE__`、到達しないコードの削除 |
| 08 例外処理 | [exception.md](exception.md) | `15460c2` | `sepc`、`stval` の出どころ |
| 09 メモリ割り当て | [memory-allocation.md](memory-allocation.md) | `e16b8d9` | `kernel.ld` の読み方、`alloc_pages` |
| 10 プロセス | [process.md](process.md) | `419f4c5` | `sp` の付け替え、`sscratch` |
| 11 ページテーブル | [page-table.md](page-table.md) | `e9a655d` | `satp` から表を手でたどる、`A` / `D` |
| 12 アプリケーション | [application.md](application.md) | `9d3983e` | `shell.bin` の埋め込み |
| 13 ユーザーモード | [user-mode.md](user-mode.md) | `da57c6c`、`df321b7` | `sret` で U-mode へ、`PAGE_U` の保護 |
| 14 システムコール | [system-call.md](system-call.md) | `e70c8c6` | `sepc += 4`、`medeleg` の答え |
| 15 ディスク読み書き | [virtio-blk.md](virtio-blk.md) | `228fc4e` | virtqueue、DMA |
| 16 ファイルシステム | [file-system.md](file-system.md) | `15824e0` | tar、SUM ビット |

## 訂正した理解

- 08 章で「`stval` は QEMU が `stval` に書く」と読んだが、実際は不正な命令は OpenSBI を経由しており、`stval` に書いたのは OpenSBI だった（14 章で訂正。`exception.md`）。
- 10 章のはじめのテストで、A は自分のカーネルスタックで動くと予想したが、`kernel_main` が直接呼んだので `boot` のスタックで動いていた（`process.md`）。
- 09 章で「ページテーブルは次の 10 章」と書いたが、正しくは 11 章（ノートからは削除済み）。

## 残った疑問

- `MIDELEG : 0x00001666`（割り込みの委譲）の意味（`riscv-intro.md`）。
- なぜカーネルの番地が `0x8020_0000` なのか。OpenSBI の範囲（〜`0x8004_ffff`）との差の理由（`boot.md`）。
- 協調的マルチタスクで、CPU を譲らないプロセスがいたらどうなるか。タイマー割り込みが要る理由（`overview.md`）。
- プリエンプティブにしたとき、`switch_context` の 13 個の保存で足りるか（`process.md`）。
- 486 の TSS の `esp0` は、`sscratch` のカーネルスタックと同じ役割か（`process.md`）。
- `csrw satp` の前にも `sfence.vma` を置く理由（`page-table.md`）。

## 次に試すこと

- [ ] OpenSBI の代わりに、M-mode で起動する小さなファームウェアを自分で書き、`-bios` に渡す（ブートローダーへの興味の本丸。`boot.md` の「次に掘るところ」）
- [ ] 割り込みとタイマーを実装し、プリエンプティブなマルチタスクにする
- [ ] xv6（RISC-V 版）や HinaOS を読み、この OS と比べる（教材の 17 章の勧め）
- [ ] `qemu.log` で、`unimp` のときに M-mode の例外が起きていることを見る（`exception.md`）
- [ ] `satp` が B の表に変わるのを見る、`info mem` で A / D の付き方が入れ替わるのを見る（`page-table.md`）
- [ ] 仕様の `sret` と `sstatus`、`scause` の表を読む（`user-mode.md`）
- [ ] 486 本の第 10 章（セキュリティ、特権レベルとスタック切り替え）を読む（`process.md`）

各章の「次に試すこと」には、ほかにも細かい宿題が残っている。
