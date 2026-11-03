//! Vivo app-store channel driver (Wave 1, Todo 11).
//!
//! Network access goes exclusively through [`HttpPort`]; this crate never links
//! an HTTP client. Saved search results live in `channel_apps` under the bound
//! [`ChannelKey`], which is also how Dart implements the channel.
//!
//! Dart parity sources (quoted lines are from `VivoChannel.dart`):
//!
//! * Search request (`:455-470`):
//!   ```dart
//!   final response = await _dio.post(
//!     _searchUrl,
//!     queryParameters: {
//!       ..._defaultParams,
//!       'key': keyword,
//!       'page_index': 1,
//!       'apps_per_page': 20,
//!     },
//!     options: Options(headers: {
//!       'Accept': 'application/json, text/plain, */*',
//!       'Accept-Language': 'zh-CN,zh;q=0.9',
//!       'Content-Type': 'application/x-www-form-urlencoded',
//!     }),
//!   );
//!   ```
//!   The defaults are `imei=1234567890&av=18&app_version=2100&pictype=webp&
//!   h5_websource=h5appstore&target=local&cfrom=2` (`:36-43`).
//! * Search mapping (`:798-829`):
//!   ```dart
//!   final appId = packageName.isNotEmpty ? packageName : id;
//!   repositories: id, // repositories 存放 vivoId
//!   extra: {'vivoId': id, 'packageName': packageName, 'title': title,
//!           'developer': developer, 'iconUrl': icon, 'remark': remark}
//!   ```
//! * Info mapping (`:740-775`): `appId: packageName`, `repositories:
//!   packageName`, `category: [categoryName]`.
//! * Detail (`:244-350`): `vivoId ??= appInfo?.repositories; vivoId ??=
//!   appId;`, `sizeKb * 1024`, `fileName = '${packageName}_$versionCode.apk'`,
//!   and sections Version / Statistics / Rating / Downloads / Readme /
//!   Permissions.
//! * Save (`:620-640`): `ChannelAddedApp.withChannel(... category:
//!   app.category?.join(','), addTime: DateTime.now().millisecondsSinceEpoch,
//!   extra: app.extra != null ? jsonEncode(app.extra) : null)`.
//!
//! Error mapping (stricter than Dart, which silently returns an empty list for
//! an error envelope): non-2xx responses and a non-zero API `code` are
//! [`Error::Network`]; malformed JSON or a structurally invalid payload is
//! [`Error::Serialization`]. All are typed and panic-free.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{OptionalExtension, Row};
use serde_json::{Map, Value};

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelMeta, DetailSection,
    detail_labels, insert_info_tag, label_downloads, summary_labels,
};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::http::{HttpOptions, HttpPort, HttpResponse};

const BASE_URL: &str = "https://h5-api.appstore.vivo.com.cn";
const SEARCH_URL: &str = "https://h5-api.appstore.vivo.com.cn/h5appstore/search/result-list";
const DETAIL_URL: &str = "https://h5-api.appstore.vivo.com.cn/detailInfo";
const SEARCH_LIMIT: u32 = 20;

/// Vivo channel driver bound to one [`ChannelKey`].
pub struct VivoDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    db: DbHandle,
    config: CoreConfig,
    http: Arc<dyn HttpPort>,
    initialized: AtomicBool,
}

impl sealed::Sealed for VivoDriver {}

#[derive(Debug, Clone)]
struct StoredApp {
    app_id: String,
    name: String,
    user: String,
    repositories: String,
    icon: String,
    description: String,
    category: Option<String>,
    extra_raw: Option<String>,
}

impl StoredApp {
    fn extra(&self) -> Option<Map<String, Value>> {
        self.extra_raw
            .as_deref()
            .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
            .and_then(|value| value.as_object().cloned())
    }

