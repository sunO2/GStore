//! Canonical profile/node model returned by the `profile.import_*` methods.
//!
//! This is the wire schema the Dart side receives and that Todo 12 persists.
//! It is deliberately a *whitelisted* projection of subscription content: the
//! model has no `dns`, `tun`, `external-controller`, `script`, or provider
//! fields, so untrusted provider YAML can never smuggle one through.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionUserinfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub download: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expire: Option<i64>,
}

impl SubscriptionUserinfo {
    pub(crate) fn is_empty(&self) -> bool {
        self.upload.is_none()
            && self.download.is_none()
            && self.total.is_none()
            && self.expire.is_none()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RealityParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub short_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spider_x: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct WsParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct GrpcParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct NodeSource {
    pub format: String,
    pub origin: String,
    pub index: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProxyNode {
    pub name: String,
    #[serde(rename = "type")]
    pub node_type: String,
    pub server: String,
    pub port: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cipher: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uuid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alter_id: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub security: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flow: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network: Option<String>,
    #[serde(default)]
    pub tls: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sni: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skip_cert_verify: Option<bool>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub alpn: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reality: Option<RealityParams>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ws: Option<WsParams>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grpc: Option<GrpcParams>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obfs: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obfs_password: Option<String>,
    #[serde(default)]
    pub groups: Vec<String>,
    pub source: NodeSource,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProxyGroup {
    pub name: String,
    #[serde(rename = "type")]
    pub group_type: String,
    #[serde(default)]
    pub members: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ImportSource {
    #[serde(default)]
    pub origin: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub final_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fetched_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ImportedProfile {
    pub name: String,
    pub format: String,
    pub node_count: usize,
    #[serde(default)]
    pub nodes: Vec<ProxyNode>,
    #[serde(default)]
    pub groups: Vec<ProxyGroup>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub userinfo: Option<SubscriptionUserinfo>,
    pub source: ImportSource,
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportUrlRequest {
    pub url: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub user_agent: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportTextRequest {
    pub text: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub content_type: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportLinkRequest {
    pub link: String,
    #[serde(default)]
    pub name: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_serializes_canonical_type_field() {
        let node = ProxyNode {
            name: "n1".into(),
            node_type: "ss".into(),
            server: "1.2.3.4".into(),
            port: 8388,
            cipher: Some("aes-256-gcm".into()),
            password: Some("pw".into()),
            uuid: None,
            alter_id: None,
            security: None,
            flow: None,
            network: None,
            tls: false,
            sni: None,
            skip_cert_verify: None,
            alpn: Vec::new(),
            fingerprint: None,
            reality: None,
            ws: None,
            grpc: None,
            obfs: None,
            obfs_password: None,
            groups: Vec::new(),
            source: NodeSource {
                format: "clash".into(),
                origin: "text".into(),
                index: 0,
            },
        };
        let value = serde_json::to_value(&node).unwrap();
        assert_eq!(value["type"], "ss");
        assert_eq!(value["name"], "n1");
        assert!(value.get("alterId").is_none());
        assert_eq!(value["groups"], serde_json::json!([]));
    }
}
