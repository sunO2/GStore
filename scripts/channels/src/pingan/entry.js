// ============================================================
// 平安 Iris Store 渠道脚本 · entry.js（发现页）
// ------------------------------------------------------------
// 用途：平安企业应用分发平台（Iris Store）渠道脚本，用户导入应用使用。
// 应用二进制不含此脚本；本文件由用户通过「设置 → 脚本渠道」导入 zip
// 渠道包（channels/pingan.zip），不进入版本库（已被 .gitignore 忽略）。
//
// 本文件为 zip 渠道包的发现页部分（entry.js，必须）：
//   main(method, params) → { ok, data } | null
//   method: getAllApps / searchApps / getAppInfo / getAppDetail
//         | checkAppUpdate / checkUpdate / doUpdate
// 详情页部分在 detail.js（页面级 JsDetailChannel 独立 runtime 消费），
// 两者各自独立 runtime，无法共享工具函数——各文件自带所需工具。
//
// 接口（已实测）：
//   GET /istore/istore-api/sunflower/i/app-list  应用列表（分页，公开）
//   GET /istore/istore-api/sunflower/i/build-list 版本构建列表（按 env）
//   GET /istore/istore-api/sunflower/i/build      详情（截图 + 历史构建）
//   GET /mcd-api/mcd-api/login/check?um&value     凭证校验 → {url}
//   GET /mcd-api/mcd-api/proxy/<env>/<ipa>?um&value APK 下载
// env: sit(开发) uat(验证) prd(生产) rge(内测) tmp(临时)
//
// 环境变量（应用内「脚本渠道 → 环境变量」配置）：
//   PINGAN_USER / PINGAN_PASS  下载凭证
//   PINGAN_ENV                 默认环境（默认 sit）
//
// ⚠️ 契约对齐说明（与 test/pingan_script_test.dart 的 mock 结构一致）：
//   - build 组无 ipa 字段 → 下载地址取 builds[0].fileurl[0]（真实接口为
//     ipa[0].name 文件名 + proxy 转发，两者均兼容，见 firstDownloadRef）
//   - detail.extra 为对象（Map），非 JSON 字符串
//   - app-list 分页契约：pageNum 递增拉取，某页不足 pageSize(20) 即结尾
//   - 认证失败降级（不抛）：主路径 login/check 失败后再试文档路径
//   - 凭证检测（login/check）为会话级懒检测：同 user/pass 在会话内只调一次
//     （成功缓存，见 ensureAuthChecked），失败忽略不阻塞（不缓存，下次可重试）
// ============================================================

const BASE_HOST = 'https://test-b-fat.pingan.com.cn';
const ISTORE_BASE = BASE_HOST + '/istore';
const API_BASE = ISTORE_BASE + '/istore-api';
const MCD_BASE = BASE_HOST + '/mcd-api/mcd-api';
const MCD_LOGIN_BASE = BASE_HOST + '/mcd-api/mcd-api';

// User-Agent：模拟 Android Chrome，避免被接口反爬
const DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

// UA 预设（与 detail.js 同步）
const _UAS = {
  ANDROID: 'Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Mobile Safari/537.36',
  IOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
  HARMONY: 'Mozilla/5.0 (Phone; HarmonyOS 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 ArkWeb/4.1.6.1 Mobile HuaweiBrowser/5.0.3.351',
};
var _currentUA = DEFAULT_UA;

const CHANNEL_META = {
  name: '平安测试商店',
  description: 'Iris Store 企业应用分发（需导入环境变量下载）',
};

function genUuid() { return (Math.random() + '_' + new Date().getTime()); }
function safeStr(v) { try { return String(v); } catch (e) { return ''; } }
function toNumOrNull(v) { var n = Number(v); return isNaN(n) ? null : n; }
function toTime(v) { var t = typeof v === 'number' ? v : Date.parse(v); return isNaN(t) ? 0 : t; }
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
    // 被 Dio 解析进 queryParameters，故必须走 params；且保留原始类型
    // （pageNum 为数字，mock 按 num 强转）。
    var qp = {};
    if (params) {
      for (var k in params) {
        if (params[k] !== undefined && params[k] !== null && params[k] !== '') {
          qp[k] = params[k];
        }
      }
    }
    var r = await host.network.get(url, { params: qp, headers: { 'User-Agent': _currentUA } });
    var d = r && r.data !== undefined ? r.data : r;
    if (r && r.ok === false) return { ok: false, data: null, error: safeStr(r.error) };
    return { ok: true, data: d, status: r && r.status };
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
  return { user: user, pass: pass, env: env };
}

