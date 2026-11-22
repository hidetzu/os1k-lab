# 16 ファイルシステム

教材：[ファイルシステム | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/16-file-system)

## この章で答えたい問い

<!-- 例：セクタ単位でしか読み書きできないディスクの上に、名前で読み書きできる「ファイル」をどう作るのか -->

## 階層の図

```
 shell (U-mode)       readfile("hello.txt", buf, len) / writefile(...)
   | syscall: a0 = filename, a1 = buf, a2 = len, a3 = SYS_READFILE / SYS_WRITEFILE
   | ecall
   v
 kernel (S-mode)      handle_syscall
   |                    fs_lookup(filename) -> struct file in files[]
   |                    read : memcpy(buf, file->data, len)
   |                    write: memcpy(file->data, buf, len); fs_flush()
   v
 fs_flush             files[] -> tar image in disk[] -> write all sectors
   | read_write_disk (sector by sector)
   v
 virtio-blk driver    virtqueue -> device (DMA)
   v
 disk.tar (host file)
```

- 起動時は逆向き：`fs_init` が `read_write_disk` でディスク全体を `disk[]` に読み込み、tar のヘッダをたどって `files[]` に並べる。
- アプリから見えるのは「名前で読み書きする」API だけ。セクタや tar の形は、カーネルの中に隠れている。

## tar ファイルシステム

tar は、複数のファイルを1つにまとめる形式。この OS は、tar（ustar 形式）の並びを、そのままディスク上のファイルシステムとして使う。

- 推論：ホストの `tar` コマンドで、ディスクイメージを作ることも、中身を確かめることもできる。自前の形式を考えなくてよい。

### tar の構造

```
disk.tar
offset 0     +---------------------------+
             | header (512 B)            |  name, mode, size (octal), checksum, magic "ustar", ...
512          +---------------------------+
             | data of file 1            |  padded up to a multiple of 512
             +---------------------------+
             | header (512 B)            |
             +---------------------------+
             | data of file 2            |
             +---------------------------+
             | zero blocks ...           |  end of archive
             +---------------------------+
```

- 1 つのファイルは「512 バイトのヘッダ + 中身」。中身の後ろは、512 バイトの倍数になるまで 0 で埋める。次のファイルのヘッダは、必ずセクタの境界から始まる。
- 次のヘッダの位置は `off += align_up(sizeof(struct tar_header) + filesz, SECTOR_SIZE)` で求める。

### struct tar_header

```c
struct tar_header {
  char name[100];
  char mode[8];
  char uid[8];
  char gid[8];
  char size[12];
  char mtime[12];
  char checksum[8];
  char type;
  char linkname[100];
  char magic[6];
  char version[2];
  char uname[32];
  char gname[32];
  char devmajor[8];
  char devminor[8];
  char prefix[155];
  char padding[12];
  char data[]; // ヘッダに続くデータ領域を指す配列 (フレキシブル配列メンバ)
} __attribute__((packed));
```

- 欄を全部足すと 512 バイト。ディスク上の並びと同じ形にするので `packed`（15 章の virtqueue の構造体と同じ理由。`virtio-blk.md`）。
- 数値（`size` や `mode` など）は、数ではなく 8 進数の文字列で書く。
- `data[]`（フレキシブル配列メンバ）：大きさを書かない配列。構造体の最後に置くと、「ヘッダの直後に続く中身」をこの名前で指せる。`sizeof(struct tar_header)` には含まれない。

### oct2int

```c
int oct2int(char *oct, int len) {
  int dec = 0;
  for (int i = 0; i < len; i++) {
    if (oct[i] < '0' || oct[i] > '7')
      break;

    dec = dec * 8 + (oct[i] - '0');
  }
  return dec;
}
```

- 8 進数の文字列を数に直す。`'0'`〜`'7'` 以外の文字（`\0` など）で止まる。
- 1 桁読むたびに、それまでの値を 8 倍して足す。`"013"` なら 0 -> 0*8+1 = 1 -> 1*8+3 = 11。

## ディスクイメージの作成（run.sh）

`run.sh` に、カーネルのビルドのあと、ディスクイメージを作る行を足した。QEMU に渡すディスクも、`lorem.txt` から `disk.tar` に替えた。

