# RWFit SDK 原始 PPG 数据获取能力分析

> 分析对象：https://github.com/RWFitSDK 组织下各平台 SDK
> 分析方法：源码通读 + 官方文档 + **AAR 二进制反编译验证**（CFR 0.152）
> 分析日期：2026-09-04
>
> 📄 配套文档：[`RWFIT_SDK_DATA_INVENTORY.md`](RWFIT_SDK_DATA_INVENTORY.md) —— SDK **全量**数据能力清单
> （健康指标 / 全天历史 / 运动 Workout / 设备事件，共五类）

---

## 一、结论（先说答案）

**✅ 可以获取原始 PPG 数据包。** 且不止 PPG——绿光 PPG、红光 PPG、红外 IR、三轴 ACC 全部可拿到**逐采样点的原始整数序列**，不是厂商加工后的心率值。

但有一条**关键限制**必须先知道：

> **原始 PPG 只能"历史补取"，不能真正实时流式推送。**
> 设备端只保留**最近一次约 1 分钟**的数据，采集结束后必须**立刻**同步，否则被下一次采集覆盖。

这一条直接决定了应用架构（详见第五节）。

---

## 二、证据链：这不是推测

我没有只看文档，而是把 AAR 反编译到字节解析层做了交叉验证。

### 2.1 官方文档明确写明（`RW_Android_SDK/doc/blesdkandroid_zh.md` §5.2.5）

```
| PPG/ACC/PPG Red/IR原始数据 | 历史获取 | APP控制设备开始/停止采集, 采集完成后主动同步历史数据 |
| 睡眠状态数据               | 实时推送 | 设备在睡眠过程中自动推送, APP只需订阅回调           |
```

### 2.2 能力位（设备自报，运行时必须先查）

| 配置位 | 含义 |
|---|---|
| `isSupportSensorRawPPG` | 是否支持获取 PPG 原始数据 |
| `isSupportSensorRawACC` | 是否支持获取 ACC 原始数据 |
| `isSupportSensorRawPPGRed` | 是否支持获取 PPG Red 原始数据 |
| `isSupportSensorRawIR` | 是否支持获取 IR 红外原始数据 |
| `isSupportSensorRawSleep` | 是否支持睡眠实时数据 |
| `isSupportPPGMonitoring` | 是否支持 PPG 定时监测 |

### 2.3 反编译验证：字节级解析逻辑

`com/example/blesdk/internal/obfuscated/f.class` 方法 `q()`（历史包解析），确认了真实的**协议帧结构**——文档里没写这一层：

```
偏移 3   : sensorType  (1 字节)  数据类型
偏移 4-5 : sequence    (2 字节, 小端 uint16)  包序号
偏移 6-7 : count       (2 字节, 小端 uint16)  本包采样点数
偏移 8.. : payload
```

payload 按 type 分支解析（关键——**位宽不同**）：

| type | 数据 | 每采样点解析方式 |
|---|---|---|
| 1 | PPG（绿光） | `bytesLE2Int32` → **int32，4 字节/点** |
| 2 | ACC | `bytesLE2Int16` × 3 → x,y,z **各 int16，6 字节/点** |
| 3 | PPG Red | `bytesLE2Int32` → **int32，4 字节/点** |
| 4 | IR | `bytesLE2Int32` → **int32，4 字节/点** |

> 这证明 PPG 是**原始 ADC 计数值**（int32 量程），而非 0-100 或 bpm 之类的加工结果。真原始数据。

### 2.4 反编译还发现了文档未提的实时解析分支

同类中方法 `r()` 是**实时**推送解析器，它的 `type` 分支同样含 `1=PPG / 2=ACC / 3=PPG Red / 4=IR`，另有 `type=0` 授时（时间戳）和 `type=5` 睡眠。

**含义**：固件+SDK 底层其实具备实时推 PPG 的解析能力，但官方文档明确声明 PPG 不走实时通道、仅 `type=5` 睡眠实际启用。

