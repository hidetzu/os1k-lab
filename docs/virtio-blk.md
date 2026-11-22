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

virtqueue は、カーネル（ドライバ）と機器が共有するメモリ上のキュー。3 つの部分でできている。

| 部分 | 構造体 | 書く側 | 中身 |
| --- | --- | --- | --- |
| descriptor table | `struct virtq_desc descs[16]` | ドライバ | 1 つのバッファの物理アドレス、長さ、印（`NEXT` / `WRITE`）、次の descriptor の番号 |
| available ring | `struct virtq_avail` | ドライバ | 「処理してほしい依頼」の先頭の descriptor の番号を並べる。`index` で何個入れたかを数える |
| used ring | `struct virtq_used` | 機器 | 「処理し終わった依頼」を並べる。`index` で何個終わったかを数える |

```
 driver (kernel)                       device (QEMU virtio-blk)
 +---------------------------+
 | descs[0] -> descs[1] -> descs[2]   (descriptor chain = one request)
 +---------------------------+
 | avail.ring[i] = 0         | -- kick (QUEUE_NOTIFY) -->  reads the chain,
 | avail.index++             |                             does the disk I/O
 +---------------------------+
 | used.index                | <-- device increments ----  writes used.ring
 +---------------------------+
   driver waits until used.index == last_used_index
```

```c
struct virtq_desc {
  uint64_t addr;
  uint32_t len;
  uint16_t flags;
  uint16_t next;
} __attribute__((packed));
...
struct virtio_virtq {
  struct virtq_desc descs[VIRTQ_ENTRY_NUM];
  struct virtq_avail avail;
  struct virtq_used used __attribute__((aligned(PAGE_SIZE)));
  int queue_index;
  volatile uint16_t *used_index;
  uint16_t last_used_index;
} __attribute__((packed));
```

- `__attribute__((packed))`：機器は、仕様で決まったバイトの並びでこのメモリを読み書きする。`uint16_t` や `uint64_t` が混ざると、コンパイラは隙間（パディング）を入れることがあるので、`packed` で仕様どおりの並びに固定する（推論）。08 章の `trap_frame` では、全部 `uint32_t` なので、なくても同じ並びになるはずだった（`exception.md`）。
- `used` は `aligned(PAGE_SIZE)` で、次のページの先頭に置く。推論：レガシーの virtio では、used ring をページの境界にそろえる決まりがある。
- `used_index` は `volatile` のポインタ。機器が勝手に書き換える場所なので、コンパイラに「毎回メモリから読み直せ」と伝える。

### virtio_blk_req（1 回の依頼の中身）

```c
struct virtio_blk_req {
  // 1 つ目の descriptor：機器からは読み込み専用
  uint32_t type;
  uint32_t reserved;
  uint64_t sector;
  // 2 つ目の descriptor：読み込みのときは機器が書く（VIRTQ_DESC_F_WRITE）
  uint8_t data[512];
  // 3 つ目の descriptor：機器が書く（VIRTQ_DESC_F_WRITE）
  uint8_t status;
} __attribute__((packed));
```

1 つの構造体を、3 つの descriptor で3つの部分に分けて機器に見せる。

## デバイスドライバの初期化

### 機器のレジスタ

`0x1000_1000` からの番地に、機器のレジスタが並んでいる（MMIO）。`kernel.h` に番地のずれ（オフセット）を定義した。

| 名前 | オフセット | 使い方 |
| --- | --- | --- |
| `VIRTIO_REG_MAGIC` | `0x00` | `0x74726976`（`"virt"` をリトルエンディアンで読んだ値）か確かめる |
| `VIRTIO_REG_VERSION` | `0x04` | 1（レガシー）か確かめる |
| `VIRTIO_REG_DEVICE_ID` | `0x08` | 2（ブロックデバイス）か確かめる |
| `VIRTIO_REG_PAGE_SIZE` | `0x28` | ページの大きさ（4096）を教える。`QUEUE_PFN` の計算に使われる |
| `VIRTIO_REG_QUEUE_SEL` | `0x30` | どの virtqueue を設定するか選ぶ（0） |
| `VIRTIO_REG_QUEUE_NUM` | `0x38` | virtqueue の大きさ（16） |
| `VIRTIO_REG_QUEUE_PFN` | `0x40` | virtqueue の物理ページ番号（物理アドレスではない） |
| `VIRTIO_REG_QUEUE_NOTIFY` | `0x50` | 書き込むと「新しい依頼がある」と機器に知らせる |
| `VIRTIO_REG_DEVICE_STATUS` | `0x70` | 初期化の段階（ACK、DRIVER、DRIVER_OK） |
| `VIRTIO_REG_DEVICE_CONFIG` | `0x100` | ブロックデバイスの設定。先頭 8 バイトが容量（セクタ数） |

