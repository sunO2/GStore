---
name: js-channel-development
description: 用户要新增或改造 js_ 脚本渠道、接入新的应用数据源、编写或调试 entry.js / detail.js / meta.json 渠道包（三者必须齐全）、用 webView 调试 JS 页面或抓接口，或排查 CORE_E_SCRIPT_*、pack_* 报错时使用。
---

# 脚本渠道（js_*）开发

把一个新的应用数据源（应用商店、企业分发、私有仓库、HTTP 接口）接成 GStore 的 `js_*` 渠道包。渠道包是纯 JS 数据适配层：**不改 App 源码、不需要重新编译**。

当前架构是 Rust QuickJS 通道（`ChannelApi` / `RustChannelFacade`），Dart `JsChannel` 旧轨已删除。**一个渠道 = 一个 zip**。

## 0. 先确认交付方式

1. 产物是一个 zip，根目录**只能**有：
   - `entry.js`（必须）：发现页 / 搜索 / 应用信息 / 更新
   - `detail.js`（必须）：详情页 / 版本 / 环境 / 自定义动作（即使没有详情逻辑也要提供最小文件）
   - `meta.json`（必须）：显示名、描述、必需环境变量（至少要有 name / description）
   - `icons/`（可选）：包内图标资源
2. 渠道 key = `js_<zip 文件名>`：
   - `vivo.zip` → `js_vivo`
   - **不要**命名成 `js_vivo.zip`，否则 key 会变成 `js_js_vivo`
   - zip 文件名（不含 `.zip`）必须匹配 `^[a-zA-Z_][a-zA-Z0-9_]*$`
3. 你（AI）可以在工作区写 `entry.js` / `detail.js` / `meta.json`，但**不能打 zip、不能导入渠道包**：
   - 最后一步由用户在「设置 → 脚本渠道 → 导入渠道包」选择 zip；
   - 导入后需要用户重新打包并再次导入同名 zip 来覆盖更新。
4. 文件工具默认关闭。写文件前先用 `fileList` 确认工作区；`fileWrite` / `fileEdit` 需要用户审批，不要假设一定成功。
5. 内部工作区是 App 私有目录，用户不方便取出文件；想让用户直接压缩打包，建议把渠道目录建在用户选择的**外部 SAF 工作区**。如果做不到，就把完整文件内容输出到聊天里让用户自行保存。
6. `fileWrite` 只能写文本：`icons/` 等二进制资源让用户自己放，不要尝试写二进制。

## 1. 开工前必须问清楚（一次问全）

| 需要确认 | 为什么 |
| --- | --- |
| 数据源名称、主页、Base URL | 决定文件名、`CHANNEL_META`、请求前缀 |
| 列表 / 搜索接口：方法、路径、参数、分页、响应示例 | `searchApps` 是发现入口，必须有 |
| 详情接口：路径、参数、响应示例 | `getAppInfo` / `getAppDetail` |
| 下载地址规则 | 直链、跳转、是否需要 token / cookie |
| 鉴权方式 | 无 / 账号密码 / Token / Cookie；是否分环境（sit/uat/prd） |
| `appId` 语义 | 用包名，还是渠道内 ID（决定能否判断已安装 / 更新） |
| 更新判断字段 | `versionCode` / `versionName` / build 号 |
| 是否需要选版本 / 环境 | 决定 `detail.js` 里要实现哪些方法（文件本身必须提供） |

**工具选择（先看这里）：**

- 静态 HTML / 可直接请求的 JSON：`webFetch` / `httpRequest`
- **JS 渲染、SPA、需要登录态、要抓 XHR/fetch：必须用 `webView`**
  - `webView open` → `wait`（selector/networkIdle）→ `content`
  - `webView requests` 看页面实际发出的接口
- 需要人工登录/验证码：先让用户到「AI 设置 → WebView 调试」登录；
  登录后 Cookie 共享，再 `webView open` 同一 URL

规则：

- **没有接口样例就不要编。** 先向用户要 curl、抓包或接口文档。
- 拿到公网 URL 后，可以先用 `httpRequest` 直接探测：
  - 支持 `GET/POST/PUT/PATCH/DELETE/HEAD`、自定义 Header、JSON/原始 Body；
  - 返回状态码、响应头与响应体，适合确认真实字段；
  - GET/HEAD 无副作用；POST/PUT/PATCH/DELETE 只用于查询型接口或用户明确要求的接口；
  - 内网/回环地址会被拒绝，跨源重定向会丢弃 Authorization/Cookie。
- `webFetch` 只用于抓网页正文（HTML→可读文本，带 Jina 兜底），不要拿它探测 JSON 接口。
- 如果文档站/接口页面依赖 JS 渲染，用 `webView` 的 `open` + `content` 读取渲染后内容，
  用 `requests` 看页面实际发出的 XHR/fetch；静态 HTML 仍优先 `webFetch`。
- 不要用 HTML 页面猜接口：运行环境没有 HTML 解析库，只有字符串和正则，维护成本极高。优先找 JSON 接口。
- 不确定的字段先少映射，保证 `appId` + `name` 正确，其余后续再补。

## 2. 工作区目录与打包

建议在工作区这样组织（最终只把三个文件打进 zip）：

```text
channels/<stem>/
├── entry.js      # 必须，打进 zip 根目录
├── detail.js     # 必须，打进 zip 根目录
├── meta.json     # 必须，打进 zip 根目录
└── README.md     # 只给自己/用户看，不要放进 zip
```

- zip 里出现 `README.md`、`package.json` 等未知根文件，严格模式会**整包拒绝**（`pack_layout`）。
- `icons/` 可以有子目录；其它文件只能放在根目录。
- 限制：最多 1024 个条目、单条目 8MB、总解压 32MB、zip 本体 64MB。

### 2.1 交付规范：三个文件缺一不可

**必须提供 `entry.js`、`detail.js`、`meta.json` 三个文件。缺少任何一个都视为不合格渠道包，不要交付。**

- 即使详情逻辑全部写在 `entry.js`，也必须提供一个最小的 `detail.js`：
  ```js
  async function main(method, params) {
    return null; // 详情页会回退 entry.js 的 getAppDetail
  }
  ```
- 即使不需要环境变量，也必须提供 `meta.json`，至少包含：
  ```json
  {
    "name": "渠道名称",
    "description": "渠道说明"
  }
  ```
- 不要以“运行时能导入”为由省略 `detail.js` / `meta.json`；本技能要求必须提供。
- 文件名必须完全一致：`detail.js` / `meta.json`；`Detail.js`、`Meta.json`、`meta.js` 都不合格。
- zip 里不要套文件夹：根目录只能是这三个文件 + `icons/`。

