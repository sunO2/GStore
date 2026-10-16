//! 证书解析（PEM / DER X.509；私钥/公钥/容器识别）
//!
//! 契约见 `.omo/plans/apk-browser-cert-preview.md` 的「Frozen JSON schema (CertInfo v1)」。
//! 该 schema 同时被 Rust `Serialize` 与 Dart 解码器引用，字段名/取值不可漂移。
//!
//! ## 关键不变量
//! **任何解析失败（损坏/截断/未知/文件读取失败）都必须返回 `Ok(CertInfo{status=...})`，
//! 绝不返回 `Err`、绝不 panic。** `Err` 只用于 payload 参数错误（在 `lib.rs` 的分发层，Todo 7）。
//! 原因：边界层 `catch_unwind`/`_roundtripJson` 会把 `Err` 吞成「模块不可用」，
//! 从而丢失「这个文件确实是坏证书」的语义。
//!
//! ## 识别顺序（内容优先，扩展名仅作消歧）
//! 去前导空白后：PEM(`-----BEGIN`) → JKS(`FE ED FE ED`) → JCEKS(`CE CE CE CE`) →
//! BKS(`00 00 00 01/02`) → 首字节 `0x30` 时依次尝试 X.509 DER → PKCS#7 → PKCS#12 →
//! DER 私钥(`PrivateKeyInfo`) → DER 公钥(`SubjectPublicKeyInfo`) → 落空为 `malformed`
//! （`0x30` 起头的结构性失败，以及 0 字节空输入）；非空且无任何已知魔数 → `unrecognized`。

use serde::Serialize;

use p12_keystore::{error::Error as P12Error, KeyStore, KeyStoreEntry, Pkcs12ImportPolicy};

use jks::{KeyStore as JksKeyStore, KeyStoreError};

use x509_parser::asn1_rs::{FromDer, Oid};
use x509_parser::certificate::X509Certificate;
use x509_parser::extensions::{DistributionPointName, GeneralName, ParsedExtension};
use x509_parser::objects::oid_registry;
use x509_parser::pem::Pem;
use x509_parser::public_key::PublicKey;
use x509_parser::x509::SubjectPublicKeyInfo;
use x509_parser::parse_x509_certificate;

// ==================== Frozen JSON schema (CertInfo v1) ====================

/// 解析状态（序列化为 snake_case 字符串）
#[allow(dead_code)] // PasswordRequired/BadPassword 由 Todo 4/5 使用
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CertStatus {
    Ok,
    PasswordRequired,
    BadPassword,
    Unrecognized,
    Malformed,
    Unsupported,
}

/// 证书/容器格式（序列化为 snake_case 字符串）
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CertFormat {
    Pem,
    Der,
    Pkcs7,
    Pkcs12,
    Jks,
    Bks,
    Jceks,
    Unknown,
}

/// 顶层结果
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertInfo {
    pub status: CertStatus,
    pub format: CertFormat,
    pub password_protected: bool,
    pub message: String,
    pub certificates: Vec<CertEntry>,
}

/// 单张证书
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertEntry {
    pub subject: CertName,
    pub issuer: CertName,
    pub serial_number_hex: String,
    pub not_before: String,
    pub not_after: String,
    pub signature_algorithm: String,
    pub public_key_algorithm: String,
    pub public_key_bits: usize,
    pub public_key_curve: String,
    pub version: u32,
    pub san: Vec<CertSan>,
    pub subject_key_identifier: String,
    pub authority_key_identifier: String,
    pub key_usage: Vec<String>,
    pub extended_key_usage: Vec<String>,
    pub basic_constraints: CertBasicConstraints,
    pub crl_distribution_points: Vec<String>,
    pub authority_info_access: Vec<CertAia>,
    pub sha256_fingerprint: String,
    pub sha1_fingerprint: String,
    pub pem: String,
}

/// X.509 名称（subject / issuer）
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertName {
    pub common_name: String,
    pub full: String,
    pub fields: Vec<CertNameField>,
}

/// RDN 属性
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertNameField {
    pub oid: String,
    pub name: String,
    pub value: String,
}

/// SAN 条目
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertSan {
    #[serde(rename = "type")]
    pub san_type: String,
    pub value: String,
}

/// BasicConstraints
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertBasicConstraints {
    pub is_ca: bool,
    pub path_len: Option<u32>,
}

/// AuthorityInfoAccess 条目
#[derive(Clone, Debug, Serialize, Default)]
pub struct CertAia {
    #[serde(rename = "type")]
    pub aia_type: String,
    pub url: String,
}

// Status 需要用 Default（default = Malformed 以外的最保守值；仅内部构造用）
impl Default for CertStatus {
    fn default() -> Self {
        CertStatus::Malformed
    }
}

impl Default for CertFormat {
    fn default() -> Self {
        CertFormat::Unknown
    }
}

// ==================== 公共 API ====================

/// 读取文件并解析（IO 失败 → `status=malformed`，**不** Err）
#[allow(dead_code)] // Todo 7 分发层调用
pub fn parse(path: &str, password: &str) -> CertInfo {
    match std::fs::read(path) {
        Ok(bytes) => parse_bytes(&bytes, ext_of(path).as_deref(), password),
        Err(e) => CertInfo {
            status: CertStatus::Malformed,
            format: CertFormat::Unknown,
            message: format!("无法读取文件: {e}"),
            ..Default::default()
        },
    }
}

/// 从字节解析（无文件系统依赖，供单测与分发复用）
#[allow(dead_code)]
pub(crate) fn parse_bytes(bytes: &[u8], ext_hint: Option<&str>, password: &str) -> CertInfo {
    let b = strip_leading_ws(bytes);

    // 1. PEM
    if b.starts_with(b"-----BEGIN") {
        return parse_pem(b);
    }
    // 2. JKS（真实解析：单一密码假设 store=key password；见 parse_jks）
    if b.starts_with(&[0xFE, 0xED, 0xFE, 0xED]) {
        return parse_jks(b, password);
    }
    // 3. JCEKS（无字段解析计划）
    if b.starts_with(&[0xCE, 0xCE, 0xCE, 0xCE]) {
        return unsupported(CertFormat::Jceks, "JCEKS 不支持字段解析（仅识别为容器）");
    }
    // 4. BKS（魔数 + 扩展名/结构消歧）
    if detect_bks(b, ext_hint) {
        return unsupported(CertFormat::Bks, "BKS 不支持字段解析（仅识别为容器）");
    }
    // 5. 0x30 起头：按 DER 分支尝试
    if b.first() == Some(&0x30) {
        return parse_der(b, ext_hint, password);
    }
    // 6. 空输入 → malformed；非空无魔数 → unrecognized
    if b.is_empty() {
        return malformed(CertFormat::Unknown, "空文件：无证书内容");
    }
    unrecognized(CertFormat::Unknown, "无法识别的证书格式")
}

// ==================== PEM ====================