⚠️ **不要依赖这个"隐藏能力"**——它未开放、未承诺、随固件变更即失效。第五节按官方契约设计。

---

## 三、⚠️ 硬约束（照抄自官方 IMPORTANT 块）

| # | 约束 | 后果 |
|---|---|---|
| 1 | **仅历史获取，无实时推送** | 拿不到毫秒级实时波形 |
| 2 | **设备只存最近一次约 1 分钟** | 收到停止通知后不立刻同步 → **数据被覆盖丢失** |
| 3 | **绿光与红光不能共存** | 单次采集只能选一种光源 |
| 4 | **红外不能单独启动**，必须与绿光或红光组合 | `sensorType` 组合受限 |
| 5 | 定时监测与手动测量**共用同一块存储** | 定时监测会覆盖手动采集结果 |
| 6 | **采样率全仓库无任何记载** | 必须实测标定（见第六节） |

---

## 四、API 对照表（四平台均已支持）

### 4.1 核心两步

| 作用 | Android (Kotlin) | iOS (Objective-C) |
|---|---|---|
| 启停采集 | `DHBleSdk.ringControlSensorRaw(outputType, sensorType)` | `[DHBleCommand ringControlSensorRaw:type:block:]` |
| 同步历史 | `DHBleSdk.ringGetHistorySensorRaw()` | `[DHBleCommand ringGetHistorySensorRaw:dataBlock:]` |

| 平台 | 启停 | 同步历史 | 停止事件 |
|---|---|---|---|
| **uni-app x (UTS)** | `controlSensorRaw({enabled, sensorType})` | `getSensorRawHistory({success})` | `onSensorRawStopped(cb)` |
| **Flutter** | `controlSensorRaw(bool, selection)` | `getSensorRawHistory()` | `onSensorRawStopped` (Stream) |
| **微信小程序** | `controlSensorRaw(1\|2, sensorType)` | — | `type:"sensorRaw"` 事件 |
| **HarmonyOS** | ✅ 已支持（30 处 `sensorRaw` 引用） | ✅ | ✅ |

### 4.2 回调

| 回调 | 用途 |
|---|---|
| `SensorRawControlCallback.onSuccess()` | 启停指令下发成功 |
| `SensorRawControlCallback.onResult(reason)` | **设备主动停止 → 立刻同步的信号** |
| `SensorHistoryRawCallback.onResult(List<SensorHistoryRawBean>)` | 返回历史原始数据 |
| `SensorHistoryRawCallback.onSuccess()` | 本次同步完成 |

### 4.3 `sensorType` 合法组合（控制接口用，按位组合）

| 值 | 含义 |
|---|---|
| 1 | 仅 ACC |
| 2 | 仅绿光 PPG |
| **3** | **绿光 + ACC ← 运动伪影去除推荐** |
| 4 | 仅红光 |
| 5 | 红光 + ACC |
| 10 | 绿光 + 红外 |
| 11 | 绿光 + ACC + 红外 |
| 12 | 红光 + 红外 |
| 13 | 红光 + ACC + 红外 |

> 🚨 **极易踩的坑**：控制接口的 `sensorType` 与返回数据的 `type` **编号定义不同**！
> `sensorType=1` = 开启 ACC，但历史数据 `type=1` = PPG。
> `sensorType=5` = 红光+ACC，但实时数据 `type=5` = 睡眠状态。

### 4.4 数据结构 `SensorHistoryRawBean`

```java
int  type;                          // 1=PPG, 2=ACC, 3=PPG Red, 4=IR
int  sequence;                      // 包序号，从1开始；多传感器共用同一序号
List<Integer>     ppgDataList;      // 绿光 PPG，int32
List<AccRawItem>  accDataList;      // ACC，x/y/z 各 int16
List<Integer>     ppgRedDataList;   // 红光 PPG，int32
List<Integer>     irDataList;       // 红外 IR，int32
```

> `sequence` 多传感器共用 → 可用它做 **PPG 与 ACC 的时间对齐**，这是做运动伪影消除的基础。

---

## 五、推荐采集时序（含防丢数据设计）

