#!/bin/bash
# GitHub Actions 用：在 macOS runner 自己的桌面会话里，用 build/DD 下的 Release build 跑自动测试。
# 先运行 Tools/SelfTest/build.sh。SELFTEST_GROUPS 选要跑的几组（Slack、锁屏要人参与，watchdog 会让 Copi 经 Launch Services
# 重新打开、拿不到这里给它的辅助功能权限，这几组默认不跑）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/selftest"
COPI_APP="$ROOT/build/DD/Build/Products/Release/Copi.app"
TEST_APP="$OUT/CopiSelfTest.app"
TEST_GROUPS="${SELFTEST_GROUPS:-basic,browsers,browsermore,terminal,sudo,guard,iterm,vm,vscode,matrix,concealed}"

# 运行环境记进 ci-env.log（和报告一起上传）
exec > >(tee "$OUT/ci-env.log") 2>&1
sw_vers
csrutil status || true

# 辅助功能权限：从这个 shell 直接启动的进程沿用 runner 自己的授权；系统完整性保护关着时，再给 Copi 和测试程序加上明确的授权
if csrutil status 2>/dev/null | grep -qi "disabled"; then
  db="/Library/Application Support/com.apple.TCC/TCC.db"
  for service in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceListenEvent; do
    for client in "$COPI_APP/Contents/MacOS/Copi:1" "$TEST_APP/Contents/MacOS/CopiSelfTest:1" "com.gokoding.Copi:0" "dev.local.CopiSelfTest:0"; do
      sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags)
        VALUES ('$service', '${client%:*}', ${client##*:}, 2, 4, 1, 0);" && echo "granted $service to ${client%:*}" || echo "could not add $service for ${client%:*}"
    done
  done
  sudo pkill -x tccd || true
  sleep 2
else
  echo "SIP is on: relying on the runner's own Accessibility grant being inherited"
fi

# Chrome（这里测 Chromium 用它：Brave 在这台虚拟机上拿不到辅助功能的焦点）第一次启动：不要欢迎页、默认浏览器的提示；
# 不用系统钥匙串（全新的机器上会弹出钥匙串对话框），不找局域网里的投屏设备（会弹出本地网络权限的询问）
if [ -d "/Applications/Google Chrome.app" ]; then
  open -a "Google Chrome" --args --no-first-run --no-default-browser-check --use-mock-keychain --password-store=basic \
    --disable-features=MediaRouter,DialMediaRouteProvider
  sleep 8
fi

# Copi：从这个 shell 直接启动（不经过 Launch Services），沿用 runner 的辅助功能授权
"$COPI_APP/Contents/MacOS/Copi" > "$OUT/copi-stdout.log" 2>&1 &
sleep 8
pgrep -lf "Copi.app/Contents/MacOS/Copi" || echo "Copi is not running"

# 测试程序同样直接启动；最多等 45 分钟
"$TEST_APP/Contents/MacOS/CopiSelfTest" --only="$TEST_GROUPS" &
test_pid=$!
for _ in $(seq 1 2700); do
  kill -0 "$test_pid" 2>/dev/null || break
  sleep 1
done
kill "$test_pid" 2>/dev/null && echo "the self-test was still running after 45 minutes and was stopped"

cat "$OUT/report.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$OUT/report.md" >> "$GITHUB_STEP_SUMMARY"
fi
# 没有报告、整轮中止、有 FAIL 或者一组中止了：这一步算失败（报告照样上传）
[ -f "$OUT/report.md" ] || { echo "no report"; exit 1; }
! grep -qE "\| (FAIL|ABORT) \||\*\*中止\*\*" "$OUT/report.md"