导入失败最常见原因（按顺序检查）：

- **zip 里套了文件夹**（最常见）：`mychannel/entry.js` → 导入会报 `pack_missing_entry` / `pack_layout`。要选中文件本身压缩，让 `entry.js` 直接在 zip 根目录。
- **文件名拼写/大小写错误**：`Detail.js`、`Meta.json`、`meta.js` 都不会被识别；元信息必须叫 `meta.json`（不是 `meta.js`）。
- **根目录有杂项**：`.DS_Store`、`__MACOSX/`、`README.md`、`package.json` 等会让严格模式整包拒绝（`pack_layout`）。
- **entry.js 为空**：会被当作缺 entry（`pack_missing_entry`）。
- **路径非法**：`..`、绝对路径、软链接、加密 zip 都会被拒绝（`pack_unsafe_entry` / `pack_corrupt`）。
- **meta.json 格式错**：必须是 JSON 对象，`requiredEnvVars` 必须是字符串数组（`pack_invalid_meta`）。

如果导入的是没有 `detail.js` 的历史包，可能看到下面两条 DEBUG 日志；**按本技能规范交付的包不应出现**：

```text
[RustScriptDetailChannel] js_xxx has no detail.js; menu disabled
[RustScriptDetailChannel] no detail from js_xxx ...; keeping the prefill
```

- 第一句：包没有 `detail.js`，只是“更多”菜单为空；
- 第二句：`detail.js` 没有详情，且 `entry.js` 的 `getAppDetail` 也没有返回数据，页面保留列表带过来的基础信息（名称/图标/包名），不会白屏。

`meta.json`（必须提供）：

```json
{
  "name": "示例商店",
  "description": "示例数据源脚本渠道",
  "requiredEnvVars": ["EXAMPLE_USER", "EXAMPLE_PASS"]
}
```

最小可用版本（不需要环境变量时）：

```json
{
  "name": "示例商店",
  "description": "示例数据源脚本渠道"
}
```

- `requiredEnvVars` 是唯一会被导入流程解释的字段：导入时弹窗要求用户逐项填写，值通过 `host.env.get(name)` 读取。
- `name` / `description` / `icon` 用于设置页展示；`CHANNEL_META` 用于运行时渠道元信息，两者建议一致。
- `meta.json` 必须是 JSON 对象，`requiredEnvVars` 必须是字符串数组；严格模式下格式不对会拒绝整包（`pack_invalid_meta`）。
- 不需要环境变量就不要写 `requiredEnvVars`。

## 3. 运行时硬约束

### 3.1 生命周期

- 一个渠道一个 QuickJS 运行时（entry 常驻，直到渠道被移除/重建）。
- `entry.js` 在渠道初始化时 **eval 一次**；顶层代码会立即执行，`CHANNEL_META` 也在这时读取。
- `detail.js` 是必须提供的页面级脚本：**每次 detail 方法调用都会新建运行时，返回后销毁**。不要依赖跨调用的模块级缓存；同一次 `main` 调用内可以缓存。
- entry 与 detail 是**两个独立运行时**，不能共享函数、变量、缓存。

### 3.2 统一入口

```js
async function main(method, params) {
  // params 永远是对象（可能是 {}）
  switch (method) {
    case 'searchApps': return await searchApps(params.keyword || '');
    // ...
    default: return null; // 未实现 → null，让宿主走降级
  }
}
```

返回语义（必须记住）：

| 返回值 | 宿主如何处理 |
| --- | --- |
| `{ ok: true, data: <值> }` | 把 `data` 交给上层 |
| `{ ok: true, data: null }` | 视为“没有结果”，走降级 |
| `{ ok: true }`（无 data） | 视为“没有结果” |
| `{ ok: false, ... }` | 视为“没有结果”，走降级（**不是错误**） |
| `null` / `undefined` | 视为“没有结果” |
| JS 抛异常 | 该次 `main` 视为“没有结果”，走降级 |
| 数组 / 字符串 / 数字 / 布尔（非对象） | 直接当成 `data` |
| 没有 `ok` 字段的对象 | 直接当成 `data`（兼容旧脚本） |

因此：

- **未实现的方法必须 `return null`，不要 `throw`。**
- `main` 内部的 `throw` 会被宿主当作“没有结果”**静默降级**（不会报错）；业务失败必须自己 `return { ok:false, error:'...' }` 并写 `host.log.error`。
- 网络失败时优先返回 `{ ok: false, error: '...' }`，让宿主降级；只有确实拿到空结果才返回 `{ ok: true, data: [] }`。
- 返回空数组表示“搜索成功但没有匹配”；**不要用 `null` 表示“没匹配”**，否则会触发全量兜底（可能很慢）。

### 3.3 可用环境

可用：

- 标准 JS 内置对象：`JSON`、`Math`、`Date`、`RegExp`、`Array`、`Promise`、`Map`、`Set` 等
- `async` / `await`（Promise 会被引擎排空）
- `host.*`（见第 4 节）
- `sendMessage(method, payload)`（底层桥，一般不用）

**不可用**（不要写，否则 eval 直接失败）：

- `require` / `module.exports` / `import` / `export`
- Node API：`process`、`Buffer`、`fs`、`path`、`crypto`
- 浏览器 / 网络全局：`fetch`、`XMLHttpRequest`、`window`、`document`
- `setTimeout` / `setInterval` / `console.log`
- 不要依赖 `URL` / `URLSearchParams` / `TextEncoder` / `atob` / `btoa` 等宿主扩展
- 没有 `node_modules`、没有多文件模块：**所有代码写在 entry.js / detail.js 各自文件里**

网络统一走 `host.network.*`。

### 3.4 预算（超了会报错，不会静默截断）

| 限制 | 值 | 说明 |
| --- | --- | --- |
| 单次 eval | **5 秒** | 网络请求在脚本线程内同步等待，**请求耗时也算进 5 秒** |
| 单次结果 | 10MB | JSON 序列化后的 `main` 返回值 |
| 网络响应 | 20MB | `host.network.*` 的 `data` |
| 内存 | 64MB | QuickJS heap |
| 栈 | 1MB | 深递归会失败 |
| 重定向 | 5 次 | 脚本不能把这个值调大 |
| 并发 runtime | 32 | 进程级 |
| 单 runtime 累计执行 | 10 分钟 | 超了拒绝继续执行 |

实践建议：

