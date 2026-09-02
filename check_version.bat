@echo off
title AsthmaGuard 版本自检
echo ============================================
echo        AsthmaGuard 版本自检工具
echo ============================================
echo.
set "DIR=F:\asthmaguard-app"

if not exist "%DIR%" (
  echo [错误] 目录 F:\asthmaguard-app 不存在！
  echo        请确认解压位置。
  pause
  exit /b
)

echo [1/4] 检查嵌套目录（解压错位的元凶）...
if exist "%DIR%\asthmaguard-app" (
  echo   [问题] 发现嵌套目录 F:\asthmaguard-app\asthmaguard-app
  echo          解压时多套了一层！新文件全在里面，项目用的还是旧文件。
  echo          修复：把嵌套目录里的所有文件剪切到 F:\asthmaguard-app 根下覆盖。
) else if exist "%DIR%\asthmaguard-app-fixed" (
  echo   [问题] 发现嵌套目录 F:\asthmaguard-app\asthmaguard-app-fixed
  echo          解压时多套了一层！新文件全在里面，项目用的还是旧文件。
  echo          修复：把嵌套目录里的所有文件剪切到 F:\asthmaguard-app 根下覆盖。
) else (
  echo   [正常] 无嵌套目录
)
echo.

echo [2/4] 检查关键文件是否存在...
if not exist "%DIR%\pages\login\login.uvue" (
  echo   [错误] 找不到 pages\login\login.uvue
  echo          目录结构不对，请截图 F:\asthmaguard-app 下的内容反馈。
  echo.
  echo   当前目录内容：
  dir /b "%DIR%"
  pause
  exit /b
)
echo   [正常] login.uvue 存在
echo.

echo [3/4] 检查文件版本（识别是否为最新代码）...
findstr /C:"build 09-02 17:10" "%DIR%\pages\login\login.uvue" >nul 2>&1
if %errorlevel%==0 (
  echo   [正常] 磁盘文件已是最新版 build 09-02 17:10
) else (
  echo   [问题] 磁盘文件是旧版本！覆盖没有成功。
  echo          可能原因：下载的是旧 zip / 解压到了别处 / 没有选"覆盖"。
  echo          当前文件里的版本标识（若无输出说明是 14:50 前的更早版本）：
  findstr /C:"build " "%DIR%\pages\login\login.uvue"
)
echo.

echo [4/4] 检查 HBuilderX 编译产物缓存...
if exist "%DIR%\unpackage" (
  echo   [提示] 存在 unpackage 编译缓存目录。
  echo          若磁盘文件是新的但 App 显示旧界面，
  echo          请在 HBuilderX 中: 菜单「运行」-「运行到手机或模拟器」
  echo          -「清除缓存后运行」，或直接删除 unpackage 文件夹后重新运行。
) else (
  echo   [提示] 未发现 unpackage 缓存目录（可能项目从未编译成功）
)
echo.
echo ============================================
echo 结论：App 里看登录页底部小字
echo   显示「build 09-02 17:10」= 新版已生效
echo   不显示或显示其他版本      = 旧版仍在运行
echo ============================================
pause