レジスタの読み書きは、`volatile` のポインタで行う。

```c
uint32_t virtio_reg_read32(unsigned offset) {
  return *((volatile uint32_t *)(VIRTIO_BLK_PADDR + offset));
}
```

- 普通のメモリと違い、機器のレジスタは、読むたび・書くたびに機器が反応する。`volatile` がないと、コンパイラが「同じ番地を2回読む必要はない」と読み出しを省いたり、順番を変えたりする（推論）。

### 初期化の手順（virtio_blk_init）

1. `MAGIC`、`VERSION`、`DEVICE_ID` を確かめる。違えば `PANIC`。
2. `DEVICE_STATUS` を 0 にして、機器をリセットする。
3. `ACK`（機器を見つけた）、`DRIVER`（使い方を知っている）の順にビットを立てる。
4. `PAGE_SIZE` を設定し、`virtq_init(0)` で virtqueue を作る。
5. `DRIVER_OK`（使える状態になった）を書く。
6. `DEVICE_CONFIG` から容量を読む（セクタ数 x 512 バイト）。
7. 依頼の中身（`virtio_blk_req`）の置き場所を `alloc_pages` で確保する。

`virtq_init` は、virtqueue のメモリを `alloc_pages` で確保し、`QUEUE_SEL`、`QUEUE_NUM`、`QUEUE_PFN` を書く。`QUEUE_PFN` には、物理アドレスを 4096 で割ったページ番号を書く。11 章の `satp` と同じく、ページの先頭の番地は下位 12 ビットが常に 0 なので、番号だけを渡す（`page-table.md`）。

### create_process で機器のページを表に載せる

```c
map_page(page_table, VIRTIO_BLK_PADDR, VIRTIO_BLK_PADDR, PAGE_R | PAGE_W);
```

- ページングを有効にしたあとは、機器のレジスタも表に載せないと触れない。カーネルの RAM と同じく、物理アドレスと同じ番地で載せる（恒等マッピング）。
- `PAGE_U` がない：アプリから機器を直接触らせない。カーネルだけが使う。
- `PAGE_X` がない：推論：レジスタは命令ではないので、実行する理由がない。間違って飛び込んだときに、例外で止まるほうが安全。
- 今のテストでは、`virtio_blk_init` と `read_write_disk` は `kernel_main` の中、最初の `yield` より前（ページングが無効のとき）に呼ぶ。この表の対応が効いてくるのは、プロセスが動いている間にディスクを読み書きするとき（推論。16 章のファイルシステム）。

## IO リクエストの送信

`read_write_disk(buf, sector, is_write)` が、1 セクタ（512 バイト）を読み書きする。

### 3つの descriptor のつながり

```
 blk_req (physical address blk_req_paddr)
 +---------------------------------+
 | type, reserved, sector (16 B)   | <- descs[0]: flags = NEXT,                  next = 1
 +---------------------------------+
 | data[512]                       | <- descs[1]: flags = NEXT | (read ? WRITE : 0), next = 2
 +---------------------------------+
 | status (1 B)                    | <- descs[2]: flags = WRITE
 +---------------------------------+
```

- `VIRTQ_DESC_F_NEXT`：この descriptor の次に、`next` の descriptor が続く。
- `VIRTQ_DESC_F_WRITE`：機器が書き込んでよいバッファ。読み込み（`VIRTIO_BLK_T_IN`）のときは、機器が `data` にディスクの中身を書く。書き込み（`VIRTIO_BLK_T_OUT`）のときは、機器が `data` を読んでディスクに書く。
- `status` は、いつも機器が書く。0 なら成功。

### 依頼して待つ

1. `blk_req` に `type` と `sector` を書く。書き込みなら `data` に `buf` を写す。
2. 3 つの descriptor を書く。
3. `virtq_kick`：available ring に descriptor 0 の番号を入れ、`avail.index` を 1 増やし、`QUEUE_NOTIFY` に書いて機器に知らせる。`last_used_index` も 1 増やしておく。
4. `virtq_is_busy`：機器が `used.index` を増やして `last_used_index` に追いつくまで、ループで待つ（割り込みを使わないので、ポーリング）。
5. `status` を確かめ、読み込みなら `data` を `buf` に写す。

- `virtq_kick` の `__sync_synchronize()` は、メモリの読み書きの順番を守らせる命令（メモリバリア）。推論：available ring を書き終わる前に機器に知らせると、機器が書きかけの中身を読んでしまうため。

