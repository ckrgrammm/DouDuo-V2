# 推荐流供应管线（4-Worker Feed Pipeline + Shared Video Pool）

代码：`DouDuo/DouyinFeedPipeline.swift`（纯 Foundation，可单独编译测试）、`DYFeedModel`（`DouyinFeedView.swift`）。

## 结构

```
UI（DouyinFeedScreen）
  │ focusCurrent → feed.supply(current:)     loadMore / refresh（用户在等）
  ▼
DYFeedModel（@MainActor）── deliver() ← 播放列表 items 唯一的追加出口
  │ demand(ahead:, urgent:) / take(n) / awaitNextMerge()
  ▼
DYFeedCoordinator（actor，独占全部共享状态）
  ├─ 序号 seq（唯一、单调递增，跨刷新不回退）→ refresh_index = seq+1，第一个请求 pull_type=0
  ├─ 在途请求表 + 乱序结果缓冲：按 seq 顺序合并（seq 超时视为失败，不卡后面）
  ├─ DYSharedVideoPool：候选元数据，保持服务端顺序，全来源统一去重，按竖横比例取
  ├─ 水位：待播（列表里当前条之后 + 池）< 8 开始补，补到 20 停
  └─ 保护：并发上限、每轮最多 8 个请求、每分钟 24 个、连续 3 页无新内容暂停 20s、失败指数退避
  │ ticket
  ▼
Worker（只拿票去请求，不碰 refresh_index、不碰播放列表）
  W1 主推荐请求：用户在等 / 待播 < 3 时优先
  W2 主推荐预取：待播 < 20 时补
  W3 后台候选补充：待播 < 20 时补
  W4 备用：有失败时顶上、或待播 < 8；新候选合并后给池子前几条暖封面（只是图片）
```

并发：默认 4 个角色、**同时最多 2 个推荐请求**。`/aweme/v1/web/tab/feed/` 不是游标分页
（refresh_index 是客户端计数，响应里没有游标），所以允许有限并发；若接口改成依赖串行游标，
把 `DYFeedPipelineConfig.serialCursor` 设为 true，并发即锁为 1。

## 缓存分层

| 层 | 内容 | 位置 |
|---|---|---|
| 候选池 | 推荐元数据（≤80 条） | `DYSharedVideoPool`，内存 |
| Forward Buffer | 播放列表里当前条之后 6 条元数据 | `DYFeedModel.items` |
| 播放器预热 | 只给后面 3 条建 `AVPlayer`（发热时 2 / 1） | `DYPreloader` |
| 视频文件 | 当前条整条 + 后 2 条，向上滑优先读本地 | `DYVideoCache`（磁盘） |
| 会话 | 已看过的列表 + 进度，向上滑复用 | `DYFeedSession`（Application Support） |

候选池里的视频不建 `AVPlayer`、不下载视频文件。

## 测试与对比

- 逻辑测试（不需要模拟器 / 网络）：`scripts/test_feed_pipeline.sh`
- 1 / 2 / 4 Worker 实测：`scripts/feed_bench.sh <DouDuo.app> [每轮秒数] [每条停留秒数]`
  - DEBUG 环境变量：`DOUDUO_FEED_WORKERS=1|2|4`、`DOUDUO_FEED_CONCURRENCY`、`DOUDUO_FEED_SERIAL=1`、
    `DOUDUO_FEED_AUTOSWIPE=<秒>`、`DOUDUO_FEED_BENCH_SECS=<秒>`
  - 压测模式从空列表起跑、**不上报观看、不写观看历史、不覆盖保存的会话**
  - 指标：请求延迟 p50/p90、每秒新增唯一视频、重复率、错误率、首帧耗时（切到当前条 → 首帧）、
    滑动等待（切到某条时后面已经没得播）。日志 `DDFEEDBENCH`，结果 `Documents/feed-bench-w*-c*.json`

## 实测（2026-11-11，iOS 26.5 模拟器，每轮 75s、每 1.5s 滑一条，从空列表起跑，各跑一轮）

| workers | 请求数 | 延迟 p50 | 延迟 p90 | 唯一/秒 | 重复率 | 错误率 | 首帧 p50 | 首帧 p90 | 滑动等待 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 13 | 2481ms | 2854ms | 0.91 | 0.0% | 0.0% | 98ms | 1318ms | 0/50 |
| 2 | 12 | 2498ms | 2798ms | 0.93 | 0.0% | 0.0% | 627ms | 1127ms | 0/50 |
| 4 | 14 | 2413ms | 3247ms | 0.93 | 5.3% | 0.0% | 85ms | 919ms | 0/50 |

结论：
- 供应按水位驱动，三档都稳定在待播 20 条附近，一次滑动等待都没有；每秒新增唯一视频受消费速度限制，三档差不多。
- 单页约 2.5 秒、5–6 条，单 Worker 理论供应约 2 条/秒，已经高于这个滑动速度的消耗。并发主要在冷启动、
  刷新和连续失败时有用（W1 + W2/W4 同时发）。
- 4 并发开始出现跨页重复（5.3%），p90 延迟变高，供应却没有增加 → **保持默认并发 2**，不升到 4。
- 首帧耗时主要取决于预加载 / 本地缓存是否命中，跟 Worker 数关系不大；每档只有约 50 个样本、模拟器网络，误差较大。
