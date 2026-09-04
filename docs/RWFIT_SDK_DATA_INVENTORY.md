# RWFit SDK 全量数据能力清单

> 配套文档：[`RWFIT_SDK_RAW_PPG_ANALYSIS.md`](RWFIT_SDK_RAW_PPG_ANALYSIS.md)（原始 PPG 专项分析）
> 依据：`RW_Android_SDK/doc/blesdkandroid_zh.md`（2803 行）+ `rwfit-ble/utssdk/interface.uts`（202 个类型 / 85 个 API）
> 分析日期：2026-09-04

---

## 一、总览：数据分五类

| 类别 | 通道 | 时效 | 能否拿到"原始"级 |
|---|---|---|---|
| **A. 传感器原始数据** | 历史补取 | 仅存最近 1 分钟 | ✅ 原始 ADC 值 |
| **B. 健康指标（实时单次）** | 实时推送 | 即时 | ❌ 仅结果值 |
| **C. 健康指标（全天历史）** | 主动同步 | 设备存 **3-6 天** | ❌ 仅结果值 |
| **D. 运动 Workout** | 实时 + 报告 | 实时/结束后 | ❌ 仅结果值 |
| **E. 设备与交互事件** | 实时推送 | 即时 | — |

> **核心认知**：只有 A 类是真正的原始波形。B/C/D 类都是设备固件算好的**结果值**（bpm、%、mmHg），拿不到中间波形。

---

## 二、A 类：传感器原始数据（唯一的原始级）

| 数据 | 数据 `type` | 精度 | 说明 |
|---|---|---|---|
| PPG 绿光 | 1 | **int32/点** | 原始 ADC 计数值 |
| ACC 三轴 | 2 | **3×int16/点** | x / y / z |
| PPG 红光 | 3 | **int32/点** | 与绿光互斥 |
| IR 红外 | 4 | **int32/点** | 不能单独启动 |
| 睡眠状态 | 5 | 时间戳+模式 | **唯一走实时推送的原始类数据** |

详见专项分析文档。关键约束：**仅历史获取、只存 1 分钟、绿光红光互斥、采样率未记载**。

---

## 三、B 类：健康指标 —— 实时单次检测

**API**：`controlHealthDataJL(healthType, testStatus)` → 回调 `HealthDataBroCallback`

| 指标 | 常量 | 单位 |
|---|---|---|
| 心率 | `JL_HR_DATA_TRANSFER_KEY` | bpm |
| 血氧 | `JL_BO_DATA_TRANSFER_KEY` | % |
| HRV | `JL_HRV_DATA_TRANSFER_KEY` | ms |
| 压力 | `JL_PRESSURE_DATA_TRANSFER_KEY` | 无单位 |
| 血糖 | `JL_BLOODSUGAR_DATA_TRANSFER_KEY` | float |
| 血压 | `JL_BP_DATA_TRANSFER_KEY` | mmHg（sp/dp 双值）|
| 体温 | `JL_TEMP_DATA_TRANSFER_KEY` | temp/10 ℃ |

> 🚨 **硬约束（官方 CAUTION）**：**同一时间只能开启一种健康检测类型**。必须等当前检测结束（收到完成回调）或主动关闭后才能启动新类型，同时开多种会导致**检测异常**。
>
> ⚠️ **睡眠无实时检测**。
>
> 💡 完成判定：`HealthDataControlCallback.onResult(data)` 中 `data >= 10` 表示测量完成。

---

## 四、C 类：健康指标 —— 全天历史同步

**API**：`syncAllHealthData(cb)`（按能力表自动遍历支持的类型）或 `syncHealthDataByType(type, cb)`

**保留期：设备可存 3-6 天**（远优于原始 PPG 的 1 分钟）

### 4.1 十类数据

| 数据 | 回调 | 数值字段 | 单位/换算 |
|---|---|---|---|
| 计步 | `onSyncStep` | `steps` / `calorie` / `distance` | 步 / cal / m |
| 睡眠 | `onSyncSleep` | `sleepType` / `len` | 分钟 |
| 心率 | `onSyncHr` | `hr` | bpm |
| 血压 | `onSyncBp` | **`sp` + `dp`** | mmHg |
| 血氧 | `onSyncBo` | `bloodOxy` | % |
| 体温 | `onSyncTemp` | `temp` | **实际 = temp / 10 ℃** |
| 压力 | `onSyncPressure` | `pressure` | 无单位 |
| 血糖 | `onSyncBloodSugar` | `sugar` | **float** |
| HRV | `onSyncHrv` | `hrv` | ms |
| 赞念 | `onSyncMuslimCount` | `count` | 次（按小时）|