```sh
# --format=ustar: ustar形式のtarファイルを作成する
(cd disk && tar cf ../disk.tar --format=ustar *.txt)

$QEMU -machine virt -bios default -nographic -serial mon:stdio --no-reboot \
    -d unimp,guest_errors,int,cpu_reset -D qemu.log \
    -drive id=drive0,file=disk.tar,format=raw,if=none \
    -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
    -kernel kernel.elf
```

| 行 | 意味 |
| --- | --- |
| `(cd disk && tar cf ../disk.tar --format=ustar *.txt)` | `disk/` の中の `.txt` を ustar 形式の tar にまとめ、`disk.tar` を作る。かっこで囲むと、`cd` はその中だけで効き、後ろの行に影響しない |
| `-d unimp,guest_errors,int,cpu_reset -D qemu.log` | QEMU が、未実装の機能、ゲストの誤り、割り込みと例外、CPU のリセットを `qemu.log` に記録する（教材の QEMU の行にあるオプション） |
| `-drive id=drive0,file=disk.tar,...` | ディスクの中身を `disk.tar` にする |

- `-d ... int` で、例外が起きるたびに `qemu.log` に記録される。`exception.md` に残した「QEMU のログで、`unimp` のときに M-mode の例外が起きていることを見る」宿題も、これで試せる。
- `qemu.log` と `disk.tar` は、`.gitignore` の `*.log` と `*.tar` で除外済み。
- `lorem.txt` は使わなくなった。

### disk/ の中身

```
$ ls -l disk/
-rw-r--r-- 1 ... 0 ... hello.txt
-rw-r--r-- 1 ... 0 ... meow.txt
```

- 2 つとも 0 バイト。教材では `hello.txt` に文章を入れている。空のままだと、シェルの `readfile` で何も表示されず、読めたかどうか分からない。何か 1 行入れておくとよい。
- `.gitignore` には、最初のコミットのときから `/disk/*` と `!/disk/.gitkeep` が入っている。今のままだと `disk/` の中身は git に入らない。ディスクの初期の中身として残したいなら、`.gitignore` を変える必要がある。

### 動かす前に見ておくとよいこと

`./run.sh` を一度動かすと `disk.tar` ができる。ホストの Arch で中身を確かめられる。

```
tar tvf disk.tar         # 入っているファイルの一覧
ls -l disk.tar           # 大きさ
xxd disk.tar | head -40  # 先頭のヘッダの中身
```

推論：中身が数十バイトしかなくても、tar の決まりで、`disk.tar` は思ったより大きくなる。カーネルの `fs_init` が読む大きさ（`DISK_MAX_SIZE`）と比べると面白い。

## ファイルシステムの読み込み（fs_init）

```c
// kernel.h
#define FILES_MAX 2
#define DISK_MAX_SIZE align_up(sizeof(struct file) * FILES_MAX, SECTOR_SIZE)

struct file {
  bool in_use;     // このファイルエントリが使われているか
  char name[100];  // ファイル名
  char data[1024]; // ファイルの内容
  size_t size;     // ファイルサイズ
};

// kernel.c
struct file files[FILES_MAX];
uint8_t disk[DISK_MAX_SIZE];
```

- `files[]`：メモリ上のファイルの一覧。最大 2 つ、1 つ 1024 バイトまで。
- `disk[]`：ディスクの中身をまるごと置くメモリ。`struct file` は 4 + 100 + 1024 + 4 = 1132 バイトで、2 つ分の 2264 バイトを 512 の倍数に切り上げて 2560 バイト。`writefile` のあとの `wrote 2560 bytes to disk` はこの大きさ。

```c
void fs_init(void) {
  for (unsigned sector = 0; sector < sizeof(disk) / SECTOR_SIZE; sector++)
    read_write_disk(&disk[sector * SECTOR_SIZE], sector, false);

  unsigned off = 0;
  for (int i = 0; i < FILES_MAX; i++) {
    struct tar_header *header = (struct tar_header *)&disk[off];
    if (header->name[0] == '\0')
      break;

    if (strcmp(header->magic, "ustar") != 0)
      PANIC("invalid tar header: magic=\"%s\"", header->magic);

    int filesz = oct2int(header->size, sizeof(header->size));
    struct file *file = &files[i];
    file->in_use = true;
    strcpy(file->name, header->name);
    memcpy(file->data, header->data, filesz);
    file->size = filesz;
    printf("file: %s, size=%d\n", file->name, file->size);

    off += align_up(sizeof(struct tar_header) + filesz, SECTOR_SIZE);
  }
}
```