function buildApkUrl(env, ipaName, user, pass) {
  if (!user || !pass || !ipaName) return '';
  return MCD_BASE + '/proxy/' + encodeURIComponent(env) + '/' + encodeURIComponent(ipaName) +
      '?um=' + encodeURIComponent(user) + '&value=' + encodeURIComponent(pass);
}

// ---- 会话级凭证检测（login/check 懒检测 + 缓存）----
// 同 user/pass 在会话内只调一次 login/check（成功缓存，见 ensureAuthChecked）；
// 失败 60s 冷却（_authFail）：冷却期内直接返回 false 不再重发。
// 修复前失败完全不缓存 → 每次 getAppInfo/getAppDetail 都重发 login/check
// （主+文档路径 2 次），认证端点异常时形成请求风暴（真机复现根因之一）。
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

// ---- 包名 → 应用名解析缓存（同 entry runtime 会话内有效）----
// getAppInfo/getAppDetail 成功时记录 `包名(identifier) → 查询名(name)`；
// 详情/更新路径收到包名 appId 时 resolveAppName 直接命中，避免二次网络/查库。
var _nameCache = {};

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
// 测试 mock 的 builds[] 无 ipa 字段：下载地址 = fileurl[0]。
// 真实接口历史字段为 ipa[0].name（下载文件名，经 proxy 转发），兼容保留。
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

/// 直连下载地址：仅 fileurl[0] 可直连（绝对化）；ipa[0].name 是 proxy 文件名，
/// 不是直连 URL（真实接口经 /mcd-api/mcd-api/proxy 转发），故不在此返回。
function directDownloadUrl(build) {
  var f = (build && Array.isArray(build.fileurl) && build.fileurl.length > 0) ? String(build.fileurl[0]) : '';
  return f ? abs(f) : '';
}

async function fetchAppList() {
  var all = [];
  var firstFailed = false;
  var firstError = '';
  for (var p = 1; p <= 5; p++) {
    var res = await safeGet('/sunflower/i/app-list', { type: '', pageSize: 20, pageNum: p, uuid: genUuid() });
    if (!res || !res.ok) {
      // 首请求失败 → 整体失败（③⑬ 契约：getAllApps/doUpdate 返回 ok:false）
      if (p === 1) { firstFailed = true; firstError = (res && res.error) || 'app-list 请求失败'; }
      break;
    }
    var list = res.data && Array.isArray(res.data.appList) ? res.data.appList : [];
    all = all.concat(list);
    if (list.length < 20) break; // 不足一页 → 已到末尾
  }
  if (firstFailed) return { ok: false, data: null, error: firstError };
  return { ok: true, data: all };
}

// ---- 请求级缓存（同 runtime 会话内有效，TTL 防陈旧）----
// build-list 按 'name|version|env' 缓存：getAppInfo/getAppDetail/checkAppUpdate
// 重复拉同一查询 → 缓存命中零请求（修复前每次进入详情/更新检测都重复拉
// build-list，请求风暴根因之一）；TTL 5 分钟：会话内复用，超时重拉防数据陈旧。
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

function mapListApp(a) {
  return {
    appId: a.name || a._id || '',
    name: a.displayname || a.name || '',
    des: a.intro || '',
    icon: apiAbs(a.imgSrc),
    user: 'js_pingan',
    repositories: a._id || '', // ② 契约：repositories = _id
    description: a.intro || '', // 落库兼容字段（②⑫ 契约）
    extra: { // 契约：extra 为对象（Map），非 JSON 字符串
      _id: a._id || '',
      name: a.name || '',
      screenshots: (Array.isArray(a.screenshots) ? a.screenshots : []).map(shotAbs),
    },
  };
}

function isAndroidGroup(g) {
  // 非 Android UA 时不过滤平台（iOS/Harmony UA 需显示全部平台供二维码下载）
  if (_currentUA !== _UAS.ANDROID && _currentUA !== DEFAULT_UA) return !!g;
  return !!g && (!g.platform || g.platform === 'android');
}

function buildDetailFromGroup(group, env, screenshots, queryAppId) {
  if (!group || typeof group !== 'object') return null;
  var builds = Array.isArray(group.builds) ? group.builds : [];
  // 防御：剔除 null/非对象条目（真实接口历史构建偶有脏数据，杜绝 TypeError）
  var valid = [];
  for (var i = 0; i < builds.length; i++) {
    if (builds[i] && typeof builds[i] === 'object') valid.push(builds[i]);
  }
  builds = valid;
  if (builds.length === 0) return null;
  var build = builds[0];
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
    identifier: identifier, // 真实包名（聚合/详情解析用；appId 保持渠道查询键）
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
  };
}

// 该组是否需凭证检测：无 fileurl 直连 → 走 proxy → 需确认凭证有效
function groupNeedsAuth(group) {
  var b = (group && Array.isArray(group.builds) && group.builds.length > 0) ? group.builds[0] : null;
  return !(b && Array.isArray(b.fileurl) && b.fileurl.length > 0);
}

