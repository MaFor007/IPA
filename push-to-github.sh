# 一键推到 GitHub 并触发云端构建（Windows / macOS 通用）
# 用法:  bash push-to-github.sh git@github.com:你的账号/iphone-bridge.git
set -e
cd "$(dirname "$0")"

REMOTE="$1"
if [ -z "$REMOTE" ]; then
  echo "用法: bash push-to-github.sh <仓库地址>"
  echo "例:   bash push-to-github.sh https://github.com/xxx/iphone-bridge.git"
  exit 1
fi

if [ ! -d .git ]; then
  git init -q
  git branch -M main 2>/dev/null || true
fi

git add -A
git commit -q -m "iPhone Bridge: USB 控制台 + 手机端 App" 2>/dev/null || echo "(没有新改动)"

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE"
git push -u origin main

echo ""
echo "已推送。接下来："
echo "1. 打开仓库的 Actions 页面，等 Build TrollStore TIPA 跑完（约 3-5 分钟）"
echo "2. 在该次运行页面底部下载 iPhoneBridge-tipa 工件"
echo "3. 解压得到 Bridge.tipa，传到手机用 TrollStore 安装"
