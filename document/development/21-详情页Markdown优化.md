# 详情页 README Markdown / SVG 渲染优化

> 入口：应用详情 → 详细介绍（`lib/page/detail/widgets.dart` 的 `ReadmeSection`）。
> 相关：`AppImage`（`lib/core/image/app_image.dart`）、HTML→Markdown 转换
> （`lib/core/utils/unit.dart`）。

## 1. 渲染链路

```
GitHub readme (markdown)
  → resolveReadmeImageUrls（相对图片绝对化）
  → convertHtmlImgsToMarkdown（<img>/<a> → markdown；剥离内联 HTML）
  → flutter_markdown_plus MarkdownBody
      imageBuilder → _ReadmeImage → AppImage → SvgPicture / Image
```

## 2. SVG（shields.io 徽章）异常的原因

README 顶部 7 个徽章都是 `img.shields.io` 的 SVG：**固定 width/height（如 98×20）、
没有 viewBox、带 `<text>` 文本**。

### 2.1 根因（真机确认）

shields 的 SVG 文本结构是：

```xml
<g font-size="110">
  <g transform="scale(.1)"><text x="285" y="150">项目状态</text></g>
</g>
```

`vector_graphics` 编译器遇到「纯缩放/平移」的组变换时，会把变换**折算进文本坐标**
（x/y × 0.1）并清空 transform，但**没有同时折算 font-size**；渲染阶段也不会
再应用父组变换。结果：背景矩形正常，**文字按 110px 绘制**（实际应为 11px），
溢出被裁 → 截图里看到的"巨大白色字形碎片"。

在真机用 `AppImage` 单独渲染该徽章复现（文字巨大、背景正常），确认与
Markdown/尺寸计算无关。

### 2.2 修复：渲染前修正 SVG 文本字号

新增 `lib/core/image/svg_text_scale_fix.dart`：

- 扫描 `<g>/<text>` 标签，累计祖先 `scale()` 的等比缩放；
- 对每个 `<text>` 显式写入 `font-size = 继承字号 × 缩放`（110×0.1=11）；
- 坐标保持原值，仍由 `vector_graphics` 折算；
- 只处理**等比缩放**；旋转/斜切/非等比保持原样（这些情况渲染器会保留 transform 并整体应用）。
- 使用 UTF-8 解码/编码，避免中文被二次编码成乱码。

`AppImage` 在 SVG 渲染前调用该修正（命中 `<text` + `transform` 才处理）。

### 2.3 另外三处尺寸问题（一并修复）

1. **盒子被拉满整行且不收敛**
   `AppImage` 对 badge 直接返回 `Size(width ?? maxWidth, 30)`：
   - 没有显式宽度时宽度 = 显示区宽度（如 361），单个徽章占满一行；
   - 若 `maxWidth` 比父级实际可用宽度大（表格单元格、列表缩进、分栏等），
     这个盒子会**超出父级**，被父级裁剪 → 只看到徽章的一块。
2. **显式 HTML 尺寸完全不裁剪**
   `resolveImageDisplaySize` 原样返回 README 里的 `width/height`
   （如 `<img width="1040" height="30">`），超宽盒子同样被裁剪；
   `SvgPicture` 在紧约束里按 `BoxFit.contain` 缩放，结果看起来像"局部放大"。
3. **徽章识别过窄**
   只认 `img.shields.io`。代理改写、其他徽章服务（fury / badgen / codecov /
   github workflow badge …）都按普通 SVG 处理，不享受高度钳制与等比缩放。

- badge 不再铺满整行：按 SVG **固有宽高比**算尺寸（98×20 → 高 30 时宽 147），
  再收敛到 `maxWidth`；徽章因此可以自然并排。
- 显式 `width/height`：**超限时等比缩放**（不再原样返回），并最终 clamp 到显示区。
- `isBadgeUrl` 扩展为徽章服务白名单（github/gitlab 仅匹配 `badge.svg`、
  `badges/`、`workflows/` 路径），避免误判普通仓库图片。
- 增加单行诊断日志：`AppImage: url=… intrinsic=… -> size=… (box=…)`，
  真机异常时可直接定位是尺寸、判型还是字节问题。

## 3. Markdown 其它修复

| 问题 | 修复 |
|---|---|
| GitHub 懒加载图片 `src` 是 1×1 占位 gif（真实地址在 `data-src`/`srcset`） | 转换器优先 `data-src`，其次 `srcset` 第一项 |
| `<details>/<summary>` 直接显示成 HTML 或被吞 | `summary` 转 `**加粗标题**`，`details` 标签剥离、内容保留 |
| `<kbd>Ctrl</kbd>` 显示原标签 | 转行内代码 `` `Ctrl` `` |
| `&nbsp;` / `&amp;` / `&#x4E2D;` 原样显示 | 解码常见与数字 HTML 实体 |
| 代码块长行被软换行、缩进错乱 | 关闭软换行 + 横向滚动 + 可选中 |
| 目录锚点 `#简介` 点击打开浏览器 | 忽略页内锚点（不再误跳浏览器） |

## 4. 测试

- `test/app_image_test.dart`：badge 按固有比例（150×30）、超宽等比缩到 maxWidth、
  显式尺寸超宽不裁剪（800×400 → 200×100）、既有 badge 钳制/固有尺寸用例。
- `test/detail_readme_image_test.dart`：README 徽章渲染为 150×30（不再铺满整行）。
- `test/html_to_markdown_test.dart`：data-src/srcset、details/summary、kbd、HTML 实体、
  width/height title。