fn parse_pem(b: &[u8]) -> CertInfo {
    let mut certs: Vec<CertEntry> = Vec::new();
    let mut pkcs7_blocks: Vec<Vec<u8>> = Vec::new();
    let mut saw_private = false;
    let mut saw_public = false;
    let mut other_label: Option<String> = None;

    for item in Pem::iter_from_buffer(b) {
        let pem = match item {
            Ok(p) => p,
            Err(_) => continue, // 坏块跳过，尽力而为
        };
        match pem.label.as_str() {
            "CERTIFICATE" | "X509 CERTIFICATE" | "TRUSTED CERTIFICATE" => {
                if let Ok((_, cert)) = parse_x509_certificate(&pem.contents) {
                    certs.push(entry_from_cert(&cert));
                }
            }
            // `BEGIN PKCS7` 块 → 交由 PKCS#7 提取器（下方统一处理）
            "PKCS7" | "PKCS #7 SIGNED DATA" => pkcs7_blocks.push(pem.contents.clone()),
            "PRIVATE KEY" | "RSA PRIVATE KEY" | "EC PRIVATE KEY" | "DSA PRIVATE KEY"
            | "ENCRYPTED PRIVATE KEY" => saw_private = true,
            "PUBLIC KEY" | "RSA PUBLIC KEY" => saw_public = true,
            other => {
                if other_label.is_none() {
                    other_label = Some(other.to_string());
                }
            }
        }
    }

    if !certs.is_empty() {
        return CertInfo {
            status: CertStatus::Ok,
            format: CertFormat::Pem,
            certificates: certs,
            ..Default::default()
        };
    }
    if !pkcs7_blocks.is_empty() {
        let mut all: Vec<CertEntry> = Vec::new();
        let mut ber = false;
        let mut bad: Option<&'static str> = None;
        for block in &pkcs7_blocks {
            match extract_pkcs7(block) {
                Pkcs7Outcome::Certs(mut c) => all.append(&mut c),
                Pkcs7Outcome::BerIndefinite => ber = true,
                Pkcs7Outcome::Malformed => bad = Some("PEM PKCS#7 结构损坏或无可解析证书"),
                Pkcs7Outcome::NotPkcs7 => bad = Some("PEM PKCS#7 块内容不是 SignedData"),
            }
        }
        if !all.is_empty() {
            return CertInfo {
                status: CertStatus::Ok,
                format: CertFormat::Pkcs7,
                certificates: all,
                ..Default::default()
            };
        }
        if ber {
            return unsupported(CertFormat::Pkcs7, "PKCS#7 使用 BER 不定长编码，暂不支持");
        }
        return malformed(CertFormat::Pkcs7, bad.unwrap_or("PEM PKCS#7 未找到证书"));
    }
    if saw_private {
        return unsupported(CertFormat::Pem, "PEM 私钥（不支持解析为证书）");
    }
    if saw_public {
        return unsupported(CertFormat::Pem, "PEM 公钥（不支持解析为证书）");
    }
    if let Some(label) = other_label {
        return unsupported(CertFormat::Pem, &format!("PEM 标签 {label} 不支持解析为证书"));
    }
    malformed(CertFormat::Pem, "PEM 中未找到证书块")
}

// ==================== DER ====================

fn parse_der(der: &[u8], ext_hint: Option<&str>, password: &str) -> CertInfo {
    // 1. X.509 证书
    if let Ok((_, cert)) = parse_x509_certificate(der) {
        return CertInfo {
            status: CertStatus::Ok,
            format: CertFormat::Der,
            certificates: vec![entry_from_cert(&cert)],
            ..Default::default()
        };
    }
    // 2. PKCS#7 / CMS：提取 SignedData 中全部证书
    match extract_pkcs7(der) {
        Pkcs7Outcome::Certs(certs) => {
            return CertInfo {
                status: CertStatus::Ok,
                format: CertFormat::Pkcs7,
                certificates: certs,
                ..Default::default()
            };
        }
        Pkcs7Outcome::BerIndefinite => {
            return unsupported(CertFormat::Pkcs7, "PKCS#7 使用 BER 不定长编码，暂不支持");
        }
        Pkcs7Outcome::Malformed => {
            return malformed(CertFormat::Pkcs7, "PKCS#7 结构损坏或 SignedData 不含证书");
        }
        Pkcs7Outcome::NotPkcs7 => {}
    }
    // 3. PKCS#12：真实解析（p12-keystore）；空密码优先，密码流见 parse_pkcs12
    if detect_pkcs12(der) || matches!(ext_hint, Some("p12") | Some("pfx")) {
        return parse_pkcs12(der, password);
    }
    // 4. DER 私钥（PrivateKeyInfo）
    if is_private_key_info(der) {
        return unsupported(CertFormat::Der, "DER 私钥（PrivateKeyInfo），不解析为证书");
    }
    // 5. DER 公钥（SubjectPublicKeyInfo）
    if SubjectPublicKeyInfo::from_der(der).is_ok() {
        return unsupported(
            CertFormat::Der,
            "DER 公钥（SubjectPublicKeyInfo），不解析为证书",
        );
    }
    // 6. 0x30 起头但什么都认不出 → 结构损坏
    malformed(CertFormat::Der, "DER 结构无法识别：并非有效的 X.509 证书或已知容器")
}

// ==================== PKCS#12 ====================

/// PKCS#12 解析（`p12-keystore`）；决策 #4：证书袋/信任库通常不加密，**先试空密码**。
///
/// 错误映射对照 `p12-keystore 0.4.1` 的实际错误面（`error::Error`）：
/// `MacError`（MAC 校验失败）、`Pkcs5Error`（PBES2 解密失败）、`UnpadError`（PBES1 去填充失败）
/// 均由密码错误/缺失引起；其余（`DerError`/`InvalidVersion`/`X509Error`/…）视为结构损坏。
fn parse_pkcs12(data: &[u8], password: &str) -> CertInfo {
    match try_keystore(data, "") {
        Ok(ks) => {
            let certs = p12_certs(&ks);
            if !certs.is_empty() {
                return pkcs12_result(CertStatus::Ok, certs, false, "");
            }
            if password.is_empty() {
                return malformed(CertFormat::Pkcs12, "PKCS#12 中未找到证书袋");
            }
        }
        Err(e) if p12_password_failure(&e) => {
            if password.is_empty() {
                return pkcs12_result(
                    CertStatus::PasswordRequired,
                    Vec::new(),
                    true,
                    "PKCS#12 受密码保护，需要密码",
                );
            }
        }
        Err(_) => return malformed(CertFormat::Pkcs12, "PKCS#12 结构损坏或无法解析"),
    }

    match try_keystore(data, password) {
        Ok(ks) => {
            let certs = p12_certs(&ks);
            if certs.is_empty() {
                return malformed(CertFormat::Pkcs12, "PKCS#12 中未找到证书袋");
            }
            pkcs12_result(CertStatus::Ok, certs, true, "")
        }
        Err(e) if p12_password_failure(&e) => {
            pkcs12_result(CertStatus::BadPassword, Vec::new(), true, "PKCS#12 密码错误")
        }
        Err(_) => malformed(CertFormat::Pkcs12, "PKCS#12 结构损坏或无法解析"),
    }
}

fn try_keystore(data: &[u8], password: &str) -> std::result::Result<KeyStore, P12Error> {
    KeyStore::from_pkcs12(data, password, Pkcs12ImportPolicy::Raw)
}

fn p12_password_failure(e: &P12Error) -> bool {
    matches!(
        e,
        P12Error::MacError(_) | P12Error::Pkcs5Error(_) | P12Error::UnpadError
    )
}

