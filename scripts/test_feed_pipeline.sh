#!/bin/sh
# 推荐流管线逻辑测试（macOS 本机编译运行，不需要模拟器 / 网络）
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/dd_feed_pipeline_test"
mkdir -p "$work"
cp scripts/test_feed_pipeline.swift "$work/main.swift"
xcrun swiftc -D DEBUG -swift-version 5 -o "$work/run" DouDuo/DouyinFeedPipeline.swift "$work/main.swift"
"$work/run"
