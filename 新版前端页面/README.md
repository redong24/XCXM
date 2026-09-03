# AsthmaGuard · uni-app x 项目代码

基于 Phase 1 视觉设计（32 屏）落地的完整 uni-app x 项目。

## 环境要求

- HBuilderX **3.99+**（含 uni-app x 支持）
- Node.js 18+
- 目标平台：iOS 13+ / Android 8.0+（uni-app x 只跑 iOS 和 Android，不支持 H5/小程序）

## 快速开始

1. 用 HBuilderX 打开 `app/` 目录（作为一个 uni-app x 项目）
2. 顶部菜单 · 运行 → 运行到手机或模拟器 → Android 模拟器 / iOS 模拟器
3. 首次运行需要下载 uni-app x 编译器（约 400MB）

## 项目结构

```
app/
├── App.uvue                 # 根组件（主题切换、全局事件）
├── main.uts                 # 入口
├── pages.json               # 路由 + tabbar 配置
├── manifest.json            # 应用信息 + 权限声明
├── uni.scss                 # 设计 tokens（SCSS 变量）
├── pages/                   # 32 屏页面
│   ├── login/               # A · 引导
│   ├── onboarding/
│   ├── permission/
│   ├── empty/
│   ├── home/                # B · 5 大 Tab
│   ├── trend/
│   ├── location/
│   ├── device/
│   ├── me/
│   ├── alert/               # C · 报警流程
│   │   └── detail.uvue
│   ├── offline/
│   ├── history/             # 关注记录
│   ├── plan/                # 行动计划
│   ├── threshold/           # 阈值设置
│   ├── notification/
│   ├── measure/             # D · 数据管理
│   │   ├── measuring.uvue
│   │   └── result.uvue
│   ├── symptom/
│   ├── detail-chart/
│   ├── medication/
│   ├── export/
│   ├── children/            # E · 用户与档案
│   │   ├── children.uvue
│   │   └── form.uvue
│   ├── family/
│   ├── pair/
│   ├── account/
│   │   └── delete.uvue
│   ├── error/               # 网络异常
│   ├── inbox/               # F · 内容与系统
│   ├── search/
│   ├── knowledge/
│   ├── support/
│   └── about/
├── components/              # 可复用组件
│   ├── ag-button/
│   ├── ag-card/
│   ├── ag-header/
│   ├── ag-tabbar/
│   ├── ag-kid-chip/
│   ├── ag-breath-ring/      # 首页核心动画
│   └── ag-metric-cell/
├── composables/             # 组合式函数
│   ├── useTheme.uts         # 明暗切换
│   ├── useKid.uts           # 当前守护儿童
│   └── useRing.uts          # 戒指 Bluetooth 桩
├── static/                  # 静态资源
│   ├── brand/               # logo mark（6 档尺寸）
│   ├── tabbar/              # 5 tab 图标
│   └── icons/               # 戒指等 UI 图标
└── utils/                   # 工具函数
    ├── copy.uts             # 合规文案常量
    ├── format.uts           # 数字/时间格式化
    └── zone.uts             # 关注等级判定
```

## 设计 Tokens

`uni.scss` 是唯一颜色/字体/间距源头 —— 与 Phase 1 的 `mockups/v4/shared/tokens.css` 完全对应。

## 合规文案

**六项必须常驻的免责声明**沿用原设计系统（参考 `utils/copy.uts`）：
- 登录页底部
- 首页
- 报警详情页顶部
- 报警详情页第 3 步
- 行动计划页
- 阈值设置页

**禁用词库**：不允许出现"诊断"、"病情加重"、"立即就医"、"已保护"、"守护中"，全部替换为合规同义词。

**无 emoji · 无 unicode 图标**：视觉图标全部走 SVG / PNG。

## Bluetooth 桩

`composables/useRing.uts` 目前是**Mock 模拟数据**（返回假的心率/呼吸/血氧数据），方便前端开发。真正对接 RWFit R2 时替换 Bluetooth API 调用即可。

## 交付批次

- ✅ Batch 1 · 基础设施 + 3 个基础组件
- ⏳ Batch 2 · 5 大 Tab 主页面
- ⏳ Batch 3 · 报警流程 6 屏
- ⏳ Batch 4 · 数据管理 6 屏
- ⏳ Batch 5 · 引导 + 账户 + 内容 12 屏