- 一次 `main` 只做 1～2 个请求，不要在一个调用里循环翻几十页。
- 列表接口尽量一次取够（`size=50/100`），不要每页 10 条慢慢翻。
- 详情页不要逐条请求截图 / 下载项；一次详情接口拿全。
- 不要写长轮询、重试循环、`while` 等待。

## 4. host API 速查

所有 host 调用都是**同步返回结果、可 `await`**，返回信封 `{ ok, data, error? }`（`host.log.*` 除外）。

### 4.1 网络

```js
var r = await host.network.get(url, {
  params: { q: 'term', page: 1 },        // 自动拼到 query，number 也会带上
  headers: { 'User-Agent': '...' },
});

var r2 = await host.network.post(url, {
  headers: { 'Content-Type': 'application/json' },
  body: { user: 'a', pass: 'b' },        // 对象会被 JSON 序列化；也可传字符串
});
```

返回：

```js
// 2xx
{ ok: true, status: 200, data: <已 JSON 解码的对象/数组，或纯文本字符串> }

// 非 2xx：仍然保留响应体
{ ok: false, status: 401, data: <响应体>, error: 'HTTP 401' }
```

注意：

- `ok` 只代表 2xx；业务错误码要看 `data`。
- POST 不会自动加 `Content-Type`，需要自己传。
- GET 的 `body` 会被忽略。
- `params` 里的 `null` / `undefined` 会被跳过；空字符串会被原样拼上（自己过滤）。
- 最多 5 次重定向，最终仍可能返回 3xx。

### 4.2 本地渠道库

```js
await host.database.getAppsByChannel();      // → { ok:true, data:[AppRow...] }
await host.database.getApp(appId);           // → { ok:true, data:AppRow|null }
await host.database.insertApps(apps);        // → { ok:true, data:插入条数 }
```

- 读写都**强制绑定当前渠道**，脚本不能访问别的渠道。
- `insertApps` 会剥掉脚本传入的 `channelCode`，以运行时渠道为准。
- `AppRow` 字段：`appId`、`name`、`user`、`repositories`、`apprepo`、`icon`、`description`、`category`、`addTime`、`channelCode`、`extra`。
- 注意：这里只有**已保存行**，不是搜索结果；不要拿它当远程列表用。

### 4.3 配置与环境变量

```js
await host.config.get('some_key');   // → { ok:true, data:<值>|null }
await host.env.get('EXAMPLE_USER');  // → { ok:true, data:'值'|null }
await host.env.all();                // → { ok:true, data:{KEY:'值', ...} }
await host.env.has('EXAMPLE_USER');  // → { ok:true, data:true|false }
```

- 环境变量来自「设置 → 脚本渠道 → 环境变量」，按渠道隔离，只读。
- 值一定是字符串；没配置时 `get` 的 `data` 为 `null`。

### 4.4 已安装版本

```js
await host.utils.checkVersion('com.example.app');
// → { ok:true, data:{ installed:false } }
// → { ok:true, data:{ installed:true, version:'1.2.3', versionCode:123, name:'示例' } }
```

用于判断本机是否已安装、版本是否落后。读的是宿主已安装应用清单。

### 4.5 日志

```js
host.log.info('同步到 20 条');
host.log.error('详情失败: ' + e);
```

日志会出现在 App 日志里，排错时优先加日志，不要只 `return null`。

### 4.6 UI 往返（仅详情页，可选高级）

```js
var r = await host.ui.call('showVersionPicker', {
  title: '选择版本',
  envs: ['sit', 'prd'],
  versions: versions,       // [{version, envs, buildCount}]
  currentEnv: env,
  currentVersion: version,
});
// 用户选择后的切换由宿主完成；这里只处理“页面未打开 / 调用失败”
if (!r || r.ok !== true) return { ok: true, data: null };
return { ok: true, data: true };
```

只有实现了 `versionOptions` + `switchVersion` 的包，`showVersionPicker` 才有意义（宿主会用它们完成切换）。

只支持 8 个 kind：

| kind | payload 关键字段 | 行为 / 返回 |
| --- | --- | --- |
| `showVersionPicker` | `title? / envs / versions[{version,envs,buildCount}] / currentEnv? / currentVersion?` | 宿主弹选择器；用户确认后**宿主自己**调用 `switchVersion` 并刷新详情页。data 为 null，**不要读返回值**，也不要再自己发 `refreshDetail` |
| `showBuildHistory` | `builds / version / env` | 宿主弹构建历史；选中后宿主直接处理下载。data 为 null，**不要读返回值** |
| `refreshDetail` | 完整 detail map | 用这份 map 刷新页面，无 data |
| `updateDownloadList` | `{ downloads: [...] }` | 只局部更新下载区，无 data |
| `showUAPicker` | `{ options:[{label,ua}], current }` | 返回用户选中的 UA 字符串；取消为 null |
| `updateDetail` | 局部 detail map | 局部更新详情字段，无 data |
| `setBusy` | `{ visible, label }` | 显示/隐藏忙碌态，无 data |
| `download` | `{ url, name, version, size }` | 触发宿主下载，返回 `{ ok:true }` |

限制：

- 只在**详情页已打开且已绑定**时可用；没有活动详情页会返回 `{ ok:false, error:'CORE_E_SCRIPT_UI_NO_ACTIVE_DETAIL' }`。
- UI 等待最长约 30 秒，这段等待**不计入** 5 秒执行预算（宿主会 park 脚本线程）；但脚本自身的纯计算仍受 5 秒限制。
- 用户取消时 `data` 为 `null`，不要当错误。
- 只有 `showUAPicker` / `download` 的返回值有内容；`showVersionPicker` / `showBuildHistory` 是**宿主驱动**的，选择结果不会回到脚本。
- `host.core.call` / `host.alert.call` 当前**未注册**，会返回 `{ ok:false, error:'... 未注册' }`，不要使用。

## 5. entry.js：发现 / 搜索 / 信息 / 更新

宿主按方法名调用 `main`：

| method | params | 返回 data | 谁调用 / 未实现时 |
| --- | --- | --- | --- |
| `searchApps` | `{ keyword }` | `AppInfo[]` | 发现页搜索；返回 null/非数组时回退 `getAllApps` 本地过滤 |
| `getAppInfo` | `{ appId, version? }` | `AppInfo` 或 null | 单应用信息；回退读本渠道已保存行 |
| `getAppDetail` | `{ appId, version? }` | `Detail` | 详情页兜底（优先 `detail.js`） |
| `getAllApps` | `{}` | `AppInfo[]` | 仅 `doUpdate` / `searchApps` 兜底时调用 |
| `checkAppUpdate` | `{ appId }` | `Update` | 单应用更新检查；回退用已保存行拼一个没有版本号的更新信息 |
| `checkUpdate` | `{}` | `bool` | 渠道全量更新检查；非 bool 当作 false |
| `doUpdate` | `{}` | `bool`（或 null） | 全量刷新；null → 宿主调用 `getAllApps` 并写入本地库 |
| `getConfig` | `{}` | `{ version, proxy }` | 渠道配置；没有时视为无配置 |

