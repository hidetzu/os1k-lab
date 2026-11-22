# 06 C標準ライブラリ

教材：[C標準ライブラリ | OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/06-libc)

## この章で答えたい問い

`-nostdlib` の環境で、型の定義や `memcpy` のような「当たり前にある関数」は誰が用意するのか。

`printf` の本体は前の章（05 Hello World! の「printf関数」）で書く。この章は、型・メモリ操作・文字列操作を `common.c` / `common.h` にそろえる章。

## ファイルとビルドの関係

<!-- common.c / kernel.c → clang → kernel.elf の図。kernel.c から memset を common.c へ移したこと -->

## common.h：基本的な型とマクロ

<!-- 表：名前 / 中身 / なぜ必要か -->

## メモリ操作

<!-- memcpy / memset -->

## 文字列操作

<!-- strcpy / strcmp。strcpy の危険性、strcmp で unsigned char にキャストする理由 -->

## 観察結果

<!-- 実行したコマンド（ホスト / QEMU モニターを区別）と出力 -->

## 次に試すこと

- [ ] `common.c` が両方で使われる仕組みを確かめ、`overview.md` の疑問を閉じる

## 読んだ範囲・動かした範囲・疑問

- 読んだ範囲：
- 動かした範囲：
- 疑問：