fn p12_certs(ks: &KeyStore) -> Vec<CertEntry> {
    let mut out = Vec::new();
    for (_, entry) in ks.entries() {
        match entry {
            KeyStoreEntry::Certificate(c) => push_cert(&mut out, c.as_der()),
            KeyStoreEntry::PrivateKeyChain(chain) => {
                for c in chain.certs() {
                    push_cert(&mut out, c.as_der());
                }
            }
            KeyStoreEntry::Secret(_) => {}
        }
    }
    out
}

fn push_cert(out: &mut Vec<CertEntry>, der: &[u8]) {
    if let Ok((_, cert)) = parse_x509_certificate(der) {
        out.push(entry_from_cert(&cert));
    }
}

fn pkcs12_result(
    status: CertStatus,
    certs: Vec<CertEntry>,
    protected: bool,
    msg: &str,
) -> CertInfo {
    CertInfo {
        status,
        format: CertFormat::Pkcs12,
        password_protected: protected,
        message: msg.to_string(),
        certificates: certs,
    }
}

// ==================== JKS ====================

/// JKS 解析（`jks` crate，`default-features=false`）。
///
/// 单一密码假设：store password = key password。`KeyStore::load` 读取全部条目后校验
/// SHA-1 完整性摘要；摘要不匹配（`InvalidDigest`）即密码错误 → `bad_password`。
/// 截断/损坏（IO 或结构错误）→ `malformed`。私钥条目的证书链无需解密私钥即可获取。
fn parse_jks(data: &[u8], password: &str) -> CertInfo {
    let mut ks = JksKeyStore::new();
    match ks.load(data, password.as_bytes()) {
        Ok(()) => {
            let certs = jks_certs(&ks);
            if certs.is_empty() {
                return malformed(CertFormat::Jks, "JKS 中未找到证书");
            }
            CertInfo {
                status: CertStatus::Ok,
                format: CertFormat::Jks,
                certificates: certs,
                ..Default::default()
            }
        }
        Err(KeyStoreError::InvalidDigest) => CertInfo {
            status: CertStatus::BadPassword,
            format: CertFormat::Jks,
            password_protected: true,
            message: "JKS 密码错误".to_string(),
            certificates: Vec::new(),
        },
        Err(_) => malformed(CertFormat::Jks, "JKS 结构损坏或无法解析"),
    }
}

/// 收集 JKS 全部证书：受信证书条目 + 私钥条目的证书链
fn jks_certs(ks: &JksKeyStore) -> Vec<CertEntry> {
    let mut out = Vec::new();
    for alias in ks.aliases() {
        if ks.is_trusted_certificate_entry(&alias) {
            if let Ok(tce) = ks.get_trusted_certificate_entry(&alias) {
                push_cert(&mut out, &tce.certificate.content);
            }
        } else if ks.is_private_key_entry(&alias) {
            if let Ok(chain) = ks.get_private_key_entry_certificate_chain(&alias) {
                for c in chain {
                    push_cert(&mut out, &c.content);
                }
            }
        }
    }
    out
}

// ==================== X.509 → CertEntry（尽力而为） ====================

fn entry_from_cert(cert: &X509Certificate<'_>) -> CertEntry {
    let subject = build_name(cert.subject());
    let issuer = build_name(cert.issuer());

    let serial_number_hex = serial_hex(cert.raw_serial());
    let not_before = fmt_utc(cert.validity().not_before.timestamp());
    let not_after = fmt_utc(cert.validity().not_after.timestamp());

    let sig_oid = &cert.signature_algorithm.algorithm;
    let signature_algorithm = format!("{} ({})", oid_display(sig_oid), sig_oid.to_id_string());

    let public_key = cert.public_key();
    let (public_key_algorithm, public_key_bits, public_key_curve) = match public_key.parsed() {
        Ok(pk) => {
            let alg = match &pk {
                PublicKey::RSA(_) => "RSA",
                PublicKey::EC(_) => "EC",
                PublicKey::DSA(_) => "DSA",
                PublicKey::GostR3410(_) | PublicKey::GostR3410_2012(_) => "GOST",
                PublicKey::Unknown(_) => "",
            };
            let curve = if alg == "EC" {
                public_key
                    .algorithm
                    .parameters
                    .as_ref()
                    .and_then(|p| p.parse_der::<Oid>().ok())
                    .map(|(_, oid)| oid_display(&oid))
                    .unwrap_or_default()
            } else {
                String::new()
            };
            (alg.to_string(), pk.key_size(), curve)
        }
        Err(_) => (String::new(), 0, String::new()),
    };

    let version = cert.version().0 + 1;

    // 扩展：逐个尽力解析，任何一个失败都不影响基础字段
    let mut san: Vec<CertSan> = Vec::new();
    if let Some(ext) = cert.subject_alternative_name().ok().flatten() {
        san = ext.value.general_names.iter().map(san_entry).collect();
    }
    let mut subject_key_identifier = String::new();
    let mut authority_key_identifier = String::new();
    let mut crl_distribution_points: Vec<String> = Vec::new();
    let mut authority_info_access: Vec<CertAia> = Vec::new();
    for ext in cert.iter_extensions() {
        match ext.oid.to_id_string().as_str() {
            "2.5.29.14" => {
                if let ParsedExtension::SubjectKeyIdentifier(ki) = ext.parsed_extension() {
                    subject_key_identifier = colon_hex(ki.0);
                }
            }
            "2.5.29.35" => {
                if let ParsedExtension::AuthorityKeyIdentifier(aki) = ext.parsed_extension() {
                    if let Some(ki) = &aki.key_identifier {
                        authority_key_identifier = colon_hex(ki.0);
                    }
                }
            }
            "2.5.29.31" => {
                if let ParsedExtension::CRLDistributionPoints(dp) = ext.parsed_extension() {
                    for p in &dp.points {
                        if let Some(DistributionPointName::FullName(names)) = &p.distribution_point
                        {
                            for n in names {
                                if let GeneralName::URI(u) = n {
                                    crl_distribution_points.push((*u).to_string());
                                }
                            }
                        }
                    }
                }
            }
            "1.3.6.1.5.5.7.1.1" => {
                if let ParsedExtension::AuthorityInfoAccess(aia) = ext.parsed_extension() {
                    for d in &aia.accessdescs {
                        let t = match d.access_method.to_id_string().as_str() {
                            "1.3.6.1.5.5.7.48.1" => "OCSP",
                            "1.3.6.1.5.5.7.48.2" => "caIssuers",
                            _ => continue,
                        };
                        if let GeneralName::URI(u) = &d.access_location {
                            authority_info_access.push(CertAia {
                                aia_type: t.to_string(),
                                url: (*u).to_string(),
                            });
                        }
                    }
                }
            }
            _ => {}
        }
    }

    let key_usage = cert
        .key_usage()
        .ok()
        .flatten()
        .map(|e| key_usage_names(e.value))
        .unwrap_or_default();
    let extended_key_usage = cert
        .extended_key_usage()
        .ok()
        .flatten()
        .map(|e| eku_names(e.value))
        .unwrap_or_default();
    let basic_constraints = cert
        .basic_constraints()
        .ok()
        .flatten()
        .map(|e| CertBasicConstraints {
            is_ca: e.value.ca,
            path_len: e.value.path_len_constraint,
        })
        .unwrap_or_default();

    let raw = cert.as_raw();
    CertEntry {
        subject,
        issuer,
        serial_number_hex,
        not_before,
        not_after,
        signature_algorithm,
        public_key_algorithm,
        public_key_bits,
        public_key_curve,
        version,
        san,
        subject_key_identifier,
        authority_key_identifier,
        key_usage,
        extended_key_usage,
        basic_constraints,
        crl_distribution_points,
        authority_info_access,
        sha256_fingerprint: sha256_fingerprint(raw),
        sha1_fingerprint: sha1_fingerprint(raw),
        pem: to_pem(raw),
    }
}