    fn package_name(&self) -> Option<String> {
        self.extra()
            .as_ref()
            .and_then(|map| map.get("packageName"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    }

    fn to_summary(&self) -> AppSummary {
        let package_name = self.package_name();
        AppSummary {
            app_id: self.app_id.clone(),
            package_name: package_name.clone(),
            name: self.name.clone(),
            user: self.user.clone(),
            repositories: self.repositories.clone(),
            icon: self.icon.clone(),
            des: self.description.clone(),
            readme: None,
            category: self
                .category
                .as_deref()
                .map(|value| value.split(',').map(ToString::to_string).collect()),
            extra: self.extra(),
            labels: summary_labels(&self.user, package_name.as_deref(), &self.repositories),
        }
    }
}

fn stored_from_row(row: &Row<'_>) -> rusqlite::Result<StoredApp> {
    Ok(StoredApp {
        app_id: row.get(0)?,
        name: row.get(1)?,
        user: row.get(2)?,
        repositories: row.get(3)?,
        icon: row.get(4)?,
        description: row.get(5)?,
        category: row.get(6)?,
        extra_raw: row.get(7)?,
    })
}

impl VivoDriver {
    /// Creates a driver bound to `key`.
    pub fn new(
        key: ChannelKey,
        meta: ChannelMeta,
        db: DbHandle,
        config: CoreConfig,
        http: Arc<dyn HttpPort>,
    ) -> Self {
        Self {
            key,
            meta,
            db,
            config,
            http,
            initialized: AtomicBool::new(false),
        }
    }

    fn reader(&self) -> Result<rusqlite::Connection, Error> {
        self.db
            .reader()
            .map_err(|error| Error::Io(format!("vivo open reader: {error}")))
    }

    fn load_stored(&self) -> Result<Vec<StoredApp>, Error> {
        let conn = self.reader()?;
        let mut statement = conn
            .prepare(
                "SELECT app_id,name,user,repositories,icon,description,category,extra \
                 FROM channel_apps WHERE channel_key = ?1 ORDER BY add_time DESC, app_id ASC",
            )
            .map_err(|error| Error::Io(format!("vivo prepare stored apps: {error}")))?;
        let rows = statement
            .query_map([self.key.as_str()], stored_from_row)
            .map_err(|error| Error::Io(format!("vivo stored apps: {error}")))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("vivo stored row: {error}")))
    }

    fn find_stored(&self, app_id: &str) -> Result<Option<StoredApp>, Error> {
        let conn = self.reader()?;
        conn.query_row(
            "SELECT app_id,name,user,repositories,icon,description,category,extra \
             FROM channel_apps WHERE channel_key = ?1 AND app_id = ?2 LIMIT 1",
            rusqlite::params![self.key.as_str(), app_id],
            stored_from_row,
        )
        .optional()
        .map_err(|error| Error::Io(format!("vivo lookup stored app: {error}")))
    }

    fn get_options(&self) -> HttpOptions {
        match self.config.proxy_url() {
            Some(proxy) => HttpOptions::new().with_proxy(proxy),
            None => HttpOptions::new(),
        }
    }

    fn search_options(&self) -> HttpOptions {
        self.get_options()
            .with_header("Accept", "application/json, text/plain, */*")
            .with_header("Accept-Language", "zh-CN,zh;q=0.9")
            .with_header("Content-Type", "application/x-www-form-urlencoded")
    }

    fn search_url(keyword: &str) -> String {
        format!(
            "{SEARCH_URL}?{}&key={}&page_index=1&apps_per_page={SEARCH_LIMIT}",
            default_query(),
            encode_query_component(keyword)
        )
    }

    fn detail_url(vivo_id: &str) -> String {
        format!(
            "{DETAIL_URL}?{}&appId={}&frompage=messageh5",
            default_query(),
            encode_query_component(vivo_id)
        )
    }

    fn get_json(&self, url: &str, options: &HttpOptions) -> Result<Value, Error> {
        let response = self.http.get(url, options)?;
        decode_response(url, &response)
    }

    fn parse_summary(object: &Map<String, Value>, app_id: &str) -> AppSummary {
        let icon = string_field(object, &["icon_url", "icon"]).unwrap_or_default();
        let name = string_field(object, &["title_zh", "title_en", "appName"]).unwrap_or_default();
        let package_name = string_field(object, &["package_name", "packageName"])
            .unwrap_or_else(|| app_id.to_string());
        let description =
            string_field(object, &["introduction", "shortIntroduction"]).unwrap_or_default();
        let developer = string_field(object, &["developerName"]).unwrap_or_default();
        let category = string_field(object, &["categoryName"])
            .filter(|value| !value.is_empty())
            .map(|value| vec![value]);

        let labels = summary_labels(&developer, Some(&package_name), &package_name);
        AppSummary {
            app_id: package_name.clone(),
            package_name: Some(package_name.clone()),
            name,
            user: developer,
            repositories: package_name,
            icon,
            des: description,
            readme: None,
            category,
            extra: None,
            labels,
        }
    }

