# Flutter + Rust + NDK + zxing-cpp 二维码扫描技术方案

**版本**：v1.1  
**日期**：2026-09-10  
**目标平台**：Android  
**通信方式**：rust-flutter-bridge  

---

## 1. 文档说明

### 1.1 目的

本文档描述一套完整的二维码扫描技术方案，核心特点如下：

- 使用 **Rust** 作为中控（相机生命周期、状态机、帧调度、与 Flutter 交互）
- 使用 **Camera2 NDK** 进行相机采集
- 使用 **zxing-cpp** 进行解码（通过 Rust 调用）
- Flutter 负责 UI、240×240 预览、ROI 绘制、结果展示
- 通过 **rust-flutter-bridge** 完成双向通信

### 1.2 目标能力

| 能力 | 说明 |
|------|------|
| 实时预览 | 240×240 Texture 零拷贝预览 |
| 高性能解码 | zxing-cpp，提升异形/模糊/变形码识别率 |
| ROI 实时回调 | 识别过程中返回定位点/框，用于 UI 绘制 |
| 识别成功定格 | 成功后暂停采集，画面定格在成功帧 |
| 快速再扫 | 成功后不释放 CameraDevice，再次识别可快速恢复 |
| 生命周期安全 | 覆盖页面销毁、前后台切换、相机被抢占恢复 |
| 完整结果 | 返回文本、格式、定位点、metadata 等全部可用信息 |

---

## 2. 总体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Flutter 层                                 │
│  ┌──────────────────────┐    ┌──────────────────────┐               │
│  │ Texture (240×240)    │    │ ROI Overlay          │               │
│  │ 预览 / 定格画面       │    │ CustomPainter        │               │
│  └──────────┬───────────┘    └──────────▲───────────┘               │
│             │                           │                            │
│  ┌──────────▼───────────────────────────┴───────────┐               │
│  │              rust-flutter-bridge                  │               │
│  │  命令：start / pause / resume / stop / app事件    │               │
│  │  事件：cameraState / roi / result                 │               │
│  └──────────────────────┬───────────────────────────┘               │
└─────────────────────────┼───────────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────────┐
│                        Rust 中控层                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │ 状态机        │  │ 生命周期管理  │  │ Bridge 适配  │               │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘               │
│         │                 │                 │                        │
│  ┌──────▼─────────────────▼─────────────────▼──────┐                │
│  │              Camera Service (NDK)                │                │
│  │  预览流 → Surface (Flutter Texture)              │                │
│  │  分析流 → AImageReader → Y 平面                  │                │
│  └──────────────────────┬──────────────────────────┘                │
│                         │                                            │
│  ┌──────────────────────▼──────────────────────────┐                │
│  │           Decoder Service (zxing-cpp)            │                │
│  │  灰度图输入 → 解码 → ROI / 完整结果               │                │
│  └─────────────────────────────────────────────────┘                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. 技术栈

| 层级 | 技术 | 说明 |
|------|------|------|
| UI | Flutter + Texture + CustomPainter | 240×240 预览与 ROI 绘制 |
| 通信 | rust-flutter-bridge | Flutter ↔ Rust 双向调用与事件 |
| 中控 | Rust | 状态机、生命周期、帧调度 |
| 相机 | Camera2 NDK (`ACamera*` / `AImageReader`) | 高性能采集 |
| 解码 | zxing-cpp（Rust 调用） | 识别能力更强的开源引擎 |
| 构建 | cargo-ndk + 现有 Flutter/Rust 工程 | 复用现有 Rust 集成方式 |

---

## 4. 状态机设计

```
Idle
  │ create_texture / prepare
  ▼
Created
  │ start
  ▼
Opening ──失败──► Error
  │成功
  ▼
Previewing ◄──────────────────┐
  │                            │
  │ 识别成功                    │ resume（再扫）
  ▼                            │
Paused ────────────────────────┘
  │
  │ 进入后台
  ▼
Background
  │ 回前台
  ▼
检测 CameraDevice
  ├─ 有效 → 恢复到 Previewing 或保持 Paused
  └─ 无效 → 重新 Opening
```

### 状态说明

| 状态 | CameraDevice | 捕获会话 | 预览画面 | 说明 |
|------|--------------|----------|----------|------|
| Idle | 释放 | 无 | 无 | 完全空闲 |
| Created | 未打开 | 无 | 空 | Texture 已就绪 |
| Opening | 打开中 | 无 | - | 过渡态 |
| Previewing | 打开 | 运行中 | 实时 | 正常扫描 |
| **Paused** | **保持打开** | **停止** | **定格** | 识别成功，支持快速再扫 |
| Background | 可能被抢占 | 停止 | 定格/黑屏 | 应用在后台 |
| Error | 不确定 | 停止 | - | 需提示或重建 |

