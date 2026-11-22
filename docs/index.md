# 学習ノート目次

『1000行でOSを作ってみよう』（[OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/ja/)）を主教材に、32ビット RISC-V の小さな OS を作りながら、コンピュータが起動してアプリを動かすまでを理解する。

最初の問い：カーネルを誰がメモリに配置し、CPU はどうやって自分が書いた最初の命令に到達するのか。

| 章 | ノート | 教材 |
| --- | --- | --- |
| 01 開発環境のセットアップ | [setup-arch.md](setup-arch.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/01-setting-up-development-environment) |
| 02 RISC-V入門 | [riscv-intro.md](riscv-intro.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/02-assembly) |
| 03 OSの全体像 | [overview.md](overview.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/03-overview) |
| 04 ブート | [boot.md](boot.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/04-boot) |
| 05 Hello World! | [hello-world.md](hello-world.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/05-hello-world) |
| 06 C標準ライブラリ | [libc.md](libc.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/06-libc) |
| 07 カーネルパニック | [kernel-panic.md](kernel-panic.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/07-kernel-panic) |
| 08 例外処理 | [exception.md](exception.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/08-exception) |
| 09 メモリ割り当て | [memory-allocation.md](memory-allocation.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/09-memory-allocation) |
| 10 プロセス | [process.md](process.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/10-process) |
| 11 ページテーブル | [page-table.md](page-table.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/11-page-table) |
| 12 アプリケーション | [application.md](application.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/12-application) |
| 13 ユーザーモード | [user-mode.md](user-mode.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/13-user-mode) |
| 14 システムコール | [system-call.md](system-call.md) | [リンク](https://operating-system-in-1000-lines.vercel.app/ja/14-system-call) |