    fn parse_search(value: &Value) -> Result<Vec<AppSummary>, Error> {
        check_error_envelope(value)?;
        let results = search_results(value)?;
        let mut apps = Vec::with_capacity(results.len());
        for item in results {
            let Value::Object(map) = item else {
                continue;
            };
            let id = flat_string(map.get("id")).unwrap_or_default();
            let title = string_field(&map, &["title_zh", "title"]).unwrap_or_default();
            let icon = string_field(&map, &["icon_url", "icon"]).unwrap_or_default();
            let package_name =
                string_field(&map, &["package_name", "packageName"]).unwrap_or_default();
            let developer = string_field(&map, &["developer", "developerName"]).unwrap_or_default();
            let remark = string_field(&map, &["remark", "introduction", "shortIntroduction"])
                .unwrap_or_default();
            let app_id = if package_name.is_empty() {
                id.clone()
            } else {
                package_name.clone()
            };
            let extra = [
                ("vivoId".to_string(), Value::String(id.clone())),
                (
                    "packageName".to_string(),
                    Value::String(package_name.clone()),
                ),
                ("title".to_string(), Value::String(title.clone())),
                ("developer".to_string(), Value::String(developer.clone())),
                ("iconUrl".to_string(), Value::String(icon.clone())),
                ("remark".to_string(), Value::String(remark.clone())),
            ]
            .into_iter()
            .collect();
            let labels = summary_labels(&developer, Some(&package_name), &id);
            apps.push(AppSummary {
                app_id,
                package_name: (!package_name.is_empty()).then_some(package_name),
                name: title,
                user: developer,
                repositories: id,
                icon,
                des: remark,
                readme: None,
                category: None,
                extra: Some(extra),
                labels,
            });
        }
        Ok(apps)
    }

    fn build_detail(
        &self,
        app_id: &str,
        stored: Option<&StoredApp>,
        object: &Map<String, Value>,
    ) -> AppDetail {
        let version = string_field(object, &["version_name", "versionName", "version"]);
        let version_code_raw = string_field(object, &["version_code", "versionCode"]);
        let version_code = version_code_raw
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok());
        let size_kb = number_field(object, &["size", "apkSize"]);
        let size = size_kb.map(|kb| kb * 1024);
        let developer = string_field(object, &["developerName", "developer"])
            .or_else(|| stored.map(|app| app.user.clone()))
            .unwrap_or_default();
        let package_name = string_field(object, &["package_name", "packageName"])
            .or_else(|| stored.map(|app| app.app_id.clone()))
            .unwrap_or_else(|| app_id.to_string());
        let download_count = number_field(object, &["download_count", "downloadCount"]);
        let rating = float_field(object, &["score"]);
        let rating_count = number_field(object, &["raters_count", "scoreCount"]);
        let favorites = number_field(object, &["favorite_count", "favoriteCount"]);
        let description = string_field(object, &["introduction", "shortIntroduction"])
            .or_else(|| stored.map(|app| app.description.clone()))
            .unwrap_or_default();

        let screenshots = string_list(
            object
                .get("screenshotList")
                .or_else(|| object.get("screenShots")),
        );
        let permissions = permission_list(
            object
                .get("permissionList")
                .or_else(|| object.get("permissions")),
        );

        let mut download_url = string_field(object, &["download_url", "downloadUrl"])
            .filter(|value| !value.is_empty());
        if download_url.is_none() {
            if let Some(apk) = string_field(object, &["apk"]).filter(|value| !value.is_empty()) {
                download_url = Some(if apk.starts_with("http") {
                    apk
                } else if apk.starts_with('/') {
                    format!("{BASE_URL}{apk}")
                } else {
                    format!("{BASE_URL}/{apk}")
                });
            }
        }