> 🚨 **官方 CAUTION 两条易错点**：
> - 血压含 `sp`/`dp` **两个值，不可按单值处理**
> - 血糖 `sugar` 为 **float，不可按整数处理**

### 4.2 时间戳陷阱（官方 IMPORTANT）

> `time` / `timeMills` / `timestamp` / `asleepTime` / `awakeTime` **全部是 Unix 秒**。
> **`timeMills` 是历史命名，实际不是毫秒**——转 Java 毫秒需 `× 1000`。

### 4.3 计步的特殊行为

> 🚨 若设备有历史数据，`onSyncStep` **会分两次回调**：第一次今天计步（通常单个 Bean），第二次历史计步（可能多日）。按"只回调一次"写逻辑会丢数据。

| | items 内容 | 总数来源 | 明细间隔 |
|---|---|---|---|
| 今天 | 设备实际返回明细 | 设备返回的当天总计 | `activityDataInterval`：10 或 60 分钟 |
| 历史 | 按日期分组的明细 | 对当天明细**求和** | 固定 60 分钟 |

以 `StepItemBean.timestamp` 为准确时间。

### 4.4 睡眠分期

`SleepItemBean`：`sleepType` = 0.清醒 / 1.浅睡 / 2.深睡 / 3.REM，`len` = 该状态持续分钟数。
另有 `isTemporary`：0 正式 / 1 临时数据。

> ⚠️ 注意 A 类实时睡眠推送的编码**不同**：17=睡眠开始 / 34=睡眠结束 / 1=深睡 / 2=浅睡 / 3=清醒 / 4=REM。两套编码不可混用。

### 4.5 全天监测间隔设置

> ⚠️ **只有心率可设间隔（30 或 60 分钟）**；血氧/HRV/压力/血糖**仅能开关**。起止时间固定全天不可改。
> 另支持 PPG 定时监测（`isSupportPPGMonitoring`）与温度定时监测（`isSupportTemperatureMonitoring`）。

---

## 五、D 类：运动 Workout

| API | 作用 |
|---|---|
| `getSportStatusJL()` | 获取设备当前运动状态 |
| `controlSportJL()` | 控制进入/退出运动 |
| `setExerciseMore(1/0)` | 开关运动数据实时通知 |
| `getSport3ResultJL()` | 获取运动报告 |

**实时**（`WorkoutRealtimeData`）：`duration` / `steps` / `distance` / `calorie` / `heartRate`

**报告**（`WorkoutReport` / `SportResultBean`）：
`startTime` `endTime` `sportType` `duration` `step` `distance` `calorie` `height` `pressure` `cadence` `speed` `pace` `averageHeartRate` `maxHeartRate` `minHeartRate` `maxCadence/minCadence` `maxPace/minPace` `viewType`
+ **`heartRateItems`（运动中心率序列，1 分钟一个点）**
+ `pacePerKmItems`（每公里配速，不支持则为 null）

> 💡 `heartRateItems` 是除 C 类外另一条**心率时序**来源，做运动分析时可用。
> ⚠️ `viewType` 指示当前运动类型有无步数/步频/配速/距离，UI 渲染前必须判断，否则会显示无意义的 0。

---

## 六、E 类：设备信息与交互事件

### 6.1 设备信息（可读）

| 数据 | API | 内容 |
|---|---|---|
| 固件/型号 | `getFirmwareVersionJL()` | `deviceClazz`(型号唯一标识) `deviceNo`(固件版本) `screenType`(0方/1圆) `screenWidth/Height` `uiVersion` |
| 电量 | `getPowerJL()` | `power` 0-100 |
| 能力表 | `onRingDidFunctionMenu()` | **48+ 项功能位**（见 §7）|
| SDK 版本 | `getSDKVersion()` | — |

> 🚨 OTA 前**必须校验 `deviceClazz` 与固件型号一致**，不一致禁止升级（刷错固件可能变砖）。

### 6.2 实时事件推送

