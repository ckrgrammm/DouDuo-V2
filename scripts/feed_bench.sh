#!/bin/sh
# 推荐流供应对比：1 / 2 / 4 Worker 各跑一轮（Debug 包、模拟器、真实网络）。
# 用法：scripts/feed_bench.sh <DouDuo.app 路径> [每轮秒数=90] [每条停留秒数=3] [模拟器=booted]
# 自动滑动模式不上报观看、不写观看历史（见 DouyinFeedScreen.reportWatch），不影响账号推荐。
# 结果：每轮 App 写 Documents/feed-bench-w<N>-c<N>.json，本脚本汇总成表。
set -e
APP="$1"; SECS="${2:-90}"; STEP="${3:-3}"; DEV="${4:-booted}"
BUNDLE=com.ray.douduo
[ -d "$APP" ] || { echo "用法：$0 <DouDuo.app> [秒数] [停留秒数] [模拟器]"; exit 1; }
xcrun simctl install "$DEV" "$APP"
DOCS="$(xcrun simctl get_app_container "$DEV" $BUNDLE data)/Documents"
for N in 1 2 4; do
  rm -f "$DOCS/feed-bench-w$N-c$N.json"
  xcrun simctl terminate "$DEV" $BUNDLE 2>/dev/null || true
  echo "== workers=$N：跑 ${SECS}s，每 ${STEP}s 滑一条"
  SIMCTL_CHILD_DOUDUO_FEED_WORKERS=$N SIMCTL_CHILD_DOUDUO_FEED_AUTOSWIPE=$STEP SIMCTL_CHILD_DOUDUO_FEED_BENCH_SECS=$SECS \
    xcrun simctl launch "$DEV" $BUNDLE >/dev/null
  waited=0
  while [ ! -f "$DOCS/feed-bench-w$N-c$N.json" ] && [ $waited -lt $((SECS + 60)) ]; do sleep 2; waited=$((waited + 2)); done
  sleep 1
done
xcrun simctl terminate "$DEV" $BUNDLE 2>/dev/null || true
python3 - "$DOCS" <<'EOF'
import json, sys, os
docs = sys.argv[1]
def pct(xs, p):
    if not xs: return None
    s = sorted(xs); return s[min(len(s) - 1, round((len(s) - 1) * p))]
rows = []
for n in (1, 2, 4):
    f = os.path.join(docs, f"feed-bench-w{n}-c{n}.json")
    if not os.path.exists(f): rows.append((n, None)); continue
    rows.append((n, json.load(open(f))))
hdr = ["workers", "req", "p50 延迟", "p90 延迟", "唯一/秒", "重复率", "错误率", "首帧 p50", "首帧 p90", "滑动等待"]
print("| " + " | ".join(hdr) + " |"); print("|" + "---|" * len(hdr))
for n, d in rows:
    if d is None: print(f"| {n} | （没有结果） |"); continue
    ms = lambda v: "-" if v is None else f"{v}ms"
    req = d["requests"]; ret = d["returned"]; act = d["activeSeconds"]
    print("| " + " | ".join([
        str(n), str(req), ms(pct(d["latenciesMs"], .5)), ms(pct(d["latenciesMs"], .9)),
        f'{d["fresh"] / act:.2f}' if act > 0 else "-",
        f'{d["duplicates"] * 100 / ret:.1f}%' if ret else "-",
        f'{(d["failed"] + d["timedOut"]) * 100 / req:.1f}%' if req else "-",
        ms(pct(d["firstFramesMs"], .5)), ms(pct(d["firstFramesMs"], .9)),
        f'{d["swipeWaits"]}/{d["swipes"]}']) + " |")
EOF
