# 開発環境

Arch Linux上に同様の環境を構築する方針で進める。

```bash
sudo pacman -Syu --needed clang llvm lld qemu-system-riscv qemu-system-riscv-firmware curl
```

## パッケージの役割

| パッケージ | 主なコマンド・ファイル | 用途 |
| --- | --- | --- |
| `clang` | `clang` | C をRISC-V 32bit向けにコンパイル（`--target=riscv32-unknown-elf`） |
| `lld` | `ld.lld` | リンカ。リンカスクリプトに従ってカーネルの配置番地を決める |
| `llvm` | `llvm-objdump` `llvm-nm` `llvm-addr2line` `llvm-objcopy` | 逆アセンブル、シンボル確認、アドレス→ソース行の変換、バイナリ変換。デバッグで使う |
| `qemu-system-riscv` | `qemu-system-riscv32` | 32bit RISC-V の `virt` マシンをエミュレート |
| `qemu-system-riscv-firmware` | `/usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin` | OpenSBI（QEMU起動直後に動くファームウェア） |

## 確認したこと

2026-11-21 時点、手元の Arch Linux で確認。

| ツール | バージョン |
| --- | --- |
| clang / llvm / lld | 23.1.5 |
| qemu-system-riscv / qemu-system-riscv-firmware | 11.1.3 |

- コンパイラーが32ビットRISC-Vに対応しているか

```bash
$ clang -print-targets | grep riscv32
    riscv32     - 32-bit RISC-V
    riscv32be   - 32-bit big endian RISC-V
```

`virt` マシンはリトルエンディアンなので、使うのは `riscv32`。

- リンカがあるか

```bash
$ ld.lld --version
LLD 23.1.5 (compatible with GNU linkers)
```

- エミュレータがあるか

```bash
$ qemu-system-riscv32 --version
QEMU emulator version 11.1.3
Copyright (c) 2003-2026 Fabrice Bellard and the QEMU Project developers
```

- OpenSBI があるか

```bash
$ ls /usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin
/usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin
$ pacman -Qo /usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin
/usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin は qemu-system-riscv-firmware 11.1.3-1 によって所有されています
```

## 教材（Ubuntu/macOS手順）との違い

- Arch では OpenSBI のバイナリが `qemu-system-riscv-firmware` パッケージに同梱されている。教材のように別途ダウンロードしなくても、QEMU の `-bios default` で見つかるはず（未確認）。
- バージョンは教材執筆時より新しい。出力例（OpenSBI の起動バナーなど）が教材と違っても、まずバージョン差を疑う。

## 起動バナーで確かめた OpenSBI（2026-11-21）

05 章のカーネルを `./run.sh` で起動したとき、OpenSBI の起動バナーに次のように出た（ホストの Arch、QEMU 11.1.3）。

```
OpenSBI v1.8.1
...
Runtime SBI Version         : 3.0
Standard SBI Extensions     : time,rfnc,ipi,base,hsm,srst,pmu,dbcn,fwft,legacy,dbtr,sse
```

- `qemu-system-riscv-firmware 11.1.3-1` に同梱の OpenSBI は v1.8.1 で、SBI 仕様 3.0 に対応している。
- 教材の手順（別途ダウンロード）は要らず、`-bios default` だけで起動した。
- バナーにはファイル名が出ないので、読み込まれたのが `/usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin` であることは推論のまま。

## 次に試すこと

- [x] 最初に起動したとき、OpenSBI のバージョンを起動バナーで確認する → v1.8.1
- [ ] 読み込まれた OpenSBI のファイルが `/usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin` であることを確かめる（例：`strings` でそのファイルに `v1.8.1` が含まれるか見る）
