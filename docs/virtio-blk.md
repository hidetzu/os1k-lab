# 15 ディスク読み書き

教材：[ディスク読み書き | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/15-virtio-blk)

## この章で答えたい問い

<!-- 例：カーネルは、どうやって機器（ディスク）に直接仕事を頼み、結果を受け取るのか -->

## virtio とは

virtio は、仮想マシンの中の OS が、仮想的な機器（ディスク、ネットワーク、コンソールなど）を使うための標準のやり方（一般知識）。

### なぜ必要か

QEMU のような仮想マシンで、ゲストの OS に機器を見せる方法は、大きく2つある。

| 方法 | 中身 | 良いところ | 苦手なところ |
| --- | --- | --- | --- |
| 本物の機器のまねをする（エミュレーション） | 実在するディスクやネットワークカードのレジスタの動きを、ソフトウェアで再現する | ゲストの OS は本物の機器のドライバをそのまま使える | 本物の機器は複雑なので、再現が大変で遅い |
| 仮想マシン用に設計した機器を見せる（virtio） | 最初から「仮想マシンで使う」前提の、単純な機器の決まりを作る | 単純で速い | ゲストの OS に virtio 用のドライバが要る |

- virtio は 2 つ目の方法。「ゲストは自分が仮想マシンの中にいると知っている」前提で、やり取りを簡単にしている。
- 仕様は OASIS という標準化団体が公開していて、QEMU、KVM、Linux など多くのところで使われている（一般知識）。

### 3つの層

| 層 | 中身 | この教材では |
| --- | --- | --- |
| 機器の種類 | ディスク（blk）、ネットワーク（net）、コンソール、乱数など。種類ごとに番号がある | ディスク（`VIRTIO_DEVICE_BLK` = 2） |
| 共通のやり取りの仕組み | virtqueue：ゲストと機器が共有するメモリ上のキュー。依頼を入れて知らせ、終わったら結果を受け取る | この章の中心 |
| つなぎ方（transport） | 機器のレジスタをどう見せるか。PCI、MMIO など | MMIO（`0x1000_1000` から、メモリの番地としてレジスタが見える） |

ディスクでもネットワークでも、やり取りの仕組み（virtqueue）は共通。ディスクのドライバを1つ書けば、ほかの virtio の機器も同じ骨組みで扱える。

### これまでの機器の使い方との比較

| | 05 章の文字出力 | 15 章のディスク |
| --- | --- | --- |
| 機器 | UART（`0x1000_0000`） | virtio-blk（`0x1000_1000`） |
| 誰が直接触るか | OpenSBI（カーネルは `ecall` で頼む） | カーネルが自分で |
| やり取りの形 | 1 文字ずつレジスタに書く | virtqueue に依頼を入れて、機器が RAM を直接読み書きする |

カーネルが自分でデバイスドライバを書くのは、この章が初めて。

### QEMU で確かめたこと（QEMU v11.1.3 のソース）

