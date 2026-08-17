// ============================================================================
// GStore 脚本渠道模板（示例）—— assets/channels/example.js
// ----------------------------------------------------------------------------
// 用途：演示脚本渠道契约。复制本脚本到应用"渠道脚本目录"（Android 文档目录
// 下的 channels/ 文件夹）后按需修改即可启用，应用二进制本身不包含第三方
// 渠道逻辑（本模板不调用任何真实第三方 API，占位域名 example.com 仅作示例）。
//
// 脚本契约（详见 JsChannel）：
//   - 导出统一分发器 async function main(method, params) → { ok, data } | null
//   - 可选 const CHANNEL_META = { name, description, icon }
//   - host API（异步，返回 Promise）：
//       host.network.get(url, { params, headers })      → { ok, status, data }
//       host.network.post(url, { params, body, headers })→ { ok, status, data }
//       host.database.getAppsByChannel() / getApp(appId) / insertApps(list)
//       host.config.get(key) / host.log.info(msg) / host.log.error(msg)
//   - AppInfo JSON 字段：appId / name / user / repositories / icon / des /
//     readme / category / extra（extra 可放任意渠道特性数据，零限制）
//   - 未实现的 method 返回 null → JsChannel 走降级策略（查本渠道库等）
// ============================================================================

const CHANNEL_META = {
  name: '示例渠道（模板）',
  description: '脚本渠道模板：复制到应用 channels/ 目录后按需修改',
  icon: 'template-icon',
};

// ---------- main 分发器骨架：method → 对应实现 ----------
async function main(method, params) {
  params = params || {};
  switch (method) {
    case 'getAllApps':
      return await getAllApps();
    case 'searchApps':
      return await searchApps(params.keyword || '');
    case 'getAppInfo':
      return await getAppInfo(params.appId || '');
    case 'getAppDetail':
      return await getAppDetail(params.appId || '');
    case 'checkAppUpdate':
      return await checkAppUpdate(params.appId || '');
    case 'checkUpdate':
      return { ok: true, data: false };
    case 'doUpdate':
      // 未实现 → 返回 null，JsChannel 会走"拉全量落库"兜底
      return null;
    default:
      // 未实现的 method → null = 走 JsChannel 降级策略
      return null;
  }
}

// ---------- host.network.get 用法示例 ----------
async function searchApps(keyword) {
  if (!keyword) return { ok: true, data: [] };

  const res = await host.network.get('https://example.com/api/search', {
    params: { q: keyword, page: 1, size: 20 },
    headers: { 'Accept': 'application/json' },
  });
  if (!res || !res.ok) {
    host.log.error('搜索失败: ' + (res && res.error ? res.error : '网络错误'));
    return { ok: false, error: (res && res.error) || '网络请求失败' };
  }
  host.log.info('搜索 "' + keyword + '" 返回条目数: ' + (Array.isArray(res.data) ? res.data.length : 0));
  // res.data 已由 host 层做 JSON 解码；防御性处理非数组
  const list = Array.isArray(res.data) ? res.data : [];
  return { ok: true, data: list.map(mapApp) };
}

// ---------- 全量应用（可配合 doUpdate 落库） ----------
async function getAllApps() {
  const res = await host.network.get('https://example.com/api/apps', {
    params: { page: 1, size: 50 },
  });
  if (!res || !res.ok) {
    return { ok: false, error: (res && res.error) || '网络请求失败' };
  }
  const list = Array.isArray(res.data) ? res.data : [];
  return { ok: true, data: list.map(mapApp) };
}

// ---------- 单应用信息 ----------
async function getAppInfo(appId) {
  if (!appId) return { ok: true, data: null };
  const res = await host.network.get('https://example.com/api/app', {
    params: { appId: appId },
  });
  if (!res || !res.ok || !res.data) return { ok: true, data: null };
  return { ok: true, data: mapApp(res.data) };
}

// ---------- 详情（返回更丰富的字段供详情页展示） ----------
async function getAppDetail(appId) {
  if (!appId) return { ok: true, data: null };
  const res = await host.network.get('https://example.com/api/detail', {
    params: { appId: appId },
  });
  if (!res || !res.ok || !res.data) return { ok: true, data: null };
  const raw = res.data;
  return {
    ok: true,
    data: {
      appId: raw.packageName || raw.appId || appId,
      name: raw.name || '',
      icon: raw.icon || '',
      description: raw.description || '',
      version: raw.versionName || raw.version || '',
      developer: raw.developer || '',
      packageName: raw.packageName || '',
      projectUrl: raw.homepage || '',
      downloads: (Array.isArray(raw.downloads) ? raw.downloads : []).map(function (d) {
        return { url: d.url || '', name: d.name || '', size: d.size || null, version: d.version || '' };
      }),
    },
  };
}

// ---------- 更新检测（返回最新版本信息，供详情页展示） ----------
async function checkAppUpdate(appId) {
  if (!appId) return { ok: true, data: null };
  const res = await host.network.get('https://example.com/api/app', {
    params: { appId: appId },
  });
  if (!res || !res.ok || !res.data) return { ok: true, data: null };
  const raw = res.data;
  return {
    ok: true,
    data: {
      appId: raw.packageName || raw.appId || appId,
      packageName: raw.packageName || raw.appId || appId,
      name: raw.name || '',
      icon: raw.icon || '',
      version: raw.versionName || raw.version || '',
    },
  };
}

// ---------- 原始数据 → AppInfo JSON 映射示例 ----------
function mapApp(raw) {
  if (!raw) return null;
  return {
    // appId 使用包名（AppInfo.appId 语义）；渠道内唯一即可
    appId: raw.packageName || raw.appId || '',
    name: raw.name || '',
    icon: raw.icon || '',
    des: raw.description || raw.summary || '',
    user: raw.developer || '',
    repositories: raw.repo || '',
    category: raw.category || [],
    extra: {
      // 渠道特性数据可自由扩展（版本号、评分、渠道内 ID 等），零限制透传
      versionName: raw.versionName || '',
      versionCode: raw.versionCode || '',
      rating: raw.rating || 0,
      source: 'example-template',
    },
  };
}
