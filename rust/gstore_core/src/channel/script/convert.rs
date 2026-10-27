//! Script JSON -> core DTO conversion.
//!
//! The wire names follow Dart `appSummaryFromScript` and `JsChannelDetailProxy`:
//! app rows use `appId/name/user/repositories/icon/des|description/readme/
//! category/extra`, details add `version/developer/packageName/projectUrl/
//! sections/downloads`, and downloads use `url/name/size/version/platform/
//! downloadable/note/publishedAt/updateTime`.
//!
//! One deliberate deviation: a non-string `publishedAt` that is not a numeric
//! epoch is dropped (`None`) because core has no date parser dependency.

use serde_json::{Map, Value as JsonValue};

use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelKind, DetailSection,
};
use crate::error::Error;

const CHANNEL_FIELD_ERROR: &str = "script channel returned a non-object value";

/// Maps a `getAllApps` / `searchApps` payload; `None` when it is not an array.
///
/// Dart's `_appsFromScript` returns `null` for a non-list (so the caller falls
/// back) and silently skips rows that fail the `appId && name` check.
pub(crate) fn apps_opt(value: &JsonValue, channel: &ChannelKey) -> Option<Vec<AppSummary>> {
    let items = value.as_array()?;
    let mut apps = Vec::with_capacity(items.len());
    for item in items {
        if let Some(app) = summary(item, channel).ok().flatten() {
            apps.push(app);
        }
    }
    Some(apps)
}

/// Maps one app row; `Ok(None)` means the row failed Dart's `appId && name` check.
pub(crate) fn summary(
    value: &JsonValue,
    channel: &ChannelKey,
) -> Result<Option<AppSummary>, Error> {
    let map = value
        .as_object()
        .ok_or_else(|| Error::Serialization(CHANNEL_FIELD_ERROR.to_string()))?;
    let app_id = text(map, "appId").unwrap_or_default();
    let name = text(map, "name").unwrap_or_default();
    if app_id.is_empty() || name.is_empty() {
        return Ok(None);
    }
    let extra = map.get("extra").and_then(JsonValue::as_object).cloned();
    let package_name = text(map, "packageName")
        .or_else(|| {
            extra
                .as_ref()
                .and_then(|extra| extra.get("packageName"))
                .and_then(text_value)
        })
        .filter(|value| !value.is_empty());

    Ok(Some(AppSummary {
        app_id,
        package_name,
        name,
        user: text(map, "user").unwrap_or_else(|| channel.as_str().to_owned()),
        repositories: text(map, "repositories").unwrap_or_else(|| channel.as_str().to_owned()),
        icon: text(map, "icon").unwrap_or_default(),
        des: text(map, "des")
            .or_else(|| text(map, "description"))
            .unwrap_or_default(),
        readme: text(map, "readme"),
        category: categories(map.get("category")),
        extra,
    }))
}

/// Maps a `getAppDetail` payload.
pub(crate) fn detail(value: &JsonValue) -> Result<AppDetail, Error> {
    let map = value
        .as_object()
        .ok_or_else(|| Error::Serialization(CHANNEL_FIELD_ERROR.to_string()))?;
    let app_id = text(map, "appId").unwrap_or_default();
    let package_name = text(map, "packageName").or_else(|| {
        if app_id.is_empty() {
            None
        } else {
            Some(app_id.clone())
        }
    });
    Ok(AppDetail {
        app_id,
        name: text(map, "name").unwrap_or_default(),
        icon: text(map, "icon").unwrap_or_default(),
        description: text(map, "description")
            .or_else(|| text(map, "des"))
            .unwrap_or_default(),
        version: text(map, "version"),
        developer: text(map, "developer").or_else(|| text(map, "user")),
        package_name,
        project_url: text(map, "projectUrl"),
        channel: ChannelKind::JsLocal,
        sections: sections(map.get("sections")),
        downloads: downloads(map.get("downloads")),
        extra: map.clone(),
    })
}

/// Maps a `checkAppUpdate` payload; the detail proxy is built from the same map.
pub(crate) fn update(value: &JsonValue, requested_app_id: &str) -> Result<AppUpdate, Error> {
    let map = value
        .as_object()
        .ok_or_else(|| Error::Serialization(CHANNEL_FIELD_ERROR.to_string()))?;
    let app_id = text(map, "appId").unwrap_or_else(|| requested_app_id.to_owned());
    let package_name = text(map, "packageName").unwrap_or_else(|| app_id.clone());
    let name = text(map, "name").unwrap_or_else(|| app_id.clone());
    let detail = detail(value)?;
    Ok(AppUpdate {
        app_id,
        package_name,
        name,
        icon: text(map, "icon"),
        latest_version: text(map, "version"),
        latest_download: None,
        detail,
    })
}

