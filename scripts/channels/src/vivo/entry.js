// ============================================================
// vivo 应用市场渠道脚本 · entry.js（发现页）
// ------------------------------------------------------------
// 用途：vivo 应用市场（h5-api.appstore.vivo.com.cn）渠道脚本，用户导入应用使用。
// 应用二进制不含此脚本；本文件由用户通过「设置 → 脚本渠道」导入 zip
// 渠道包（channels/vivo.zip），不进入版本库（已被 .gitignore 忽略）。
//
// 本文件为 zip 渠道包的发现页部分（entry.js，必须）：
//   main(method, params) → { ok, data } | null
//   method: getAllApps / searchApps / getAppInfo / getAppDetail
//         | checkAppUpdate / checkUpdate / doUpdate
// 详情页部分在 detail.js（页面级 JsDetailChannel 独立 runtime 消费），
// 两者各自独立 runtime，无法共享工具函数——各文件自带所需工具。
//
// 接口（还原自 lib/core/channel/impl/VivoChannel.dart，Dart 内置版语义为权威）：
//   POST https://h5-api.appstore.vivo.com.cn/h5appstore/search/result-list  搜索
//        queryParameters：imei/av/app_version/pictype/h5_websource/target/cfrom
//        + key / page_index=1 / apps_per_page=20（参数全在 query，无 body）
//   GET  https://h5-api.appstore.vivo.com.cn/detailInfo                    详情
//        queryParameters：默认参数 + appId(<vivoId>) / frompage=messageh5
//
// vivo 专属说明：
//   - vivoId 概念：搜索响应中每条结果的 id 即 vivoId；repositories 字段存放
//     vivoId（Dart _parseSearchResults 语义）；详情请求的参数 appId 实为 vivoId
//     （getAppDetail 按 库 extra.vivoId → 库 repositories → 查询 appId 依次解析）。
//   - 无全量应用接口：getAllApps 返回本渠道库（host.database）已保存的搜索结果，
//     对齐 Dart getAllApps → getChannelApps 行为。
//   - checkUpdate/doUpdate 恒 false/true（对齐 Dart，vivo 无远程全量可对比/可更新）。
//
// ⚠️ 与 Dart 内置 VivoChannel 的差异标注：
//   ① getAppInfo 命中渠道库时返回库数据：Flutter 侧 JsChannel 标记 fromCache:false
//      （Dart 内置为 fromCache:true）——仅元信息差异，数据一致。
//   ② 搜索接口 API 错误码（code != 0）→ 返回成功空数组（对齐 Dart _parseSearchResults）。
//   ③ 详情路径 AppInfo.repositories = 包名（对齐 Dart _parseAppDetail）；
//      搜索路径 AppInfo.repositories = vivoId（对齐 Dart _parseSearchResults）——
//      两条路径映射各自与 Dart 对应路径一致。
//   ④ 图标/截图 URL 原样透传，不做绝对化补全（对齐 Dart）。
// ============================================================

const BASE_URL = 'https://h5-api.appstore.vivo.com.cn';
const SEARCH_URL = BASE_URL + '/h5appstore/search/result-list';
const DETAIL_URL = BASE_URL + '/detailInfo';

// User-Agent：模拟 Android Chrome（统一 UA，与其他脚本渠道一致），避免被接口反爬
const DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

const CHANNEL_META = {
  name: 'vivo 应用市场',
  description: 'vivo 应用市场脚本渠道',
};

// 默认请求参数（还原自 VivoChannel._defaultParams）
const DEFAULT_PARAMS = {
  imei: '1234567890',
  av: '18',
  app_version: '2100',
  pictype: 'webp',
  h5_websource: 'h5appstore',
  target: 'local',
  cfrom: '2',
};

function safeStr(v) {
  try {
    if (v === undefined || v === null) return '';
    return String(v);
  } catch (e) { return ''; }
}