---

## 5. 核心行为定义

### 5.1 正常扫描

1. Flutter 调用 `start`
2. Rust 打开相机，配置预览流 + 分析流
3. 预览流输出到 Flutter Texture（240×240）
4. 分析流取帧 → 送 zxing-cpp
5. 过程中回调 ROI
6. 成功则进入 Paused，并回调完整结果

### 5.2 识别成功（Paused）

1. 停止分析回调与捕获会话
2. **不 close CameraDevice**
3. 预览 Surface 保留最后一帧 → 画面定格
4. 回调 `result` + `cameraState = paused`
5. 此后不再产生新的 ROI

### 5.3 再次识别（快速恢复）

1. Flutter 调用 `resume`
2. Rust 检查 Device 是否有效
3. 有效：重新启动 CaptureSession → Previewing
4. 无效：走完整 open 流程
5. 清空旧结果，恢复 ROI 回调

### 5.4 进入后台 / 回前台

**进入后台（`on_app_paused`）**
- 停止捕获会话
- 进入 Background
- 按「可能被系统抢占」处理（可选择主动释放 Device，更稳妥）

**回前台（`on_app_resumed`）**
- 检查 CameraDevice 是否仍然有效
- 有效 → 尝试快速恢复会话
- 无效 → 重新 open
- 将最终状态通过事件回传 Flutter

### 5.5 页面销毁

- 调用 `stop` + 释放 Texture
- 关闭 CameraDevice、ImageReader 等全部资源
- 进入 Idle

---

## 6. 模块划分（Rust）

建议按以下模块组织：

```
qr_scanner/
├── bridge/          # rust-flutter-bridge 接口与事件
├── state/           # 状态机与状态定义
├── camera/          # NDK Camera 封装
│   ├── device.rs
│   ├── session.rs
│   └── image_reader.rs
├── decoder/         # zxing-cpp 调用封装
├── pipeline/        # 帧处理与调度
└── types/           # ROI、Result、错误码等公共类型
```

### 职责

| 模块 | 职责 |
|------|------|
| bridge | 接收 Flutter 命令，向外发送 state / roi / result |
| state | 维护状态，保证转换合法、串行 |
| camera | 打开/关闭设备、配置预览与分析流、处理 disconnect |
| decoder | 输入灰度图，调用 zxing-cpp，输出解码结果 |
| pipeline | 取帧 → 预处理 → 解码 → 触发回调 |
| types | 统一数据结构，便于序列化给 Flutter |

---

## 7. 与 Flutter 的接口设计（rust-flutter-bridge）

### 7.1 命令（Flutter → Rust）

| 方法 | 说明 |
|------|------|
| `prepare()` / `create_texture()` | 创建 Texture，返回 textureId |
| `start()` | 打开相机并开始预览 + 识别 |
| `pause()` | 进入 Paused（也可由解码成功自动触发） |
| `resume()` | 从 Paused 快速恢复识别 |
| `stop()` | 彻底停止并释放相机 |
| `dispose_texture()` | 释放 Texture |
| `on_app_paused()` | 应用进入后台 |
| `on_app_resumed()` | 应用回到前台 |

### 7.2 事件（Rust → Flutter）

**相机状态**
```json
{
  "type": "cameraState",
  "state": "previewing" | "paused" | "background" | "error" | "closed",
  "reason": "success" | "app_background" | "camera_disconnected" | null,
  "message": null
}
```

**ROI（识别过程中，可降频）**
```json
{
  "type": "roi",
  "points": [[x1,y1], [x2,y2], [x3,y3], [x4,y4]],
  "boundingBox": {
    "left": 0.0,
    "top": 0.0,
    "width": 0.0,
    "height": 0.0
  },
  "timestamp": 1710000000000
}
```

**识别结果**
```json
{
  "type": "result",
  "text": "二维码内容",
  "format": "QR_CODE",
  "rawBytes": "base64...",
  "points": [[x,y], ...],
  "metadata": {
    "errorCorrectionLevel": "M",
    "byteSegments": null,
    "structuredAppend": null,
    "symbologyIdentifier": null
  },
  "timestamp": 1710000000000
}
```

> 所有坐标统一为 **240×240 预览坐标系**，由 Rust 侧完成从分析分辨率到预览分辨率的转换。

---

## 8. 数据流

### 8.1 预览流（零拷贝）

```
Camera → ANativeWindow（Flutter Texture 对应的 Surface）
      → Flutter Texture (240×240)
```

### 8.2 分析 / 解码流

```
Camera → AImageReader
      → 提取 Y 平面（注意 stride）
      → 可选预处理
      → zxing-cpp 解码
      → 成功：结果回调 + 进入 Paused
      → 过程中：ROI 回调
```