### 機器に渡す番地は物理アドレス（DMA）

- descriptor の `addr` に書くのは、`blk_req_paddr` などの物理アドレス。機器は、ページテーブルを通らずに RAM を直接読み書きする（DMA）。
- `blk_req` も virtqueue も `alloc_pages` で確保した、恒等マッピングの範囲のメモリ。カーネルは同じ値をポインタとしても使えるし、機器には物理アドレスとして渡せる。11 章の「物理アドレスをそのままポインタにしてよい」理由が、ここでも効いている（`page-table.md`）。
- 推論：アプリのメモリ（`0x0100_0000` など）の仮想アドレスを、そのまま機器に渡しても通じない。機器にとっては物理アドレスだから。

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

### ディスクの読み書きテスト（./run.sh）

`kernel_main` で、`virtio_blk_init` のあと、先頭のセクタを読んで表示し、`hello from kernel!!!\n` を書き込んだ。

```c
char buf[SECTOR_SIZE];
read_write_disk(buf, 0, false);
printf("first sector: %s\n", buf);

strcpy(buf, "hello from kernel!!!\n");
read_write_disk(buf, 0, true);
```

1 回目：

```
virtio-blk: capacity is 1024 bytes
first sector: Lorem ipsum dolor sit amet, consectetur adipiscing elit. ...（中略）... Mauris et tellus quis riC
>
```

2 回目（1 回目で書き換わった `lorem.txt` のまま、もう一度 `./run.sh`）：

```
virtio-blk: capacity is 1024 bytes
first sector: hello from kernel!!!
```

1 回目のあとの `lorem.txt`（ホストの Arch）：

```
$ od -c lorem.txt | head -3
0000000   h   e   l   l   o       f   r   o   m       k   e   r   n   e
0000020   l   !   !   !  \n  \0   a   m   e   t   ,       c   o   n   s
0000040   e   c   t   e   t   u   r       a   d   i   p   i   s   c   i
$ ls -l lorem.txt
-rw-r--r-- 1 ... 598 ... lorem.txt
```

Claude がスクラッチパッドにコピーした `lorem.txt` で動かした結果も同じだった。

読み取り：

1. `capacity is 1024 bytes`：`lorem.txt` は 598 バイトだが、容量は 512 バイトのセクタ 2 つ分（1024 バイト）。推論：QEMU がディスクの大きさをセクタ単位に切り上げて見せている（QEMU のソースでは未確認）。教材の出力例と同じ値。
2. 1 回目の `first sector` の最後が文字化けした（`riC`）：`read_write_disk` は 512 バイトを `buf` にちょうど詰める。`lorem.txt` の先頭 512 バイトに `\0` はないので、`buf` の中に文字列の終わりがない。`printf("%s")` が `buf` の後ろのスタックのごみまで表示した。教材の出力例は `...` で省略していて、見えていなかった。
3. 書き込んだあとの `lorem.txt`：先頭が `hello from kernel!!!\n` に書き換わり、直後に `\0`、続けて元の文章の `amet, consectetur ...` が残った。`strcpy` が書いたのは先頭の 22 バイト（`\0` まで）だけで、`buf` の残りには、さっき読んだ元のセクタの中身が残っていた。`read_write_disk` がその 512 バイトをまるごと書き戻したので、元の文章の続き（`Lorem ipsum dolor sit ` の 22 文字の後ろ）が残った。
4. ファイルの大きさは 598 バイトのまま。書き込んだのは、ファイルの範囲の中の先頭 512 バイトだけ。
5. 2 回目の `first sector` は `hello from kernel!!!` だけ：`printf("%s")` が 22 バイト目の `\0` で止まった。末尾の文字化けも消えた。

書き込んだ内容が `lorem.txt`（ホストのファイル）に残り、次に起動したときにも読めた。カーネルの外にある「電源を切っても残る記憶」を、初めて使えた。

## 次に試すこと

- [x] ドライバを書いたあと、`capacity` の表示を `lorem.txt` の大きさ（598 バイト）と比べる → 1024 バイト（セクタ 2 つ分に切り上げ。推論）
- [ ] QEMU のソースで、ディスクの大きさがセクタ単位に切り上げられる箇所を確かめる
- [x] `first sector` の文字化けを直す（例：`buf` を 1 バイト大きくして最後に `\0` を入れる）か決める → 直さない。このテストの目的は「ディスクとして `lorem.txt` を読めている」と分かることで、先頭の文章が表示されれば十分。文字化けは表示だけの問題で、16 章でこのテストのコードは使わなくなるはず（推論）
- [ ] `lorem.txt` を git に入れるか、実験のたびに作り直す手順を決める

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