function toNumOrNull(v) {
  if (v === undefined || v === null || v === '') return null;
  var n = Number(v);
  return isNaN(n) ? null : n;
}

/// 默认参数 + 额外参数（额外空值剔除，保留类型：page_index/apps_per_page 为数字）
function defaultParamsWith(extra) {
  var out = {};
  for (var k in DEFAULT_PARAMS) { out[k] = DEFAULT_PARAMS[k]; }
  if (extra) {
    for (var k2 in extra) {
      if (extra[k2] !== undefined && extra[k2] !== null && extra[k2] !== '') {
        out[k2] = extra[k2];
      }
    }
  }
  return out;
}

/// extra 字段：host 层已解码为对象；防御字符串（JSON）形式
function parseExtra(ex) {
  if (!ex) return null;
  if (typeof ex === 'string') {
    try { return JSON.parse(ex); } catch (e) { return null; }
  }
  return (typeof ex === 'object') ? ex : null;
}

/// 统一 GET：host.network → { ok, status, data }；任何失败 → { ok:false, data:null, error }，不抛
async function safeGet(path, params) {
  try {
    var url = (path.indexOf('http') === 0) ? path : BASE_URL + path;
    var qp = {};
    if (params) {
      for (var k in params) {
        if (params[k] !== undefined && params[k] !== null && params[k] !== '') {
          qp[k] = params[k];
        }
      }
    }
    var r = await host.network.get(url, { params: qp, headers: { 'User-Agent': DEFAULT_UA } });
    if (!r || r.ok === false) {
      return { ok: false, data: null, error: safeStr(r && r.error) || ('HTTP ' + (r && r.status ? r.status : '请求失败')) };
    }
    // 空 body 经桥接可能为 undefined → 统一归一为 null（勿回退为 r 整体）
    var d = (r.data !== undefined && r.data !== null) ? r.data : null;
    return { ok: true, data: d, status: r.status };
  } catch (e) {
    host.log.error('safeGet(' + path + ') 异常: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

/// 统一 POST（搜索用）：同 safeGet 语义；参数经 opts.params（→ Dio queryParameters）
async function safePost(path, params, headers) {
  try {
    var url = (path.indexOf('http') === 0) ? path : BASE_URL + path;
    var qp = {};
    if (params) {
      for (var k in params) {
        if (params[k] !== undefined && params[k] !== null && params[k] !== '') {
          qp[k] = params[k];
        }
      }
    }
    var hd = { 'User-Agent': DEFAULT_UA };
    if (headers) {
      for (var k2 in headers) { hd[k2] = headers[k2]; }
    }
    var r = await host.network.post(url, { params: qp, headers: hd });
    if (!r || r.ok === false) {
      return { ok: false, data: null, error: safeStr(r && r.error) || ('HTTP ' + (r && r.status ? r.status : '请求失败')) };
    }
    // 空 body 经桥接可能为 undefined → 统一归一为 null（勿回退为 r 整体）
    var d = (r.data !== undefined && r.data !== null) ? r.data : null;
    return { ok: true, data: d, status: r.status };
  } catch (e) {
    host.log.error('safePost(' + path + ') 异常: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// ==================== 渠道库操作 ====================

/// 查本渠道库（host 层已强制当前渠道；record.extra 为解码后的对象）
/// 注意：host 前缀 wrapper 为 getApp(appId)（字符串参数），勿传对象
async function getSavedApp(appId) {
  try {
    var res = await host.database.getApp(appId);
    if (!res || res.ok === false || !res.data) return null;
    return res.data;
  } catch (e) {
    host.log.error('getSavedApp(' + appId + ') 查库异常: ' + safeStr(e));
    return null;
  }
}

/// 渠道库记录 → AppInfo JSON（对齐 AppSummary.fromChannelAddedApp：
/// packageName 从 extra.packageName 提升；category 逗号串拆数组）
function dbAppToAppInfo(rec) {
  if (!rec) return null;
  var ex = parseExtra(rec.extra);
  var packageName = (ex && ex.packageName) ? safeStr(ex.packageName) : null;
  var category = null;
  if (rec.category) {
    category = safeStr(rec.category).split(',');
    var list = [];
    for (var i = 0; i < category.length; i++) {
      if (category[i].trim() !== '') list.push(category[i].trim());
    }
    category = list.length > 0 ? list : null;
  }
  return {
    appId: safeStr(rec.appId),
    packageName: packageName,
    name: safeStr(rec.name),
    user: safeStr(rec.user),
    repositories: safeStr(rec.repositories),
    icon: safeStr(rec.icon),
    des: safeStr(rec.description),
    category: category,
    extra: ex,
  };
}

// ==================== 搜索响应解析（对齐 Dart _parseSearchResults）====================

/// 搜索响应格式: {code: 0, data: {appSearchResponse: {value: [...]}}}
function mapSearchApp(item) {
  var id = safeStr(item.id);
  var title = safeStr(item.title_zh) || safeStr(item.title);
  var icon = safeStr(item.icon_url) || safeStr(item.icon);
  var packageName = safeStr(item.package_name) || safeStr(item.packageName);
  var developer = safeStr(item.developer) || safeStr(item.developerName);
  var remark = safeStr(item.remark) || safeStr(item.introduction) || safeStr(item.shortIntroduction);
  var appId = packageName !== '' ? packageName : id; // appId 优先包名，否则 vivoId
  return {
    appId: appId,
    packageName: packageName !== '' ? packageName : null,
    name: title,
    user: developer,
    repositories: id, // repositories 存放 vivoId（对齐 Dart 搜索路径）
    icon: icon,
    des: remark,
    category: null, // vivo 搜索结果无分类
    extra: {
      vivoId: id,
      packageName: packageName,
      title: title,
      developer: developer,
      iconUrl: icon,
      remark: remark,
    },
  };
}

function parseSearchResults(data) {
  if (!data) return [];
  // API 错误码 → 成功但空数组（对齐 Dart：记录日志后返回 []）
  if (typeof data === 'object' && data.code !== undefined && data.code !== 0) {
    host.log.error('vivo 搜索接口返回错误码: ' + safeStr(data.code));
    return [];
  }
  var results = [];
  if (Array.isArray(data)) {
    results = data;
  } else if (data.data !== undefined && data.data !== null) {
    var dataObj = data.data;
    if (typeof dataObj === 'object' && dataObj.appSearchResponse !== undefined && dataObj.appSearchResponse !== null) {
      var sr = dataObj.appSearchResponse;
      if (Array.isArray(sr.value)) results = sr.value;
    } else if (Array.isArray(dataObj)) {
      results = dataObj;
    }
  } else {
    return [];
  }
  var apps = [];
  for (var i = 0; i < results.length; i++) {
    var item = results[i];
    if (!item || typeof item !== 'object') continue;
    apps.push(mapSearchApp(item));
  }
  return apps;
}

// ==================== 详情响应解析（对齐 Dart getAppDetail）====================

/// 详情解析 → 详情 Map（rawData 结构对齐 Dart 内置版：详情页代理按同键读取）
function buildDetailData(detail, appId, rec) {
  var savedApp = rec ? dbAppToAppInfo(rec) : null;

  var version = safeStr(detail.version_name) || safeStr(detail.versionName) || safeStr(detail.version);
  var versionCode = safeStr(detail.version_code) || safeStr(detail.versionCode);
  // vivo 接口 size/apkSize 单位为 KB → 统一归一化为字节（DownloadInfo.size 契约）
  var size = toNumOrNull(detail.size !== undefined && detail.size !== null ? detail.size : detail.apkSize);
  if (size !== null) size = size * 1024;
  var developer = safeStr(detail.developerName) || safeStr(detail.developer) || (savedApp ? safeStr(savedApp.user) : '');
  var packageName = safeStr(detail.package_name) || safeStr(detail.packageName) || (savedApp ? safeStr(savedApp.appId) : '') || appId;

  // 统计
  var downloads = toNumOrNull(detail.download_count !== undefined && detail.download_count !== null ? detail.download_count : detail.downloadCount);
  var rating = toNumOrNull(detail.score);
  var ratingCount = toNumOrNull(detail.raters_count !== undefined && detail.raters_count !== null ? detail.raters_count : detail.scoreCount);
  var favorites = toNumOrNull(detail.favorite_count !== undefined && detail.favorite_count !== null ? detail.favorite_count : detail.favoriteCount);

  // 截图（string[]）
  var screenshots = [];
  var shotsData = detail.screenshotList !== undefined ? detail.screenshotList : detail.screenShots;
  if (Array.isArray(shotsData)) {
    for (var i = 0; i < shotsData.length; i++) {
      var u = shotsData[i];
      if (u === undefined || u === null) continue;
      var url = (typeof u === 'object') ? safeStr(u.url) : safeStr(u);
      if (url !== '') screenshots.push(url);
    }
  }

  // 权限（{permissionName|name} 或 string）
  var permissions = [];
  var permData = detail.permissionList !== undefined ? detail.permissionList : detail.permissions;
  if (Array.isArray(permData)) {
    for (var j = 0; j < permData.length; j++) {
      var p = permData[j];
      var perm = '';
      if (p && typeof p === 'object') { perm = safeStr(p.permissionName) || safeStr(p.name); }
      else if (p !== undefined && p !== null) { perm = safeStr(p); }
      if (perm !== '') permissions.push(perm);
    }
  }

  // 介绍
  var description = safeStr(detail.introduction) || safeStr(detail.shortIntroduction) || (savedApp ? safeStr(savedApp.des) : '');

  // 下载地址：download_url 完整链接；apk 相对路径兜底拼 BASE_URL（对齐 Dart）
  var downloadUrl = safeStr(detail.download_url) || safeStr(detail.downloadUrl);
  if (downloadUrl === '' && detail.apk !== undefined && detail.apk !== null) {
    var apkPath = safeStr(detail.apk);
    downloadUrl = apkPath.indexOf('http') === 0
        ? apkPath
        : BASE_URL + (apkPath.charAt(0) === '/' ? apkPath : '/' + apkPath);
  }

  // 下载列表（文件名: package_name_version_code.apk，对齐 Dart）
  var downloadsList = [];
  if (downloadUrl !== '') {
    var fileName = versionCode !== ''
        ? packageName + '_' + versionCode + '.apk'
        : packageName + '_' + (version !== '' ? version : 'latest') + '.apk';
    downloadsList.push({
      url: downloadUrl,
      name: fileName,
      size: size,
      version: version,
      platform: 'android',
    });
  }

  // sections（对齐 Dart _buildSections：截图统一内嵌，不单独成区块）
  var sections = ['version'];
  if ((downloads !== null || favorites !== null) || rating !== null) sections.push('statistics');
  if (rating !== null) sections.push('rating');
  sections.push('downloads');
  if (description !== '') sections.push('readme');
  if (permissions.length > 0) sections.push('permissions');

  return {
    appId: savedApp ? safeStr(savedApp.appId) : appId,
    name: savedApp ? safeStr(savedApp.name) : '',
    icon: savedApp ? safeStr(savedApp.icon) : '',
    description: savedApp ? safeStr(savedApp.des) : '',
    version: version,
    developer: developer,
    packageName: packageName,
    sections: sections,
    downloads: downloadsList,
    downloadCount: downloads,
    screenshots: screenshots,
    readme: description,
    permissions: permissions,
    rating: rating,
    ratingCount: ratingCount,
    favorites: favorites,
    detailData: detail, // 原始数据（对齐 Dart rawData.detailData）
  };
}

/// 详情核心：解析 vivoId → detailInfo 请求 → 解析 → 详情 Map（getAppDetail/checkAppUpdate 共用）
async function fetchDetailData(appId) {
  // ① 查库解析 vivoId（对齐 Dart getAppDetail：extra.vivoId → repositories → appId）
  var rec = await getSavedApp(appId);
  var vivoId = '';
  if (rec) {
    var ex = parseExtra(rec.extra);
    if (ex && ex.vivoId) vivoId = safeStr(ex.vivoId);
    if (vivoId === '' && rec.repositories) vivoId = safeStr(rec.repositories);
  }
  if (vivoId === '') vivoId = appId;

  // ② detailInfo（参数 appId 实为 vivoId）
  var res = await safeGet(DETAIL_URL, defaultParamsWith({ appId: vivoId, frompage: 'messageh5' }));
  if (!res || !res.ok) {
    return { ok: false, data: null, error: (res && res.error) || 'detailInfo 请求失败' };
  }
  var raw = res.data;
  if (raw === undefined || raw === null || (typeof raw === 'string' && raw.trim() === '')) {
    return { ok: false, data: null, error: 'vivo 详情接口返回空数据（请确认 vivoId 正确: ' + vivoId + '）' };
  }
  if (typeof raw === 'string') {
    try { raw = JSON.parse(raw); } catch (e) { return { ok: false, data: null, error: '详情响应 JSON 解析失败' }; }
  }
  if (!raw || typeof raw !== 'object') {
    return { ok: false, data: null, error: 'Invalid response data' };
  }
  return { ok: true, data: buildDetailData(raw, appId, rec) };
}

// ==================== main 分发器 ====================

/// 全量应用：vivo 无全量接口 → 返回本渠道库已保存的搜索结果（对齐 Dart getAllApps）
async function getAllApps() {
  try {
    var res = await host.database.getAppsByChannel();
    if (!res || res.ok === false) {
      return { ok: false, data: null, error: (res && safeStr(res.error)) || '查询渠道库失败' };
    }
    var list = Array.isArray(res.data) ? res.data : [];
    return { ok: true, data: list.map(dbAppToAppInfo) };
  } catch (e) {
    host.log.error('getAllApps 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

/// 搜索：POST result-list（参数全在 queryParameters，对齐 Dart；无 body）
async function searchApps(keyword) {
  var kw = safeStr(keyword || '');
  if (kw === '') return { ok: true, data: [] }; // 空 keyword → 空数组，不发请求（对齐 Dart）
  try {
    var res = await safePost(SEARCH_URL, defaultParamsWith({
      key: kw,
      page_index: 1,
      apps_per_page: 20,
    }), {
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Content-Type': 'application/x-www-form-urlencoded',
    });
    if (!res || !res.ok) {
      return { ok: false, data: null, error: (res && res.error) || '搜索请求失败' };
    }
    var apps = parseSearchResults(res.data);
    return { ok: true, data: apps };
  } catch (e) {
    host.log.error('searchApps 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

/// 单应用信息：先查库（命中直接返回，对齐 Dart 非 forceRefresh 行为），
/// 未命中 → detailInfo（vivoId 直接使用 appId，对齐 Dart getAppInfo）。
/// ⚠️ 差异标注①：库命中时 Flutter 侧标记 fromCache:false（Dart 内置为 true），仅元信息。
async function getAppInfo(appId) {
  if (!appId) return { ok: true, data: null };
  try {
    var rec = await getSavedApp(appId);
    if (rec) return { ok: true, data: dbAppToAppInfo(rec) };

    var res = await safeGet(DETAIL_URL, defaultParamsWith({ appId: appId, frompage: 'messageh5' }));
    if (!res || !res.ok) {
      return { ok: false, data: null, error: (res && res.error) || 'detailInfo 请求失败' };
    }
    var raw = res.data;
    if (raw === undefined || raw === null || (typeof raw === 'string' && raw.trim() === '')) {
      return { ok: false, data: null, error: 'vivo 详情接口返回空数据' };
    }
    if (typeof raw === 'string') {
      try { raw = JSON.parse(raw); } catch (e) { return { ok: false, data: null, error: '详情响应 JSON 解析失败' }; }
    }
    var app = parseAppDetail(raw, appId);
    if (!app) return { ok: false, data: null, error: '解析详情数据失败' };
    return { ok: true, data: app };
  } catch (e) {
    host.log.error('getAppInfo 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

/// 详情 AppInfo 解析（对齐 Dart _parseAppDetail：repositories = 包名，无 extra）
function parseAppDetail(data, appId) {
  try {
    if (!data || typeof data !== 'object') return null;
    var icon = safeStr(data.icon_url !== undefined && data.icon_url !== null ? data.icon_url : data.icon);
    var name = safeStr(data.title_zh) || safeStr(data.title_en) || safeStr(data.appName);
    var packageName = safeStr(data.package_name) || safeStr(data.packageName) || appId;
    var description = safeStr(data.introduction) || safeStr(data.shortIntroduction);
    var developer = safeStr(data.developerName);
    var category = null;
    if (data.categoryName !== undefined && data.categoryName !== null) {
      category = [safeStr(data.categoryName)];
    }
    return {
      appId: packageName,
      packageName: packageName,
      name: name,
      user: developer,
      repositories: packageName, // ⚠️ 差异标注③：详情路径 repositories = 包名（Dart 语义）
      icon: icon,
      des: description,
      category: category,
    };
  } catch (e) {
    host.log.error('解析应用详情失败: ' + safeStr(e));
    return null;
  }
}

/// 详情页数据（vivoId 解析 + detailInfo + 完整详情 Map）
/// 发现页/Agent 下载路径消费（entry runtime 的 main('getAppDetail')）；
/// 详情页优先走 detail.js（页面级 JsDetailChannel），本实现保留保证 entry 侧可用。
async function getAppDetail(appId) {
  if (!appId) return { ok: true, data: null };
  try {
    return await fetchDetailData(appId);
  } catch (e) {
    host.log.error('getAppDetail 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

/// 更新检测（对齐 Dart AppUpdateCheckMixin：getAppDetail 提取版本信息）
async function checkAppUpdate(appId) {
  if (!appId) return { ok: true, data: null };
  try {
    var res = await fetchDetailData(appId);
    if (!res || !res.ok || !res.data) {
      return { ok: false, data: null, error: (res && res.error) || '获取应用详情失败' };
    }
    var d = res.data;
    var packageName = safeStr(d.packageName) || appId;
    return {
      ok: true,
      data: {
        appId: packageName,
        packageName: packageName,
        name: safeStr(d.name),
        icon: safeStr(d.icon),
        version: safeStr(d.version),
      },
    };
  } catch (e) {
    host.log.error('checkAppUpdate 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

/// 渠道数据更新检查：vivo 无全量接口 → 恒无更新（对齐 Dart checkUpdate → false）。
async function checkUpdate() {
  return { ok: true, data: false };
}

/// 渠道数据更新：vivo 无远程全量可拉取 → 无需更新（对齐 Dart doUpdate → true）。
async function doUpdate() {
  return { ok: true, data: true };
}

// entry 分发器：仅发现页/更新路径方法（详情页走 detail.js）
async function main(method, params) {
  params = params || {};
  switch (method) {
    case 'getAllApps': return await getAllApps();
    case 'searchApps': return await searchApps(params.keyword);
    case 'getAppInfo': return await getAppInfo(params.appId);
    case 'getAppDetail': return await getAppDetail(params.appId);
    case 'checkAppUpdate': return await checkAppUpdate(params.appId);
    case 'checkUpdate': return await checkUpdate();
    case 'doUpdate': return await doUpdate();
    default: return null; // 未实现 method → null（JsChannel 降级策略）
  }
}
