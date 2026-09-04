# 移动端 APP（哮卫 AsthmaGuard）

uni-app x（UTS）移动应用，连接 RWFit 智能戒指，实现儿童哮喘可穿戴监测。

## 一、技术栈

| 项 | 选型 |
|----|------|
| 框架 | uni-app x（5.x）+ UTS |
| 语言 | UTS（类 TypeScript，编译为 Kotlin/Swift/ArkTS）|
| 状态管理 | 全局 reactive 变量（Android VDOM 不支持 Pinia）|
| 蓝牙 | rw-uniapp-uts-plugin（RWFit 官方，插件市场 id 27471）|
| IDE | HBuilderX（Alpha 版）|
| 后端 | https://39.183.171.185:9443/api |

## 二、工程结构

```
app/
├── App.uvue               # 根组件（应用生命周期）
├── main.uts               # 入口文件
├── manifest.json          # 应用配置（含 uni-app-x 标记、蓝牙/定位权限）
├── pages.json             # 页面路由 + tabBar 配置
├── uni.scss               # 全局样式变量
├── pages/                 # 页面（.uvue 文件）
│   ├── login/             # 登录/注册
│   ├── home/              # 首页（实时指标 + 预警）
│   ├── device/            # 设备管理（扫描/连接/绑定）
│   ├── measure/           # 手动检测（原始PPG采集）
│   ├── history/           # 历史记录（预警 + 反馈）
│   └── profile/           # 个人中心（反馈 + 退出）
├── api/index.uts          # 后端 API 客户端
├── common/request.uts     # HTTP 请求封装（统一鉴权）
├── store/                 # 全局 reactive 状态管理
│   ├── user.uts           # 用户状态（token/用户信息）
│   └── device.uts         # 设备状态（当前连接设备）
├── utils/rwble.uts        # RWFit 蓝牙适配层（含 mock 回退）
└── uni_modules/           # UTS 插件目录（放 rw 插件）
```

## 三、打开与运行

1. **下载 HBuilderX Alpha 版**：https://www.dcloud.io/hbuilderx.html
2. **打开项目**：文件 → 导入 → 选择本 `app/` 目录
3. **安装依赖**：HBuilderX 会自动识别并安装
4. **运行到真机**：运行 → 运行到手机或模拟器 → Android App 基座

> ⚠️ uni-app x 目前仅支持真机运行，不支持断点 debug，也不支持 H5 完整预览。

## 四、硬件接入（重要，硬件到位后必做）

当前 `utils/rwble.uts` 中 `USE_MOCK = true`（模拟模式），所有页面可独立联调。**拿到戒指硬件后**，按以下步骤接入真实插件：

### 4.1 导入 rw 插件

1. 在 HBuilderX 插件市场搜索 `rw-uniapp-uts-plugin`（或 id 27471）
2. 导入到项目的 `uni_modules/` 目录
3. 插件模块名通常是 `hl-rwble-ring`

### 4.2 启用真实调用

编辑 `utils/rwble.uts`，将 `USE_MOCK` 改为 `false`，并取消注释各 TODO 处的真实插件调用。关键 API 对应关系：

> ⚠️ 下表已按官方 `uni_modules/rwfit-ble/utssdk/interface.uts` 核对更新。
> 早期版本此处填的是 `RwBleRing.initSDK()` / `controlHealthDataJL()` / `ringControlSensorRaw()`，
> **这些名字在 UTS 插件中不存在**（`ringControlSensorRaw` 属于 Android 原生 SDK）。
> 真实契约是 uni 风格 options 对象 + 独立 `onXxx` 事件订阅。

| 适配层方法 | 真实插件 API（UTS） | 说明 |
|-----------|-------------|------|
| `initSDK()` | `initialize({ success, fail })` | 初始化 |
| `startScan()` | `startScan({})` + `onScanResult(cb)` | 扫描设备 |
| `connect()` | `connect({ deviceId })` | 连接设备 |
| `startHealthData()` | `startRealtimeMeasure({ metric })` + `onRealtimeData(cb)` | 实时结果值（HR/血氧/HRV）|
| `startRawPpgCapture()` | `controlSensorRaw({ enabled, sensorType })` + `getSensorRawHistory()` | 原始PPG采集 + 同步 |