1. ディスクの先頭 2560 バイト（5 セクタ）を、1 セクタずつ `disk[]` に読み込む。
2. 先頭からヘッダをたどる。名前が空ならアーカイブの終わり。
3. `magic` が `"ustar"` でなければ `PANIC`（tar の形ではない）。
4. `size` を `oct2int` で数に直し、名前と中身を `files[i]` に写す。
5. 次のヘッダの位置へ進む。

- `disk.tar` は 10240 バイトあるが、読むのは先頭の 2560 バイトだけ。ファイルが 2 つで小さいうちは、それで足りる。

## ディスクへの書き込み戻し（fs_flush）

`fs_flush` は、`files[]` から tar の形を `disk[]` に作り直し、2560 バイト全体をディスクに書き戻す。

1. `disk[]` を 0 で埋める。
2. 使っているファイルごとに、ヘッダを作る。
   - `name`、`mode`（`"000644"`）、`magic`（`"ustar"`）、`version`（`"00"`）、`type`（`'0'` = 普通のファイル）を書く。
   - `size`：ファイルの大きさを 8 進数の文字列にして、右詰めで書く（下の桁から `% 8` で 1 桁ずつ）。
   - `checksum`：ヘッダの全バイトを足した値。計算するときは、`checksum` の欄そのものを空白 8 文字として数える（`' ' * sizeof(header->checksum)` から始める）。結果を 8 進数 6 桁で書く。
3. ヘッダの直後に中身を写し、次のヘッダの位置へ進む。
4. `disk[]` を 1 セクタずつディスクに書き戻し、`wrote 2560 bytes to disk` と表示する。

- 1 つのファイルを書き換えるだけでも、ディスク全体（2560 バイト）を書き直す。単純だが、ファイルが増えると重い（推論）。
- `uid`、`gid`、`mtime` は書かない（0 のまま）。`tar tvf` で見ると、持ち主は `0/0`、日時は 1970-01-01 になる（推論。日時 0 は UTC の 1970 年 1 月 1 日 0 時）。

## ファイルの読み書きのシステムコール

```c
// common.h
#define SYS_READFILE 4
#define SYS_WRITEFILE 5

// user.c
int readfile(const char *filename, char *buf, int len) {
  return syscall(SYS_READFILE, (int)filename, (int)buf, len);
}

int writefile(const char *filename, const char *buf, int len) {
  return syscall(SYS_WRITEFILE, (int)filename, (int)buf, len);
}
```

```c
// kernel.c
struct file *fs_lookup(const char *filename) {
  for (int i = 0; i < FILES_MAX; i++) {
    struct file *file = &files[i];
    if (!strcmp(file->name, filename))
      return file;
  }

  return NULL;
}

// handle_syscall
  case SYS_READFILE:
  case SYS_WRITEFILE:
    const char *filename = (const char *)f->a0;
    char *buf = (char *)f->a1;
    int len = f->a2;
    struct file *file = fs_lookup(filename);
    if (!file) {
      printf("file not found: %s\n", filename);
      f->a0 = -1;
      break;
    }

    if (len > (int)sizeof(file->data))
      len = file->size;

    if (f->a3 == SYS_WRITEFILE) {
      memcpy(file->data, buf, len);
      file->size = len;
      fs_flush();
    } else {
      memcpy(buf, file->data, len);
    }

    f->a0 = len;
    break;
```

- `fs_lookup`：`files[]` を先頭から順に見て、名前が一致するファイルを返す。ディレクトリはなく、名前の完全一致だけ。
- 読み書きは 1 つの `case` にまとめ、`a3`（システムコールの番号）で分ける。
- 引数は `syscall` が入れた順に、`a0` = ファイル名、`a1` = バッファ、`a2` = 長さ。最初は `buf` を `f->a0` から取っていて、`readfile` が何も表示しなかった（`buf` がファイル名の文字列を指していた）。`f->a1` に直した。
- 書き込み：中身を `file->data` に写し、大きさを更新して `fs_flush` でディスクに書き戻す。
- 読み込み：`file->data` をアプリの `buf` に写す。
- 戻り値（`f->a0`）は長さ。ファイルがなければ -1。

気になる点（推論）：

