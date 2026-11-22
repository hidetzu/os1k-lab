#!/bin/bash
# ビルドと起動の手順は Makefile にまとめた。
# ノートに書いた ./run.sh の手順がそのまま使えるように、このスクリプトは残している。
set -e
exec make run