- 教材は virtio のレガシー（古い形式）のレジスタを使い、バージョンが 1 であることを確かめる。[`hw/virtio/virtio-mmio.c` L735](https://github.com/qemu/qemu/blob/v11.1.3/hw/virtio/virtio-mmio.c#L735) は `DEFINE_PROP_BOOL("force-legacy", VirtIOMMIOProxy, legacy, true)` で、既定はレガシーのまま。教材のコードがそのまま使えるはず。
- `hw/riscv/virt.c` の L99 は `[VIRT_VIRTIO] = { 0x10001000, 0x1000 }`。02 章の `info mtree` で見た `virtio-mmio` の並びの最初の1つ（`riscv-intro.md`）。

## virtio デバイスの有効化（run.sh）

QEMU の起動オプションに2行を足した。

```sh
$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
    -drive id=drive0,file=lorem.txt,format=raw,if=none \
    -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
    -kernel kernel.elf
```

| オプション | 意味 |
| --- | --- |
| `-drive id=drive0,file=lorem.txt,format=raw,if=none` | ホストの `lorem.txt` を、加工なし（`raw`）のディスクの中身として `drive0` という名前で用意する。`if=none` で、まだどの機器にもつながない |
| `-device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0` | virtio-blk の機器を作り、`drive0` をつなぎ、1 つ目の `virtio-mmio` の口に差す |

- `lorem.txt` はホストの作業ディレクトリに置いた（598 バイト）。中身がそのままディスクの中身になる。
- 注意 1：ディスクは 512 バイトのセクタ単位で読み書きする。598 バイトは 512 の倍数ではない。推論：教材の出力例の `capacity is 1024 bytes` とは違う値になるかもしれない（QEMU が半端な分をどう扱うかは未確認）。
- 注意 2：教材のテストは、ディスクの先頭に `hello from kernel!!!` を書き込む。`./run.sh` を実行するたびに `lorem.txt` の中身が変わる。

### 3つの「打ち込む場所」

14 章でシェルができたので、`./run.sh` の直後は、キー入力が自作 OS のシェルに届く。最初は `info block` をシェルに打ち込んでしまい、`unknown command: info block` と返された。

| 打ち込む場所 | プロンプト | 例 |
| --- | --- | --- |
| ホストの Arch | `❯` など | `./run.sh`、`llvm-nm` |
| 自作 OS のシェル | `> ` | `hello`、`exit` |
| QEMU モニター | `(qemu)` | `info block`、`info registers` |

`Ctrl-A` を押して離してから `c` で、シェルと QEMU モニターが切り替わる（IME はオフで）。`(qemu)` のプロンプトが出ているかを見れば、どちらに打ち込んでいるか分かる。

## Virtqueue

<!-- descriptor table / available ring / used ring の図。誰が書き、誰が読むか -->

## デバイスドライバの初期化

<!-- 機器のレジスタ（magic、version、device id、status）。virtio_blk_init、virtq_init。create_process で 0x1000_1000 を表に載せる理由 -->

## IO リクエストの送信

<!-- read_write_disk。3 つの descriptor のつながり。kick して待つ。機器に渡す番地は物理アドレス（DMA） -->

## 観察結果

2026-11-22、ホストの Arch で観察。

### ディスクがつながったか（QEMU モニター）

`run.sh` に2行を足した時点（カーネル側のドライバはまだない）で確かめた。

```
(qemu) info block
drive0 (#block124): lorem.txt (raw)
Attached to: /machine/peripheral-anon/device[0]
Cache mode: writeback

floppy0: [not inserted]
Removable device: not locked, tray closed
```

- `run.sh` の `-drive` のとおり、`drive0` として `lorem.txt` がそのままの形式（`raw`）でつながっている。
- `Attached to` で、どこかの機器に接続済みだと分かる。
- `floppy0: [not inserted]` は、QEMU が最初から用意している空のフロッピーの口。今回は関係ない。

```
(qemu) info qtree
...
dev: virtio-mmio, id ""
  force-legacy = true
  mmio 0000000010001000/0000000000000200
  bus: virtio-mmio-bus.0
    dev: virtio-blk-device, id ""
      drive = "drive0"
      logical_block_size = 512 (512 B)
      ...
      num-queues = 1 (0x1)
      queue-size = 256 (0x100)
```

| 表示 | 読み方 |
| --- | --- |
| `mmio 0000000010001000/...200` | この `virtio-mmio` のレジスタは `0x1000_1000` から。教材の `VIRTIO_BLK_PADDR` と同じ番地 |
| `bus: virtio-mmio-bus.0` | `run.sh` の `bus=virtio-mmio-bus.0` で指定した場所。8 つある `virtio-mmio` のうち最初の 1 つ |
| `force-legacy = true` | レガシーの形式。QEMU のソースで確かめた既定値（`virtio-mmio.c` L735）と、実物でも一致した |
| `drive = "drive0"` | `info block` の `drive0`（`lorem.txt`）がここにつながっている |
| `logical_block_size = 512` | 1 セクタは 512 バイト。教材の `SECTOR_SIZE` と同じ |
| `num-queues = 1`、`queue-size = 256` | virtqueue は 1 本で、最大 256 個まで。教材は `VIRTQ_ENTRY_NUM` を 16 にして、この範囲で使う |

- すぐ隣の `0x1000_2000` の `virtio-mmio` は、何もつながっていない空の口。
- QEMU 側の準備（`run.sh`）が正しくできていることが分かった。

## 次に試すこと

- [ ] ドライバを書いたあと、`capacity` の表示を `lorem.txt` の大きさ（598 バイト）と比べる
- [ ] `lorem.txt` を git に入れるか、実験のたびに作り直す手順を決める

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