- `if (len > sizeof(file->data)) len = file->size;`：長すぎるときに、上限の 1024 ではなく、今のファイルの大きさにしている。書き込みで 1024 バイトを超えると、思った長さにならない。
- 読み込みは、ファイルの大きさではなく、アプリが頼んだ `len` だけ写す。ファイルが小さいと、中身の後ろのごみまで写す。
- シェルの `readfile` は `buf[128]` に `len = sizeof(buf)` = 128 を渡し、戻ってきた長さで `buf[len] = '\0'` とする。`len` が 128 だと、`buf[128]` は配列の 1 つ外への書き込みになる。
- カーネルは、アプリが渡した番地（`filename`、`buf`）を確かめずに読み書きする。教材も、安全上の問題として注意している。

### シェルのコマンド

```c
    else if (strcmp(cmdline, "readfile") == 0) {
      char buf[128];
      int len = readfile("hello.txt", buf, sizeof(buf));
      buf[len] = '\0';
      printf("%s\n", buf);
    } else if (strcmp(cmdline, "writefile") == 0)
      writefile("hello.txt", "Hello from shell!\n", 19);
```

- `readfile`：`hello.txt` を読んで表示する。
- `writefile`：`hello.txt` に `"Hello from shell!\n"` と最後の `\0` の 19 バイトを書く。

## ユーザーポインタへのアクセス（SUM ビット）

シェルの `readfile` で、カーネルがページフォールトを起こした（「観察結果」の「readfile でページフォールト（SUM なし）」）。

- シェルが `readfile("hello.txt", ...)` を呼ぶと、カーネルの `fs_lookup` が `strcmp` でファイル名を比べる。そのとき、アプリが渡したファイル名の番地（`0x0100_0410`、アプリのページ）を、カーネル（S-mode）が読もうとする。
- アプリのページには `PAGE_U` が付いている。S-mode は、`sstatus` の SUM ビットが 0 の間、`U` の付いたページに触れない。読み書きするとページフォールトになる（一般知識。仕様の変換手順の「`pte.u` ビットと SUM で、今のモードからのアクセスが許されるか確かめる」手順。`page-table.md`）。

```
address 0x0100_0410 -> PTE: V=1, R=1, U=1
  app    (U-mode) reads -> U=1, so OK
  kernel (S-mode) reads -> U=1 page with SUM=0 is not allowed -> page fault (scause=13)
```

「表に載っていない」から失敗したのではなく、「載っているが、S-mode からの読み込みは許されていない」から失敗した。

### 13 章の保護と逆向き

| | 13 章（`user-mode.md`） | 16 章（今回） |
| --- | --- | --- |
| 誰が触ったか | アプリ（U-mode） | カーネル（S-mode） |
| どのページに | カーネルのページ（`U` なし） | アプリのページ（`U` あり） |
| `scause` | 15（書き込みのページフォールト） | 13（読み込みのページフォールト） |
| `sepc` | アプリの中（`0x0100_0018`） | カーネルの中（`0x8020_1386`） |

U-mode と S-mode は、`U` の印を境に、お互いのページに勝手に触れないようになっている。

### 直し方

`user_entry` で、`sstatus` に `SSTATUS_SUM`（ビット 18）も立てる。SUM（permit Supervisor User Memory access）は、「S-mode から U のページに触れてよい」というスイッチ。

```c
[sstatus] "r"(SSTATUS_SPIE | SSTATUS_SUM)
```

- 推論：普段は SUM を 0 にしておき、カーネルがアプリのメモリに触れる必要があるときだけ 1 にすれば、カーネルのバグでアプリのメモリをうっかり壊すことを防げる。教材は簡単のため、アプリに入るときに立てたままにする。

## 観察結果

2026-11-22、ホストの Arch で観察。

### fs_init まで入れて起動（./run.sh）

```
virtio-blk: capacity is 10240 bytes
file: hello.txt, size=0
file: meow.txt, size=11
first sector: hello.txt
>
```

| 表示 | 読み方 |
| --- | --- |
| `capacity is 10240 bytes` | `disk.tar` の大きさ（`ls -l` で 10240 バイト）と同じ。推論：中身は 11 バイトしかないが、GNU tar は 512 バイトのブロック 20 個分（10240 バイト）を 1 単位として、その倍数に切り上げて作る |
| `file: hello.txt, size=0` | `disk/hello.txt` は空のまま |
| `file: meow.txt, size=11` | `disk/meow.txt` の 11 バイト。tar のヘッダの大きさの欄（8 進数）を `oct2int` で読めている |
| `first sector: hello.txt` | 15 章の読み書きテストが `kernel_main` に残っていて、先頭のセクタ（tar のヘッダ）を読んだ。ヘッダの先頭は名前の欄なので `hello.txt` と表示された |