```
1. 查能力位 isSupportSensorRawPPG / isSupportSensorRawACC   ← 必须先查，勿假设
2. 订阅 SensorRawControlCallback + SensorHistoryRawCallback  ← 必须先订阅再启动
3. ringControlSensorRaw(1, 3)        // 启动：绿光 + ACC
4. 设备采集约 1 分钟
5. onResult(reason) 触发             // 设备主动停止
6. 【立刻】ringGetHistorySensorRaw()  // ⚠️ 不能延迟，否则被覆盖
7. onResult 收包 → 按 sequence 排序拼接 → 落本地库
8. onSuccess 同步完成 → 再上传后端
```

### 工程上必须做的三件事

1. **先落盘再上传**：第 7 步先写本地存储，网络失败可重传。直接上传会因断网永久丢数据。
2. **采集期间禁用 PPG 定时监测**：两者共用存储，定时监测会覆盖手动采集结果。
3. **给 `onResult` 加超时兜底**：若停止通知丢失（BLE 不可靠），用定时器在预期时长后主动触发同步。

---

## 六、必须实测标定的项

| 项 | 为什么必须实测 |
|---|---|
| **采样率 fs** | 全仓库零记载（已 grep 确认）。**直接决定滤波器系数、FFT 频率轴、HR/HRV 全部算法参数** |
| 单包 count / 总包数 | 决定缓冲区与拼接策略 |
| PPG 数值量程与基线 | int32 但实际有效位宽未知，影响归一化 |
| ACC 量程（g/LSB） | 影响伪影消除阈值 |
| 实际采集时长 | "约 1 分钟"是模糊表述 |

**采样率标定方法**：采一次完整 1 分钟，`fs ≈ PPG 总采样点数 / 实际采集秒数`。建议重复 3 次取均值，并用已知心率（同步戴指夹式血氧仪）做交叉校验。

> ⚠️ 在标定完成前，任何频域算法（HR/HRV/呼吸率）结果都不可信。当前项目 `utils/rwble.uts` 中 mock 的 `fs = 125` 是**占位假设值，无出处**，切勿当作真实值使用。

---

## 七、对本项目（哮卫 AsthmaGuard）的落地修正

分析中发现当前 `utils/rwble.uts` 与 `README.md` 存在与官方契约不符之处：

| 位置 | 现状 | 应修正为 |
|---|---|---|
| `README.md` §4.2 表格 | `RwBleRing.initSDK()`、`controlHealthDataJL()`、`ringControlSensorRaw()` | 这些名字在 `rwfit-ble` 官方 `interface.uts` 中**不存在**（`ringControlSensorRaw` 是 **Android 原生 SDK** 名，UTS 插件里叫 `controlSensorRaw`） |
| `README.md` §4.3 时序 | 写的是原生 SDK 名 | 应改用 UTS 名：`controlSensorRaw` / `getSensorRawHistory` |
| `utils/rwble.uts` L342 | `fs: 125` | 标注为未标定占位值，实测后替换 |

✅ `utils/rwble.uts` 文件头注释已正确记录了这次纠偏（模块名应为 `rwfit-ble`、真实契约是 options 对象风格），该判断与本次核查一致。

---

## 八、附：本次分析所用命令（可复现）

```bash
# 克隆各平台 SDK
git clone --depth 1 https://github.com/RWFitSDK/RW_Android_SDK.git
git clone --depth 1 https://github.com/RWFitSDK/rw-uniapp-uts-plugin.git
git clone --depth 1 https://github.com/RWFitSDK/RW_flutter_plugin.git

# 反编译 AAR 验证字节级协议
unzip -o blesdk-rwfit-release_v2_260820.aar      # → classes.jar
unzip -o classes.jar -d cls
curl -sLO https://github.com/leibnitz27/cfr/releases/download/0.152/cfr-0.152.jar
java -jar cfr-0.152.jar cls/com/example/blesdk/internal/obfuscated/f.class > f.java
# 看 q()=历史包解析，r()=实时包解析
```