### 5.1 最重要的现实语义

- **发现页的渠道列表读取的是“已保存行”（`channel_apps`），不会自动执行脚本的 `getAllApps`。**
- 脚本的 `searchApps` 是发现入口：搜索 → 结果 → 用户选择 → 保存到渠道。
- 因此 `searchApps` 必须在**没有任何本地行**的情况下也能从网络拿到结果。
- `getAppInfo` / `getAppDetail` 要对搜索结果里的 `appId` 直接可用，不能依赖“已经保存过”。

### 5.2 `checkUpdate` / `doUpdate` 怎么设计

- `doUpdate` 返回 `true`：表示脚本**自己**已经调用 `host.database.insertApps` 完成落库。
- `doUpdate` 返回 `null`：宿主会再调用 `getAllApps`，把返回的数组写进本地库。
- `doUpdate` 返回 `false`：什么都不做（不要用它表示成功）。
- `checkUpdate` 返回 `true/false` 表示远程全量列表是否有变化；只返回非 bool 会被当作 false。
- 大目录不要在 `doUpdate` 里翻几十页，容易 5 秒超时；一次取一页可接受的大列表。

### 5.3 AppInfo 字段

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `appId` | ✅ | 渠道内唯一。建议用包名；没有包名就用渠道 ID |
| `name` | ✅ | `appId` 或 `name` 为空的行会被**直接丢弃** |
| `packageName` | 建议 | 用于安装 / 更新判断；缺省时上层用 `appId` |
| `icon` | 建议 | 绝对 URL |
| `des` / `description` | 建议 | 简介；`des` 优先 |
| `readme` | 可选 | 长文本详情 |
| `user` | 可选 | 开发者；缺省为渠道 key |
| `repositories` | 可选 | 渠道内标识 / 仓库；缺省为渠道 key |
| `category` | 可选 | 字符串数组，或单个字符串 |
| `extra` | 可选 | **必须是对象**，任意渠道字段放这里（版本号、评分、渠道 ID 等） |

字符串字段接受字符串 / 数字 / 布尔（会自动转字符串）；对象和数组会被丢弃。数字类型的 `versionCode` 建议放 `extra` 或转成字符串。

### 5.4 entry 模板

```js
const BASE = 'https://api.example.com';
const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 ' +
           '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

const CHANNEL_META = {
  name: '示例商店',
  description: '示例数据源脚本渠道',
};

function str(v) {
  if (v === undefined || v === null) return '';
  return String(v);
}

function pick(obj, keys, fallback) {
  if (!obj) return fallback;
  for (var i = 0; i < keys.length; i++) {
    var v = obj[keys[i]];
    if (v !== undefined && v !== null && v !== '') return v;
  }
  return fallback;
}

async function get(path, params) {
  try {
    var r = await host.network.get(BASE + path, {
      params: params || {},
      headers: { 'User-Agent': UA },
    });
    if (!r || r.ok === false) {
      return { ok: false, data: null, error: str(r && (r.error || ('HTTP ' + r.status))) };
    }
    return { ok: true, data: r.data === undefined ? null : r.data };
  } catch (e) {
    host.log.error('GET ' + path + ' 失败: ' + str(e));
    return { ok: false, data: null, error: str(e) };
  }
}

function mapApp(raw) {
  if (!raw) return null;
  var id = str(pick(raw, ['packageName', 'appId', 'id'], ''));
  var name = str(pick(raw, ['name', 'title'], ''));
  if (!id || !name) return null;
  return {
    appId: id,
    packageName: str(pick(raw, ['packageName', 'package'], id)),
    name: name,
    icon: str(pick(raw, ['icon', 'logo'], '')),
    des: str(pick(raw, ['description', 'summary', 'des'], '')),
    user: str(pick(raw, ['developer', 'author'], '')),
    repositories: id,
    category: Array.isArray(raw.category) ? raw.category.map(str)
        : (raw.category ? [str(raw.category)] : []),
    extra: {
      sourceId: str(pick(raw, ['id'], id)),
      version: str(pick(raw, ['versionName', 'version'], '')),
    },
  };
}

async function searchApps(keyword) {
  var kw = str(keyword).trim();
  if (!kw) return { ok: true, data: [] }; // 空关键词直接空数组，不要发请求
  var r = await get('/search', { q: kw, page: 1, size: 50 });
  if (!r.ok) return { ok: false, error: r.error };
  var list = Array.isArray(r.data) ? r.data
      : (r.data && Array.isArray(r.data.items) ? r.data.items : []);
  return { ok: true, data: list.map(mapApp).filter(function (a) { return a !== null; }) };
}

async function getAppInfo(appId) {
  if (!appId) return { ok: true, data: null };
  var r = await get('/app/' + encodeURIComponent(appId));
  if (!r.ok || !r.data) return { ok: true, data: null };
  return { ok: true, data: mapApp(r.data) };
}

async function getAppDetail(appId) {
  if (!appId) return { ok: true, data: null };
  var r = await get('/app/' + encodeURIComponent(appId));
  if (!r.ok || !r.data) return { ok: true, data: null };
  var raw = r.data;
  return {
    ok: true,
    data: {
      appId: str(pick(raw, ['packageName', 'appId', 'id'], appId)),
      packageName: str(pick(raw, ['packageName'], appId)),
      name: str(pick(raw, ['name', 'title'], '')),
      icon: str(pick(raw, ['icon', 'logo'], '')),
      description: str(pick(raw, ['description', 'summary', 'des'], '')),
      version: str(pick(raw, ['versionName', 'version'], '')),
      developer: str(pick(raw, ['developer', 'author'], '')),
      projectUrl: str(pick(raw, ['homepage', 'projectUrl'], '')),
      sections: ['downloads', 'readme'],
      downloads: [{
        url: str(pick(raw, ['downloadUrl', 'url'], '')),
        name: str(pick(raw, ['name', 'title'], '')) + '.apk',
        size: Number(pick(raw, ['size'], 0)) || null,
        version: str(pick(raw, ['versionName', 'version'], '')),
        publishedAt: Number(pick(raw, ['updatedAt'], 0)) || null,
      }],
    },
  };
}

async function main(method, params) {
  params = params || {};
  switch (method) {
    case 'searchApps': return await searchApps(params.keyword);
    case 'getAppInfo': return await getAppInfo(params.appId);
    case 'getAppDetail': return await getAppDetail(params.appId);
    default: return null;
  }
}
```