15 章のテストが disk.tar を壊していた：

- `kernel_main` の 15 章の読み書きテストが、`fs_init` のあとに、先頭のセクタへ `hello from kernel!!!` を書き込んでいた。

```
$ xxd disk.tar | head -2
00000000: 6865 6c6c 6f20 6672 6f6d 206b 6572 6e65  hello from kerne
00000010: 6c21 2121 0a00 0000 0000 0000 0000 0000  l!!!............

$ tar tvf disk.tar
tar: これは tar アーカイブではないようです
tar: 次のヘッダをスキップします
-rw-r--r-- kawashima/kawashima 11 2026-11-22 16:57 meow.txt
```

- `hello.txt` のヘッダが上書きされて、tar として読めなくなった。`meow.txt` は 2 つ目のヘッダなので無事。
- `run.sh` が毎回 `tar cf` で `disk.tar` を作り直すので、次に起動するときには元に戻る。そのため気づきにくい。ただ、`writefile` の結果を確かめるときには、このテストが書き込みを上書きしてしまう。`kernel_main` から 15 章のテストを外す。
- `disk/meow.txt` の中身は `hello.otxt`（打ち間違いかもしれない）。

### readfile でページフォールト（SUM なし）

ファイルの読み書きコマンドまで実装し、SUM ビットを立てる前に、シェルで `readfile` を実行した。

```
PANIC: kernel.c:547: unexpected trap scause=0000000d, stval=01000410, sepc=80201386
```

どこで起きたか（ホストの Arch）：

```
$ llvm-addr2line -f -e kernel.elf 80201386
strcmp
.../common.c:29

$ llvm-objdump -d kernel.elf
8020137e <strcmp>:
8020137e: 00054603   lbu  a2, 0x0(a0)
80201382: ca19       beqz a2, 0x80201398 <strcmp+0x1a>
80201384: 0505       addi a0, a0, 0x1
80201386: 0005c683   lbu  a3, 0x0(a1)   <- exception here (sepc)
8020138a: 00d61763   bne  a2, a3, 0x80201398 <strcmp+0x1a>
8020138e: 00054603   lbu  a2, 0x0(a0)
80201392: 0585       addi a1, a1, 0x1
80201394: 0505       addi a0, a0, 0x1
80201396: fa65       bnez a2, 0x80201386 <strcmp+0x8>
80201398: 0005c503   lbu  a0, 0x0(a1)
8020139c: 40a60533   sub  a0, a2, a0
802013a0: 8082       ret

$ llvm-objdump -s -j .rodata shell.elf
 1000400 656c6c6f 00726561 6466696c 65000a00  ello.readfile...
 1000410 68656c6c 6f2e7478 74003031 32333435  hello.txt.012345
```

| 値 | 読み方 |
| --- | --- |
| `scause=0000000d` | 13 = 読み込みのページフォールト（Load page fault） |
| `stval=01000410` | 読もうとした番地。シェルの `.rodata` にある文字列 `"hello.txt"` |
| `sepc=80201386` | カーネルの `strcmp`（`common.c` の 29 行目）の `lbu a3, 0x0(a1)`。`a1` がアプリの文字列を指していた |

### PANIC のあとのシェルの表（QEMU モニター）

```
(qemu) info mem
vaddr    paddr            size     attr
-------- ---------------- -------- -------
01000000 000000008026d000 00001000 rwxu-a-
01001000 000000008026f000 0000f000 rwxu---
01010000 000000008027e000 00001000 rwxu-ad
10001000 0000000010001000 00001000 rw-----
80200000 0000000080200000 00002000 rwx--a-
...
```

| ページ | attr | 読み方 |
| --- | --- | --- |
| `0x0100_0000` | `rwxu-a-` | アプリの先頭ページ。`.text` と `.rodata` があり、`stval` の `0x0100_0410` もこのページの中。`r` も `u` もある有効なページ |
| `0x0100_1000`〜 | `rwxu---` | アプリの残りのページ。まだ一度も触れていない |
| `0x0101_0000` | `rwxu-ad` | アプリのスタックの上端（`__stack_top` の付近）。シェルが書き込んだので `d` |
| `0x1000_1000` | `rw-----` | virtio-blk のレジスタ。`map_page` に渡したとおり `rw` だけで、`x` も `u` もない。`a` もない |