| 事件 | UTS 订阅 | 内容 |
|---|---|---|
| 触摸事件 | `onTouchEvent` | `action` / `keyType` / `touchType` |
| 来电控制 | `onCallControl` | `action` / `rawValue` |
| **健康报警** | `onHealthAlert` | `type` / `value`（心率/血氧超阈值）|
| 心率校正结果 | `onHeartRateCalibration` | `testMode` / `result` |
| 连接状态 | `onConnectState` | 连接状态变化 |
| 扫描结果 | `onScanResult` / `onScanFinish` | `BleDevice` |
| 同步进度 | `onSyncProgress` / `onSyncResult` / `onSyncFinish` / `onSyncError` | — |
| OTA 进度 | `onOtaProgress` / `onOtaFinish` | — |

> 💡 **`onHealthAlert` 对哮卫项目有直接价值**：设备侧自主触发的心率/血氧越界报警，不依赖 APP 在前台轮询。配合 `setHeartRateAlert` / `setBloodOxygenAlert` 设置阈值。

### 6.3 可设置项（非数据获取，供参考）

用户信息、闹钟、震动次数/时长/间隔、屏幕睡眠模式、消息与来电推送、心率/血氧报警阈值、亮屏时长、抬腕亮屏、12/24 小时制、佩戴位置、LED 亮度、拍照控制、查找设备、关机/恢复出厂、跌落提醒、计数提醒、设备密码认证、即时屏幕控制、视频手势控制（需 HID 配对）。

---

## 七、运行时必须先查能力表

设备型号众多、功能差异大。**所有数据获取前都应检查对应能力位**，否则在不支持的机型上静默失败。

**数据相关能力位**：
`isStep` `isHr` `isBloodPress` `isSleep` `isBloodOxy` `isHrv` `isPressure` `isBloodSugar` `isDataTypeTemperature` `isMuslimCountData` `isNewSport`(多运动)
`isSupportSensorRawPPG` `isSupportSensorRawACC` `isSupportSensorRawPPGRed` `isSupportSensorRawIR` `isSupportSensorRawSleep`
`isSupportPPGMonitoring` `isSupportTemperatureMonitoring`
`isSupportHrReminder` `isSupportBoReminder` `isSupportFallDetect` `isSupportRecording` `isSupportScreenControl` `isSupportDevicePasswordAuth`
`activityDataInterval`（计步明细间隔）

> ⚠️ `isSupportRecording`（录音）**仅在能力表中出现，全文档无任何对应 API**。属于预留位，不要假设可用。

---

## 八、对哮卫项目（儿童哮喘监测）的选型建议

| 需求 | 推荐通道 | 理由 |
|---|---|---|
| **算法输入（呼吸率/HRV 细粒度）** | **A 类原始 PPG + ACC**（sensorType=3）| 唯一能拿到波形；ACC 同 `sequence` 可做运动伪影消除 |
| **长期趋势基线** | **C 类全天历史**（心率/血氧/HRV）| 存 3-6 天，掉线也不丢；成本远低于原始采集 |
| **即时人工测量** | B 类实时单次 | 用户主动触发，秒级返回 |
| **夜间发作监测** | **A 类睡眠实时推送 + `onHealthAlert`** | 均为设备侧自主推送，不需 APP 常驻前台 |
| **活动量/依从性** | C 类计步 | 低功耗 |

**建议的双轨架构**：
- **主轨**：C 类全天历史（低频、可靠、耐断线）作为长期基线
- **副轨**：A 类原始 PPG（仅在预警触发或用户手动时启动 1 分钟）用于精细算法

> 这样既规避了原始 PPG "1 分钟即覆盖"的高风险，又保留了算法所需的波形能力。**不要试图用原始 PPG 做长期连续监测**——架构上不可行。

---

## 九、易踩坑清单（汇总）

| # | 坑 | 后果 |
|---|---|---|
| 1 | `sensorType`(入参) 与 `type`(返回) **编号定义不同** | 解析错数据类型 |
| 2 | `timeMills` **不是毫秒**，是 Unix 秒 | 时间错 1000 倍 |
| 3 | `onSyncStep` **分两次回调** | 丢历史计步 |
| 4 | 血压是 `sp`+`dp` 双值 | 数据结构错 |
| 5 | 血糖 `sugar` 是 float | 整数化后精度全失 |
| 6 | 体温需 `/10` | 显示 365℃ |
| 7 | 实时检测**同时只能开一种** | 检测异常 |
| 8 | 原始 PPG 只存 1 分钟 | 数据被覆盖丢失 |
| 9 | 睡眠分期编码 A 类与 C 类**不同** | 分期判断错误 |
| 10 | 采样率 fs **无记载** | 频域算法全部失真 |
| 11 | OTA 未校验 `deviceClazz` | 刷错固件 |
| 12 | 未查能力位就调用 | 静默失败 |