fn build_name(name: &x509_parser::x509::X509Name<'_>) -> CertName {
    let mut fields = Vec::new();
    let mut common_name = String::new();
    for attr in name.iter_attributes() {
        let oid = attr.attr_type().to_id_string();
        let value = attr
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|_| String::from_utf8_lossy(attr.as_slice()).to_string());
        if oid == "2.5.4.3" && common_name.is_empty() {
            common_name = value.clone();
        }
        let short = match oid.as_str() {
            "2.5.4.3" => "CN",
            "2.5.4.6" => "C",
            "2.5.4.7" => "L",
            "2.5.4.8" => "ST",
            "2.5.4.10" => "O",
            "2.5.4.11" => "OU",
            "1.2.840.113549.1.9.1" => "emailAddress",
            _ => oid.as_str(),
        }
        .to_string();
        fields.push(CertNameField {
            oid,
            name: short,
            value,
        });
    }
    CertName {
        common_name,
        full: name.to_string(),
        fields,
    }
}

fn san_entry(g: &GeneralName<'_>) -> CertSan {
    let (t, v) = match g {
        GeneralName::DNSName(s) => ("DNS", (*s).to_string()),
        GeneralName::RFC822Name(s) => ("EMAIL", (*s).to_string()),
        GeneralName::URI(s) => ("URI", (*s).to_string()),
        GeneralName::IPAddress(b) => ("IP", ip_to_string(b)),
        other => ("OTHER", other_name(other)),
    };
    CertSan {
        san_type: t.to_string(),
        value: v,
    }
}

fn ip_to_string(b: &[u8]) -> String {
    match b.len() {
        4 => std::net::Ipv4Addr::new(b[0], b[1], b[2], b[3]).to_string(),
        16 => {
            let mut octets = [0u8; 16];
            octets.copy_from_slice(b);
            std::net::Ipv6Addr::from(octets).to_string()
        }
        _ => b.iter().map(|x| format!("{x:02x}")).collect::<Vec<_>>().join(""),
    }
}

fn other_name(g: &GeneralName<'_>) -> String {
    match g {
        GeneralName::OtherName(oid, _) => oid.to_id_string(),
        GeneralName::DirectoryName(n) => n.to_string(),
        GeneralName::RegisteredID(oid) => oid.to_id_string(),
        _ => String::new(),
    }
}

fn key_usage_names(ku: &x509_parser::extensions::KeyUsage) -> Vec<String> {
    let mut out = Vec::new();
    if ku.digital_signature() {
        out.push("digitalSignature".to_string());
    }
    if ku.non_repudiation() {
        out.push("nonRepudiation".to_string());
    }
    if ku.key_encipherment() {
        out.push("keyEncipherment".to_string());
    }
    if ku.data_encipherment() {
        out.push("dataEncipherment".to_string());
    }
    if ku.key_agreement() {
        out.push("keyAgreement".to_string());
    }
    if ku.key_cert_sign() {
        out.push("keyCertSign".to_string());
    }
    if ku.crl_sign() {
        out.push("cRLSign".to_string());
    }
    if ku.encipher_only() {
        out.push("encipherOnly".to_string());
    }
    if ku.decipher_only() {
        out.push("decipherOnly".to_string());
    }
    out
}

fn eku_names(eku: &x509_parser::extensions::ExtendedKeyUsage<'_>) -> Vec<String> {
    let mut out = Vec::new();
    if eku.any {
        out.push("anyExtendedKeyUsage".to_string());
    }
    if eku.server_auth {
        out.push("serverAuth".to_string());
    }
    if eku.client_auth {
        out.push("clientAuth".to_string());
    }
    if eku.code_signing {
        out.push("codeSigning".to_string());
    }
    if eku.email_protection {
        out.push("emailProtection".to_string());
    }
    if eku.time_stamping {
        out.push("timeStamping".to_string());
    }
    if eku.ocsp_signing {
        out.push("OCSPSigning".to_string());
    }
    for oid in &eku.other {
        out.push(oid.to_id_string());
    }
    out
}

// ==================== 极小 DER walker（供魔数/结构检测；Todo 3 复用） ====================

/// `(tag, header_start, value_start, value_end)`
type Tlv = (u8, usize, usize, usize);

/// 读一个定长 DER TLV（不支持不定长 BER）
fn read_tlv(b: &[u8], head: usize) -> Option<Tlv> {
    if head + 2 > b.len() {
        return None;
    }
    let tag = b[head];
    let l0 = b[head + 1];
    let (len, vs) = if l0 & 0x80 == 0 {
        (l0 as usize, head + 2)
    } else {
        let n = (l0 & 0x7f) as usize;
        if n == 0 || n > 4 || b.len().saturating_sub(head) < 2 + n {
            return None;
        }
        let mut v = 0usize;
        for i in 0..n {
            v = (v << 8) | b[head + 2 + i] as usize;
        }
        (v, head + 2 + n)
    };
    let ve = vs.checked_add(len)?;
    if ve > b.len() {
        return None;
    }
    Some((tag, head, vs, ve))
}

/// 遍历 `[start, end)` 内的连续 TLV
fn children(b: &[u8], start: usize, end: usize) -> Vec<Tlv> {
    let mut out = Vec::new();
    let mut off = start;
    while off < end {
        match read_tlv(b, off) {
            Some(t) if t.3 <= end => {
                out.push(t);
                off = t.3;
            }
            _ => break,
        }
    }
    out
}

/// 长度字节是否为 BER 不定长（`0x80`）
fn is_indefinite_len(b: &[u8], head: usize) -> bool {
    head + 2 <= b.len() && b[head + 1] == 0x80
}

enum TlvRead {
    Ok(Tlv),
    Indefinite,
    Fail,
}

/// 读 TLV，并显式区分「BER 不定长」与「读取失败」
fn read_tlv_ex(b: &[u8], head: usize) -> TlvRead {
    if is_indefinite_len(b, head) {
        return TlvRead::Indefinite;
    }
    match read_tlv(b, head) {
        Some(t) => TlvRead::Ok(t),
        None => TlvRead::Fail,
    }
}

enum ChildrenRead {
    Ok(Vec<Tlv>),
    Indefinite,
}

fn children_ex(b: &[u8], start: usize, end: usize) -> ChildrenRead {
    let mut out = Vec::new();
    let mut off = start;
    while off < end {
        match read_tlv_ex(b, off) {
            TlvRead::Ok(t) if t.3 <= end => {
                out.push(t);
                off = t.3;
            }
            TlvRead::Indefinite => return ChildrenRead::Indefinite,
            _ => break,
        }
    }
    ChildrenRead::Ok(out)
}