## 6. detail.js：详情页 / 版本 / 环境

`detail.js` 是**必须文件**。即使不实现任何详情/版本能力，也要提供最小文件：

```js
async function main(method, params) {
  return null; // 详情页会回退 entry.js 的 getAppDetail
}
```

有了这个最小文件，详情页会回退到 `entry.js` 的 `getAppDetail`；如果 entry 也没有实现，
页面保留基础信息。需要“更多”菜单、版本/环境、构建历史时，再按下面的完整骨架实现。

页面级方法（都可省略）：

| method | params | 返回 data |
| --- | --- | --- |
| `getAppDetail` | `{ appId }` | `Detail` |
| `versionOptions` | `{ appId, env?, version? }` | `{ title?, envs:[], versions:[{version,envs,buildCount}], currentEnv?, currentVersion?, ...extra }` |
| `switchVersion` | `{ appId, env, version, build? }` | `Detail`（与 getAppDetail 同结构） |
| `buildHistory` | `{ appId, version, env }` | `{ builds:[{num,publishedAt,size,changelog,installTimes,...}] }` |
| `detailMenu` | `{ appId }` | `[{ action, jscall, icon?, clickIsDimiss? }]` |

### 6.0 完整骨架（可直接改）

`detail.js` 与 `entry.js` 不能共享代码：两个文件各自带一份 helper。

```js
// ============================================================
// detail.js —— 详情页 / 版本 / 环境 / 自定义动作
// 每次 detail 方法调用都会新建 runtime：不要依赖跨调用缓存。
// ============================================================

const BASE = 'https://api.example.com';
const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 ' +
           '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

function str(v) {
  if (v === undefined || v === null) return '';
  return String(v);
}

function pick(obj, keys, fallback) {
  if (!obj) return fallback;
  for (var i = 0; i < keys.length; i++) {
    var v = obj[keys[i]];
    if (v !== undefined && v !== null && v !== '') return v;
  }
  return fallback;
}

async function get(path, params) {
  try {
    var r = await host.network.get(BASE + path, {
      params: params || {},
      headers: { 'User-Agent': UA },
    });
    if (!r || r.ok === false) {
      return { ok: false, data: null,
        error: str(r && (r.error || ('HTTP ' + r.status))) };
    }
    return { ok: true, data: r.data === undefined ? null : r.data };
  } catch (e) {
    host.log.error('detail GET ' + path + ' 失败: ' + str(e));
    return { ok: false, data: null, error: str(e) };
  }
}

// 原始详情 → 页面 Detail。downloads / readme / screenshots 都放顶层。
function buildDetail(raw, appId) {
  var downloads = (Array.isArray(raw.downloads) ? raw.downloads : []).map(function (d) {
    return {
      url: str(pick(d, ['url', 'downloadUrl'], '')),
      name: str(pick(d, ['name'], '')) ||
          (str(pick(raw, ['name'], appId)) + '.apk'),
      size: Number(pick(d, ['size'], 0)) || null,
      version: str(pick(d, ['version'], pick(raw, ['versionName', 'version'], ''))),
      versionCode: Number(pick(d, ['versionCode'], 0)) || null,
      platform: 'android',
      // 必须是数字时间戳（秒/毫秒）；ISO 字符串会被丢弃
      publishedAt: Number(pick(d, ['publishedAt', 'updatedAt'], 0)) || null,
      downloadable: d.downloadable !== false,
      note: str(pick(d, ['note'], '')),
    };
  });
  return {
    appId: appId,
    packageName: str(pick(raw, ['packageName'], appId)),
    name: str(pick(raw, ['name'], '')),
    icon: str(pick(raw, ['icon', 'logo'], '')),
    description: str(pick(raw, ['description', 'summary'], '')),
    version: str(pick(raw, ['versionName', 'version'], '')),
    developer: str(pick(raw, ['developer', 'author'], '')),
    projectUrl: str(pick(raw, ['homepage', 'projectUrl'], '')),
    readme: str(pick(raw, ['readme', 'description'], '')),
    sections: ['downloads', 'readme', 'changelog'],
    changelog: str(pick(raw, ['changelog'], '')),
    downloads: downloads,
  };
}

// ---------- 详情 ----------
async function getAppDetail(appId) {
  if (!appId) return { ok: true, data: null };
  var r = await get('/app/' + encodeURIComponent(appId));
  if (!r.ok || !r.data) return { ok: true, data: null };
  return { ok: true, data: buildDetail(r.data, appId) };
}

// ---------- 版本 / 环境 ----------
async function versionOptions(appId, env) {
  if (!appId) return { ok: true, data: null };
  var r = await get('/versions', { appId: appId, env: env || '' });
  if (!r.ok || !r.data) return { ok: false, error: r.error || '无版本数据' };
  var list = Array.isArray(r.data) ? r.data : (r.data.versions || []);
  return {
    ok: true,
    data: {
      title: '选择版本',
      envs: ['sit', 'uat', 'prd'],
      versions: list.map(function (v) {
        return {
          version: str(v.version),
          envs: Array.isArray(v.envs) ? v.envs : [env || 'sit'],
          buildCount: Number(v.buildCount) || 0,
        };
      }),
      currentEnv: env || 'sit',
      currentVersion: str(list.length ? list[0].version : ''),
    },
  };
}

// build 是宿主选中构建后回传的 { num, ipaName }
async function switchVersion(appId, env, version, build) {
  if (!appId || !version) return { ok: false, error: '缺少 appId/version' };
  var r = await get('/build', {
    appId: appId,
    env: env || 'sit',
    version: version,
    buildNum: build ? build.num : '',
    ipaName: build ? (build.ipaName || '') : '',
  });
  if (!r.ok || !r.data) return { ok: false, error: r.error || '切换版本失败' };
  return { ok: true, data: buildDetail(r.data, appId) };
}

// ---------- 构建历史 ----------
async function buildHistory(appId, version, env) {
  if (!appId || !version) return { ok: true, data: { builds: [] } };
  var r = await get('/builds', { appId: appId, version: version, env: env || 'sit' });
  if (!r.ok || !r.data) return { ok: false, error: r.error || '无构建数据' };
  var list = Array.isArray(r.data) ? r.data : (r.data.builds || []);
  return {
    ok: true,
    data: {
      builds: list.map(function (b) {
        return {
          num: Number(b.num) || 0,
          publishedAt: str(pick(b, ['publishedAt', 'updateTime'], '')),
          size: Number(pick(b, ['size'], 0)) || null,
          changelog: str(pick(b, ['changelog'], '')),
          installTimes: Number(pick(b, ['installTimes'], 0)) || null,
          // 宿主选中构建后会把 num/ipaName 回传给 switchVersion
          ipaName: str(pick(b, ['ipaName', 'fileName'], '')),
        };
      }),
    },
  };
}

// ---------- 更多菜单 ----------
function detailMenu(appId) {
  return {
    ok: true,
    data: [
      { action: '切换版本', jscall: 'jsswitchVersion', clickIsDimiss: true },
      { action: '构建历史', jscall: 'jsBuildHistory', clickIsDimiss: true },
      { action: '切换 UA', jscall: 'jsswitchUA', clickIsDimiss: true },
    ],
  };
}

// 自定义动作：只有非宿主内置的 jscall 才会进到这里
async function jsSwitchUA(appId) {
  var r = await host.ui.call('showUAPicker', {
    title: '切换 UA',
    options: [
      { label: 'Android', ua: UA },
      { label: 'iOS', ua: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148' },
    ],
    current: UA,
  });
  if (!r || r.ok !== true || !r.data) return { ok: true, data: null };
  // UA 只在本文件内生效；这里演示刷新详情
  var detail = await getAppDetail(appId);
  if (detail && detail.ok && detail.data) {
    await host.ui.call('refreshDetail', detail.data);
  }
  return { ok: true, data: true };
}

// ---------- 统一分发 ----------
async function main(method, params) {
  params = params || {};
  switch (method) {
    case 'getAppDetail': return await getAppDetail(params.appId);
    case 'versionOptions': return await versionOptions(params.appId, params.env);
    case 'switchVersion':
      return await switchVersion(params.appId, params.env, params.version, params.build);
    case 'buildHistory':
      return await buildHistory(params.appId, params.version, params.env);
    case 'detailMenu': return detailMenu(params.appId);
    case 'jsswitchUA': return await jsSwitchUA(params.appId);
    default: return null; // 未实现 → null，不要 throw
  }
}
```

