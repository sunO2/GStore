// ============================================================
// 平安 Iris Store 渠道脚本 · detail.js（详情页）
// ------------------------------------------------------------
// 用途：平安企业应用分发平台（Iris Store）渠道脚本 zip 渠道包
// （channels/pingan.zip）的详情页部分（detail.js，可选）。
// 由页面级 JsDetailChannel（独立 runtime）消费，页面退出释放。
// 应用二进制不含此脚本；不进入版本库（已被 .gitignore 忽略）。
//
// 本文件为 zip 渠道包的详情页部分：
//   main(method, params) → { ok, data } | null
//   method: getAppDetail / versionOptions / switchVersion / buildHistory
//         | detailMenu / jsswitchVersion / jsBuildHistory
// 发现页部分在 entry.js（发现页/更新路径独立 runtime 消费），
// 两者各自独立 runtime，无法共享工具函数——本文件自带所需工具。
//
// Hybrid 详情页契约（与 Flutter 侧 detailMenu / host.ui 对齐）：
//   main('detailMenu', {appId}) → { ok, data: [{action, jscall, clickIsDimiss}] }
//     详情页「更多」菜单声明；点击 action → Flutter 调 main(jscall, {appId})（JS 全权）。
//   main('jsswitchVersion', {appId}) → 拉版本选项 → host.ui.call('showVersionPicker') 弹
//     Flutter 选择框 → 用户选 {env, version} → host.ui.call('refreshDetail') 刷新详情页
//     （切版本/env 数据确实不同，需重拉详情）。
//   main('jsBuildHistory', {appId}) → 拉当前 env 最新版本 builds（缓存复用）→
//     host.ui.call('showBuildHistory') 弹 Flutter 构建历史选择器 → 用户选构建 →
//     从缓存取该构建 → 生成单条 downloads → host.ui.call('updateDownloadList') 局部更新
//     下载区（切构建历史数据同源，仅下载项不同——不再 refreshDetail 全量重拉）。
//
// 接口/契约对齐说明同 entry.js（安全凭证检测为 detail runtime 会话级，
// 与 entry runtime 互不共享——各自独立缓存）。
// ============================================================

const BASE_HOST = 'https://test-b-fat.pingan.com.cn';
const ISTORE_BASE = BASE_HOST + '/istore';
const API_BASE = ISTORE_BASE + '/istore-api';
const MCD_BASE = BASE_HOST + '/mcd-api/mcd-api';
const MCD_LOGIN_BASE = BASE_HOST + '/mcd-api/mcd-api';
const ALL_ENVS = ['sit', 'uat', 'prd', 'rge', 'tmp'];

// User-Agent：模拟 Android Chrome，避免被接口反爬
const DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

// UA 预设
const _UAS = {
  ANDROID: 'Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Mobile Safari/537.36',
  IOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
  HARMONY: 'Mozilla/5.0 (Phone; HarmonyOS 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 ArkWeb/4.1.6.1 Mobile HuaweiBrowser/5.0.3.351',
};
var _currentUA = DEFAULT_UA; // 当前 UA（可切换，影响 safeGet 请求头）

function genUuid() { return (Math.random() + '_' + new Date().getTime()); }
function safeStr(v) { try { return String(v); } catch (e) { return ''; } }
function toNumOrNull(v) { var n = Number(v); return isNaN(n) ? null : n; }
function toTime(v) { var t = typeof v === 'number' ? v : Date.parse(v); return isNaN(t) ? 0 : t; }
// 字节数 → 可读文本（B/KB/MB/GB），非正数返回空串（对齐 Dart formatFileSize 口径）
function formatBytes(v) {
  var n = Number(v);
  if (!n || isNaN(n) || n <= 0) return '';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
  return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}
function abs(p) {
  if (!p) return '';
  if (p.indexOf('http') === 0) return p;
  if (p.charAt(0) === '/') return ISTORE_BASE + p;
  return ISTORE_BASE + '/' + p;
}

/// 截图专用前缀：build 接口 appInfo.screenshots 实际资源位于 istore-api/sunflower 下
function shotAbs(p) {
  if (!p) return '';
  if (p.indexOf('http') === 0) return p;
  var SCREENSHOT_BASE = API_BASE + '/sunflower';
  if (p.charAt(0) === '/') return SCREENSHOT_BASE + p;
  return SCREENSHOT_BASE + '/' + p;
}

/// 同 abs，但使用 API_BASE 前缀（app-list 的 imgSrc 等资源路径）
function apiAbs(p) {
  if (!p) return '';
  if (p.indexOf('http') === 0) return p;
  if (p.charAt(0) === '/') return API_BASE + p;
  return API_BASE + '/' + p;
}

