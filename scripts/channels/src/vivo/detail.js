// ============================================================
// vivo 应用市场渠道脚本 · detail.js（详情页）
// ------------------------------------------------------------
// 用途：vivo 应用市场（h5-api.appstore.vivo.com.cn）渠道脚本 zip 渠道包
// （channels/vivo.zip）的详情页部分（detail.js，可选）。
// 由页面级 JsDetailChannel（独立 runtime）消费，页面退出释放。
// 应用二进制不含此脚本；不进入版本库（已被 .gitignore 忽略）。
//
// 本文件为 zip 渠道包的详情页部分：
//   main(method, params) → { ok, data } | null
//   method: getAppDetail / checkAppUpdate / detailMenu
// 发现页部分在 entry.js（发现页/更新路径独立 runtime 消费），
// 两者各自独立 runtime，无法共享工具函数——本文件自带所需工具。
//
// vivo 详情走独立 detail（页面级 JsDetailChannel 消费 getAppDetail）；
// 无多版本选择/无额外操作 → detailMenu 返回空 Actions（Flutter 侧空菜单 →
// 维持现状兜底）。
//
// 接口/契约对齐说明同 entry.js（Dart 内置 VivoChannel 语义为权威）。
// ============================================================

const BASE_URL = 'https://h5-api.appstore.vivo.com.cn';
const DETAIL_URL = BASE_URL + '/detailInfo';

// User-Agent：模拟 Android Chrome（统一 UA，与其他脚本渠道一致），避免被接口反爬
const DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

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

// 字节数 → 可读文本（B/KB/MB/GB），非正数返回空串（对齐 Dart formatFileSize 口径）
function formatBytes(v) {
  var n = Number(v);
  if (!n || isNaN(n) || n <= 0) return '';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
  return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

// 计数 → 中文缩写（≥1亿 X.X亿；≥1万 X.X万；其余原数），对齐 Dart formatFileCount
function formatCount(v) {
  var n = Number(v);
  if (!n || isNaN(n) || n <= 0) return '';
  if (n >= 100000000) return (n / 100000000).toFixed(1) + '亿';
  if (n >= 10000) return (n / 10000).toFixed(1) + '万';
  return String(n);
}

/// 默认参数 + 额外参数（额外空值剔除，保留类型）
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
      updateTime: safeStr(detail.update_time) || safeStr(detail.updateTime) || '',
      extra: {
        'size': {icon: 'sd_card', text: formatBytes(size)},
        'platform': {icon: 'phone_android', text: 'android'},
        'version': {icon: 'label', text: detail.version_name || ''},
        'download_count': {icon: 'cloud_download', text: formatCount(downloads)},
      },
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

    // ①.5 渠道库命中 → 入库信息预填推送：已保存应用信息先进内存上屏
    //     （push 进内存，不落 ConfigStore；API 解析完成后由下方全量 return 替换）。
    //     字段映射对齐 dbAppToAppInfo（packageName 从 extra.packageName 提升）；
    //     经 host.ui.call('updateDetail') 路由到 Dart 侧 ui.updateDetail 粒度推送原语。
    //     推送失败静默，不影响主流程。
    try {
      host.ui.call('updateDetail', {
        appId: safeStr(rec.appId),
        name: safeStr(rec.name),
        icon: safeStr(rec.icon),
        description: safeStr(rec.description),
        packageName: (ex && ex.packageName) ? safeStr(ex.packageName) : null,
        sections: ['readme'],
      });
    } catch (e) { /* 预填推送失败不阻塞详情加载 */ }
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

/// 详情页数据（vivoId 解析 + detailInfo + 完整详情 Map；已安装时附带 installedVersion）
async function getAppDetail(appId) {
  if (!appId) return { ok: true, data: null };
  try {
    var res = await fetchDetailData(appId);
    if (!res || !res.ok || !res.data) return res;
    var d = res.data;
    var packageName = safeStr(d.packageName) || appId;
    try {
      var chk = await host.utils.call('checkVersion', { packageName: packageName });
      if (chk && chk.ok && chk.data && chk.data.installed && chk.data.version) {
        d.installedVersion = safeStr(chk.data.version);
        if (chk.data.versionCode != null) d.installedVersionCode = chk.data.versionCode;
      }
    } catch (eCv) {}
    return { ok: true, data: d };
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
    var updData = {
      appId: packageName,
      packageName: packageName,
      name: safeStr(d.name),
      icon: safeStr(d.icon),
      version: safeStr(d.version),
    };
    try {
      var chk = await host.utils.call('checkVersion', { packageName: packageName });
      if (chk && chk.ok && chk.data && chk.data.installed && chk.data.version) {
        updData.installedVersion = safeStr(chk.data.version);
        if (chk.data.versionCode != null) updData.installedVersionCode = chk.data.versionCode;
      }
    } catch (eCv) {}
    return {
      ok: true,
      data: updData,
    };
  } catch (e) {
    host.log.error('checkAppUpdate 失败: ' + safeStr(e));
    return { ok: false, data: null, error: safeStr(e) };
  }
}

// ============================================================
// Hybrid 详情页：detailMenu
// ------------------------------------------------------------
// vivo 无多版本选择、无额外操作 → 返回空 Actions 数组。
// Flutter 侧（JsDetailChannel.detailMenu）收到 [] → 详情页「更多」菜单为空 →
// 维持现状兜底（不声明 jsswitchVersion，避免半成品交互）。
// ============================================================

function getDetailMenu(appId) {
  return { ok: true, data: [] };
}

// detail 分发器：仅详情页方法（发现页/更新路径走 entry.js）
async function main(method, params) {
  params = params || {};
  switch (method) {
    case 'getAppDetail': return await getAppDetail(params.appId);
    case 'checkAppUpdate': return await checkAppUpdate(params.appId);
    case 'detailMenu': return getDetailMenu(params.appId);
    case 'download': {
      var url = params.url;
      if (!url) return { ok: false, error: '下载地址为空' };
      return await host.ui.call('download', {
        appId: params.appId,
        url: params.url,
        name: params.name,
        version: params.version,
        size: params.size,
      });
    }
    default: return null; // 未实现 method → null（JsChannel 降级策略）
  }
}