        let mut downloads = Vec::new();
        if let Some(url) = download_url {
            let file_version = version.as_deref().unwrap_or("latest");
            let file_name = match version_code_raw
                .as_deref()
                .filter(|value| !value.is_empty())
            {
                Some(code) => format!("{package_name}_{code}.apk"),
                None => format!("{package_name}_{file_version}.apk"),
            };
            downloads.push(AppDownload {
                url,
                name: file_name,
                size,
                download_count,
                version: version.clone(),
                version_code,
                published_at: None,
                platform: Some("android".to_string()),
                hash: None,
                hash_type: None,
                downloadable: true,
                note: None,
                extra: None,
            });
        }

        let has_statistics = download_count.is_some() || favorites.is_some();
        let has_rating = rating.is_some();
        let mut sections = vec![DetailSection::Version];
        if has_statistics || has_rating {
            sections.push(DetailSection::Statistics);
        }
        if has_rating {
            sections.push(DetailSection::Rating);
        }
        sections.push(DetailSection::Downloads);
        if !description.is_empty() {
            sections.push(DetailSection::Readme);
        }
        if !permissions.is_empty() {
            sections.push(DetailSection::Permissions);
        }

        let mut extra = Map::new();
        extra.insert("appId".to_string(), Value::String(app_id.to_string()));
        if let Some(download_count) = download_count {
            extra.insert(
                "downloadCount".to_string(),
                Value::Number(download_count.into()),
            );
        }
        if let Some(rating) = rating {
            extra.insert("rating".to_string(), json_number(rating));
        }
        if let Some(rating_count) = rating_count {
            extra.insert(
                "ratingCount".to_string(),
                Value::Number(rating_count.into()),
            );
        }
        if let Some(favorites) = favorites {
            extra.insert("favorites".to_string(), Value::Number(favorites.into()));
        }
        extra.insert(
            "screenshots".to_string(),
            Value::Array(
                screenshots
                    .iter()
                    .map(|url| Value::String(url.clone()))
                    .collect(),
            ),
        );
        extra.insert(
            "permissions".to_string(),
            Value::Array(
                permissions
                    .iter()
                    .map(|value| Value::String(value.clone()))
                    .collect(),
            ),
        );
        extra.insert("readme".to_string(), Value::String(description.clone()));
        extra.insert("detailData".to_string(), Value::Object(object.clone()));
        if let Some(category) = string_field(object, &["categoryName", "category"]) {
            extra.insert("category".to_string(), Value::String(category.clone()));
            insert_info_tag(&mut extra, "category", "分类", category);
        }

        let developer = (!developer.is_empty()).then_some(developer);
        let mut labels = detail_labels(version.as_deref(), developer.as_deref(), Some(&package_name));
        labels.extend(label_downloads(download_count));

        AppDetail {
            app_id: app_id.to_string(),
            name: string_field(object, &["title_zh", "title_en", "appName", "title"])
                .or_else(|| stored.map(|app| app.name.clone()))
                .unwrap_or_default(),
            icon: string_field(object, &["icon_url", "icon"])
                .or_else(|| stored.map(|app| app.icon.clone()))
                .unwrap_or_default(),
            description,
            version,
            developer,
            package_name: Some(package_name),
            project_url: None,
            channel: self.meta.kind,
            sections,
            downloads,
            extra,
            labels,
        }
    }

    fn stored_vivo_id(stored: &StoredApp, app_id: &str) -> String {
        let from_extra = stored
            .extra()
            .as_ref()
            .and_then(|map| map.get("vivoId"))
            .and_then(flat_string_value);
        if let Some(value) = from_extra {
            return value;
        }
        if stored.repositories.is_empty() {
            app_id.to_string()
        } else {
            stored.repositories.clone()
        }
    }
}

impl ChannelDriver for VivoDriver {
    fn key(&self) -> &ChannelKey {
        &self.key
    }

    fn meta(&self) -> &ChannelMeta {
        &self.meta
    }