async function safeGet(path, params) {
  try {
    var url = (path.indexOf('http') === 0) ? path : (API_BASE + path);
    // 参数经 opts.params 传递（→ Dio queryParameters）：mock/测试按
    // queryParameters 路由（pageNum/appname），URL 字符串内联的 query 不会
    // 被 Dio 解析进 queryParameters，故必须走 params；且保留原始类型。
    var qp = {};
    if (params) {
      for (var k in params) {
        if (params[k] !== undefined && params[k] !== null && params[k] !== '') {
          qp[k] = params[k];
        }
      }
    }
    var r = await host.network.get(url, { params: qp, headers: { 'User-Agent': _currentUA } });
    if (!r) return { ok: false, data: null, error: '网络错误' };
    var d = r.data !== undefined ? r.data : null;
    if (r.ok === false) {
      // 非 2xx：保留响应体（data）供脚本按 status 降级（401 → 重认证、500 → 降级）
      return { ok: false, status: r.status, data: d, error: safeStr(r.error || ('HTTP ' + r.status)) };
    }
    return { ok: true, data: d, status: r.status };
  } catch (e) {
    host.log.error('safeGet(' + path + ') 异常: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

async function readCredentials() {
  var user = '', pass = '', env = 'sit'; // 默认 sit（PINGAN_ENV 配置优先）
  try {
    var u = await host.env.get('PINGAN_USER');
    var p = await host.env.get('PINGAN_PASS');
    var e = await host.env.get('PINGAN_ENV');
    if (u && u.data !== undefined && u.data !== null) user = String(u.data);
    if (p && p.data !== undefined && p.data !== null) pass = String(p.data);
    if (e && e.data !== undefined && e.data !== null && String(e.data) !== '') env = String(e.data);
  } catch (err) { host.log.error('读取凭证异常: ' + safeStr(err)); }
  // 诊断日志（不打印密码明文，只打长度）：真机确认 detail runtime 是否读到渠道 env
  host.log.info('readCredentials user=' + (user ? '非空(' + user.length + ')' : '空') +
      ' pass=' + (pass ? '非空(' + pass.length + ')' : '空') + ' env=' + env);
  return { user: user, pass: pass, env: env };
}

function buildApkUrl(env, ipaName, user, pass) {
  if (!user || !pass || !ipaName) return '';
  return MCD_BASE + '/proxy/' + encodeURIComponent(env) + '/' + encodeURIComponent(ipaName) +
      '?um=' + encodeURIComponent(user) + '&value=' + encodeURIComponent(pass);
}

// ---- 会话级凭证检测（login/check 懒检测 + 缓存，detail runtime 独立）----
// 成功 → 会话内永久缓存（同 user/pass 只调一次）；
// 失败 → 60s 冷却（_authFail）：冷却期内直接返回 false 不再重发。
// 修复前失败完全不缓存 → 每次 getAppDetail/switchVersion/jsBuildHistory 都重发
// login/check（主+文档路径 2 次），认证端点异常时形成请求风暴（真机复现根因之一）。
var _authChecked = null;
var _authRetryMs = 60 * 1000; // 失败冷却窗口
var _authFail = null; // {user, pass, at}（按凭证记录，换凭证不受旧冷却影响）

async function ensureAuthChecked(cred, source) {
  if (!cred || !cred.user || !cred.pass) return false;
  var src = source || '?';
  if (_authChecked && _authChecked.user === cred.user && _authChecked.pass === cred.pass) {
    host.log.info('[login/check] 会话缓存命中（已认证）source=' + src);
    return true;
  }
  var now = new Date().getTime();
  if (_authFail && _authFail.user === cred.user && _authFail.pass === cred.pass &&
      (now - _authFail.at) < _authRetryMs) {
    host.log.info('[login/check] 失败冷却中跳过重发 source=' + src +
        '（距上次失败 ' + Math.round((now - _authFail.at) / 1000) + 's，' +
        Math.round((_authRetryMs - (now - _authFail.at)) / 1000) + 's 后可重试）');
    return false;
  }
  try {
    host.log.info('[login/check] 发起校验 source=' + src +
        ' user=' + (cred.user ? cred.user.length + '字' : '空') +
        ' pass=' + (cred.pass ? cred.pass.length + '字' : '空'));
    var main = await safeGet(MCD_LOGIN_BASE + '/login/check', { um: cred.user, value: cred.pass });
    if (main && main.ok && main.data && String(main.data.code) === '000000') {
      _authChecked = { user: cred.user, pass: cred.pass };
      _authFail = null;
      host.log.info('[login/check] 校验通过 source=' + src);
      return true;
    }
    _authFail = { user: cred.user, pass: cred.pass, at: now };
    host.log.error('[login/check] 校验失败，进入 ' +
        Math.round(_authRetryMs / 1000) + 's 冷却 source=' + src);
  } catch (e) {
    host.log.error('ensureAuthChecked 异常: ' + safeStr(e));
    _authFail = { user: cred.user, pass: cred.pass, at: now };
  }
  return false; // 冷却期内不再重发（防请求风暴），超时后重试一次
}

// ---- 包名 → 应用名解析缓存（同 detail runtime 会话内有效）----
// getAppDetail/switchVersion 成功时记录 `包名(identifier) → 查询名(name)`；
// 详情页收到包名 appId 时 resolveAppName 直接命中，避免二次网络/查库。
var _nameCache = {};
var _currentEnv = ''; // 当前有效 env（getAppDetail/switchVersion 设置，后续操作复用）
var _currentVersion = ''; // 当前有效 version（getAppDetail/switchVersion 设置）
var _currentBuildNum = null; // 当前构建 num（getAppDetail/switchVersion 设置，历史构建弹框预选中）
var _currentAppLogo = ''; // 当前应用图标（getAppDetail 设置，switchVersion 回退兜底）

async function resolveAppName(appId) {
  var cached = _nameCache[appId];
  if (cached !== undefined) return cached;
  try {
    var all = await host.database.getAppsByChannel();
    var list = (all && all.data !== undefined && Array.isArray(all.data)) ? all.data : (Array.isArray(all) ? all : []);
    for (var i = 0; i < list.length; i++) {
      var it = list[i]; if (!it) continue;
      var ex = it.extra;
      try { ex = typeof it.extra === 'string' ? JSON.parse(it.extra) : it.extra; } catch (e) { ex = it.extra; }
      var exAppId = ex && ex.appId !== undefined ? String(ex.appId) : '';
      var name = it.name !== undefined ? String(it.name) : '';
      var repo = it.repositories !== undefined ? String(it.repositories) : '';
      if (exAppId === appId || repo === appId) return name;
    }
  } catch (e) { host.log.error('resolveAppName 查库异常: ' + safeStr(e)); }
  return appId;
}

// ---- 构建文件下载引用 ----
function firstDownloadRef(build) {
  if (!build) return '';
  var f = Array.isArray(build.fileurl) && build.fileurl.length > 0 ? String(build.fileurl[0]) : '';
  if (f) return f;
  if (Array.isArray(build.ipa) && build.ipa.length > 0 && build.ipa[0] && build.ipa[0].name) {
    return String(build.ipa[0].name);
  }
  return '';
}

/// 供 proxy 转发的文件名：优先真实接口 ipa[0].name，否则取 fileurl 末段
function buildIpaName(build) {
  if (!build) return '';
  if (Array.isArray(build.ipa) && build.ipa.length > 0 && build.ipa[0] && build.ipa[0].name) {
    return String(build.ipa[0].name);
  }
  var f = firstDownloadRef(build);
  if (f) { var parts = String(f).split('/'); return parts[parts.length - 1]; }
  return '';
}

/// 直连下载地址：仅 fileurl[0] 可直连（绝对化）；ipa[0].name 是 proxy 文件名
function directDownloadUrl(build) {
  var f = (build && Array.isArray(build.fileurl) && build.fileurl.length > 0) ? String(build.fileurl[0]) : '';
  return f ? abs(f) : '';
}

// ---- 请求级缓存（同 runtime 会话内有效，TTL 防陈旧）----
// build-list 按 'name|version|env' 缓存：进入详情(getAppDetail)/版本选项
// (getVersionOptions)/切版本(switchVersion)/构建历史(getBuildHistory) 重复拉同一
// 查询 → 缓存命中零请求。修复前四者各自重复拉 build-list（详情页一次会话
// 十几次 build-list 的根因之一）；TTL 5 分钟：会话内复用，超时重拉防数据陈旧。
var _CACHE_TTL_MS = 5 * 60 * 1000;
var _buildListCache = {}; // key 'name|version|env' → {at, data:{appLogo, buildList}}
var _buildDetailCache = {}; // key 'groupId' → {at, data}

async function fetchBuildList(name, version, env, source) {
  if (!name) {
    // 空 appname 防护：safeGet 会过滤空参数 → 裸 URL（无 appname/env/uuid），
    // 服务端行为不可控且无法定位调用方——拒绝并记来源日志，绝不发无意义请求。
    host.log.error('[build-list] appname 为空，拒绝请求（source=' + (source || '?') + '）');
    return null;
  }
  var key = String(name) + '|' + String(version || '') + '|' + String(env || '');
  var hit = _buildListCache[key];
  if (hit && (new Date().getTime() - hit.at) < _CACHE_TTL_MS) {
    host.log.info('[build-list] 缓存命中 source=' + (source || '?') + ' key=' + key);
    return hit.data;
  }
  host.log.info('[build-list] 发起请求 source=' + (source || '?') + ' key=' + key);
  var res = await safeGet('/sunflower/i/build-list', { appname: name, version: version || '', env: env || '', uuid: genUuid() });
  if (!res || !res.ok) {
    host.log.error('[build-list] 请求失败 source=' + (source || '?') + ' key=' + key + ' err=' + safeStr(res && res.error));
    return null;
  }
  var body = res.data || {};
  var data = { appLogo: body.appLogo || '', buildList: Array.isArray(body.buildList) ? body.buildList : [] };
  _buildListCache[key] = { at: new Date().getTime(), data: data };
  return data;
}

async function fetchBuildDetail(groupId, source) {
  if (!groupId) {
    host.log.error('[build] _id 为空，拒绝请求（source=' + (source || '?') + '）');
    return null;
  }
  var hit = _buildDetailCache[String(groupId)];
  if (hit && (new Date().getTime() - hit.at) < _CACHE_TTL_MS) {
    host.log.info('[build] 缓存命中 source=' + (source || '?') + ' groupId=' + groupId);
    return hit.data;
  }
  host.log.info('[build] 发起请求 source=' + (source || '?') + ' groupId=' + groupId);
  var res = await safeGet('/sunflower/i/build', { uuid: genUuid(), _id: groupId });
  if (!res || !res.ok) {
    host.log.error('[build] 请求失败 source=' + (source || '?') + ' groupId=' + groupId + ' err=' + safeStr(res && res.error));
    return null;
  }
  _buildDetailCache[String(groupId)] = { at: new Date().getTime(), data: res.data || null };
  return res.data || null;
}

// 当前 UA 是否 Android 系（Android UA 或默认 UA）：Android 系 → 只取 android 平台组；
// 非 Android 系（iOS/Harmony UA）→ 不过滤平台（需显示全部平台供二维码下载）。
function isAndroidUA() {
  return _currentUA === _UAS.ANDROID || _currentUA === DEFAULT_UA;
}
function isIOSUA() {
  return _currentUA === _UAS.IOS;
}
function isHarmonyUA() {
  return _currentUA === _UAS.HARMONY;
}

function isAndroidGroup(g) {
  if (!g) return false;
  if (isAndroidUA()) return !g.platform || g.platform === 'android';
  if (isIOSUA()) return g.platform === 'ios';
  if (isHarmonyUA()) return g.platform === 'harmony';
  return true;
}

function findPlatformGroup(groups) {
  if (!groups || groups.length === 0) return null;
  if (isAndroidUA()) return groups.find(function(g) { return !g.platform || g.platform === 'android'; }) || groups[0];
  if (isIOSUA()) return groups.find(function(g) { return g.platform === 'ios'; }) || groups[0];
  if (isHarmonyUA()) return groups.find(function(g) { return g.platform === 'harmony'; }) || groups[0];
  return groups[0];
}

function buildDetailFromGroup(group, env, screenshots, queryAppId, selBuild) {
  if (!group || typeof group !== 'object') return null;
  var builds = Array.isArray(group.builds) ? group.builds : [];
  // 防御：剔除 null/非对象条目（真实接口历史构建偶有脏数据，杜绝 TypeError）
  var valid = [];
  for (var i = 0; i < builds.length; i++) {
    if (builds[i] && typeof builds[i] === 'object') valid.push(builds[i]);
  }
  builds = valid;
  if (builds.length === 0) return null;
  // 指定构建（历史构建选中项；未命中/缺省 → 该版本最新构建）
  var build = (selBuild && typeof selBuild === 'object') ? selBuild : builds[0];
  var identifier = build.identifier || '';
  var versionname = build.versionname || group.version || '';
  var version = group.version || '';
  var history = [];
  for (var j = 0; j < builds.length; j++) {
    var b = builds[j];
    history.push({
      num: toNumOrNull(b.num),
      publishedAt: b.publishedAt !== undefined ? b.publishedAt : null,
      size: toNumOrNull(b.size),
      changelog: b.changelog || '',
      installTimes: toNumOrNull(b.installTimes),
      builtBy: b.builtBy || '',
      fileUrl: firstDownloadRef(b),
    });
  }
  var extra = {
    _id: group._id || '',
    identifier: identifier, // 真实包名（详情解析用；appId 保持渠道查询键）
    version: version,
    versionname: versionname,
    num: toNumOrNull(build.num),
    size: toNumOrNull(build.size),
    installTimes: toNumOrNull(build.installTimes),
    changelog: build.changelog || '',
    builtBy: build.builtBy || '',
    env: env || group.env || '',
    platform: group.platform || '',
    publishedAt: group.publishedAt !== undefined ? group.publishedAt : null,
    versionHistory: history,
    screenshots: (Array.isArray(screenshots) ? screenshots : []).map(shotAbs),
  };
  return {
    // appId = 查询键（build-list 的 appname，渠道语义；绝不用 identifier 包名覆盖，
    // 否则详情/聚合会把 appId 变包名导致后续 build-list 查不到）
    appId: queryAppId || identifier || versionname || version || group.appname || '',
    name: versionname || version || '',
    icon: '',
    des: '',
    user: 'js_pingan',
    repositories: group.appname || '',
    extra: extra,
    // 顶层截图键 + 区块声明（纯 additive）：代理 getter 只读顶层 _data['screenshots']，
    // 既有 extra.screenshots 嵌套键保留不动；sections 声明驱动 view 渲染截图区块。
    // 本构造器为 getAppDetail 与 switchVersion 共用 → 切版路径同类缺陷一并修复。
    sections: ['downloads', 'screenshots'],
    screenshots: (Array.isArray(screenshots) ? screenshots : []).map(shotAbs),
  };
}

// 兜底：buildDetailFromGroup 抛错时用 group 原始字段组装最简详情（不因历史映射失败）
function minimalDetailFromGroup(group, env, screenshots, queryAppId) {
  var g = (group && typeof group === 'object') ? group : {};
  var builds = Array.isArray(g.builds) ? g.builds : [];
  var build = (builds.length > 0 && builds[0] && typeof builds[0] === 'object') ? builds[0] : {};
  var versionname = build.versionname || g.version || '';
  var identifier = build.identifier || '';
  return {
    // appId = 查询键（同 buildDetailFromGroup，绝不用 identifier 包名覆盖）
    appId: queryAppId || identifier || versionname || g.appname || '',
    name: versionname || '',
    icon: '',
    des: '',
    user: 'js_pingan',
    repositories: g.appname || '',
    extra: {
      _id: g._id || '',
      identifier: identifier, // 真实包名
      version: g.version || '',
      versionname: versionname,
      num: toNumOrNull(build.num),
      size: toNumOrNull(build.size),
      env: env || g.env || '',
      platform: g.platform || '',
      screenshots: (Array.isArray(screenshots) ? screenshots : []).map(shotAbs),
      versionHistory: [],
    },
    // 顶层截图键 + 区块声明（纯 additive，同 buildDetailFromGroup——代理 getter
    // 只读顶层 _data['screenshots']；既有 extra.screenshots 嵌套键保留不动）
    sections: ['downloads', 'screenshots'],
    screenshots: (Array.isArray(screenshots) ? screenshots : []).map(shotAbs),
  };
}

// 该组是否需凭证检测：无 fileurl 直连 → 走 proxy → 需确认凭证有效
function groupNeedsAuth(group) {
  var b = (group && Array.isArray(group.builds) && group.builds.length > 0) ? group.builds[0] : null;
  return !(b && Array.isArray(b.fileurl) && b.fileurl.length > 0);
}

// 历史构建选中项 → 组内具体构建：优先 num 匹配，其次 ipaName（真实 ipa[0].name 或
// versionname+'.apk' 下载名）；未命中/缺省 → 组内最新构建（builds[0]）。
function findBuild(group, selBuild) {
  var builds = (group && Array.isArray(group.builds)) ? group.builds : [];
  // 防御：剔除 null/非对象条目（真实接口历史构建偶有脏数据，杜绝 TypeError）
  var valid = [];
  for (var i = 0; i < builds.length; i++) {
    if (builds[i] && typeof builds[i] === 'object') valid.push(builds[i]);
  }
  builds = valid;
  if (builds.length === 0) return null;
  if (selBuild && typeof selBuild === 'object') {
    var selNum = toNumOrNull(selBuild.num);
    var selIpa = selBuild.ipaName ? String(selBuild.ipaName) : '';
    for (var i = 0; i < builds.length; i++) {
      if (selNum !== null && toNumOrNull(builds[i].num) === selNum) return builds[i];
    }
    for (var j = 0; j < builds.length; j++) {
      var b = builds[j];
      var ipa = buildIpaName(b);
      var downloadName = (b.versionname || group.version || 'app') + '.apk';
      if (selIpa && (ipa === selIpa || downloadName === selIpa)) return b;
    }
  }
  return builds[0];
}

// ---- 下载地址解析（⑤⑥⑦⑧ 契约）----
function resolveDownloadUrl(group, cred, authOk, selBuild) {
  var build = findBuild(group, selBuild);
  var direct = directDownloadUrl(build);
  if (direct) {
    return { apkUrl: direct, downloadNote: null, authError: null, authAttempted: false };
  }
  if (!cred || !cred.user || !cred.pass) {
    return {
      apkUrl: null,
      downloadNote: '需认证或暂不可下载',
      authError: '未配置 PINGAN_USER/PINGAN_PASS 环境变量',
      authAttempted: false,
    };
  }
  if (!authOk) {
    return {
      apkUrl: null,
      downloadNote: '需认证或暂不可下载',
      authError: '认证失败，无法获取下载地址',
      authAttempted: true,
    };
  }
  return {
    apkUrl: buildApkUrl('prd', buildIpaName(build), cred.user, cred.pass),
    downloadNote: null,
    authError: null,
    authAttempted: true,
  };
}

// 下载列表（详情页代理读取）：fileurl 直连优先，否则凭证检测通过 → proxy；无则 url 空串。
// selBuild 可选：指定历史构建 → 只输出该构建单条（详情页"历史构建"切换用）。
async function buildDownloads(groups, cred, authOk, selBuild) {
  var hasCred = !!(cred && cred.user && cred.pass);
  var canProxy = hasCred && !!authOk;
  var list = [];
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i];
    var build = findBuild(group, selBuild);
    if (!build) continue;
    var url = directDownloadUrl(build);
    if (!url && canProxy) url = buildApkUrl('prd', buildIpaName(build), cred.user, cred.pass);
    list.push({
      url: url,
      name: (Array.isArray(build.ipa) && build.ipa.length > 0 && build.ipa[0] && build.ipa[0].name)
          ? String(build.ipa[0].name)
          : ((build.versionname || group.version || 'app') + '.apk'),
      size: toNumOrNull(build.size),
      version: group.version || '',
      platform: group.platform || 'android',
      downloadable: !!url,
      note: url ? '' : (hasCred ? '凭证校验未通过，暂不可下载' : '需在渠道环境变量配置 PINGAN_USER/PINGAN_PASS 后下载'),
      buildNum: toNumOrNull(build.num),
      env: (cred && cred.env) || 'sit',
      updateTime: group.publishedAt,
      extra: {
        'size': {icon: 'sd_card', text: formatBytes(build.size)},
        'platform': {icon: 'phone_android', text: group.platform || 'android'},
        'build': {icon: 'build', text: '#' + String(build.num || '')},
        'env': {icon: 'cloud', text: (cred && cred.env) || ''},
        'install': {icon: 'install', text: build.installTimes ? String(build.installTimes) : ''},
      },
    });
  }
  return list;
}

async function resolveAndroidBuilds(appId, env, version) {
  var bl = await fetchBuildList(appId, version || '', env, 'resolveAndroidBuilds:直查');
  var groups = (bl && Array.isArray(bl.buildList)) ? bl.buildList.filter(isAndroidGroup) : [];
  var name = appId;
  if (bl && groups.length === 0) {
    var resolved = await resolveAppName(appId);
    if (resolved !== appId) {
      name = resolved;
      bl = await fetchBuildList(resolved, version || '', env, 'resolveAndroidBuilds:解析后重查');
      groups = (bl && Array.isArray(bl.buildList)) ? bl.buildList.filter(isAndroidGroup) : [];
    }
  }
  return { bl: bl, groups: groups, name: name };
}

function sortGroupsDesc(groups) {
  groups.sort(function (a, b) { return toTime(b && b.publishedAt) - toTime(a && a.publishedAt); });
}

async function getAppDetail(appId, version) {
  if (!appId) return { ok: true, data: null };
  try {
    var cred = await readCredentials();
    _currentEnv = cred.env; // 记录当前环境
    var r;
    try {
      r = await resolveAndroidBuilds(appId, cred.env, version);
    } catch (e) {
      host.log.error('getAppDetail resolveAndroidBuilds 异常: ' + safeStr(e));
      return { ok: false, data: null, error: 'build-list 请求失败' };
    }
    if (!r.bl) return { ok: false, data: null, error: 'build-list 请求失败' }; // ⑲ 契约
    if (r.groups.length === 0) {
      // ⑰ 契约；包名形态（resolveAppName 未能解析）→ 附提示指引回渠道列表
      var hint = (r.name === appId && String(appId).indexOf('.') >= 0)
          ? '（无法解析为渠道应用名：' + appId + '，请从渠道列表重新进入）'
          : '';
      return { ok: false, data: null, error: '未找到该应用的 Android 构建' + hint };
    }
    sortGroupsDesc(r.groups);
    var group = findPlatformGroup(r.groups) || r.groups[0];
    // S1 渐进推送：选组完成即上屏名称/版本 + 下载区骨架声明（经 host.ui.call 路由到
    // Dart 侧 ui.updateDetail handler；await+try/catch——推送失败绝不影响主链）
    try {
      var s1b0 = (Array.isArray(group.builds) && group.builds[0] && typeof group.builds[0] === 'object')
          ? group.builds[0] : {};
      await host.ui.call('updateDetail', {
        name: r.name,
        version: group.version || '',
        sections: ['downloads'],
        extra: {
          identifier: s1b0.identifier || '',
          env: cred.env,
          platform: group.platform || '',
        },
      });
    } catch (e) {}
    var screenshots = [], appInfo = null;
    try {
      var bd = await fetchBuildDetail(group._id, 'getAppDetail');
      if (bd) {
        appInfo = bd.appInfo || null;
        screenshots = (appInfo && Array.isArray(appInfo.screenshots)) ? appInfo.screenshots : [];
        // 完整构建补全（同 switchVersion/getBuildHistory）：build 接口返回真实结构
        // {build:{builds:[...]}}（每条含 ipa[0].name 真实下载文件名）；build-list 组内
        // builds 无 ipa 字段 → 不补全则首次下载名合成（"平安口袋银行.apk"）+ proxy URL
        // 拼不出（buildApkUrl 需 ipaName）→ 下载地址空（首次路径 bug 根因）
        var inner = (bd.build && Array.isArray(bd.build.builds)) ? bd.build.builds
            : (Array.isArray(bd.builds) ? bd.builds : null);
        if (inner && inner.length > 0) {
          group = Object.assign({}, group, { builds: inner });
        }
        // 缓存构建历史供 jsBuildHistory 复用（切版本/env 后无需重拉 build-list/build）
        if (inner && inner.length > 0) {
          var cacheKey = String(version || group.version || '') + '|' + String(cred.env || 'sit');
          _buildHistoryCache[cacheKey] = inner;
        }
      }
      // S2 渐进推送：build 补全后上屏截图——screenshots 必须推顶层键（UI getter 读
      // _data['screenshots']，extra.screenshots 嵌套键无 getter 消费）且 sections
      // 声明含 'screenshots'（view 仅按 sections 渲染截图区块）；空数组 UI 自隐藏。
      // await+try/catch：推送失败绝不影响主链。
      try {
        await host.ui.call('updateDetail', {
          sections: ['downloads', 'screenshots'],
          screenshots: (Array.isArray(screenshots) ? screenshots : []).map(shotAbs),
        });
      } catch (e) {}
    } catch (e) {
      host.log.error('getAppDetail fetchBuildDetail 异常（降级继续）: ' + safeStr(e));
    }
    var detail;
    try {
      detail = buildDetailFromGroup(group, cred.env, screenshots, r.name);
    } catch (e) {
      host.log.error('getAppDetail buildDetailFromGroup 异常（降级最简详情）: ' + safeStr(e));
      detail = minimalDetailFromGroup(group, cred.env, screenshots, r.name);
    }
    if (!detail) return { ok: false, data: null, error: '未找到该应用的 Android 构建' };
    detail.icon = apiAbs(r.bl.appLogo);
    _currentAppLogo = detail.icon; // 缓存图标，供 switchVersion 兜底
    if (appInfo) {
      detail.name = detail.name || appInfo.displayname || '';
      detail.des = appInfo.intro || '';
      detail.repositories = appInfo.name || detail.repositories || '';
    }
    // 包名 → 查询名缓存（resolveAppName 包名兜底；identifier ≠ 查询名才记录）
    var identifier = detail.extra.identifier || '';
    if (identifier && identifier !== r.name) _nameCache[identifier] = r.name;
    detail.appId = r.name; // 查询键保持（同 entry getAppInfo）
    detail.packageName = identifier || r.name; // 真实包名（安装检测用）
    try {
      var chk = await host.utils.call('checkVersion', { packageName: identifier || '' });
      if (chk && chk.ok && chk.data && chk.data.installed && chk.data.version) {
        detail.installedVersion = safeStr(chk.data.version);
        if (chk.data.versionCode != null) detail.installedVersionCode = chk.data.versionCode;
      }
    } catch (eCv) {}
    // 一次性凭证检测（会话缓存）：只在输出可下载列表前调一次，失败忽略不阻塞
    var authOk = groupNeedsAuth(group) ? await ensureAuthChecked(cred, 'getAppDetail') : true;
    var dl = resolveDownloadUrl(group, cred, authOk);
    detail.extra.apkUrl = dl.apkUrl;
    detail.extra.downloadNote = dl.downloadNote; // ⑭ 契约
    detail.extra.authError = dl.authError;
    // 详情页契约字段（⑭ 契约）
    // versionname 生产语义=应用显示名（如"平安口袋银行"），不可作版本号；版本一律取组号 group.version
    detail.version = group.version || '';
    _currentVersion = detail.version; // 记录当前版本
    _currentBuildNum = detail.extra.num || null; // 记录当前构建 num
    detail.description = appId; // 查询用 appId
    detail.des = detail.des || appId;
    detail.downloads = await buildDownloads([group], cred, authOk);
    // S3 渐进推送：真实下载项填充下载区（与最终 return 同一数组引用）；
    // await+try/catch：推送失败绝不影响主链。
    try {
      await host.ui.call('updateDetail', { downloads: detail.downloads });
    } catch (e) {}
    return { ok: true, data: detail };
  } catch (e) {
    host.log.error('getAppDetail 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// 版本选项：按 env 单次拉取（不再遍历 5 env 全量）。
// env 缺省 → 凭证默认 env（PINGAN_ENV，默认 sit）。
// envs 仍返回全部 5 个（chips 显示用），versions 只含请求 env 的版本；
// 单次失败 → ok:false（调用方提示，不再静默跳过）。
// versions 只统计 android 平台组（build-list 全量含 ios/harmony 组）：
// 真实接口「最新版本」可能只有 ios/harmony 构建（如 8.9.0）而 android 最新是
// 8.8.0 → 不过滤会取到无 android 构建的版本 → 历史构建空/只剩 1 条（残留根因）。
async function getVersionOptions(appId, env, currentVersion) {
  if (!appId) return { ok: true, data: null };
  try {
    var name = await resolveAppName(appId);
    var cred = await readCredentials();
    var targetEnv = env || cred.env || 'sit';
    var bl = await fetchBuildList(name, '', targetEnv, 'getVersionOptions');
    if (!bl) {
      host.log.error('versionOptions env=' + targetEnv + ' 失败');
      return { ok: false, data: null, error: 'build-list 请求失败' };
    }
    var list = (bl.buildList || []).filter(isAndroidGroup);
    var versionMap = {};
    for (var j = 0; j < list.length; j++) {
      var group = list[j], version = group.version || '';
      if (!version) continue;
      var rec = versionMap[version];
      if (!rec) { rec = { envs: [], buildCount: 0, latestTime: 0 }; versionMap[version] = rec; }
      if (rec.envs.indexOf(targetEnv) < 0) rec.envs.push(targetEnv);
      // 构建次数：真实接口 __v 为 0 基构建计数（__v=34 → 35 次构建），
      // 优先使用 __v + 1，无 __v 字段时回退 builds.length（build-list 每组仅最新 1 条）。
      var v = group.__v;
      rec.buildCount = (v !== undefined && v !== null && v !== '')
          ? (Number(v) + 1)
          : (rec.buildCount || 0) + (Array.isArray(group.builds) ? group.builds.length : 0);
      var t = toTime(group.publishedAt); if (t > rec.latestTime) rec.latestTime = t;
    }
    var versions = Object.keys(versionMap).map(function (v) { return { version: v, envs: versionMap[v].envs, buildCount: versionMap[v].buildCount }; });
    versions.sort(function (a, b) { return versionMap[b.version].latestTime - versionMap[a.version].latestTime; });
    return { ok: true, data: { envs: ALL_ENVS.slice(), versions: versions, currentEnv: targetEnv, currentVersion: currentVersion || (versions.length > 0 ? versions[0].version : '') } };
  } catch (e) {
    host.log.error('getVersionOptions 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// 切换版本/环境（build 可选：历史构建选中项 → 切换到该构建，downloads 为该构建单条）
async function switchVersion(appId, env, version, build) {
  if (!appId) return { ok: true, data: null };
  try {
    var name = await resolveAppName(appId);
    var bl = await fetchBuildList(name, version || '', env || 'sit', 'switchVersion');
    if (!bl) return { ok: false, data: null, error: 'build-list 请求失败' };
    var groups = bl.buildList.filter(isAndroidGroup);
    if (groups.length === 0) return { ok: false, data: null, error: '未找到该版本构建' };
    var group = groups[0];
    var screenshots = [], appInfo = null;
    var bd = await fetchBuildDetail(group._id, 'switchVersion');
    if (bd) {
      if (bd.appInfo) {
        appInfo = bd.appInfo;
        screenshots = bd.appInfo.screenshots || [];
      }
      // 完整历史：build 接口返回 {build:{builds}}（真实结构，同 getBuildHistory）或顶层 {builds}；
      // 补全后 findBuild 才能按 num 匹配历史构建选中项
      var inner = (bd.build && Array.isArray(bd.build.builds)) ? bd.build.builds
          : (Array.isArray(bd.builds) ? bd.builds : null);
      if (inner && inner.length > 0) {
        group = Object.assign({}, group, { builds: inner });
      }
      // 缓存构建历史供 jsBuildHistory 复用
      if (inner && inner.length > 0) {
        var cacheKey = String(version || group.version || '') + '|' + String(env || 'sit');
        _buildHistoryCache[cacheKey] = inner;
      }
    }
    var selBuild = findBuild(group, build);
    var detail = buildDetailFromGroup(group, env || 'sit', screenshots, name, selBuild);
    if (!detail) return { ok: false, data: null, error: '未找到该版本构建' };
    detail.icon = apiAbs(bl.appLogo) || _currentAppLogo;
    if (appInfo) { detail.des = appInfo.intro || ''; detail.repositories = appInfo.name || ''; }
    // 包名 → 查询名缓存（resolveAppName 包名兜底；identifier ≠ 查询名才记录）
    var identifier = detail.extra.identifier || '';
    if (identifier && identifier !== name) _nameCache[identifier] = name;
    detail.appId = name; // 查询键保持（同 getAppDetail）
    detail.packageName = identifier || name; // 真实包名（安装检测用）
    try {
      var chk = await host.utils.call('checkVersion', { packageName: identifier || '' });
      if (chk && chk.ok && chk.data && chk.data.installed && chk.data.version) {
        detail.installedVersion = safeStr(chk.data.version);
        if (chk.data.versionCode != null) detail.installedVersionCode = chk.data.versionCode;
      }
    } catch (eCv) {}
    var cred = await readCredentials();
    // 用传入的 env 覆盖凭证默认 env（用户切环境后下载 URL 应使用新 env）
    if (env) cred.env = env;
    _currentEnv = cred.env;
    _currentVersion = version || ''; // 记录当前版本
    _currentBuildNum = (selBuild && toNumOrNull(selBuild.num)) || (detail.extra && detail.extra.num) || null; // 记录当前构建 num
    // 一次性凭证检测（会话缓存，失败忽略不阻塞）
    var authOk = groupNeedsAuth(group) ? await ensureAuthChecked(cred, 'switchVersion') : true;
    var dl = resolveDownloadUrl(group, cred, authOk, selBuild);
    detail.extra.apkUrl = dl.apkUrl;
    detail.extra.downloadNote = dl.downloadNote;
    detail.extra.authError = dl.authError;
    // 下载列表：Android UA → 仅最新 android 组单条；非 Android UA（iOS/Harmony）→
    // 全部平台组各一条（build-list 不分 UA 恒返回全平台组，修复前只取 groups[0]，
    // 服务器首组常为 android/ios → 切 harmony 后下载列表仍是旧平台的根因）。
    detail.downloads = await buildDownloads([group], cred, authOk, selBuild);
    return { ok: true, data: detail };
  } catch (e) {
    host.log.error('switchVersion 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// 指定版本构建历史：build-list（带 version）定位该版本组 _id（真实平台该路径
// 组内 builds 只含最新 1 条——历史列表仅 1 项的根因）→ 再用 build 接口（_id）
// 取完整历史 build.builds[]（实测 num 降序 35→1）→ num 倒序返回。
// build 接口失败/无完整列表 → 降级用 build-list 组内 builds（至少最新 1 条，不抛）。
// 完整历史缓存（模块级，key '<version>|<env>'）：切构建历史复用，不重拉 build 接口。
var _buildHistoryCache = {};

// 原始 builds → 选择器展示形态（num/ipaName 等；Flutter 侧按 num/ipaName 渲染/回传）
function mapBuildHistory(all, version) {
  var builds = all.map(function (b) {
    return {
      num: toNumOrNull(b.num),
      publishedAt: b.publishedAt !== undefined ? b.publishedAt : null,
      size: toNumOrNull(b.size),
      changelog: b.changelog || '',
      installTimes: toNumOrNull(b.installTimes),
      builtBy: b.builtBy || '',
      fileUrl: firstDownloadRef(b),
      // 下载名契约：优先真实接口 ipa[0].name（如 PABank-8.8.0-35.apk），
      // 无 ipa 字段 → 与 buildDownloads 的 name（versionname/version + '.apk'）一致，
      // Flutter 侧按 ipaName 匹配 downloads 定位下载项
      ipaName: (Array.isArray(b.ipa) && b.ipa.length > 0 && b.ipa[0] && b.ipa[0].name)
          ? String(b.ipa[0].name)
          : ((b.versionname || version || 'app') + '.apk'),
    };
  });
  builds.sort(function (a, b) { return (b.num === null ? -1 : b.num) - (a.num === null ? -1 : a.num); });
  return builds;
}

async function getBuildHistory(appId, version, env) {
  if (!appId) return { ok: true, data: null };
  try {
    var key = String(version || '') + '|' + String(env || 'sit');
    // 缓存命中：直接映射返回（切构建历史不重拉 build-list/build 接口）
    var cached = _buildHistoryCache[key];
    if (cached) {
      return { ok: true, data: { builds: mapBuildHistory(cached, version) } };
    }
    var name = await resolveAppName(appId);
    // 不传 version 参数复用全量 build-list 缓存（key='appId||env'，与 getAppDetail/getVersionOptions 一致），
      // 从结果中过滤目标版本，避免多一次 build-list 请求。
      var bl = await fetchBuildList(name, '', env || 'sit', 'getBuildHistory');
    if (!bl) return { ok: false, data: null, error: 'build-list 请求失败' };
    // 只取 android 组：真实接口 build-list（带 version）返回 android/ios/harmony
    // 3 平台组（version 相同，ios/harmony 可能排前）→ 不过滤会取错组 _id →
    // build 接口拿不到 android 完整历史 → 降级只剩 1 条（历史列表 1 项根因）
    var groups = (bl.buildList || []).filter(isAndroidGroup), group = null;
    for (var i = 0; i < groups.length; i++) { if (String(groups[i].version || '') === String(version || '')) { group = groups[i]; break; } }
    if (!group && groups.length > 0) group = groups[0];
    if (!group) return { ok: true, data: { builds: [] } };
    // 完整历史：build 接口（_id）返回该版本组全部构建（num 降序）
    var all = null;
    try {
      var bd = await fetchBuildDetail(group._id, 'getBuildHistory');
      // 真实接口：build 接口返回 {build:{builds:[...]}, appInfo:{...}} —— 完整历史在
      // build 键内层（实测 num 降序 35→1）；旧实现读 bd.builds（undefined）→ 降级
      // build-list 组内 1 条（历史列表只剩 build 35 的根因）。兼容顶层 {builds} 形态兜底。
      var inner = null;
      if (bd) {
        if (bd.build && Array.isArray(bd.build.builds)) inner = bd.build.builds;
        else if (Array.isArray(bd.builds)) inner = bd.builds;
      }
      if (inner && inner.length > 0) all = inner;
    } catch (e) {
      host.log.error('getBuildHistory fetchBuildDetail 异常（降级用 build-list builds）: ' + safeStr(e));
    }
    if (!all) all = Array.isArray(group.builds) ? group.builds : [];
    // 防御：剔除 null/非对象条目（真实接口历史构建偶有脏数据，杜绝 TypeError）
    var valid = [];
    for (var k = 0; k < all.length; k++) {
      if (all[k] && typeof all[k] === 'object') valid.push(all[k]);
    }
    // 缓存原始 builds（含 ipa[0].name/fileurl，供 jsBuildHistory 生成下载项）
    _buildHistoryCache[key] = valid;
    return { ok: true, data: { builds: mapBuildHistory(valid, version) } };
  } catch (e) {
    host.log.error('getBuildHistory 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// ============================================================
// Hybrid 详情页（Wave C）：detailMenu 声明 Actions + host.ui 驱动
// ------------------------------------------------------------
// detailMenu → 详情页「更多」菜单；点击 action → Flutter 调 main(jscall, {appId})；
// jsswitchVersion → JS 拉版本选项 → host.ui.call('showVersionPicker')（Flutter 选择框）
// → 用户选 {env, version} → host.ui.call('refreshDetail') 刷新详情页。
// ============================================================

function getDetailMenu(appId) {
  return {
    ok: true,
    data: [
      { action: '切换版本', jscall: 'jsswitchVersion', clickIsDimiss: true },
      { action: '历史构建', jscall: 'jsBuildHistory', clickIsDimiss: true },
      { action: '切换UA', jscall: 'jsswitchUA', clickIsDimiss: true },
      // 未来可扩展：测试报告/联系开发 等（脚本零成本加）
    ],
  };
}

// 切换版本：拉当前 env 版本选项（getVersionOptions 单 env，Wave 拉取优化已支持）
// → 弹 Flutter 版本选择框 → 用户选择 → host.ui.call('refreshDetail') 刷新详情页。
// 用户取消/能力未注册 → 静默 {ok:true, data:null}（不打扰）。
async function jsSwitchVersion(appId) {
  try {
    var opts = await getVersionOptions(appId, _currentEnv || undefined, _currentVersion || undefined);
    if (!opts || !opts.ok || !opts.data) return { ok: false, data: null, error: '获取版本选项失败' };
    var d = opts.data;
    // 弹 Flutter 版本选择框（host.ui；Flutter 侧已接 onEnvChanged → versionOptions(env) 联动）
    var sel = await host.ui.call('showVersionPicker', {
      title: '切换版本',
      envs: d.envs,
      versions: d.versions,
      currentEnv: d.currentEnv,
      currentVersion: d.currentVersion,
    });
    if (!sel || !sel.ok) return { ok: true, data: null }; // 能力未注册/失败 → 静默
    if (!sel.data) return { ok: true, data: null }; // 用户取消
    // 用户选择 env+version → 刷新详情页（Flutter 侧用 switchVersion 拉单版本数据更新 detailInfo）
    await host.ui.call('refreshDetail', { appId: appId, env: sel.data.env, version: sel.data.version });
    return { ok: true, data: true };
  } catch (e) {
    host.log.error('jsSwitchVersion 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// 历史构建：拉当前 env 最新版本 builds（缓存复用）→ 弹 Flutter 构建历史选择器
// （host.ui）→ 用户选中构建 → 从缓存取该构建 → 生成单条 downloads →
// host.ui.call('updateDownloadList') 局部更新下载区（不再 refreshDetail 全量重拉：
// 切构建历史数据同源，仅下载项不同；切版本/env 才走 refreshDetail）。
// 用户取消/能力未注册/失败 → 静默 {ok:true, data:null}（不打扰）；无版本/无构建 → 明确错误。
async function jsBuildHistory(appId) {
  try {
    var cred = await readCredentials();
    var targetEnv = _currentEnv || cred.env || 'sit';
    var opts = await getVersionOptions(appId, targetEnv, _currentVersion || undefined);
    if (!opts || !opts.ok || !opts.data || !opts.data.versions || !opts.data.versions.length) {
      return { ok: false, data: null, error: '无版本数据' };
    }
    var version = _currentVersion || opts.data.versions[0].version; // 当前版本优先，无则取最新
    var bh = await getBuildHistory(appId, version, targetEnv); // 该版本 builds（缓存复用）
    host.log.info('jsBuildHistory version=' + version + ' env=' + targetEnv + ' builds count: ' + ((bh && bh.data && bh.data.builds) ? bh.data.builds.length : 0));
    if (!bh || !bh.ok || !bh.data || !bh.data.builds || !bh.data.builds.length) {
      return { ok: false, data: null, error: '无构建记录' };
    }
    // 弹 Flutter 构建历史选择器（builds 已含 num/ipaName，Flutter 侧按此渲染）
    // 传 selectedBuild 让弹框预选中当前构建
    var sel = await host.ui.call('showBuildHistory', {
      version: version,
      env: targetEnv,
      builds: bh.data.builds,
      selectedBuild: _currentBuildNum,
    });
    if (!sel || !sel.ok) return { ok: true, data: null }; // 未注册/失败静默
    if (!sel.data) return { ok: true, data: null }; // 取消
    // 选中构建 → 从缓存取该构建原始数据（含 ipa[0].name/fileurl）→ 生成单条下载项
    var key = String(version || '') + '|' + String(targetEnv || 'sit');
    var cached = _buildHistoryCache[key];
    var selNum = toNumOrNull(sel.data.num);
    var selIpa = sel.data.ipaName ? String(sel.data.ipaName) : '';
    var target = null;
    if (cached && Array.isArray(cached)) {
      for (var i = 0; i < cached.length; i++) {
        if (selNum !== null && toNumOrNull(cached[i].num) === selNum) { target = cached[i]; break; }
      }
      if (!target && selIpa) {
        for (var j = 0; j < cached.length; j++) {
          var ipa = buildIpaName(cached[j]);
          var downloadName = (cached[j].versionname || version || 'app') + '.apk';
          if (ipa === selIpa || downloadName === selIpa) { target = cached[j]; break; }
        }
      }
    }
    if (!target) {
      // 缓存无该构建（异常路径）→ 降级提示，不崩
      host.log.error('jsBuildHistory 缓存未命中选中构建 num=' + safeStr(selNum) + ' ipaName=' + selIpa);
      return { ok: false, data: null, error: '未找到所选构建，请重试' };
    }
    // 生成单条下载项（含凭证 URL；无凭证/认证失败 → url 空 + downloadable:false + note）
    var group = { builds: [target], version: version, platform: 'android' };
    var authOk = groupNeedsAuth(group) ? await ensureAuthChecked(cred, 'jsBuildHistory') : true;
    var downloads = await buildDownloads([group], cred, authOk);
    // 局部更新下载区（Flutter 侧 updateDownloadList 已注入；未注册/失败 → 静默不崩）
    try {
      await host.ui.call('updateDownloadList', { downloads: downloads });
    } catch (e) {
      host.log.error('jsBuildHistory updateDownloadList 失败（静默）: ' + safeStr(e));
    }
    return { ok: true, data: true };
  } catch (e) {
    host.log.error('jsBuildHistory 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// 切换 UA：弹选择框 → 更新 _currentUA → 刷新详情页（build-list/build 重新请求）
async function jsswitchUA(appId) {
  try {
    // 构建 UA 选项列表
    var uaOptions = [
      { label: 'Android', ua: _UAS.ANDROID },
      { label: 'iOS', ua: _UAS.IOS },
      { label: 'Harmony', ua: _UAS.HARMONY },
    ];
    // 确定当前 UA 对应的 label
    var currentLabel = 'Android';
    for (var i = 0; i < uaOptions.length; i++) {
      if (uaOptions[i].ua === _currentUA) { currentLabel = uaOptions[i].label; break; }
    }
    var sel = await host.ui.call('showUAPicker', {
      title: '切换 UA',
      options: uaOptions,
      current: _currentUA, // 传完整 UA 字符串，Flutter 侧按 label 匹配高亮
    });
    if (!sel || !sel.ok) return { ok: true, data: null }; // 取消/失败
    if (!sel.data) return { ok: true, data: null };
    var selectedUA = sel.data || '';
    if (!selectedUA) return { ok: true, data: null };
    // 查找选中 UA 的完整字符串
    var fullUA = selectedUA;
    for (var i = 0; i < uaOptions.length; i++) {
      if (uaOptions[i].label === selectedUA) { fullUA = uaOptions[i].ua; break; }
    }
    _currentUA = fullUA;
    // 清空脚本级缓存，确保新 UA 触发重新请求（build-list/build 缓存可能含旧 UA 响应）
    _buildListCache = {};
    _buildDetailCache = {};
    _buildHistoryCache = {};
    _currentBuildNum = null;   // 清空构建号，避免 jsBuildHistory 预选中旧 UA 值
    _currentAppLogo = '';      // 清空图标兜底，避免显示旧 UA 图标
    host.log.info('[UA] 切换到: ' + selectedUA + '（缓存已清空）');
    // 获取当前 env/version
    var cred = await readCredentials();
    var refreshEnv = _currentEnv || cred.env || 'sit';
    // 调 versionOptions 拿当前版本列表（不传 _currentVersion，避免脏数据传播）
    var opts = await getVersionOptions(appId, refreshEnv);
    if (!opts || !opts.ok || !opts.data) {
      host.log.error('[UA] 获取版本列表失败，跳过刷新');
      return { ok: true, data: null };
    }
    // 取 API 返回的最新版本号（保证真实有效，不受 _currentVersion 脏数据影响）
    var refreshVersion = opts.data.currentVersion || '';
    host.log.info('[UA] refreshDetail env=' + refreshEnv + ' version=' + refreshVersion +
        ' (_currentVersion=' + (_currentVersion || '空') + ')');
    // 切 UA 后先拉完整详情再刷新页面：直接传 {appId,env,version} 骨架会让 Flutter 侧
    // JsChannelDetailProxy 当成完整详情，name/icon/description/downloads 全空 → 页面空白
    var fullDetail = await switchVersion(appId, refreshEnv, refreshVersion);
    if (fullDetail && fullDetail.ok && fullDetail.data) {
      await host.ui.call('refreshDetail', fullDetail.data);
    } else {
      host.log.error('[UA] switchVersion 获取完整详情失败，skip');
      return { ok: true, data: null };
    }
    // 同步 _currentVersion 为 API 真实版本号
    _currentVersion = refreshVersion;
    return { ok: true, data: true };
  } catch (e) {
    host.log.error('jsswitchUA 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// detail 分发器：仅详情页方法（发现页/更新路径走 entry.js）
async function main(method, params) {
  switch (method) {
    case 'getAppDetail': return await getAppDetail(params && params.appId, params && params.version);
    case 'versionOptions': return await getVersionOptions(params && params.appId, params && params.env);
    case 'switchVersion': {
      // 慢操作忙碌态：入口立即开启（AppBar 更多按钮转 spinner），
      // 所有 return/异常路径经 finally 复位；catch 原样上抛，错误语义不变
      try { await host.ui.call('setBusy', { visible: true, label: '正在切换版本…' }); } catch (e) {}
      try {
        return await switchVersion(params && params.appId, params && params.env, params && params.version, params && params.build);
      } catch (e) {
        throw e;
      } finally {
        try { await host.ui.call('setBusy', { visible: false }); } catch (e) {}
      }
    }
    case 'buildHistory': return await getBuildHistory(params && params.appId, params && params.version, params && params.env);
    case 'detailMenu': return getDetailMenu(params && params.appId);
    case 'jsswitchVersion': return await jsSwitchVersion(params && params.appId);
    case 'jsBuildHistory': return await jsBuildHistory(params && params.appId);
    case 'jsswitchUA': {
      // 同 switchVersion：切 UA 全程（含选框后刷新）忙碌态兜底
      try { await host.ui.call('setBusy', { visible: true, label: '正在切换 UA…' }); } catch (e) {}
      try {
        return await jsswitchUA(params && params.appId);
      } catch (e) {
        throw e;
      } finally {
        try { await host.ui.call('setBusy', { visible: false }); } catch (e) {}
      }
    }
    case 'download': {
      var url = params && params.url;
      if (!url) return { ok: false, error: '下载地址为空' };
      return await host.ui.call('download', {
        appId: params.appId,
        url: params.url,
        name: params.name,
        version: params.version,
        size: params.size,
      });
    }
    default: return null; // ⑮ 契约：未实现 method → null（不抛）
  }
}
