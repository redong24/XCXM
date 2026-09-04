# RWFIT BLE UTS Plugin

RWFIT 智能戒指 BLE UTS 插件，通过一套统一 API 适配 Android、iOS、
HarmonyOS NEXT 和微信小程序。插件封装各端原生 SDK，并统一公共字段、单位、
事件、错误码和生命周期语义，业务层无需直接处理平台 Bean、Model 或枚举。

## 平台支持

| 平台 | 最低环境 | 集成方式 |
| --- | --- | --- |
| Android | Android 8.0 / API 26 | 插件内置原生 AAR |
| iOS | iOS 12.0 | 插件内置 `DHBleSDK.xcframework` |
| HarmonyOS NEXT | API 12 | 插件内置 `rw_ble_sdk.har` |
| 微信小程序 | HBuilderX 5.15 编译工具链 | 插件内置微信 BLE SDK |

iOS XCFramework 同时包含真机 `arm64` 和模拟器 `arm64`/`x86_64` 切片，支持在
iOS 模拟器中构建和运行；扫描和设备通信仍需使用真机验证。

## 核心能力

- 初始化、扫描、连接、重连及连接状态
- 电量、固件、用户资料、时间格式及设备功能表
- 定时/实时健康检测与历史健康数据同步
- 多运动控制、实时运动数据及历史报告
- 闹钟、屏幕、佩戴方向、震动、跌落和计数提醒
- PPG、ACC、Red、IR 与睡眠原始传感器数据
- 触摸、拍照、音乐、通话、健康报警及校准事件
- 消息通知、固件文件传输和 OTA 升级
- 所有持续事件均提供对应的 `on*` / `off*` 接口

实际支持能力由戒指固件动态决定。收到设备功能表后，应根据 `menu.raw` 隐藏或
禁用当前设备不支持的功能。

## 安装

将 `rwfit-ble` 放入项目的 `uni_modules` 目录：

```text
your-project/
└── uni_modules/
    └── rwfit-ble/
```

Android 和 iOS 集成了原生依赖，请按 HBuilderX 提示制作并使用 UTS 自定义基座。
应用签名、证书、描述文件、私钥及密码由接入方自行配置，不应放入插件目录。

`initialize` 会主动触发平台蓝牙授权，`startScan` 会再次检查权限作为兜底。用户
已经拒绝并禁止再次询问时，需要引导其前往系统设置重新授权；微信小程序的系统
蓝牙授权应使用真机调试验证。

微信小程序宿主还需在 `manifest.json` 的 `mp-weixin` 节点声明授权用途：

```json
"permission": {
  "scope.userLocation": {
    "desc": "部分手机系统需要定位权限才能扫描附近的蓝牙设备"
  }
}
```

`scope.bluetooth` 由插件通过 `wx.authorize` 申请，不能写入微信
`app.json.permission`。插件默认只申请蓝牙权限；仅当微信扫描接口明确返回定位
权限错误时，才申请定位权限并自动重试一次扫描。

## 快速接入

持续事件应在扫描、连接前注册：

```js
import {
  initialize,
  startScan,
  connect,
  getPower,
  onScanResult,
  onConnectState,
  onFunctionMenu
} from '@/uni_modules/rwfit-ble'

onScanResult(device => {
  console.log('发现设备', device)
  // 用户选择设备后，将完整 device 对象传给 connect。
})

onConnectState(event => {
  console.log('连接状态', event.state)
})

onFunctionMenu(menu => {
  // onFunctionMenu 是四端统一的设备就绪信号。
  console.log('设备能力', menu.raw)
  getPower({
    success: power => console.log(`电量：${power}%`),
    fail: error => console.error(error.errCode, error.errMsg)
  })
})

initialize({
  success: () => startScan({}),
  fail: error => console.error(error.errCode, error.errMsg)
})

export function connectRing(device) {
  connect({ device })
}
```

连接时必须原样传回扫描得到的完整设备对象；iOS 和微信小程序需要其中的平台
设备标识。

## 就绪时序

`onConnectState({ state: 'connected' })` 只表示 BLE 链路已经建立。必须等待
`onFunctionMenu` 后，再调用电量、固件、健康、设置、同步或 OTA 等业务接口。

```text
扫描结果 -> connect -> connected -> onFunctionMenu -> 业务指令
```

页面或应用生命周期结束时，应调用对应的 `off*` 方法释放持续监听器。
健康同步完成、失败或页面销毁后，还应调用 `removeHealthDataCallback` 释放原生同步
callback；`offSync*` 只取消各自的 UTS 事件接收。

## 调用与错误

四端异步接口统一采用 callback options：

```ts
{
  success?: (result) => void
  fail?: (error: RwfitFail) => void
  complete?: (result: any | null) => void
}
```

公共错误包含 `errCode`、`errMsg` 和可选的原生错误码 `nativeCode`。带
`fail/complete` 的命令型 API 在当前平台或设备不支持时统一返回 `9201007`，不以
空操作或空结果冒充成功。事件注册没有错误回调；`onCallControl` 仅 Android、
HarmonyOS 有原生事件源，在 iOS、微信小程序上为空订阅且不会产生事件。

完整公共类型以 `utssdk/interface.uts` 为准。

## 版本

- 插件版本：`0.0.1`
- 原生 SDK：Android `RW_SDK_V2.0.0_20260724`；iOS `RW_SDK_V2.0.0_20260831`
- HBuilderX：`5.15.0` 或更高版本

仓库说明：[README](../../README.md) · [License](../../LICENSE)