注意：

- `jsswitchVersion` / `jsBuildHistory` 由**宿主**处理（宿主弹选择器并调用你的 `versionOptions` / `buildHistory` / `switchVersion`），**不需要**在 `main` 里实现。
- `switchVersion` 必须返回完整 Detail，不能只返回 `{appId, env, version}`。
- `detailMenu` 方法可选；没有自定义动作就返回空数组（文件本身必须存在）。

### 6.1 Detail 字段

| 字段 | 说明 |
| --- | --- |
| `appId` | 建议必填；页面有效性主要看 `packageName` + `name` |
| `name` | 必需（页面有效性检查需要） |
| `packageName` | 缺省时用 `appId` |
| `icon` | 绝对 URL |
| `description` / `des` | 简介 |
| `version` | 版本名 |
| `developer` / `user` | 开发者 |
| `projectUrl` | 项目地址 |
| `readme` | 长文本（可含 HTML，按 Markdown/文本展示） |
| `sections` | 区块顺序：`version`、`statistics`、`screenshots`、`readme`、`downloads`、`rating`、`developer`、`changelog`、`permissions`；未知值丢弃 |
| `downloads` | 下载项数组，见下 |
| `downloadCount` | 下载量（数字） |
| `screenshots` | 字符串数组或 `{url,description}` 数组 |
| `changelog` | 更新说明 |
| `permissions` | 字符串数组 |
| `statistics` / `rating` / `ratingCount` / `stars` / `forks` | 统计与评分 |

`downloads` 每一项：

| 字段 | 说明 |
| --- | --- |
| `url` | 下载直链（绝对 URL） |
| `name` | 文件名 |
| `size` | 字节数（数字或数字字符串） |
| `version` / `versionCode` | 版本 |
| `platform` | 如 `android` |
| `hash` / `hashType` | 校验值（可选） |
| `publishedAt` / `updateTime` | **数字时间戳**（秒或毫秒）；ISO 字符串会被丢弃 |
| `downloadable` | 默认 true；显式 false 时禁止下载 |
| `note` | 下载项说明（如“需要登录”“当前环境无构建”） |
| `extra` | 标签对象（`{tag: '文本'}` 或 `{tag: {text,icon}}`） |

“需要凭证 / 未登录”场景的推荐写法：

```js
{
  url: '',
  name: '需要登录后下载',
  version: version,
  downloadable: false,
  note: '请先在脚本渠道设置中填写账号密码',
}
```

### 6.2 版本 / 环境

如果数据源有“环境（sit/uat/prd）+ 版本 + 构建历史”，`versionOptions` / `switchVersion` 是标准做法：

```js
async function versionOptions(appId, env) {
  var r = await get('/versions', { appId: appId, env: env || '' });
  if (!r.ok || !r.data) return { ok: false, error: r.error || '无版本数据' };
  return {
    ok: true,
    data: {
      title: '选择版本',
      envs: ['sit', 'uat', 'prd'],
      versions: r.data.map(function (v) {
        return {
          version: str(v.version),
          envs: Array.isArray(v.envs) ? v.envs : [env || 'sit'],
          buildCount: Number(v.buildCount) || 0,
        };
      }),
      currentEnv: env || 'sit',
      currentVersion: str(r.data.length ? r.data[0].version : ''),
    },
  };
}
```

- `versions[].buildCount` 不是数字时按 0 处理。
- `switchVersion` 的返回必须和 `getAppDetail` 一样是**完整详情**；只返回 `{appId,env,version}` 骨架会导致详情页空白。
- 构建历史场景：`buildHistory` 返回的 `builds[]` 至少要有 `num`（可选 `ipaName`）；宿主选中后会调用 `switchVersion({appId, env, version, build:{num, ipaName}})`，所以 `switchVersion` 必须接收 `params.build` 并返回该构建对应的详情。
- 每次调用都是新 runtime，`_currentVersion` 之类的模块变量不会跨调用保留；需要状态就通过 `host.env` / 参数 / 重新请求获取。

### 6.3 自定义动作（`detailMenu` + `jscall`）

