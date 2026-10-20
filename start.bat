@echo off
chcp 65001 >nul
title iPhone Bridge
cd /d "%~dp0"

echo ============================================
echo   iPhone Bridge
echo ============================================
echo.

rem ---------- 1. 找 Python ----------
set "PYEXE="
where python >nul 2>&1 && set "PYEXE=python"
if not defined PYEXE if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set "PYEXE=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
if not defined PYEXE if exist "%LOCALAPPDATA%\Programs\Python\Python313\python.exe" set "PYEXE=%LOCALAPPDATA%\Programs\Python\Python313\python.exe"
if not defined PYEXE (
  echo [x] 没找到 Python，请先安装 Python 3.10+ 并勾选 "Add python.exe to PATH"
  echo     下载: https://www.python.org/downloads/
  pause & exit /b 1
)
echo [1/3] Python: %PYEXE%

rem ---------- 2. 虚拟环境 ----------
if not exist ".venv\Scripts\python.exe" (
  echo [2/3] 首次运行，创建虚拟环境...
  %PYEXE% -m venv .venv
) else (
  echo [2/3] 虚拟环境已就绪
)
set "VPY=.venv\Scripts\python.exe"

rem ---------- 3. 依赖 ----------
"%VPY%" -c "import pymobiledevice3" >nul 2>&1
if errorlevel 1 (
  echo [3/3] 安装 USB 通信组件，请稍候...
  "%VPY%" -m pip install -q --upgrade pip >nul 2>&1
  "%VPY%" -m pip install -q pymobiledevice3 -i https://pypi.tuna.tsinghua.edu.cn/simple
  "%VPY%" -c "import pymobiledevice3" >nul 2>&1
  if errorlevel 1 (
    echo       镜像失败，改用官方源重试...
    "%VPY%" -m pip install -q pymobiledevice3
  )
  "%VPY%" -c "import pymobiledevice3" >nul 2>&1
  if errorlevel 1 (
    echo [warn] 依赖安装失败：原生模式不可用，但剪贴板/文件功能只要手机端 App 在就能用
  ) else (
    echo       完成
  )
) else (
  echo [3/3] 依赖已就绪
)

rem ---------- 4. 苹果驱动检查 ----------
sc query "Apple Mobile Device Service" >nul 2>&1
if errorlevel 1 (
  echo.
  echo [warn] 没检测到 "Apple Mobile Device Service"
  echo        插上线也认不到设备。请安装 iTunes 或 Microsoft Store 的「Apple 设备」：
  echo        https://www.apple.com.cn/itunes/
  echo.
) else (
  echo [ok] 苹果 USB 服务运行中
)

echo.
echo ============================================
echo   控制台: http://127.0.0.1:8770
echo   关闭本窗口 = 停止服务
echo ============================================
echo.

"%VPY%" pc\server.py
pause