    fn initialize(&self) -> Result<(), Error> {
        self.initialized.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn is_initialized(&self) -> Result<bool, Error> {
        Ok(self.initialized.load(Ordering::SeqCst))
    }

    fn check_available(&self) -> Result<bool, Error> {
        // Dart probes the search endpoint and reports false on any failure.
        Ok(self.search_apps("汽车", true).is_ok())
    }

    fn get_all_apps(&self, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        Ok(self
            .load_stored()?
            .iter()
            .map(StoredApp::to_summary)
            .collect())
    }

    fn get_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error> {
        if !force_refresh {
            if let Some(stored) = self.find_stored(app_id)? {
                return Ok(stored.to_summary());
            }
        }

        let url = Self::detail_url(app_id);
        let value = self.get_json(&url, &self.get_options())?;
        let object = value.as_object().ok_or_else(|| {
            Error::Serialization(format!("vivo detail payload is not an object: {url}"))
        })?;
        Ok(Self::parse_summary(object, app_id))
    }

    fn get_app_detail(&self, app_id: &str, _force_refresh: bool) -> Result<AppDetail, Error> {
        // Dart consults the channel row even when forceRefresh is true because
        // the detail endpoint needs the vivo id, not the package name.
        let stored = self.find_stored(app_id)?;
        let vivo_id = match &stored {
            Some(record) => Self::stored_vivo_id(record, app_id),
            None => app_id.to_string(),
        };
        let url = Self::detail_url(&vivo_id);
        let value = self.get_json(&url, &self.get_options())?;
        let object = value.as_object().ok_or_else(|| {
            Error::Serialization(format!("vivo detail payload is not an object: {url}"))
        })?;
        Ok(self.build_detail(app_id, stored.as_ref(), object))
    }

    fn check_app_update(&self, app_id: &str) -> Result<AppUpdate, Error> {
        let detail = self.get_app_detail(app_id, false)?;
        Ok(AppUpdate {
            app_id: detail.app_id.clone(),
            package_name: detail.package_name.clone().unwrap_or_default(),
            name: detail.name.clone(),
            icon: Some(detail.icon.clone()),
            latest_version: detail.version.clone(),
            latest_download: detail.downloads.first().cloned(),
            detail,
        })
    }

    fn add_app(&self, app: &AppSummary) -> Result<(), Error> {
        let category = app
            .category
            .as_ref()
            .map(|values| values.join(","))
            .filter(|value| !value.is_empty());
        let extra = app.extra.as_ref().map(|map| {
            serde_json::to_string(&Value::Object(map.clone())).unwrap_or_else(|_| "{}".to_string())
        });
        let add_time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as i64)
            .unwrap_or(0);

        self.db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT OR REPLACE INTO channel_apps(channel_key,app_id,name,user,repositories,\
                     apprepo,icon,description,category,add_time,source_id,extra) \
                     VALUES (?1,?2,?3,?4,?5,NULL,?6,?7,?8,?9,NULL,?10)",
                    rusqlite::params![
                        self.key.as_str(),
                        app.app_id,
                        app.name,
                        app.user,
                        app.repositories,
                        app.icon,
                        app.des,
                        category,
                        add_time,
                        extra
                    ],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("vivo add app: {error}")))
    }

    fn canonical_app_id(&self, app: &AppSummary) -> Result<String, Error> {
        // Dart: `Future<String> canonicalAppId(AppSummary appInfo) async =>
        // appInfo.appId;`
        Ok(app.app_id.clone())
    }

    fn remove_app(&self, app_id: &str) -> Result<(), Error> {
        self.db
            .with_writer(|conn| {
                conn.execute(
                    "DELETE FROM channel_apps WHERE channel_key = ?1 AND app_id = ?2",
                    rusqlite::params![self.key.as_str(), app_id],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("vivo remove app: {error}")))
    }

    fn search_apps(&self, keyword: &str, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        if keyword.is_empty() {
            return Ok(Vec::new());
        }
        let url = Self::search_url(keyword);
        let response = self.http.post(&url, &[], &self.search_options())?;
        let value = decode_response(&url, &response)?;
        Self::parse_search(&value)
    }

    fn search_by_category(
        &self,
        _category_id: &str,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        // Dart: vivo has no category search; return an empty success.
        Ok(Vec::new())
    }

    fn get_all_categories(&self, _force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        Ok(Vec::new())
    }

    fn check_update(&self) -> Result<bool, Error> {
        Ok(false)
    }

    fn do_update(&self, _progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        Ok(true)
    }

    fn get_config(&self, _force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        Ok(None)
    }

    fn clear_cache(&self) -> Result<(), Error> {
        Ok(())
    }

    fn get_cache_size(&self) -> Result<u64, Error> {
        Ok(0)
    }

    fn dispose(&self) -> Result<(), Error> {
        self.initialized.store(false, Ordering::SeqCst);
        Ok(())
    }
}

