# os1k-lab

『1000行でOSを作ってみよう』（[OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/)）を通して、32 ビット RISC-V の小さな OS を作りながら、コンピュータが起動してアプリを動かすまでを調べた実験用のリポジトリ。

- 学習ノート：[docs/index.md](docs/index.md)、まとめ：[docs/summary.md](docs/summary.md)
- ビルドと起動（Arch Linux、clang / lld / LLVM、QEMU）：`make run`（`./run.sh` でも同じ）

このあとは、xv6-riscv などを参考に、必要な機能をかいつまみながら、別のリポジトリ（my-os）で自分の OS を作っていく予定。