- `0x0100_0410` のページは、表に載っていて `r` もある。それでもカーネルが読めなかったのは、`u` が付いているから（「ユーザーポインタへのアクセス（SUM ビット）」）。
- virtio のページに `a` がないのは、`virtio_blk_init` と `fs_init` が、最初の `yield` より前（ページングが無効のとき）に動くから。15 章で推論した「この表の対応が効いてくるのは、プロセスが動いている間にディスクを読み書きするとき」の裏付け（`virtio-blk.md`）。推論：SUM を立てて `writefile` を動かすと、`fs_flush` がシェルの表を通してディスクに書き込むので、このページにも `a` が付く。

### 機器のレジスタを直接のぞく（QEMU モニター）

```
(qemu) x /10c 0x10001000
10001000: 'v' 'i' 'r' 't' '\x01' '\x00' '\x00' '\x00' '\x02' '\x00' '\x00' '\x00' 'Q' 'E' 'M' 'U'
10001010: '\xd4' 'n' '\x00' '1' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00'
10001020: '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00' '\x00'
```

| オフセット | バイト | 値（リトルエンディアン） | レジスタ |
| --- | --- | --- | --- |
| `0x00` | `'v' 'i' 'r' 't'` | `0x74726976` | `VIRTIO_REG_MAGIC`。`virtio_blk_init` が確かめる値 |
| `0x04` | `01 00 00 00` | 1 | `VIRTIO_REG_VERSION`。レガシー |
| `0x08` | `02 00 00 00` | 2 | `VIRTIO_REG_DEVICE_ID`。ブロックデバイス |
| `0x0c` | `'Q' 'E' 'M' 'U'` | `0x554d4551` | ベンダー ID。教材では定義していないレジスタ（一般知識） |
| `0x10` | `d4 6e 00 31` | ― | 推論：機器が対応している機能のビット（Host Features） |

- `magic` の値を `virtio_blk_init` の `0x74726976` と見比べると、リトルエンディアンで `"virt"` を読んだ値だと分かる。
- `x` は、今の `satp` の表を通した仮想アドレスで読むコマンド（`xp` は物理アドレス）。`0x1000_1000` はシェルの表に恒等マッピングで載っているので、同じ値が読めた。推論：表に載っていなければ、`x` では読めない。

### SUM を立てたあと：writefile と readfile（自作 OS のシェル）

`user_entry` で `SSTATUS_SUM` を立て、`kernel_main` の 15 章のテストをコメントアウトしてから動かした。`readfile` で `PANIC` しなくなった。

1 回目（`handle_syscall` で `buf` を `f->a0` から取っていたとき）：

```
> writefile
wrote 2560 bytes to disk
> readfile
>
```

- `readfile` が何も表示しなかった。`buf` が `f->a0`（ファイル名の文字列）を指していた。
- 推論：`writefile` は、シェルが渡した `"Hello from shell!\n"` ではなく、`"hello.txt"` の文字列の場所から 19 バイトをファイルの中身として写した。`readfile` は、ファイルの中身をシェルの `buf` ではなく、`"hello.txt"` の文字列の場所に写した。アプリのページには `w` が付いているので、`.rodata` の文字列でもカーネルから書き換えられてしまう。

2 回目（`buf` を `f->a1` に直したあと）：

```
> writefile
wrote 2560 bytes to disk
> readfile
Hello from shell!
>
```

- `writefile` で書いた内容を、`readfile` で読み戻せた。
- `wrote 2560 bytes to disk` は `DISK_MAX_SIZE`（`struct file` 2 つ分を 512 の倍数に切り上げた大きさ）。

### ホストで disk.tar の中身を確かめる（ホストの Arch）

QEMU を止めた直後（次の `./run.sh` で作り直される前）に見た。

```
$ ls -l disk.tar
-rw-r--r-- 1 ... 10240 ... disk.tar

$ tar tvf disk.tar
-rw-r--r-- 0/0              19 1970-01-01 09:00 hello.txt
-rw-r--r-- 0/0              11 1970-01-01 09:00 memo.txt
```

`tmp/` に写して展開した：

