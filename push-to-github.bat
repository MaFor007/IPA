@echo off
chcp 65001 >nul
setlocal

if "%~1"=="" (
  echo 用法: 把仓库地址拖到这个文件上, 或在命令行运行
  echo       push-to-github.bat https://github.com/你的账号/iphone-bridge.git
  echo.
  echo 先在 https://github.com/new 建一个空仓库 ^(不要勾 README^), 再把地址粘过来。
  pause
  exit /b 1
)

set "REMOTE=%~1"
cd /d "%~dp0"

echo [1/4] 准备本地仓库...
if not exist ".git" git init -q
git branch -M main

echo [2/4] 提交改动...
git add -A
git -c user.name="MaFor007" -c user.email="16909462hs@gmail.com" commit -q -m "iPhone Bridge: USB 控制台 + 手机端 App" 2>nul

echo [3/4] 设置远端...
git remote remove origin 2>nul
git remote add origin "%REMOTE%"

echo [4/4] 推送 ^(如果弹出 GitHub 登录窗, 登录一次即可^)...
git push -u origin main
if errorlevel 1 (
  echo.
  echo 推送失败。常见原因: 仓库非空 / 地址写错 / 未登录。
  pause
  exit /b 1
)

echo.
echo ============================================
echo  已推送! 接下来:
echo  1. 打开 %REMOTE%  点上方 Actions
echo  2. 等 "Build TrollStore TIPA" 跑完 ^(约 4 分钟^)
echo  3. 进这次运行, 页面底部下载 iPhoneBridge-tipa
echo  4. 解压出 Bridge.tipa, 传到手机, 用巨魔打开安装
echo ============================================
pause