fn default_query() -> String {
    [
        ("imei", "1234567890"),
        ("av", "18"),
        ("app_version", "2100"),
        ("pictype", "webp"),
        ("h5_websource", "h5appstore"),
        ("target", "local"),
        ("cfrom", "2"),
    ]
    .iter()
    .map(|(key, value)| format!("{key}={value}"))
    .collect::<Vec<_>>()
    .join("&")
}

fn decode_response(url: &str, response: &HttpResponse) -> Result<Value, Error> {
    if !response.is_success() {
        return Err(Error::Network(format!(
            "vivo API returned status {} for {url}",
            response.status
        )));
    }
    let text = response.text()?;
    serde_json::from_str(text)
        .map_err(|error| Error::Serialization(format!("vivo malformed JSON from {url}: {error}")))
}

fn check_error_envelope(value: &Value) -> Result<(), Error> {
    let Value::Object(object) = value else {
        return Err(Error::Serialization(
            "vivo response must be a JSON object".to_string(),
        ));
    };
    let Some(code) = object.get("code") else {
        return Ok(());
    };
    let code = code.as_i64().ok_or_else(|| {
        Error::Serialization("vivo API envelope code must be an integer".to_string())
    })?;
    if code == 0 {
        return Ok(());
    }
    let message = object
        .get("message")
        .or_else(|| object.get("msg"))
        .and_then(Value::as_str)
        .unwrap_or("unknown error");
    Err(Error::Network(format!(
        "vivo API error code {code}: {message}"
    )))
}

fn search_results(value: &Value) -> Result<Vec<Value>, Error> {
    if let Value::Array(items) = value {
        return Ok(items.clone());
    }
    let Value::Object(root) = value else {
        return Err(Error::Serialization(
            "vivo search response must be an object or array".to_string(),
        ));
    };
    let Some(data) = root.get("data") else {
        return Ok(Vec::new());
    };
    match data {
        Value::Array(items) => Ok(items.clone()),
        Value::Object(data) => {
            let Some(response) = data.get("appSearchResponse") else {
                return Ok(Vec::new());
            };
            let Value::Object(response) = response else {
                return Err(Error::Serialization(
                    "vivo appSearchResponse must be an object".to_string(),
                ));
            };
            match response.get("value") {
                None | Some(Value::Null) => Ok(Vec::new()),
                Some(Value::Array(items)) => Ok(items.clone()),
                Some(_) => Err(Error::Serialization(
                    "vivo appSearchResponse.value must be an array".to_string(),
                )),
            }
        }
        _ => Err(Error::Serialization(
            "vivo search data must be an object or array".to_string(),
        )),
    }
}

fn string_field(object: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| object.get(*key).and_then(flat_string_value))
        .filter(|value| !value.is_empty())
}

fn flat_string(value: Option<&Value>) -> Option<String> {
    value.and_then(flat_string_value)
}

fn flat_string_value(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

fn number_field(object: &Map<String, Value>, keys: &[&str]) -> Option<i64> {
    keys.iter().find_map(|key| {
        let value = object.get(*key)?;
        value
            .as_i64()
            .or_else(|| value.as_f64().map(|number| number as i64))
    })
}

fn float_field(object: &Map<String, Value>, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| {
        let value = object.get(*key)?;
        value
            .as_f64()
            .or_else(|| value.as_str().and_then(|text| text.parse::<f64>().ok()))
    })
}

fn string_list(value: Option<&Value>) -> Vec<String> {
    let Some(Value::Array(items)) = value else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(flat_string_value)
        .filter(|value| !value.is_empty())
        .collect()
}

fn permission_list(value: Option<&Value>) -> Vec<String> {
    let Some(Value::Array(items)) = value else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| match item {
            Value::Object(map) => string_field(map, &["permissionName", "name"]),
            other => flat_string_value(other).filter(|value| !value.is_empty()),
        })
        .collect()
}

fn json_number(value: f64) -> Value {
    serde_json::Number::from_f64(value).map_or(Value::Null, Value::Number)
}

/// Dart `Uri.encodeQueryComponent` compatible percent-encoding (space -> `+`).
fn encode_query_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        let unreserved = byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(byte);
        match *byte {
            b' ' => encoded.push('+'),
            _ if unreserved => encoded.push(char::from(*byte)),
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}
