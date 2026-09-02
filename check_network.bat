@echo off
title AsthmaGuard 网络连通性检测（PC 端）
echo ==================================================
echo   AsthmaGuard 网络检测（PC 端）
echo   目标服务器: 39.183.171.185:9443
echo ==================================================
echo.
echo [1/3] Ping 测试（服务器可能禁 ping，失败不代表不通）...
ping -n 2 39.183.171.185
echo.
echo [2/3] TCP 9443 端口连通性（关键指标）...
powershell -NoProfile -Command "$r = Test-NetConnection 39.183.171.185 -Port 9443 -WarningAction SilentlyContinue; Write-Host ('TcpTestSucceeded: ' + $r.TcpTestSucceeded); Write-Host ('RemoteAddress    : ' + $r.RemoteAddress)"
echo.
echo [3/3] HTTPS 登录接口实测（跳过证书校验）...
curl.exe -k -s -o nul -w "HTTP 状态码: %%{http_code}，耗时 %%{time_total}s" -m 8 -X POST https://39.183.171.185:9443/api/auth/login -H "Content-Type: application/json" -d "{\"phone\":\"13800138001\",\"password\":\"123456\"}"
echo.
echo.
echo ==================================================
echo 判读指南：
echo.
echo   [2] TcpTestSucceeded: False
echo       = 你的网络到不了服务器 9443 端口（防火墙/运营商拦截）
echo       建议：PC 改连手机热点，重新运行本脚本对比
echo.
echo   [2] True 且 [3] HTTP 200
echo       = PC 网络完全正常，问题只在雷电模拟器
echo       建议：模拟器 设置-网络 改为「桥接模式」后重启
echo.
echo   [2] True 但 [3] 非 200
echo       = 端口通但服务异常，联系后端管理员
echo ==================================================
pause