// ---- 下载地址解析（⑤⑥⑦⑧ 契约）----
// 1. fileurl 非空 → 直接绝对化（不认证）；2. 无 fileurl → 凭证检测通过后
//    用 proxy 拼接；凭证缺失/检测失败 → 降级 note（authError）。
//    本函数不再调 login/check（会话级一次性检测见 ensureAuthChecked）。不抛。
function resolveDownloadUrl(group, cred, authOk) {
  var build = (group && Array.isArray(group.builds) && group.builds.length > 0) ? group.builds[0] : null;
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

// 下载列表（详情页代理读取）：fileurl 直连优先，否则凭证检测通过 → proxy；无则 url 空串
async function buildDownloads(groups, cred, authOk) {
  var hasCred = !!(cred && cred.user && cred.pass);
  var canProxy = hasCred && !!authOk;
  var list = [];
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i];
    var builds = (group && Array.isArray(group.builds)) ? group.builds : [];
    if (builds.length === 0) continue;
    var build = (builds.length > 0 && builds[0]) ? builds[0] : {};
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

async function getAllApps() {
  var res = await fetchAppList();
  if (!res.ok) return { ok: false, data: null, error: res.error }; // ③ 契约
  return { ok: true, data: res.data.map(mapListApp) };
}

async function searchApps(keyword) {
  var kw = String(keyword || '').toLowerCase();
  if (!kw) return { ok: true, data: [] }; // 空 keyword → 空数组，不发网络请求（④ 契约）
  var res = await fetchAppList();
  if (!res.ok) return { ok: false, data: null, error: res.error };
  var matched = res.data.filter(function (a) {
    return (a.name || '').toLowerCase().indexOf(kw) >= 0 ||
        (a.displayname || '').toLowerCase().indexOf(kw) >= 0 ||
        (a.intro || '').toLowerCase().indexOf(kw) >= 0;
  });
  return { ok: true, data: matched.slice(0, 50).map(mapListApp) }; // 上限 50
}

async function getAppInfo(appId, version) {
  if (!appId) return { ok: true, data: null }; // ⑪ 契约：空 appId 不发请求
  try {
    var cred = await readCredentials();
    var r = await resolveAndroidBuilds(appId, cred.env, version);
    if (!r.bl) return { ok: false, data: null, error: 'build-list 请求失败' }; // ⑩ 契约
    if (r.groups.length === 0) {
      // ⑨ 契约；包名形态（resolveAppName 未能解析）→ 附提示指引回渠道列表
      var hint = (r.name === appId && String(appId).indexOf('.') >= 0)
          ? '（无法解析为渠道应用名：' + appId + '，请从渠道列表重新进入）'
          : '';
      return { ok: false, data: null, error: '未找到该应用的 Android 构建' + hint };
    }
    sortGroupsDesc(r.groups);
    var detail = buildDetailFromGroup(r.groups[0], cred.env, undefined, r.name);
    if (!detail) return { ok: false, data: null, error: '未找到该应用的 Android 构建' };
    detail.icon = apiAbs(r.bl.appLogo);
    detail.des = appId; // ⑤ 契约：des = 查询用 appId
    // 包名 → 查询名缓存（resolveAppName 包名兜底；identifier ≠ 查询名才记录）
    var identifier = detail.extra.identifier || '';
    if (identifier && identifier !== r.name) _nameCache[identifier] = r.name;
    detail.appId = r.name; // 查询键保持（聚合 canonicalAppId 落库/详情请求 appId 均按此）
    detail.packageName = identifier || r.name; // 真实包名（安装检测/更新比对用）
    // 一次性凭证检测（会话缓存，失败忽略不阻塞）；fileurl 直连无需检测
    var authOk = groupNeedsAuth(r.groups[0]) ? await ensureAuthChecked(cred, 'getAppInfo') : true;
    var dl = resolveDownloadUrl(r.groups[0], cred, authOk);
    detail.extra.apkUrl = dl.apkUrl;
    detail.extra.downloadNote = dl.downloadNote;
    detail.extra.authError = dl.authError;
    return { ok: true, data: detail };
  } catch (e) {
    host.log.error('getAppInfo 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// 发现页/Agent 下载路径消费（entry runtime 的 main('getAppDetail')）；
// 详情页优先走 detail.js（页面级 JsDetailChannel），本实现保留保证 entry 侧可用。
async function getAppDetail(appId, version) {
  if (!appId) return { ok: true, data: null };
  try {
    var cred = await readCredentials();
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
    var group = r.groups[0];
    var screenshots = [], appInfo = null;
    try {
      var bd = await fetchBuildDetail(group._id, 'getAppDetail');
      if (bd) {
        appInfo = bd.appInfo || null;
        screenshots = (appInfo && Array.isArray(appInfo.screenshots)) ? appInfo.screenshots : [];
        // 完整构建补全（对齐 detail.js switchVersion）：build 接口返回真实结构
        // {build:{builds:[...]}}（每条含 ipa[0].name 真实下载文件名）；build-list 组内
        // builds 无 ipa 字段 → 不补全则首次下载名合成 + proxy URL 拼不出（首次路径 bug）
        var inner = (bd.build && Array.isArray(bd.build.builds)) ? bd.build.builds
            : (Array.isArray(bd.builds) ? bd.builds : null);
        if (inner && inner.length > 0) {
          group = Object.assign({}, group, { builds: inner });
        }
      }
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
    if (appInfo) {
      detail.name = detail.name || appInfo.displayname || '';
      detail.des = appInfo.intro || '';
      detail.repositories = appInfo.name || detail.repositories || '';
    }
    // 包名 → 查询名缓存（resolveAppName 包名兜底；identifier ≠ 查询名才记录）
    var identifier = detail.extra.identifier || '';
    if (identifier && identifier !== r.name) _nameCache[identifier] = r.name;
    detail.appId = r.name; // 查询键保持（同 getAppInfo）
    detail.packageName = identifier || r.name; // 真实包名（安装检测用）
    // 一次性凭证检测（会话缓存）：只在输出可下载列表前调一次，失败忽略不阻塞
    var authOk = groupNeedsAuth(group) ? await ensureAuthChecked(cred, 'getAppDetail') : true;
    var dl = resolveDownloadUrl(group, cred, authOk);
    detail.extra.apkUrl = dl.apkUrl;
    detail.extra.downloadNote = dl.downloadNote; // ⑭ 契约
    detail.extra.authError = dl.authError;
    // 详情页契约字段（⑭ 契约）
    detail.version = group.version || '';
    detail.description = appId; // 查询用 appId
    detail.des = detail.des || appId;
    // 只显示最新版本组（sortGroupsDesc 后 groups[0]）最新构建单条：不再遍历所有版本
    detail.downloads = await buildDownloads([group], cred, authOk);
    return { ok: true, data: detail };
  } catch (e) {
    host.log.error('getAppDetail 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// ⑯ 契约：返回最新 android 构建的版本信息（appId/packageName/version）
async function checkAppUpdate(appId) {
  if (!appId) return { ok: true, data: null };
  try {
    var cred = await readCredentials();
    var r = await resolveAndroidBuilds(appId, cred.env);
    if (!r.bl) return { ok: false, data: null, error: 'build-list 请求失败' };
    if (r.groups.length === 0) return { ok: false, data: null, error: '未找到该应用的 Android 构建' };
    sortGroupsDesc(r.groups);
    var group = r.groups[0];
    var build = (Array.isArray(group.builds) && group.builds.length > 0) ? group.builds[0] : {};
    var identifier = build.identifier || group.version || '';
    return {
      ok: true,
      data: { appId: identifier, packageName: identifier, version: group.version || '' },
    };
  } catch (e) {
    host.log.error('checkAppUpdate 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

async function checkUpdate() {
  try {
    var res = await fetchAppList();
    if (!res.ok) return { ok: false, data: null, error: res.error };
    var stored = await host.database.getAppsByChannel();
    var storedList = (stored && stored.data !== undefined && Array.isArray(stored.data)) ? stored.data : (Array.isArray(stored) ? stored : []);
    return { ok: true, data: res.data.length !== storedList.length };
  } catch (e) { return { ok: false, data: null, error: safeStr(e) }; }
}

async function doUpdate() {
  var res = await fetchAppList();
  if (!res.ok) return { ok: false, data: false, error: res.error }; // ⑬ 契约：失败 ok:false + data:false，不落库
  var list = res.data.map(mapListApp);
  if (list.length > 0) await host.database.insertApps(list);
  return { ok: true, data: true };
}

// entry 分发器：仅发现页/更新路径方法（详情页走 detail.js）
async function main(method, params) {
  switch (method) {
    case 'getAllApps': return await getAllApps();
    case 'searchApps': return await searchApps(params && params.keyword);
    case 'getAppInfo': return await getAppInfo(params && params.appId, params && params.version);
    case 'getAppDetail': return await getAppDetail(params && params.appId, params && params.version);
    case 'checkAppUpdate': return await checkAppUpdate(params && params.appId); // ⑯ 契约
    case 'checkUpdate': return await checkUpdate();
    case 'doUpdate': return await doUpdate();
    default: return null; // ⑮ 契约：未实现 method → null（不抛）
  }
}