/// Builds the update payload Dart derives from a saved `AppSummary`.
pub(crate) fn update_from_summary(app: &AppSummary) -> AppUpdate {
    let package_name = app
        .package_name
        .clone()
        .unwrap_or_else(|| app.app_id.clone());
    let mut extra = Map::new();
    extra.insert("appId".to_string(), JsonValue::String(app.app_id.clone()));
    extra.insert("name".to_string(), JsonValue::String(app.name.clone()));
    extra.insert("icon".to_string(), JsonValue::String(app.icon.clone()));
    extra.insert(
        "description".to_string(),
        JsonValue::String(app.des.clone()),
    );
    extra.insert(
        "packageName".to_string(),
        JsonValue::String(package_name.clone()),
    );
    extra.insert("developer".to_string(), JsonValue::String(app.user.clone()));
    if let Some(readme) = &app.readme {
        extra.insert("readme".to_string(), JsonValue::String(readme.clone()));
    }
    let detail = AppDetail {
        app_id: app.app_id.clone(),
        name: app.name.clone(),
        icon: app.icon.clone(),
        description: app.des.clone(),
        version: None,
        developer: Some(app.user.clone()),
        package_name: Some(package_name.clone()),
        project_url: None,
        channel: ChannelKind::JsLocal,
        sections: Vec::new(),
        downloads: Vec::new(),
        extra,
    };
    AppUpdate {
        app_id: app.app_id.clone(),
        package_name,
        name: app.name.clone(),
        icon: Some(app.icon.clone()),
        latest_version: None,
        latest_download: None,
        detail,
    }
}

/// Maps a `getConfig` payload to [`crate::channel::ChannelConfig`].
pub(crate) fn config(value: &JsonValue) -> Result<crate::channel::ChannelConfig, Error> {
    let map = value
        .as_object()
        .ok_or_else(|| Error::Serialization(CHANNEL_FIELD_ERROR.to_string()))?;
    Ok(crate::channel::ChannelConfig {
        version: text(map, "version").unwrap_or_default(),
        proxy: text(map, "proxy"),
    })
}

fn downloads(value: Option<&JsonValue>) -> Vec<AppDownload> {
    let Some(JsonValue::Array(items)) = value else {
        return Vec::new();
    };
    items
        .iter()
        .map(|item| match item.as_object() {
            Some(map) => download_from_map(map),
            None => download_from_text(item),
        })
        .collect()
}

fn download_from_text(value: &JsonValue) -> AppDownload {
    let text = text_value(value).unwrap_or_default();
    AppDownload {
        url: text.clone(),
        name: text,
        size: None,
        download_count: None,
        version: None,
        version_code: None,
        published_at: None,
        platform: None,
        hash: None,
        hash_type: None,
        downloadable: true,
        note: None,
        extra: None,
    }
}

fn download_from_map(map: &Map<String, JsonValue>) -> AppDownload {
    let extra = map.get("extra").and_then(JsonValue::as_object).cloned();
    let extra_time = extra.as_ref().and_then(|extra| extra.get("updateTime"));
    let published_at = map
        .get("publishedAt")
        .or_else(|| map.get("updateTime"))
        .or(extra_time)
        .and_then(epoch_ms);
    AppDownload {
        url: text(map, "url").unwrap_or_default(),
        name: text(map, "name").unwrap_or_default(),
        size: map.get("size").and_then(integer),
        download_count: map
            .get("downloadCount")
            .or_else(|| map.get("downloads"))
            .and_then(integer),
        version: text(map, "version"),
        version_code: map.get("versionCode").and_then(integer),
        published_at,
        platform: text(map, "platform"),
        hash: text(map, "hash"),
        hash_type: text(map, "hashType"),
        downloadable: map
            .get("downloadable")
            .and_then(JsonValue::as_bool)
            .unwrap_or(true),
        note: text(map, "note"),
        extra,
    }
}

fn sections(value: Option<&JsonValue>) -> Vec<DetailSection> {
    let Some(JsonValue::Array(items)) = value else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(text_value)
        .filter_map(|label| serde_json::from_value(JsonValue::String(label)).ok())
        .collect()
}

fn categories(value: Option<&JsonValue>) -> Option<Vec<String>> {
    match value? {
        JsonValue::Array(items) => {
            let categories: Vec<String> = items
                .iter()
                .filter_map(text_value)
                .filter(|value| !value.is_empty())
                .collect();
            (!categories.is_empty()).then_some(categories)
        }
        other => text_value(other)
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .map(|value| vec![value]),
    }
}

fn epoch_ms(value: &JsonValue) -> Option<i64> {
    let number = match value {
        JsonValue::Number(number) => number.as_i64()?,
        JsonValue::String(text) => text.parse::<i64>().ok()?,
        _ => return None,
    };
    if number > 100_000_000_000 {
        Some(number)
    } else if number > 1_000_000_000 {
        number.checked_mul(1000)
    } else {
        None
    }
}

fn integer(value: &JsonValue) -> Option<i64> {
    match value {
        JsonValue::Number(number) => number.as_i64().or_else(|| {
            number
                .as_f64()
                .filter(|float| float.fract() == 0.0)
                .map(|float| float as i64)
        }),
        JsonValue::String(text) => text.parse::<i64>().ok(),
        _ => None,
    }
}

fn text(map: &Map<String, JsonValue>, key: &str) -> Option<String> {
    map.get(key).and_then(text_value)
}

fn text_value(value: &JsonValue) -> Option<String> {
    match value {
        JsonValue::String(text) => Some(text.clone()),
        JsonValue::Number(number) => Some(number.to_string()),
        JsonValue::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}
