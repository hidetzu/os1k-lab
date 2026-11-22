# 02 RISC-V入門

教材：[RISC-V入門 | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/02-assembly)

## QEMU と virt マシン

QEMU は CPU だけでなく、CPU・メモリ・周辺機器を載せた「ボード」を丸ごとエミュレートする。どのボードにするかを `-machine` で選び、`virt` はその一つ。

`virt` は実在するボードを模したものではなく、仮想環境専用のシンプルなボード。RISC-V の実機は製品ごとに周辺機器や番地が違うため、教材は `virt` を使って実機固有の事情を避けている。

```
qemu-system-riscv32 -machine virt ...
└─ CPU の種類      : 32ビット RISC-V
└─ ボード（machine）: virt
     ├─ RAM
     ├─ UART（シリアル）
     ├─ 割り込みコントローラ（PLIC / CLINT）
     ├─ virtio デバイス（ディスクなど）
     └─ 小さな ROM（MROM）
```

## virt のメモリマップ

出典：QEMU v11.1.3 の [`hw/riscv/virt.c` L85-L107 `virt_memmap[]`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/virt.c#L85-L107)（主なものを抜粋）

| 番地 | 名前 | 内容 |
| --- | --- | --- |
| `0x0000_1000` | MROM | リセット直後に CPU が最初の命令を取りに行く小さな ROM |
| `0x0200_0000` | CLINT | タイマ・ソフトウェア割り込み |
| `0x0c00_0000` | PLIC | 外部割り込みコントローラ |
| `0x1000_0000` | UART0 | シリアル。ここに書くと文字が出る |
| `0x1000_1000` | VIRTIO | virtio-mmio デバイス |
| `0x8000_0000` | DRAM | RAM の先頭。OpenSBI が置かれる |
| `0x8020_0000` | （DRAM 内） | 教材のカーネルが置かれる番地（教材のリンカスクリプトより） |

> 上の表はソースと教材から読んだもの。番地の割り当ては下の「観察結果：`info mtree -f`」で実機（QEMU）でも確認した。`0x8020_0000` は教材の記述で、まだ確認していない。

## 「誰がカーネルをメモリに置くのか」を追うためのソース

実機ではブートローダーの仕事だが、`virt` では QEMU 自身が担っている部分がある。読む場所の目印（いずれも QEMU v11.1.3）：

| 何が書いてあるか | 場所 |
| --- | --- |
| マシン起動準備の本体 | [`hw/riscv/virt.c` L1203 `virt_machine_done()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/virt.c#L1203) |
| ファームウェア（OpenSBI）を探して読み込む | [`hw/riscv/boot.c` L153 `riscv_find_and_load_firmware()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L153) |
| カーネルを読み込む番地を決める | [`hw/riscv/boot.c` L94 `riscv_calc_kernel_start_addr()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L94) |
| `-kernel` で渡したファイルを読み込む | [`hw/riscv/boot.c` L266 `riscv_load_kernel()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L266) |
| MROM にリセット直後のコードを書き込む | [`hw/riscv/boot.c` L483 `riscv_setup_rom_reset_vec()`](https://github.com/qemu/qemu/blob/v11.1.3/hw/riscv/boot.c#L483) |

## QEMU モニターの `info mtree`

QEMU が内部で組み立てたメモリの構成（MemoryRegion の木）を表示するコマンド。「どの番地に何があるか」を、ソースではなく実際に動いている QEMU から確かめられる。

### モニターへの入り方

教材の起動スクリプトのように `-serial mon:stdio` を付けて起動すると、1つの端末でシリアルとモニターを切り替えられる。

| 操作 | 結果 |
| --- | --- |
| `Ctrl-A` → `C` | シリアル ⇔ モニター（`(qemu)` プロンプト）を切り替える |
| `Ctrl-A` → `X` | QEMU を終了する |

### オプション

手元の QEMU 11.1.3 の `help info mtree` の出力：

```
info mtree [-f][-d][-o][-D] -- show memory tree (-f: dump flat view for address spaces;-d: dump dispatch tree, valid with -f only);-o: dump region owners/parents;-D: dump disabled regions
```

| コマンド | 見えるもの |
| --- | --- |
| `info mtree` | 領域の木構造。コンテナの中に RAM、ROM、デバイスがどう入れ子になっているか |
| `info mtree -f` | 平坦化したビュー。重なりや優先度を解決した後の、**CPU から実際に見える**番地の並び。上のメモリマップ表と比べるならこちら |
| `info mtree -o` | 各領域を作ったデバイス（owner）も表示する |

### 読むときの注意

- 表示されるのは QEMU 側のモデル。OS が起動時に受け取るデバイスツリーとは別物（中身は対応しているはず）。
- 表示されるのは番地の割り当てだけで、メモリの中身ではない。中身を見るには、モニターの `xp` コマンドを使う（例：`xp /8i 0x1000` で MROM の先頭を逆アセンブルする）。
- x86 との比較（I/O ポートの保護は『はじめて読む486』6.2 の IOPL p.203、10.2 の I/O 許可マップ p.362 を参照）：x86 にはメモリ空間とは別に `in`/`out` 命令で使う I/O 空間がある。RISC-V にはそれがなく、UART などのデバイスもメモリと同じ番地空間に置かれる（メモリマップドI/O）。`info mtree` に出てくる `i/o` という種別は「デバイスが処理する領域」という意味で、x86 の I/O 空間とは別のもの。

## 観察結果：`info mtree -f`

2026-11-21、手元の Arch Linux / QEMU 11.1.3 で観察。カーネルは指定していない。

```bash
# ホストの Arch
qemu-system-riscv32 -machine virt -nographic
```

起動後、`Ctrl-A` → `c` でモニターに切り替えて実行した。

```
(qemu) info mtree -f
FlatView #0
AS "gpex-root", root: bus master container
Root memory region: (none)
No rendered FlatView

FlatView #1
AS "memory", root: system
AS "cpu-memory-0", root: system
Root memory region: system
0000000000001000-000000000000ffff (prio 0, rom): riscv_virt_board.mrom
0000000000100000-0000000000100fff (prio 0, i/o): riscv.sifive.test
0000000000101000-0000000000101023 (prio 0, i/o): goldfish_rtc
0000000002000000-0000000002003fff (prio 0, i/o): riscv.aclint.swi
0000000002004000-000000000200bfff (prio 0, i/o): riscv.aclint.mtimer
0000000003000000-000000000300ffff (prio 0, i/o): gpex_ioport_window
000000000c000000-000000000c5fffff (prio 0, i/o): riscv.sifive.plic
0000000010000000-0000000010000007 (prio 0, i/o): serial
0000000010001000-00000000100011ff (prio 0, i/o): virtio-mmio
0000000010002000-00000000100021ff (prio 0, i/o): virtio-mmio
0000000010003000-00000000100031ff (prio 0, i/o): virtio-mmio
0000000010004000-00000000100041ff (prio 0, i/o): virtio-mmio
0000000010005000-00000000100051ff (prio 0, i/o): virtio-mmio
0000000010006000-00000000100061ff (prio 0, i/o): virtio-mmio
0000000010007000-00000000100071ff (prio 0, i/o): virtio-mmio
0000000010008000-00000000100081ff (prio 0, i/o): virtio-mmio
0000000010100000-0000000010100007 (prio 0, i/o): fwcfg.data
0000000010100008-0000000010100009 (prio 0, i/o): fwcfg.ctl
0000000010100010-0000000010100017 (prio 0, i/o): fwcfg.dma
0000000020000000-0000000021ffffff (prio 0, romd): virt.flash0
0000000022000000-0000000023ffffff (prio 0, romd): virt.flash1
0000000030000000-000000003fffffff (prio 0, container): pcie-mmcfg-mmio
0000000040000000-000000007fffffff (prio 0, container): gpex_mmio_window @0000000040000000
0000000080000000-0000000087ffffff (prio 0, ram): riscv_virt_board.ram
0000000300000000-00000003ffffffff (prio 0, container): gpex_mmio_window @0000000300000000

FlatView #2
AS "I/O", root: io
Root memory region: io
0000000000000000-000000000000ffff (prio 0, container): io
```

### 読み取り

AS（AddressSpace）は「誰の立場でメモリにアクセスするか」という視点。FlatView は領域の木を平らにした結果で、root が同じ AS どうしは同じ FlatView を共有する。

| FlatView | AS | 意味 |
| --- | --- | --- |
| #0 | `gpex-root` | PCIe ホストブリッジ（gpex）配下のデバイスが DMA するときの視点。PCI デバイスがないので空 |
| **#1** | **`memory`, `cpu-memory-0`** | **システム全体と CPU（hart 0）の視点。root が同じ `system` なので同じビュー。メモリマップ表と比べるのはこれ** |
| #2 | `I/O` | QEMU 共通の I/O 空間（x86 の `in`/`out` 用の仕組み）。RISC-V の CPU 命令からは届かず、空のコンテナ |

観察したこと：

- メモリマップ表の番地（MROM、CLINT、PLIC、UART0、VIRTIO、DRAM）は、ソースの `virt_memmap[]` と一致した。
- CLINT は `riscv.aclint.swi`（ソフトウェア割り込み）と `riscv.aclint.mtimer`（タイマ）の2つに分かれて見える。
- `serial` の領域は `0x1000_0000`〜`0x1000_0007` の8バイト。ソースの確保サイズは `0x100`。
- RAM は `0x8000_0000`〜`0x87ff_ffff` の128MiB（`-m` 未指定）。
- 種別は `rom`、`ram`、`i/o`（デバイスが処理する領域）、`romd`（フラッシュ）、`container`（入れ物）。
- `virtio-mmio` は `0x1000_1000` から8個並んでいる。

推論（未検証）：

- `serial` が8バイトなのは、16550 互換 UART のレジスタ8個分だからだと思われる。
- `0x8020_0000`（教材のカーネルの番地）が出てこないのは、それが RAM の中の1点にすぎず、配線の区切りではないから。カーネルがどこに置かれるかは配線ではなく中身の話で、`xp` で見る必要がある。
- FlatView #2 は x86 向けの仕組みが QEMU の共通部分として残っているもの。

## CPU の動作モード（M / S / U）

M/S/U は CPU（各 hart）が持っている「今の権限」という状態。メモリやプログラムの属性ではない。

| モード | 名前 | ここで動くもの |
| --- | --- | --- |
| M | Machine | OpenSBI（ファームウェア）。最も権限が強い |
| S | Supervisor | カーネル |
| U | User | アプリケーション |

### カーネル空間 / ユーザ空間との違い

- S/U-mode：CPU が今どの権限で命令を実行しているか（CPU の状態）
- カーネル空間 / ユーザ空間：メモリのどの範囲を誰が触れるか（アドレス空間の区分け）

ふつうは OS が両者を対応させる。ページテーブルで「この範囲は S-mode からしか触れない」と決めることで、カーネル空間ができる（ページングの章で扱う）。

### OpenSBI

- **SBI**（Supervisor Binary Interface）：S-mode の OS が M-mode のファームウェアにサービスを頼むときの呼び出し方を決めた仕様。
- **OpenSBI**：SBI の代表的な実装。M-mode で動くファームウェア。

役割は2つ。

1. **起動時**：最初に M-mode で動き、ハードウェアやモードの境界（委譲の設定など）を初期化してから、S-mode に降りて次の段階へジャンプする。
2. **常駐**：起動後もメモリに残る。OS が `ecall` で呼ぶと、文字出力・タイマ設定・再起動などを M-mode で代わりに実行する。教材の「Hello World!」ではこれで文字を出す。

```
        M-mode │ OpenSBI ──(初期化して S-mode へ)──┐      ┌─ サービス実行 ─┐
               │                                   │      ▲               │
───────────────┼───────────────────────────────────┼──────┼───────────────┼───
        S-mode │                                   └─▶ カーネル ──ecall──┘  ◀─ 戻る
───────────────┼───────────────────────────────────────────────────────────────
        U-mode │                                       アプリ（あとの章）
```

### モードが切り替わる場面

| 方向 | きっかけ | 例 |
| --- | --- | --- |
| 上がる（U→S、S→M） | トラップ（例外・割り込み・`ecall`） | カーネルが `ecall` で OpenSBI を呼ぶ |
| 下がる（M→S、S→U） | `mret` / `sret` 命令 | OpenSBI が初期化を終えてカーネルへ |

- プログラムが自分で権限を上げる方法はない。だから保護が成り立つ。
- 現在のモードをそのまま示すレジスタはない。トラップ時に、トラップ前のモードが `mstatus.MPP` / `sstatus.SPP` に記録され、`mret` / `sret` はそこに記録されたモードへ戻る。

### x86 との比較

x86 側の記述は、下の「『はじめて読む486』の対応箇所」で本文を確認したものと、一般的な知識によるものが混ざっている（表の後の注を参照）。

| | x86（486） | RISC-V |
| --- | --- | --- |
| 権限の段階 | リング0〜3 | M / S / U |
| 現在の権限 | `CS` の下位2ビット（CPL）で直接わかる | 直接は読めない。トラップ前のモードだけが記録される |
| ファームウェア | BIOS。`INT 10h` などで呼べるが、プロテクトモードに移った OS はふつう使わない | OpenSBI。OS より高い権限（M-mode）で常駐し、起動後も `ecall` で呼ばれ続ける |

共通する考え方：起動時の初期化と、OS から呼べるサービスを持つファームウェアがいる。権限を上げる入口はハードウェアが決めた経路（割り込み・トラップ）に限られる。

注：「CPL が `CS` の下位2ビットに入る」は本文で確認した（p.200）。「ファームウェア」の行（BIOS の `INT 10h`、プロテクトモードの OS は BIOS をふつう使わない）は一般的な知識で、本では確認していない。

#### 『はじめて読む486』の対応箇所

蒲地輝尚『はじめて読む486』（アスキー、1994年）。ページは本のノンブル（PDF のページ番号はこれに +4）。目次から拾ったもので、本文まで読んだのは p.200 のみ。

| トピック | 章・節 | ページ |
| --- | --- | --- |
| 特権レベルの考え方（OS とアプリ） | 3.4 特権レベルと保護機能 | p.92〜 |
| 特権レベル、DPL、CPL、特権命令 | 6.2 特権レベル | p.198〜201 |
| CPL は `CS` の下位2ビットに保持される | 6.2「CPL - 特権レベルとコードセグメント」 | p.200 |
| IOPL（I/O ポートの特権レベル） | 6.2 | p.203 |
| 権限を上げる入口（コールゲート、ゲートの種類） | 6.3 ゲート | p.205〜 |
| 割り込みと例外（トラップ、フォールト、アボート） | 7.1〜7.3 | p.225〜 |
| IDT と、プロテクトモードの割り込みのしくみ | 7.4 割り込み処理 | p.238〜 |
| 特権レベルとスタック切り替え | 10.1 オペレーティングシステムのセキュリティ | p.340〜 |
| RPL | 10.1 | p.349 |
| BIOS コールのエミュレート | 11.1 仮想8086モードのしくみ | p.375 |

### 参考

- RISC-V 特権仕様：[riscv/riscv-isa-manual](https://github.com/riscv/riscv-isa-manual)
- SBI 仕様：[riscv-non-isa/riscv-sbi-doc](https://github.com/riscv-non-isa/riscv-sbi-doc)
- OpenSBI：[riscv-software-src/opensbi](https://github.com/riscv-software-src/opensbi)

> この節は、教材と Claude との対話でまとめたもの。仕様書の該当箇所とはまだ照らし合わせていない。

## 次に試すこと

- [x] QEMU モニターで `info mtree -f` を実行し、上のメモリマップと一致するか確認する（上の観察結果）
- [ ] QEMU モニターで `xp /8i 0x1000` を実行し、リセット直後に CPU が実行する命令がどこへ飛ぶかを見る
- [ ] ホストで `qemu-system-riscv32 -machine virt,dumpdtb=virt.dtb` を実行し、`dtc -I dtb -O dts virt.dtb`（`dtc` パッケージ）でデバイスツリーを読む

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
  - `0x3_0000_0000` 以降という 32 ビットを超える番地に `gpex_mmio_window` がある。32 ビットの CPU からどう届くのか。ページングの章（Sv32 の物理アドレス幅）で確かめる。
    - 手がかり（2026-11-22、RISC-V 特権仕様の Sv32 の節で確認）：Sv32 の物理アドレスは 34 ビット（`PPN[1]` 12 ビット + `PPN[0]` 10 ビット + `page offset` 12 ビット）で、16GiB まで指せる。推論：`0x3_0000_0000`（12GiB）は、ページテーブルを通せば 32 ビットの CPU からも届く。実際に対応を付けて触れる実験はまだ（`page-table.md`）。
  - OpenSBI の起動ログに出る `Boot HART MIDELEG : 0x00001666` と `Boot HART MEDELEG : 0x00f4b509` は、M-mode と S-mode の境界とどうつながるのか。
    - 2026-11-21、自分の環境（OpenSBI v1.8.1）の `./run.sh` でも同じ値が出た。同じバナーに `Platform Features : medeleg` という行もある。