/// PKCS#7 `SignedData` 的 contentType OID（1.2.840.113549.1.7.2）
const SIGNED_DATA_OID: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02];

/// PKCS#7 提取结果
enum Pkcs7Outcome {
    /// 成功提取到的全部证书（保证非空）
    Certs(Vec<CertEntry>),
    /// 检测到 BER 不定长编码
    BerIndefinite,
    /// 不是 PKCS#7 ContentInfo（首元素 OID 非 signedData）
    NotPkcs7,
    /// 是 PKCS#7，但结构损坏 / SignedData 不含可解析证书
    Malformed,
}

/// 从 PKCS#7 `ContentInfo` 提取 `SignedData` 的 `certificates [0] IMPLICIT SET OF Certificate`（全部证书）
fn extract_pkcs7(der: &[u8]) -> Pkcs7Outcome {
    // ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT SignedData }
    let (t, _, v, e) = match read_tlv_ex(der, 0) {
        TlvRead::Ok(t) => t,
        TlvRead::Indefinite => return Pkcs7Outcome::BerIndefinite,
        TlvRead::Fail => return Pkcs7Outcome::NotPkcs7,
    };
    if t != 0x30 {
        return Pkcs7Outcome::NotPkcs7;
    }
    let kids = match children_ex(der, v, e) {
        ChildrenRead::Ok(k) => k,
        ChildrenRead::Indefinite => return Pkcs7Outcome::BerIndefinite,
    };
    let oid = match kids.iter().find(|c| c.0 == 0x06) {
        Some(o) => o,
        None => return Pkcs7Outcome::NotPkcs7,
    };
    if der.get(oid.2..oid.3) != Some(SIGNED_DATA_OID) {
        return Pkcs7Outcome::NotPkcs7;
    }
    let content = match kids.iter().find(|c| c.0 == 0xa0) {
        Some(c) => *c,
        None => return Pkcs7Outcome::Malformed,
    };
    let (t1, _, v1, e1) = match read_tlv_ex(der, content.2) {
        TlvRead::Ok(t) => t,
        TlvRead::Indefinite => return Pkcs7Outcome::BerIndefinite,
        TlvRead::Fail => return Pkcs7Outcome::Malformed,
    };
    if t1 != 0x30 {
        return Pkcs7Outcome::Malformed;
    }
    let sd = match children_ex(der, v1, e1) {
        ChildrenRead::Ok(k) => k,
        ChildrenRead::Indefinite => return Pkcs7Outcome::BerIndefinite,
    };
    let certs_set = match sd.iter().find(|c| c.0 == 0xa0) {
        Some(c) => *c,
        None => return Pkcs7Outcome::Malformed,
    };
    let cert_tlvs = match children_ex(der, certs_set.2, certs_set.3) {
        ChildrenRead::Ok(k) => k,
        ChildrenRead::Indefinite => return Pkcs7Outcome::BerIndefinite,
    };
    let mut entries: Vec<CertEntry> = Vec::new();
    for ct in cert_tlvs {
        if ct.0 != 0x30 {
            continue;
        }
        if let Ok((_, cert)) = parse_x509_certificate(der.get(ct.1..ct.3).unwrap_or(&[])) {
            entries.push(entry_from_cert(&cert));
        }
    }
    if entries.is_empty() {
        return Pkcs7Outcome::Malformed;
    }
    Pkcs7Outcome::Certs(entries)
}

/// PKCS#12 `PFX`：SEQUENCE{ INTEGER version(3), ContentInfo authSafe, [MacData] }
fn detect_pkcs12(der: &[u8]) -> bool {
    let (t, _, v, e) = match read_tlv(der, 0) {
        Some(x) => x,
        None => return false,
    };
    if t != 0x30 {
        return false;
    }
    let kids = children(der, v, e);
    if kids.len() < 2 {
        return false;
    }
    let ver = kids[0];
    if ver.0 != 0x02 || der.get(ver.2..ver.3) != Some(&[0x03u8][..]) {
        return false;
    }
    kids[1].0 == 0x30
}

/// PKCS#8 `PrivateKeyInfo`：SEQUENCE{ INTEGER 0/1, AlgId SEQUENCE, OCTET STRING }
fn is_private_key_info(der: &[u8]) -> bool {
    let (t, _, v, e) = match read_tlv(der, 0) {
        Some(x) => x,
        None => return false,
    };
    if t != 0x30 {
        return false;
    }
    let kids = children(der, v, e);
    if kids.len() < 3 {
        return false;
    }
    let version_ok = kids[0].0 == 0x02
        && matches!(der.get(kids[0].2..kids[0].3), Some(&[0x00]) | Some(&[0x01]));
    version_ok && kids[1].0 == 0x30 && kids[2].0 == 0x04
}

/// BKS：魔数 `00 00 00 01/02` 且（扩展名 `.bks` 或结构校验：version+saltLen+salt+iterCount+20B MAC）
fn detect_bks(b: &[u8], ext_hint: Option<&str>) -> bool {
    if b.len() < 12 {
        return false;
    }
    let version = u32::from_be_bytes([b[0], b[1], b[2], b[3]]);
    if version != 1 && version != 2 {
        return false;
    }
    if ext_hint == Some("bks") {
        return true;
    }
    let salt_len = u32::from_be_bytes([b[4], b[5], b[6], b[7]]) as usize;
    if salt_len == 0 || salt_len > 64 {
        return false;
    }
    let need = 4 + 4 + salt_len + 4 + 20;
    if b.len() < need {
        return false;
    }
    let ic = 8 + salt_len;
    u32::from_be_bytes([b[ic], b[ic + 1], b[ic + 2], b[ic + 3]]) > 0
}

// ==================== 工具 ====================

fn strip_leading_ws(mut b: &[u8]) -> &[u8] {
    while let Some((&c, rest)) = b.split_first() {
        if c.is_ascii_whitespace() {
            b = rest;
        } else {
            break;
        }
    }
    b
}

#[allow(dead_code)]
fn ext_of(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
}

fn oid_display(oid: &Oid<'_>) -> String {
    oid_registry()
        .get(oid)
        .map(|e| e.sn().to_string())
        .unwrap_or_else(|| oid.to_id_string())
}

fn colon_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len().saturating_mul(3));
    for (i, b) in bytes.iter().enumerate() {
        if i > 0 {
            s.push(':');
        }
        s.push_str(&format!("{b:02X}"));
    }
    s
}