### 8.3 分辨率与帧率建议

| 流 | 建议分辨率 | 建议帧率 |
|----|------------|----------|
| 预览 | 240~480 量级 | 30fps |
| 分析 | 480~720 | 15~20fps（可跳帧） |

---

## 9. 生命周期与线程模型

### 9.1 线程建议

| 线程 | 职责 |
|------|------|
| Flutter UI 线程 | 显示 Texture、绘制 ROI、处理用户操作 |
| Rust 控制逻辑 | 状态机、命令处理（可与 bridge 线程协调） |
| 相机回调线程 | 仅做轻量取帧，丢入队列 |
| 解码工作线程 | 预处理 + zxing-cpp 解码 |

原则：
- 不在相机回调里做重计算
- 状态变更串行化
- 回调到 Flutter 前切换到安全上下文（按 bridge 要求）

### 9.2 Flutter 侧必须做的事

```dart
// 伪代码示意
initState:
  prepare → start
  注册 AppLifecycleListener

识别成功:
  UI 进入结果展示（画面已定格）

用户再扫:
  resume()

App 进入后台:
  on_app_paused()

App 回前台:
  on_app_resumed()

dispose:
  stop() + dispose_texture()
```

---

## 10. zxing-cpp 集成要点

### 10.1 调用方式

- 推荐使用现成 Rust 绑定（如 `zxing-cpp` crate，开启 `bundled`）
- 或自行通过 C ABI / cxx 封装最小 decode 接口

### 10.2 输入建议

- 优先使用 **灰度 Y 平面**
- 正确处理 `row_stride` / `pixel_stride`
- 分析分辨率与预览分辨率分离，解码后做坐标映射

### 10.3 输出使用

- `text`、`format`、`raw_bytes`
- `position` / `result_points` → 作为 ROI
- 其他 metadata 按需透传

---

## 11. 性能与体积

| 项目 | 预估 / 说明 |
|------|-------------|
| 预览路径 | 系统 Surface，接近原生 |
| 解码耗时 | 视分辨率与内容，通常可控制在可接受范围 |
| 成功后再扫 | 明显快于完全重新 open 相机 |
| 体积增加 | 取决于 zxing-cpp 与 Rust 代码裁剪，需实测；建议开启 LTO、strip、按需格式 |

优化建议：
- 分析流降分辨率、跳帧
- ROI 回调降频
- 仅启用需要的条码格式
- Release 开启体积优化选项

---

## 12. 开发阶段建议

| 阶段 | 目标 | 验收标准 |
|------|------|----------|
| P0 | Texture 预览 + bridge 命令打通 | 240×240 能看到实时画面 |
| P1 | NDK 取帧 + 状态机 | 状态回调正确，帧数据可验证 |
| P2 | 接入 zxing-cpp | 能返回完整识别结果 |
| P3 | ROI 回调 + 成功进入 Paused 定格 | 体验闭环 |
| P4 | resume 快速再扫 + 后台抢占恢复 | 稳定性达标 |
| P5 | 性能与坐标精细打磨 | 可上线 |

---

## 13. 风险与应对

| 风险 | 应对 |
|------|------|
| 相机被其他应用抢占 | 监听 disconnect/error；回前台检测并重建 |
| 页面退出未释放 | dispose 强制 stop + 释放 Texture |
| 坐标不一致 | 统一在 Rust 转为 240×240 坐标系 |
| 多线程竞态 | 状态机串行、命令队列化 |
| 内存泄漏 | AImage 及时释放，会话成对创建/销毁 |
| 难码仍不足 | 可增加简单预处理，或后续评估补充策略 |

---

## 14. 知识库要点

1. **预览用 Texture**，由 Rust/NDK 输出到 Surface，Flutter 只负责显示。
2. **Rust 是中控**，负责相机、解码调度、状态机、与 Flutter 交互。
3. **解码用 zxing-cpp**，通过 Rust 调用。
4. **识别成功 → Paused**：停会话、保持 Device、画面定格。
5. **再扫用 resume**，优先快速恢复会话。
6. **后台按可能被抢占处理**，回前台必须做有效性检查。
7. **Flutter 驱动生命周期**，Rust 执行并回报状态。
8. **通信使用现有 rust-flutter-bridge**，命令 + 事件分离。

---

## 15. 总结

本方案以 **Rust 为中控**，结合 **NDK 相机采集** 与 **zxing-cpp 解码**，通过 **rust-flutter-bridge** 与 Flutter 协作，实现：

- 240×240 高效预览
- 更强的二维码识别能力
- 实时 ROI 反馈
- 识别成功定格
- 快速再次识别
- 完整的生命周期与后台恢复能力

可作为项目开发、联调与后续迭代的基准技术文档。
