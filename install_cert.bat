@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title AsthmaGuard 证书安装 v6（bind mount + 软重启 zygote）

echo ==========================================================
echo  证书安装 v6：bind mount 正确路径 + 软重启
echo  关键：App 进程继承 zygote 的挂载表，bind mount 后
echo        必须重启 zygote 才能被 App 看到
echo ==========================================================
echo.
echo  【重要】运行本脚本前请先完全关闭 HBuilderX！
echo  （HBuilderX 会抢占 adb 连接导致脚本卡死）
echo.
choice /c YN /m "确认 HBuilderX 已关闭，按 Y 继续"
if !errorlevel! neq 1 exit /b 0

set "ADB="
for %%p in (
  "C:\Program Files\HBuilderX\plugins\launcher\tools\adbs\adb.exe"
  "D:\Program Files\HBuilderX\plugins\launcher\tools\adbs\adb.exe"
  "C:\HBuilderX\plugins\launcher\tools\adbs\adb.exe"
  "D:\HBuilderX\plugins\launcher\tools\adbs\adb.exe"
  "C:\Program Files\HBuilderX\plugins\adb\adb.exe"
  "D:\Program Files\HBuilderX\plugins\adb\adb.exe"
  "C:\leidian\LDPlayer9\adb.exe"
  "D:\leidian\LDPlayer9\adb.exe"
  "C:\leidian\LDPlayer\adb.exe"
  "D:\leidian\LDPlayer\adb.exe"
  "C:\LDPlayer\LDPlayer9\adb.exe"
  "D:\LDPlayer\LDPlayer9\adb.exe"
) do (
  if not defined ADB if exist %%p set "ADB=%%~p"
)
if not defined ADB (
  where adb >nul 2>&1
  if !errorlevel! == 0 set "ADB=adb"
)
if not defined ADB (
  echo [错误] 没找到 adb.exe
  pause
  exit /b 1
)
echo [1/8] adb: !ADB!
"%ADB%" start-server >nul 2>&1

"%ADB%" connect 127.0.0.1:5555 >nul 2>&1
timeout /t 2 /nobreak >nul
set "SERIAL="
for /f "skip=1 tokens=1,2" %%a in ('"%ADB%" devices 2^>nul') do (
  if "%%b" == "device" if not defined SERIAL set "SERIAL=%%a"
)
if not defined SERIAL (
  echo [错误] 未发现模拟器，请先启动雷电模拟器到桌面
  pause
  exit /b 1
)
echo [2/8] 已连接: !SERIAL!

echo [3/8] 提权 root（连接会闪断几秒，自动重连）...
"%ADB%" -s !SERIAL! root >nul 2>&1
timeout /t 3 /nobreak >nul
"%ADB%" connect 127.0.0.1:5555 >nul 2>&1
timeout /t 2 /nobreak >nul
"%ADB%" -s !SERIAL! shell id > "%TEMP%\agid.txt" 2>&1
findstr /c:"uid=0" "%TEMP%\agid.txt" >nul
if !errorlevel! neq 0 (
  echo [错误] shell 不是 root，请在雷电设置-其他设置开启 ROOT 权限并重启模拟器
  pause
  exit /b 1
)
echo       root OK

echo [4/8] 推送证书文件...
"%ADB%" -s !SERIAL! push "%~dp055e9d4fc.0" /data/local/tmp/55e9d4fc.0
if !errorlevel! neq 0 goto :FAIL
"%ADB%" -s !SERIAL! push "%~dp09d171311.0" /data/local/tmp/9d171311.0
if !errorlevel! neq 0 goto :FAIL

echo [5/8] 复制系统证书 + 注入 + bind mount...
"%ADB%" -s !SERIAL! shell "setenforce 0; rm -rf /data/local/tmp/ag_cacerts; mkdir -p /data/local/tmp/ag_cacerts; cp /system/etc/security/cacerts/* /data/local/tmp/ag_cacerts/; cp /data/local/tmp/55e9d4fc.0 /data/local/tmp/ag_cacerts/; cp /data/local/tmp/9d171311.0 /data/local/tmp/ag_cacerts/; chmod 644 /data/local/tmp/ag_cacerts/*; chcon u:object_r:system_file:s0 /data/local/tmp/ag_cacerts; chcon u:object_r:system_file:s0 /data/local/tmp/ag_cacerts/*; mount --bind /data/local/tmp/ag_cacerts /system/etc/security/cacerts; echo MOUNT_RC=$?"

echo [6/8] 验证注入（应列出 55e9d4fc 和 9d171311）：
"%ADB%" -s !SERIAL! shell "ls /system/etc/security/cacerts/ | grep -E '55e9d4fc|9d171311'"

echo [7/8] 软重启 zygote（约 60-90 秒，模拟器画面会卡住再恢复）...
timeout /t 3 /nobreak >nul
"%ADB%" -s !SERIAL! shell "stop; start"
echo 等待系统恢复...
timeout /t 45 /nobreak >nul
"%ADB%" connect 127.0.0.1:5555 >nul 2>&1
timeout /t 20 /nobreak >nul

echo [8/8] 确认系统已上线：
"%ADB%" devices
echo.
echo ==========================================================
echo  完成！现在打开 HBuilderX：
echo  1. 运行窗口若「获取不到设备」，点右上角 刷新(R)
echo     —— 耐心等，千万别重启模拟器！
echo  2. 重新「运行到 Android App 基座」
echo  3. 登录 13800138001 / 123456
echo.
echo  若模拟器日后重启，重跑本脚本即可（约 2 分钟）
echo ==========================================================
pause
exit /b 0

:FAIL
echo.
echo 失败，请截图反馈以上全部输出
pause
exit /b 1