/// 序列号：小写十六进制、无分隔（对齐 schema 示例 `0a1b2c`），去掉符号填充的前导 0x00
fn serial_hex(raw: &[u8]) -> String {
    let s = raw.strip_prefix(&[0x00]).unwrap_or(raw);
    let mut out = String::with_capacity(s.len().saturating_mul(2));
    for b in s {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// RFC3339 UTC：`YYYY-MM-DDTHH:MM:SSZ`
fn fmt_utc(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Howard Hinnant 的 `civil_from_days`（epoch 天数 → (年, 月, 日)）
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn sha256_fingerprint(der: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    colon_hex(&Sha256::digest(der))
}

fn sha1_fingerprint(der: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    colon_hex(&Sha1::digest(der))
}

/// DER → PEM armor（README/前端展示用；自实现 base64，避免新增依赖）
fn to_pem(der: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::from("-----BEGIN CERTIFICATE-----\n");
    let mut line = String::new();
    for chunk in der.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        line.push(T[((n >> 18) & 63) as usize] as char);
        line.push(T[((n >> 12) & 63) as usize] as char);
        line.push(if chunk.len() > 1 {
            T[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        line.push(if chunk.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
        if line.len() >= 64 {
            out.push_str(&line);
            out.push('\n');
            line.clear();
        }
    }
    if !line.is_empty() {
        out.push_str(&line);
        out.push('\n');
    }
    out.push_str("-----END CERTIFICATE-----\n");
    out
}

fn unsupported(format: CertFormat, msg: &str) -> CertInfo {
    CertInfo {
        status: CertStatus::Unsupported,
        format,
        message: msg.to_string(),
        ..Default::default()
    }
}

fn malformed(format: CertFormat, msg: &str) -> CertInfo {
    CertInfo {
        status: CertStatus::Malformed,
        format,
        message: msg.to_string(),
        ..Default::default()
    }
}

fn unrecognized(format: CertFormat, msg: &str) -> CertInfo {
    CertInfo {
        status: CertStatus::Unrecognized,
        format,
        message: msg.to_string(),
        ..Default::default()
    }
}

// ==================== 测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    // 提交的真实样本位于 `tests/fixtures/`（生成命令见同目录 `README.md`）。
    // 测试一律从 fixture 读取，保证「破坏 fixture → 对应测试失败」的真实性；
    // 仅 BER / random-unrecognized / 合成 SignedData 等 openssl 难以产出的形态在测试内联构造。
    fn fixture_path(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    fn fixture(name: &str) -> Vec<u8> {
        let p = fixture_path(name);
        std::fs::read(&p).unwrap_or_else(|e| panic!("read fixture {}: {e}", p.display()))
    }

    fn fixture_str(name: &str) -> String {
        String::from_utf8(fixture(name)).expect("fixture is utf8")
    }

    #[test]
    fn pem_single() {
        let info = parse_bytes(&fixture("cert.pem"), Some("pem"), "");
        assert_eq!(info.status, CertStatus::Ok);
        assert_eq!(info.format, CertFormat::Pem);
        assert_eq!(info.certificates.len(), 1);
        let c = &info.certificates[0];
        assert_eq!(c.subject.common_name, "example.com");
        assert!(c.subject.full.contains("CN=example.com"));
        assert!(!c.issuer.full.is_empty());
        // RFC3339 UTC 精确值（与 `openssl x509 -dates` 对照）
        assert_eq!(c.not_before, "2026-10-16T16:56:31Z");
        assert_eq!(c.not_after, "2036-10-13T16:56:31Z");
        // 序列号：小写无分隔
        assert_eq!(c.serial_number_hex, "78853cd0d49c66a421b79748d9133f666b72c698");
        assert!(c.signature_algorithm.contains("1.2.840.113549.1.1.11"));
        assert_eq!(c.public_key_algorithm, "RSA");
        assert!(c.public_key_bits >= 2048);
        assert_eq!(c.public_key_curve, "");
        assert_eq!(c.version, 3);
        // SAN 覆盖多类型
        assert!(c
            .san
            .iter()
            .any(|s| s.san_type == "DNS" && s.value == "example.com"));
        assert!(c.san.iter().any(|s| s.san_type == "IP" && s.value == "127.0.0.1"));
        assert!(c.san.iter().any(|s| s.san_type == "EMAIL"));
        assert!(c.san.iter().any(|s| s.san_type == "URI"));
        // KeyUsage / EKU / BasicConstraints
        assert!(c.key_usage.iter().any(|k| k == "digitalSignature"));
        assert!(c.key_usage.iter().any(|k| k == "keyEncipherment"));
        assert!(c.extended_key_usage.iter().any(|k| k == "serverAuth"));
        assert!(c.extended_key_usage.iter().any(|k| k == "clientAuth"));
        assert!(!c.basic_constraints.is_ca);
        assert_eq!(c.basic_constraints.path_len, None);
        // AIA / CRL / SKI
        assert!(c
            .authority_info_access
            .iter()
            .any(|a| a.aia_type == "OCSP" && a.url == "http://ocsp.example.com"));
        assert!(c
            .authority_info_access
            .iter()
            .any(|a| a.aia_type == "caIssuers"));
        assert!(c
            .crl_distribution_points
            .iter()
            .any(|u| u == "http://crl.example.com/a.crl"));
        assert!(!c.subject_key_identifier.is_empty());
        // 指纹：大写冒号分隔，与 `openssl x509 -fingerprint` 对照
        assert_eq!(
            c.sha1_fingerprint,
            "E7:F1:35:AF:AB:4D:E2:18:46:2E:A3:62:7E:FA:AF:AA:E4:29:E6:77"
        );
        assert_eq!(
            c.sha256_fingerprint,
            "64:77:9E:22:81:E3:C4:89:3A:D6:2A:F0:FD:07:E4:51:FB:FE:69:87:21:69:06:E2:23:C7:9F:6B:63:FF:D0:2E"
        );
        assert!(c.pem.contains("-----BEGIN CERTIFICATE-----"));
        assert!(c.pem.trim_end().ends_with("-----END CERTIFICATE-----"));
    }

    #[test]
    fn pem_chain_multi() {
        let info = parse_bytes(&fixture("chain.pem"), Some("pem"), "");
        assert_eq!(info.status, CertStatus::Ok);
        assert_eq!(info.format, CertFormat::Pem);
        assert!(
            info.certificates.len() >= 2,
            "链应返回全部证书，实际 {}",
            info.certificates.len()
        );
        // CA 证书 is_ca = true
        assert!(info.certificates.iter().any(|c| c.basic_constraints.is_ca));
        assert!(info
            .certificates
            .iter()
            .any(|c| c.subject.common_name == "Example CA"));
    }

    #[test]
    fn der_single() {
        let info = parse_bytes(&fixture("cert.der"), Some("der"), "");
        assert_eq!(info.status, CertStatus::Ok);
        assert_eq!(info.format, CertFormat::Der);
        assert_eq!(info.certificates.len(), 1);
        assert_eq!(info.certificates[0].subject.common_name, "example.com");
    }

    #[test]
    fn pem_private_key_unsupported() {
        let info = parse_bytes(&fixture("key.pem"), Some("pem"), "");
        assert_eq!(info.status, CertStatus::Unsupported);
        assert_eq!(info.format, CertFormat::Pem);
        assert!(info.message.contains("私钥"), "message={}", info.message);
    }

    #[test]
    fn der_pkcs8_unsupported() {
        let der = fixture("pkcs8.der");
        assert_eq!(der.first(), Some(&0x30), "PKCS#8 DER 应以 SEQUENCE 开头");
        let info = parse_bytes(&der, Some("der"), "");
        assert_eq!(info.status, CertStatus::Unsupported);
        assert_ne!(info.status, CertStatus::Unrecognized);
        assert!(info.message.contains("私钥"), "message={}", info.message);
    }

    #[test]
    fn der_spki_unsupported() {
        let info = parse_bytes(&fixture("spki.der"), Some("der"), "");
        assert_eq!(info.status, CertStatus::Unsupported);
        assert!(info.message.contains("公钥"), "message={}", info.message);
    }

    #[test]
    fn empty_malformed() {
        let info = parse_bytes(&fixture("empty.bin"), None, "");
        assert_eq!(info.status, CertStatus::Malformed);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn random_unrecognized() {
        // 固定字节样本：不以 0x30 开头，也无任何已知魔数（openssl 无法产出此形态 → 内联）
        let bytes = [0x4Fu8, 0x2A, 0x99, 0x00, 0xFF, 0x7E, 0x01];
        assert_ne!(bytes[0], 0x30);
        let info = parse_bytes(&bytes, None, "");
        assert_eq!(info.status, CertStatus::Unrecognized);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn extension_unparseable_still_ok() {
        // 破坏 SAN 扩展的内层内容（保持外框结构有效）→ SAN ParseError，
        // 但基础字段（subject/issuer/validity/serial/SPKI）仍应齐全且 status=ok。
        let der = corrupt_san(&fixture("cert.der"));
        let info = parse_bytes(&der, Some("der"), "");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert_eq!(info.certificates.len(), 1);
        let c = &info.certificates[0];
        assert_eq!(c.subject.common_name, "example.com");
        assert!(!c.not_before.is_empty());
        assert!(!c.serial_number_hex.is_empty());
        assert!(c.public_key_bits >= 2048);
        assert!(c.san.is_empty(), "坏扩展被尽力跳过");
    }

    #[test]
    fn corrupt_der_malformed() {
        // bad.der：截断 DER，0x30 起头但结构不完整 → Ok(malformed)，不 panic 不 Err
        let bytes = fixture("bad.der");
        assert_eq!(bytes.first(), Some(&0x30));
        let info = parse_bytes(&bytes, Some("der"), "");
        assert_eq!(info.status, CertStatus::Malformed);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn serializes_to_schema() {
        let info = parse_bytes(&fixture("cert.pem"), Some("pem"), "");
        let v = serde_json::to_value(&info).expect("serialize");
        assert_eq!(v["status"], "ok");
        assert_eq!(v["format"], "pem");
        assert!(v["password_protected"].is_boolean());
        assert!(v["message"].is_string());
        let cert = &v["certificates"][0];
        for key in [
            "subject",
            "issuer",
            "serial_number_hex",
            "not_before",
            "not_after",
            "signature_algorithm",
            "public_key_algorithm",
            "public_key_bits",
            "public_key_curve",
            "version",
            "san",
            "subject_key_identifier",
            "authority_key_identifier",
            "key_usage",
            "extended_key_usage",
            "basic_constraints",
            "crl_distribution_points",
            "authority_info_access",
            "sha256_fingerprint",
            "sha1_fingerprint",
            "pem",
        ] {
            assert!(cert.get(key).is_some(), "missing schema key: {key}");
        }
        assert_eq!(cert["basic_constraints"]["path_len"], serde_json::Value::Null);
        assert_eq!(cert["subject"]["common_name"], "example.com");
        assert!(cert["subject"]["fields"].is_array());
        assert_eq!(cert["san"][0]["type"].is_string(), true);
    }

    // ---------- 共享金样本：CertInfo JSON + 线格式 payload ----------

    #[test]
    fn golden_cert_info_json() {
        // 用链（多证书）作为金样本；比较时经 serde_json::Value 规范化（忽略键序/空白）。
        let info = parse_bytes(&fixture("chain.pem"), Some("pem"), "");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert!(info.certificates.len() >= 2);
        let got = serde_json::to_value(&info).expect("serialize CertInfo");

        let raw = fixture_str("cert_info_golden.json");
        let golden: serde_json::Value =
            serde_json::from_str(&raw).expect("golden JSON must parse");
        assert_eq!(golden["status"], "ok", "golden status 必须为 ok");
        assert_eq!(got, golden, "chain.pem 序列化必须等于 cert_info_golden.json");
    }

    #[test]
    fn wire_payload_bytes_match() {
        // 跨 FFI 契约（Todo 19 的 Dart 测试读同一文件）：payload = <path> 0x00 <password>
        let path = "store.p12";
        let password = "changeit";
        let mut bytes = Vec::with_capacity(path.len() + 1 + password.len());
        bytes.extend_from_slice(path.as_bytes());
        bytes.push(0x00);
        bytes.extend_from_slice(password.as_bytes());

        let hex = fixture_str("wire_payload.hex");
        assert_eq!(
            bytes,
            hex_decode(hex.trim()),
            "path\\0password 字节必须等于 wire_payload.hex"
        );
    }

    fn hex_decode(s: &str) -> Vec<u8> {
        let digits: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
        assert!(digits.len() % 2 == 0, "hex 长度必须为偶数: {s}");
        digits
            .chunks(2)
            .map(|p| {
                let hi = (p[0] as char).to_digit(16).expect("hex hi");
                let lo = (p[1] as char).to_digit(16).expect("hex lo");
                (hi * 16 + lo) as u8
            })
            .collect()
    }

    // ---------- PKCS#7 ----------

    fn der_wrap(tag: u8, body: &[u8]) -> Vec<u8> {
        let mut out = vec![tag];
        let n = body.len();
        if n < 0x80 {
            out.push(n as u8);
        } else if n <= 0xff {
            out.push(0x81);
            out.push(n as u8);
        } else {
            out.push(0x82);
            out.push((n >> 8) as u8);
            out.push(n as u8);
        }
        out.extend_from_slice(body);
        out
    }

    /// SignedData SEQUENCE（`certificates [0]` 内为完整 Certificate DER 的拼接）
    fn signed_data(certs: &[Vec<u8>]) -> Vec<u8> {
        let version = der_wrap(0x02, &[0x01]);
        let algos = der_wrap(0x31, &[]);
        let encap = der_wrap(0x30, &[]);
        let body: Vec<u8> = certs.iter().flatten().copied().collect();
        let certs_field = der_wrap(0xa0, &body);
        der_wrap(0x30, &[version, algos, encap, certs_field].concat())
    }

    /// 合成 PKCS#7 ContentInfo（仅用于「SignedData 无证书」等 openssl 不产出的形态）
    fn synth_pkcs7(certs: &[Vec<u8>]) -> Vec<u8> {
        let oid = der_wrap(0x06, &[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]);
        let content = der_wrap(0xa0, &signed_data(certs));
        der_wrap(0x30, &[oid, content].concat())
    }

    fn b64(data: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in data.chunks(3) {
            let b0 = chunk[0] as u32;
            let b1 = *chunk.get(1).unwrap_or(&0) as u32;
            let b2 = *chunk.get(2).unwrap_or(&0) as u32;
            let n = (b0 << 16) | (b1 << 8) | b2;
            out.push(T[((n >> 18) & 63) as usize] as char);
            out.push(T[((n >> 12) & 63) as usize] as char);
            out.push(if chunk.len() > 1 {
                T[((n >> 6) & 63) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                T[(n & 63) as usize] as char
            } else {
                '='
            });
        }
        out
    }

    #[test]
    fn pkcs7_all_certs() {
        // 真实 openssl `crl2pkcs7` 产物（DER）：提取全部证书
        let info = parse_bytes(&fixture("chain.p7b"), Some("p7b"), "");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Pkcs7);
        assert!(
            info.certificates.len() >= 2,
            "应返回全部证书，实际 {}",
            info.certificates.len()
        );
        let names: Vec<&str> = info
            .certificates
            .iter()
            .map(|c| c.subject.common_name.as_str())
            .collect();
        assert!(names.contains(&"example.com"), "names={names:?}");
        assert!(names.contains(&"Example CA"), "names={names:?}");
    }

    #[test]
    fn pkcs7_ber_unsupported() {
        // BER 不定长（openssl 不易直接产出 → 把真实 p7b 的长度字节改为 0x80）
        let mut p7 = fixture("chain.p7b");
        assert_eq!(p7[0], 0x30);
        p7[1] = 0x80; // BER 不定长
        let info = parse_bytes(&p7, Some("p7b"), "");
        assert_eq!(info.status, CertStatus::Unsupported);
        assert_eq!(info.format, CertFormat::Pkcs7);
        assert!(
            info.message.contains("BER") || info.message.contains("不定长"),
            "message={}",
            info.message
        );
    }

    #[test]
    fn corrupt_p7_malformed() {
        // (a) 截断的真实 p7b → Malformed，不 panic
        let info = parse_bytes(&fixture("corrupt.p7b"), Some("p7b"), "");
        assert_eq!(info.status, CertStatus::Malformed, "message={}", info.message);
        assert!(info.certificates.is_empty());
        // (b) SignedData 无 certificates → Malformed(Pkcs7)
        let no_certs = synth_pkcs7(&[]);
        let info = parse_bytes(&no_certs, Some("p7b"), "");
        assert_eq!(info.status, CertStatus::Malformed);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn pem_pkcs7_routes_to_extraction() {
        let p7 = fixture("chain.p7b");
        let mut body = String::new();
        for chunk in b64(&p7).as_bytes().chunks(64) {
            body.push_str(std::str::from_utf8(chunk).unwrap());
            body.push('\n');
        }
        let pem = format!("-----BEGIN PKCS7-----\n{body}-----END PKCS7-----\n");
        let info = parse_bytes(pem.as_bytes(), Some("p7b"), "");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Pkcs7);
        assert!(info.certificates.len() >= 2);
    }

    // ---------- PKCS#12 ----------

    #[test]
    fn pkcs12_empty_pw_ok() {
        let info = parse_bytes(&fixture("store-empty-pw.p12"), Some("p12"), "");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Pkcs12);
        assert!(!info.password_protected);
        assert_eq!(info.certificates.len(), 1);
        assert_eq!(info.certificates[0].subject.common_name, "p12.example.com");
    }

    #[test]
    fn pkcs12_password_required() {
        let info = parse_bytes(&fixture("store.p12"), Some("p12"), "");
        assert_eq!(
            info.status,
            CertStatus::PasswordRequired,
            "message={}",
            info.message
        );
        assert_eq!(info.format, CertFormat::Pkcs12);
        assert!(info.password_protected);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn pkcs12_bad_password() {
        let info = parse_bytes(&fixture("store.p12"), Some("p12"), "wrong-password");
        assert_eq!(info.status, CertStatus::BadPassword, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Pkcs12);
        assert!(info.password_protected);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn pkcs12_correct_password_ok() {
        let info = parse_bytes(&fixture("store.p12"), Some("p12"), "changeit");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Pkcs12);
        assert_eq!(info.certificates.len(), 1);
        assert_eq!(info.certificates[0].subject.common_name, "p12.example.com");
    }

    #[test]
    fn corrupt_p12_malformed() {
        let bytes = fixture("corrupt.p12");
        let info = parse_bytes(&bytes, Some("p12"), "");
        assert_eq!(info.status, CertStatus::Malformed, "message={}", info.message);
        assert!(info.certificates.is_empty());
        let info2 = parse_bytes(&bytes, Some("p12"), "changeit");
        assert_eq!(info2.status, CertStatus::Malformed);
    }

    /// 把 SAN 扩展的内层内容首字节改成 0xFF（令其解析失败）
    fn corrupt_san(der: &[u8]) -> Vec<u8> {
        let mut v = der.to_vec();
        let needle = [0x06u8, 0x03, 0x55, 0x1D, 0x11]; // OID 2.5.29.17
        let pos = v.windows(needle.len()).position(|w| w == needle).expect("SAN OID");
        let mut i = pos + needle.len();
        if v[i] == 0x01 {
            i += 3; // critical BOOLEAN
        }
        assert_eq!(v[i], 0x04, "extnValue OCTET STRING");
        let l0 = v[i + 1] as usize;
        let cstart = if l0 & 0x80 == 0 {
            i + 2
        } else {
            let n = l0 & 0x7f;
            i + 2 + n
        };
        v[cstart] = 0xFF; // 破坏内层 SEQUENCE tag
        v
    }

    // ---------- JKS / JCEKS / BKS ----------

    #[test]
    fn jks_ok() {
        let info = parse_bytes(&fixture("store.jks"), Some("jks"), "changeit");
        assert_eq!(info.status, CertStatus::Ok, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Jks);
        assert!(!info.password_protected);
        // PrivateKeyEntry 的证书链 + TrustedCertificateEntry（同一自签名证书）→ 收集到 2 张
        assert!(
            info.certificates.len() >= 2,
            "应同时收集私钥链与受信证书，实际 {}",
            info.certificates.len()
        );
        assert!(info
            .certificates
            .iter()
            .all(|c| c.subject.common_name == "jks.example.com"));
        assert!(info.certificates[0].pem.contains("-----BEGIN CERTIFICATE-----"));
        assert!(!info.certificates[0].sha1_fingerprint.is_empty());
    }

    #[test]
    fn jks_bad_password() {
        let info = parse_bytes(&fixture("store.jks"), Some("jks"), "wrong-password");
        assert_eq!(info.status, CertStatus::BadPassword, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Jks);
        assert!(info.password_protected);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn corrupt_jks_malformed() {
        // 截断（缺失条目/摘要字节）→ IO 错误 → malformed，不 panic 不 Err
        let info = parse_bytes(&fixture("corrupt.jks"), Some("jks"), "changeit");
        assert_eq!(info.status, CertStatus::Malformed, "message={}", info.message);
        assert_eq!(info.format, CertFormat::Jks);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn jceks_unsupported() {
        // 真实 keytool JCEKS（魔数 CE CE CE CE）；仅识别为容器，不解析字段
        let sample = fixture("store.jceks");
        assert_eq!(&sample[..4], &[0xCEu8, 0xCE, 0xCE, 0xCE]);
        let info = parse_bytes(&sample, Some("jceks"), "");
        assert_eq!(info.status, CertStatus::Unsupported);
        assert_eq!(info.format, CertFormat::Jceks);
        assert!(info.message.contains("JCEKS"), "message={}", info.message);
        assert!(info.certificates.is_empty());
    }

    #[test]
    fn bks_unsupported() {
        // BKS 结构：version(4B) + saltLen(4B) + salt + iterationCount(4B) + 20B SHA-1 MAC
        let info = parse_bytes(&fixture("store.bks"), Some("bks"), "");
        assert_eq!(info.status, CertStatus::Unsupported);
        assert_eq!(info.format, CertFormat::Bks);
        assert!(info.certificates.is_empty());
    }
}