```
$ ls -l tmp/
-rw-r--r-- 1 ... 10240 11月 22 17:29 disk.tar
-rw-r--r-- 1 ...    19  1月  1  1970 hello.txt
-rw-r--r-- 1 ...    11  1月  1  1970 memo.txt

$ od -c tmp/hello.txt
0000000   H   e   l   l   o       f   r   o   m       s   h   e   l   l
0000020   !  \n  \0

$ od -c tmp/memo.txt
0000000   h   e   l   l   o   .   o   t   x   t  \n
```

| 確かめたこと | 結果 | 読み方 |
| --- | --- | --- |
| ホストの `tar` で読めるか | 読めた（エラーなし） | `fs_flush` が作ったヘッダ（`ustar` の印、大きさの欄、チェックサム）が、本物の tar の決まりどおりになっている |
| `hello.txt` の中身 | `Hello from shell!\n\0` | シェルの `writefile` が書いた内容が、ホストのファイルとして取り出せた |
| `hello.txt` の大きさ | 19 バイト | `"Hello from shell!\n"` の 18 文字と最後の `\0`。`cat` では見えないが、最後に `\0` が 1 バイト入る。教材の `ls` の例は 26 バイトだが、コードどおりなら 19 のはず |
| 持ち主と日時 | `0/0`、1970 年 1 月 1 日（`tar tvf` では日本時間の 09:00） | `fs_flush` は `uid`、`gid`、`mtime` の欄を書かない（0 のまま）。展開したファイルにも、その日時が付いた |
| `memo.txt` | `hello.otxt\n` のまま | 書き換えたのは `hello.txt` だけ |
| `disk.tar` の大きさ | 10240 バイトのまま | `fs_flush` が書くのは先頭の 2560 バイトだけ。後ろは `tar cf` が作ったときのまま |

- 2 つ目のファイルは、`disk/` の中で `meow.txt` から `memo.txt` に名前を変えた。
- 自作 OS の中で書いたものが、外の世界（ホストの Arch）からも普通のファイルとして読めた。

### writefile のあとのシェルの表（QEMU モニター）

`./run.sh` で起動し、シェルで `writefile` を実行してから、QEMU モニターの `info mem` を見た。

```
(qemu) info mem
vaddr    paddr            size     attr
-------- ---------------- -------- -------
01000000 000000008026d000 00001000 rwxu-a-
01001000 000000008026f000 0000f000 rwxu---
01010000 000000008027e000 00001000 rwxu-ad
10001000 0000000010001000 00001000 rw---ad
80200000 0000000080200000 00002000 rwx--a-
80202000 0000000080202000 0000f000 rwx----
80211000 0000000080211000 00002000 rwx--ad
80213000 0000000080213000 00001000 rwx----
80214000 0000000080214000 00001000 rwx--a-
80215000 0000000080215000 00001000 rwx----
80216000 0000000080216000 00001000 rwx--ad
80217000 0000000080217000 00001000 rwx----
80218000 0000000080218000 00001000 rwx--a-
80219000 0000000080219000 00001000 rwx----
8021a000 000000008021a000 00001000 rwx--a-
8021b000 000000008021b000 00002000 rwx----
8021d000 000000008021d000 00001000 rwx--a-
8021e000 000000008021e000 00001000 rwx----
8021f000 000000008021f000 00001000 rwx--a-
80220000 0000000080220000 00001000 rwx----
80221000 0000000080221000 00001000 rwx--a-
80222000 0000000080222000 00001000 rwx----
80223000 0000000080223000 00001000 rwx--ad
80224000 0000000080224000 0001f000 rwx----
80243000 0000000080243000 00004000 rwx--ad
80247000 0000000080247000 001b9000 rwx----
80400000 0000000080400000 00400000 rwx----
...（0x0040_0000 ずつ同じ形の行が続く）
84000000 0000000084000000 00244000 rwx----
```

virtio のページ：

| | `readfile` の `PANIC` のあと | `writefile` のあと |
| --- | --- | --- |
| `10001000` | `rw-----` | `rw---ad` |

- `writefile` の中の `fs_flush` が `read_write_disk` を 5 回呼び、そのたびに `virtq_kick` が `VIRTIO_REG_QUEUE_NOTIFY` へ書き込んだ。`satp` はシェルの表のままだったので、この書き込みはシェルの表を通り、`a` と `d` が立った。
- 15 章と 16 章で推論した「この表の対応が効いてくるのは、プロセスが動いている間にディスクを読み書きするとき」が、観察として確かめられた（`virtio-blk.md`）。
- 推論：もし `create_process` で `VIRTIO_BLK_PADDR` を表に載せていなかったら、`writefile` の途中でカーネルがページフォールトで止まっていた。