### 4.3 原始 PPG 采集时序（关键）

```
1. 查能力位 isSupportSensorRawPPG / isSupportSensorRawACC   # 必须先查
2. 订阅 onSensorRawStopped                                  # 先订阅再启动
3. controlSensorRaw({ enabled: true, sensorType: 3 })       # 启动：绿光 + ACC
4. 设备采约 1 分钟
5. onSensorRawStopped 触发（设备主动停止）
6. getSensorRawHistory()                 # 立即同步（避免数据被覆盖）
7. 按 sequence 排序拼接 → 先落本地库
8. 再上传 /api/data/raw-ppg
```

⚠️ **硬件约束**：
- **原始 PPG 仅支持历史获取，无实时推送**
- 设备仅存最近一次约 1 分钟数据，必须在停止通知后**立即同步**，否则被覆盖
- 绿光/红光不能共存；红外不能单独启动，须与绿光或红光组合
- PPG 定时监测与手动采集**共用同一块存储**，采集期间应关闭定时监测
- 采样率**全仓库无记载，必须实测标定**（`utils/rwble.uts` 中 `fs: 125` 仅为占位假设值）

> 📄 完整分析（含 AAR 反编译验证的字节级协议、四平台 API 对照、数据结构）见
> [`docs/RWFIT_SDK_RAW_PPG_ANALYSIS.md`](docs/RWFIT_SDK_RAW_PPG_ANALYSIS.md)

## 五、后端对接配置

后端地址在 `common/request.uts` 的 `BASE_URL` 常量：

```typescript
export const BASE_URL = 'https://39.183.171.185:9443'
```

当前是自签证书 HTTPS，所以请求封装里设置了 `sslVerify: false`。

### API 对照表

| 移动端方法 | 后端端点 |
|-----------|---------|
| `authApi.login` | `POST /api/auth/login` |
| `authApi.register` | `POST /api/auth/register` |
| `deviceApi.mine` | `GET /api/devices/mine` |
| `deviceApi.bind` | `POST /api/devices/{id}/bind` |
| `deviceApi.unbind` | `POST /api/devices/{id}/unbind` |
| `dataApi.uploadHardwareResult` | `POST /api/data/hardware-result` |
| `dataApi.uploadRawPPG` | `POST /api/data/raw-ppg` |
| `alertApi.list` | `GET /api/alerts` |
| `feedbackApi.submit` | `POST /api/feedbacks/` |

## 六、设备绑定权限（已解决）

后端已支持普通 `user`/`guardian` 角色通过移动端绑定/解绑设备：

- `GET /api/devices/mine`：任何登录用户查询自己的设备
- `bind`：user/guardian 可绑定到自己或自己的被监护孩子；admin/doctor 绑定任意用户
- `unbind`：user 解绑自己的设备；admin/doctor 解绑任意设备
- 越权操作（绑定到他人、解绑他人设备）返回 403

## 七、云打包注意事项

- uni-app x 目前只支持打包 APK（Android），不支持 iOS 云打包
- AppID 已配置为 DCloud 正式签发值 `__UNI__9E0A6C2`（应用名 Asthma Guard，类型 uni-app x）
  - ⚠️ **切勿再点「重新获取 AppID」**：会导致已购插件（rw 蓝牙，market id 27471）无法关联，且旧 AppID 云打包报「AppID 无效」
- 如需 uni-push：uni-app x 靠**摇树机制**，不在 `modules` 勾 Push，须先在代码中写 `uni.getPushClientId` 再打**自定义调试基座**
- 蓝牙权限已在 manifest.json 配置（Android 12+ 的 BLUETOOTH_SCAN/CONNECT 已包含）

## 八、当前状态

- ✅ 工程骨架（manifest/pages/App.uvue/main.uts）
- ✅ API 层 + 状态管理
- ✅ 蓝牙适配层（mock 回退）
- ✅ 6 个核心页面
- ⬜ 真实插件接入（待硬件 + HBuilderX）
- ⬜ 真机联调 + 云打包