```js
function detailMenu(appId) {
  return {
    ok: true,
    data: [
      { action: '切换 UA', jscall: 'jsswitchUA', clickIsDimiss: true },
    ],
  };
}

async function main(method, params) {
  switch (method) {
    case 'detailMenu': return detailMenu(params.appId);
    case 'jsswitchUA': return await jsSwitchUA(params.appId);
    default: return null;
  }
}
```

- 用户点菜单项时，Flutter 会调用 `main(jscall, { appId })`。
- 自定义动作里可以调用 `host.ui.call(...)`；页面没有打开时 UI 调用会返回失败，要按“静默取消”处理。
- 版本/构建选择器是**宿主驱动**的：调用后由宿主完成切换/下载，脚本不要依赖返回值（详见 4.6）。
- 这类自定义方法**不能**被 AI 的 `runJsChannel` 直接调用（只有固定白名单，见第 8 节）。

### 6.4 detail 结构示例

```js
async function getAppDetail(appId) {
  var r = await get('/app/' + encodeURIComponent(appId));
  if (!r.ok || !r.data) return { ok: true, data: null };
  var raw = r.data;
  return {
    ok: true,
    data: {
      appId: appId,
      packageName: str(pick(raw, ['packageName'], appId)),
      name: str(pick(raw, ['name'], '')),
      icon: str(pick(raw, ['icon'], '')),
      description: str(pick(raw, ['description'], '')),
      version: str(pick(raw, ['versionName'], '')),
      developer: str(pick(raw, ['developer'], '')),
      readme: str(pick(raw, ['readme'], '')),
      sections: ['downloads', 'readme', 'changelog'],
      changelog: str(pick(raw, ['changelog'], '')),
      downloads: (Array.isArray(raw.downloads) ? raw.downloads : []).map(function (d) {
        return {
          url: str(d.url),
          name: str(d.name || (str(raw.name) + '.apk')),
          size: Number(d.size) || null,
          version: str(d.version || raw.versionName || ''),
          publishedAt: Number(d.updatedAt) || null,
        };
      }),
    },
  };
}
```

### 6.5 测试 detail.js

导入渠道包后：

1. 先打开该渠道的详情页（真实页面路径），确认 `getAppDetail` 能渲染名称/图标/下载区。
2. 用 `runJsChannel` 验证 detail.js 的方法：

```text
runJsChannel(channel, 'versionOptions', {'appId': '...'})
runJsChannel(channel, 'switchVersion', {'appId': '...', 'env': 'sit', 'version': '1.0.0'})
runJsChannel(channel, 'buildHistory', {'appId': '...', 'version': '1.0.0', 'env': 'sit'})
runJsChannel(channel, 'detailMenu', {'appId': '...'})
```

注意：

- `runJsChannel('getAppDetail')` 走的是 **entry.js**；`detail.js` 的 `getAppDetail` 只能通过详情页触发。
- `detailMenu` 返回空数组或 null 都正常（表示没有“更多”菜单）。
- 自定义 `jscall`（例如 `jsswitchUA`）**不能**直接通过 `runJsChannel` 调用，只能从详情页“更多”菜单点击。

如果导入的是**没有 `detail.js` 的历史包**，会看到：

```text
has no detail.js; menu disabled      // 没有“更多”菜单
no detail from ...; keeping the prefill  // entry.js 也没有 getAppDetail，只显示基础信息
```

这两句是 DEBUG 降级提示，不是导入失败。**按本技能规范交付的新包必须包含 `detail.js`，不应出现这两条。**

### 6.6 detail.js 常见坑

- `switchVersion` 只返回 `{appId, env, version}` 骨架 → 详情页空白；必须返回完整 Detail。
- `publishedAt` / `updateTime` 在 `downloads` 里必须是**数字时间戳**；ISO 字符串会被丢弃。
- `readme` / `screenshots` / `downloads` 都要放在 Detail **顶层**，不要塞进 `extra`。
- `sections` 里的未知值会被丢弃；`downloads` / `readme` 会自动渲染，`developer` / `changelog` / `permissions` 需要显式声明。
- 详情页有效性主要看 `packageName` + `name`；两者都空时页面会显得没数据。
- `downloads[].url` 用绝对地址；需要登录时用 `downloadable:false` + `note`，不要给会失败的假地址。
- 模块级变量（`_currentVersion` 等）不会跨调用保留：每次 detail 调用都是新 runtime。
- `host.ui.call` 只在详情页已打开时可靠；`showVersionPicker` / `showBuildHistory` 是宿主驱动的，不要读返回值。
- `detail.js` 只负责详情/版本/环境；不要在这里做全量同步或写 `host.database.insertApps`。

## 7. 常见数据源适配套路

### 7.1 普通 REST 商店

- `searchApps`: `/search?q=...` → 映射 `AppInfo[]`
- `getAppInfo`: `/app/{id}` → `AppInfo`
- `getAppDetail`: 同上或 `/app/{id}/detail` → `Detail` + `downloads`
- `appId` 优先用 `packageName`；没有包名就用渠道 ID，并把它同时放进 `extra`

### 7.2 企业分发 / 需要账号

- `meta.json` 声明 `requiredEnvVars`
- `entry.js` / `detail.js` 每次请求前读 `host.env.get`
- 登录失败返回 `{ ok:false, error:'凭证无效，请在脚本渠道设置中更新' }`
- 下载 URL 需要 token 时，直接把带 token 的完整 URL 放进 `downloads[].url`
- 没有凭证时：`downloadable:false` + `note`，不要给一个点了会失败的假 URL（`url` 可以为空）

### 7.3 网页 / HTML

- 优先找页面背后的 JSON 接口；实在只能解析 HTML 时，用字符串 `indexOf` / 正则提取固定字段，并加日志。
- 正则要锚定上下文，不要用贪婪匹配整页。
- HTML 变化风险高，交付时明确告诉用户维护成本。

### 7.4 分页 / 全量

- 搜索：只取第一页（或一个合理页大小），不要翻到底。
- 全量同步：一次请求拿大页；必须在 5 秒内完成。
- 超过预算就缩小范围（按分类/环境分批），不要循环重试。

## 8. 导入、验证、迭代

### 8.1 导入

1. 用户把 `<stem>/` 里的 `entry.js`、`detail.js`、`meta.json`（和 `icons/`）压成 `<stem>.zip`。
2. 「设置 → 脚本渠道 → 导入渠道包」选择 zip。
3. 若 `meta.json` 声明了 `requiredEnvVars`，导入弹窗会要求填写。
4. 同名 zip 再次导入会覆盖同 key 的渠道包。

### 8.2 用 `runJsChannel` 验证