`a` と `d` が付いたページ（`llvm-nm -n -S kernel.elf` の番地と照らし合わせた）：

| ページ | attr | 中身 | 理由（推論） |
| --- | --- | --- | --- |
| `0x1000_1000` | `ad` | virtio-blk のレジスタ | `fs_flush` の中で `QUEUE_NOTIFY` に書いた |
| `0x8021_1000`〜（2 ページ） | `ad` | `disk[]`（`0x8021_1ce0`〜）、`files[]`（`0x8021_26e0`〜） | `writefile` が `files[]` に書き、`fs_flush` が `disk[]` を作り直した |
| `0x8021_6000` | `ad` | シェルのカーネルスタックの上端（`procs[1].stack`） | システムコールの処理中に、カーネルがこのスタックを使った |
| `0x8022_3000` | `ad` | `proc_a`、`proc_b`、`blk_request_vq`、`blk_req_paddr`、`blk_req`、`idle_proc`、`current_proc`、`blk_capacity`（`0x8022_3038`〜） | `yield` などが読み書きした |
| `0x8024_3000`〜（4 ページ） | `ad` | `boot` のスタックの上端（`__stack_top` = `0x8024_3060`）と、free RAM の先頭（`__free_ram` = `0x8024_4000`。virtqueue と `blk_req`） | virtqueue と `blk_req` は `read_write_disk` が書き、機器が DMA で書く |

`a` だけ付いたページ：yield が全部の枠を見て回った跡。`procs[]` は `0x8021_2fb8` から始まり、1 枠が `0x2010` バイト。各枠の `state`（先頭から 4 バイト目）の番地を計算すると、ちょうど `a` だけのページに当たる。

| 枠 | `state` の番地 | ページ |
| --- | --- | --- |
| `procs[1]`（シェル） | `0x8021_4fcc` | `0x8021_4000` |
| `procs[3]` | `0x8021_8fec` | `0x8021_8000` |
| `procs[4]` | `0x8021_affc` | `0x8021_a000` |
| `procs[5]` | `0x8021_d00c` | `0x8021_d000` |
| `procs[6]` | `0x8021_f01c` | `0x8021_f000` |
| `procs[7]` | `0x8022_102c` | `0x8022_1000` |

- `procs[2]` の `state` は `0x8021_6fdc` で、`d` も付いた `0x8021_6000` の中。
- シェルが `getchar` でキー入力を待つ間、カーネルは `yield` を何度も呼ぶ（`system-call.md`）。`yield` は、動かせるプロセスを探して `procs[]` の 8 枠すべての `state` を読む。読むだけなので `d` は付かず、`a` だけが付いた（推論）。
- 使っていない枠のページにまで `a` が付いているのが、「全部の枠を順に見て回っている」証拠。

`a` も `d` もないページ：

- `0x8024_7000` からの約 1.7MB と、その先の約 64MB（`0x8040_0000`〜）。`alloc_pages` が配ったのは、free RAM の先頭の数十ページだけで、残りは一度も触れていない、本当の空き RAM。

## 次に試すこと

- [ ] `disk/hello.txt` に文章を入れる
- [ ] `disk/` の中身を git に入れるか決める（`.gitignore` の `/disk/*`）
- [x] `tar tvf disk.tar`、`ls -l disk.tar`、`xxd disk.tar` で、ディスクイメージの中身と大きさを確かめる（大きさは先に予想する）→ 10240 バイト。15 章のテストが先頭のヘッダを壊していた（「fs_init まで入れて起動」）
- [x] `kernel_main` から 15 章の読み書きテストを外す → コメントアウトした
- [x] `user_entry` で `SSTATUS_SUM` を立て、`readfile` と `writefile` が動くか確かめる → 動いた。ホストの `tar` でも読めた（「SUM を立てたあと」「ホストで disk.tar の中身を確かめる」）
- [ ] `tmp/`（展開の確認に使ったフォルダ）を消すか、`.gitignore` に足す
- [x] `writefile` のあと、`info mem` で virtio のページに `a` が付くか確かめる → `rw---ad`（「writefile のあとのシェルの表」）
- [ ] `qemu.log` で、`unimp` のときに M-mode の例外が起きていることを見る（`exception.md` の宿題）

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