```text
runJsChannel(channel='js_<stem>', method='searchApps', params={'keyword':'微信'})
runJsChannel(channel='js_<stem>', method='getAllApps')   // 注意：读本地已保存行
runJsChannel(channel='js_<stem>', method='checkUpdate')  // 渠道是否有全量更新
runJsChannel(channel='js_<stem>', method='getAppInfo', params={'appId':'com.tencent.mm'})
runJsChannel(channel='js_<stem>', method='getAppDetail', params={'appId':'com.tencent.mm'})
runJsChannel(channel='js_<stem>', method='getConfig')
runJsChannel(channel='js_<stem>', method='versionOptions', params={'appId':'...'})
runJsChannel(channel='js_<stem>', method='switchVersion', params={'appId':'...','env':'sit','version':'1.0.0'})
runJsChannel(channel='js_<stem>', method='buildHistory', params={'appId':'...','version':'1.0.0','env':'sit'})
runJsChannel(channel='js_<stem>', method='detailMenu', params={'appId':'...'})
```

可用方法只有白名单里的这些；其它方法（包括自定义 `jscall`）会返回 null。

验证顺序：

0. 写映射前可以先 `httpRequest` 探测接口（公网、只读方法优先），确认真实字段
1. `searchApps`（最重要，不依赖本地库）
2. `getAppInfo` → `getAppDetail`
3. 详情页 / 下载（让用户实际打开页面确认）
4. 有版本/环境时再测 `versionOptions` / `switchVersion`
5. `getAllApps` 返回的是**已保存行**，不是脚本结果；不要用它判断脚本是否正常
6. `runJsChannel('getAppDetail')` 走 **entry.js**；`detail.js` 的 `getAppDetail` 由详情页触发（可先用 `switchVersion` 验证同结构返回）

### 8.3 和其它工具配合

- 接口结构和鉴权方式不确定时，先用 `httpRequest` 探测（见第 1 节），再写 `entry.js` / `detail.js`。
- 如果接口文档/示例页面依赖 JS 渲染：用 `webView open` → `content` → `requests`；
  需要登录先让用户走「AI 设置 → WebView 调试」，Cookie 会共享。
- 调通稳定接口后，用 `requestDebug save` 保存到「请求调试」库（可指定集合）；
  后续用 `requestDebug list/get` 查看，避免每次重新抓包。
- `getAppInfo`（工具）支持 `channel: js_xxx`，可以查单个应用。
- `downloadApp` 支持 `channel: js_xxx`，会走渠道详情里的 `downloads`。
- `updateApps` 支持按 `appId + channel` 检查更新。
- **`searchApp`（工具）只遍历内置渠道枚举，不包含 `js_*`**；脚本渠道搜索必须用 `runJsChannel`。

### 8.4 迭代

```text
改工作区文件 → 用户重新打 zip → 重新导入 → 再 runJsChannel
```

不要假设“改完文件就生效”；渠道包是导入时复制进安装目录的。

## 9. 报错与排查

| 现象 / 错误 | 常见原因 | 处理 |
| --- | --- | --- |
| `CORE_E_SCRIPT_EVAL` | JS 语法错误 / 用了未定义全局（`require`、`fetch`、`console`） | 检查第 3.3 节；未实现方法要 `return null` |
| `CORE_E_SCRIPT_TIMEOUT` | 单次执行超过 5 秒（通常是网络慢 / 翻页太多） | 减少请求数、加大页大小、避免循环 |
| `CORE_E_SCRIPT_LIMIT` | 内存 / 栈 / 结果 10MB / 响应 20MB / 重定向超限 | 裁剪字段、分页、别把原始大 JSON 全返回 |
| `CORE_E_SCRIPT_INVALID_ARGUMENT` | URL 非法、bridge 参数不是对象 | 检查 `host.network` 的 url / params |
| `CORE_E_SCRIPT_HOST` | 网络传输失败、宿主能力异常 | 加 `host.log.error`，检查接口连通性 |
| `pack_not_zip` / `pack_corrupt` | 不是 zip / zip 损坏 | 重新压缩 |
| `pack_layout` | zip 根目录有 `README`、`package.json`、子目录等 | 只保留 entry.js / detail.js / meta.json / icons |
| `pack_missing_entry` | 缺 `entry.js` 或为空 | 放到 zip 根目录 |
| `pack_invalid_key` | zip 文件名不合法 | 用 `^[a-zA-Z_][a-zA-Z0-9_]*$` |
| `pack_too_large` | 超过条目/大小限制 | 精简资源 |
| `pack_unsafe_entry` | 路径穿越 / 绝对路径 / 软链接 | 只用普通文件名 |
| 搜索有结果但列表为空 | 结果行缺 `appId` 或 `name` | 补必填字段 |
| 详情页空白 | detail 缺 `name` / `packageName`，或 `switchVersion` 只返回骨架 | 返回完整 Detail |
| 发现页没有应用 | 从未保存过，且没有走搜索 | 用搜索添加；实现 `doUpdate` 可支持宿主全量刷新（入口随版本而异） |
| 更新检测永远没更新 | `checkAppUpdate` 的 `version` 与已安装版本比较口径不一致 | 用 `versionCode` 或统一的语义化版本 |
| `host.ui.call` 返回 `未注册` / 无活动页 | 在 entry runtime 或非详情页调用 | 只在 detail.js + 详情页打开时用 |

## 10. 交付前自查清单

- [ ] zip 根目录包含 `entry.js`、`detail.js`、`meta.json`（缺一不可；`icons/` 可选）
- [ ] zip 文件名合法，且没有 `js_` 前缀
- [ ] `meta.json` 至少包含 `name` / `description`，且与 `CHANNEL_META` 一致
- [ ] 即使没有详情能力，也提供了最小 `detail.js`（`main` 返回 null 即可）
- [ ] 需要凭证时 `requiredEnvVars` 已声明，脚本用 `host.env.get` 读取
- [ ] 每个 `main` 未实现的分支都 `return null`
- [ ] 没有 `require` / `fetch` / `setTimeout` / `console` / Node API
- [ ] `searchApps('')` 返回 `{ok:true,data:[]}`，不发请求
- [ ] `AppInfo` 的 `appId` + `name` 一定有值
- [ ] `downloads[].url` 是绝对地址；时间戳是数字
- [ ] 单次调用请求数少、能在 5 秒内完成
- [ ] `switchVersion` 返回完整详情（不是骨架）
- [ ] 已用 `runJsChannel` 验证 searchApps / getAppInfo / getAppDetail
- [ ] 已提醒用户：改完要重新打包导入
