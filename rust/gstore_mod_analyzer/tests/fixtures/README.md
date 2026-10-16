# cert.rs 测试样本（fixtures）

`src/cert.rs` 的单测一律从本目录读取样本，因此「删除 / 破坏某个 fixture → 对应命名测试失败」是可验证的。
所有二进制样本都很小（最大 ~3 KB），生成工具：**OpenSSL 3.0.2**、**keytool (OpenJDK 17)**。

> 说明：`openssl` / `keytool` 会在产物里写入随机盐与密钥，**重新执行下面的命令得到的是行为等价、但字节不同**的文件。
> 本目录提交的是冻结快照；测试断言的是解析结果（状态、字段、指纹），不是字节相等（`wire_payload.hex` / `cert_info_golden.json` 除外，它们是契约快照）。

---

## 1. 叶子证书 / 私钥 / DER（cert.pem, chain.pem, cert.der, key.pem, pkcs8.der, spki.der）

```bash
# 自签名叶子证书 + 私钥（含 SAN/KeyUsage/EKU/BasicConstraints/SKI/AKI/CRL/AIA）
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=example.com/O=Example Org/C=US" \
  -addext "subjectAltName=DNS:example.com,DNS:www.example.com,IP:127.0.0.1,email:admin@example.com,URI:https://example.com/" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth,clientAuth" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid,issuer" \
  -addext "crlDistributionPoints=URI:http://crl.example.com/a.crl" \
  -addext "authorityInfoAccess=OCSP;URI:http://ocsp.example.com,caIssuers;URI:http://ca.example.com/ca.crt"

# 独立自签名 CA（供多证书链 fixture 使用；断言 only is_ca=TRUE）
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 3650 -nodes \
  -subj "/CN=Example CA/O=Example Org/C=US" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

cat cert.pem ca.pem > chain.pem                                   # 2 张证书

openssl x509 -in cert.pem -outform DER -out cert.der              # X.509 DER
openssl pkcs8 -topk8 -nocrypt -in key.pem -outform DER -out pkcs8.der   # PKCS#8 PrivateKeyInfo DER
openssl pkey -in key.pem -pubout -outform DER -out spki.der       # SubjectPublicKeyInfo DER
```

对照值（`pem_single` 断言）：`notBefore=2026-10-16T16:56:31Z`，`notAfter=2036-10-13T16:56:31Z`，
`serial=78853cd0d49c66a421b79748d9133f666b72c698`，
`sha1=E7:F1:35:AF:AB:4D:E2:18:46:2E:A3:62:7E:FA:AF:AA:E4:29:E6:77`，
`sha256=64:77:9E:22:81:E3:C4:89:3A:D6:2A:F0:FD:07:E4:51:FB:FE:69:87:21:69:06:E2:23:C7:9F:6B:63:FF:D0:2E`。

> `pkcs8.der` 必须用 `openssl pkcs8 -topk8` 生成；`openssl pkey -outform DER` 对 RSA 会输出 **PKCS#1**
> （`SEQUENCE{INTEGER,INTEGER,...}`），不会命中 `0x30` 私钥分支，最终落到 `malformed` 而非 `unsupported`。

## 2. PKCS#7（chain.p7b）

```bash
openssl crl2pkcs7 -nocrl -certfile chain.pem -out chain.p7b -outform DER
```

`pkcs7_all_certs` 断言提取出 `example.com` 与 `Example CA` 两张证书。

## 3. PKCS#12（store-empty-pw.p12, store.p12）

这两个文件即 `cert.rs` 中 Todo 4 使用过的真实 const 字节（同源写入文件）。生成命令：

```bash
# 分发用的自签名证书（CN=p12.example.com；与上面的叶子证书不同）
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=p12.example.com/O=Example Org/C=US" -addext "subjectAltName=DNS:p12.example.com"

# 空密码：证书袋可被 p12-keystore 用空密码直接读出 → status=ok / password_protected=false
openssl pkcs12 -export -out store-empty-pw.p12 -nokeys -in cert.pem -passout pass:

# 有密码 changeit：空密码调用 → password_required；changeit → ok；错误密码 → bad_password
openssl pkcs12 -export -out store.p12 -inkey key.pem -in cert.pem -passout pass:changeit
```

关键点：`store-empty-pw.p12` 用 `-passout pass:`（**空**口令）导出且 `-nokeys`（仅证书袋），
因此 `pkcs12_empty_pw_ok` 的「空密码 → `ok`」可用上述命令复现。

## 4. JKS / JCEKS（store.jks, store.jceks）

```bash
# JKS：1 个 PrivateKeyEntry（证书链）+ 1 个 trustedCertEntry，共 2 张 CN=jks.example.com 证书
keytool -genkeypair -alias mykey -keyalg RSA -keysize 2048 \
  -dname "CN=jks.example.com,O=Example Org,C=US" -validity 3650 \
  -keystore store.jks -storetype JKS -storepass changeit -keypass changeit -noprompt
keytool -exportcert -alias mykey -keystore store.jks -storetype JKS \
  -storepass changeit -file mycert.der
keytool -importcert -alias trusted -file mycert.der -keystore store.jks \
  -storetype JKS -storepass changeit -keypass changeit -noprompt

# JCEKS：仅识别为容器（CE CE CE CE），不解析字段
keytool -genkeypair -alias mykey -keyalg RSA -keysize 2048 \
  -dname "CN=jceks.example.com,O=Example Org,C=US" -validity 3650 \
  -keystore store.jceks -storetype JCEKS -storepass changeit -keypass changeit -noprompt
```

`store.jks` 读取口令统一为 `storepass = keypass = changeit`（解析层采用单一密码假设）。

## 5. BKS（store.bks）

BKS 需要 BouncyCastle provider（仓库未内置 jar），参考命令：

```bash
keytool -genkeypair -alias mykey -keyalg RSA -keysize 2048 \
  -dname "CN=bks.example.com,O=Example Org,C=US" -validity 3650 \
  -keystore store.bks -storetype BKS -storepass changeit -keypass changeit -noprompt \
  -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider \
  -providerpath bcprov-jdk18on-*.jar
```

本目录提交的 `store.bks` 是**合成的最小结构**（无需 BC jar）：
`version=1`(4B) + `saltLen=20`(4B) + `salt=0x11×20` + `iterationCount=1000`(4B) + `MAC=0x22×20`(20B)。
解析层只按该结构 + 扩展名识别（`unsupported` / `format="bks"` / 空证书）。

## 6. 损坏 / 空（bad.der, empty.bin, corrupt.p7b, corrupt.p12, corrupt.jks）

```bash
head -c $(( $(wc -c < cert.der)  - 64 )) cert.der  > bad.der    # 截断 DER
: > empty.bin                                                   # 0 字节
head -c $(( $(wc -c < chain.p7b) / 2 ))  chain.p7b  > corrupt.p7b
head -c $(( $(wc -c < store.p12) / 2 ))  store.p12  > corrupt.p12
head -c $(( $(wc -c < store.jks) / 2 ))  store.jks  > corrupt.jks
```

## 7. 共享契约快照（cert_info_golden.json, wire_payload.hex）

- `cert_info_golden.json`：`chain.pem` 的 **真实序列化**结果（`serde_json::to_string_pretty(&CertInfo)`），
  `status` 必须为 `"ok"`。`golden_cert_info_json`（Rust）与 `test/apk_cert_preview_test.dart`（Dart，Todo 19）
  各自读取本文件，经规范化（忽略键序/空白）后断言相等。**不要手改**；如需更新，用真实序列化重新生成。
- `wire_payload.hex`：跨 FFI 线格式契约 `payload = <path> 0x00 <password>` 的具体字节。
  样例：path=`store.p12`、password=`changeit` → hex `73746f72652e703132006368616e67656974`
  （小写、无分隔、文件末尾可有换行，两侧按空白不敏感解析）。

## 8. 测试内联（非文件）样本

- **`ber.p7b` 不是文件**：OpenSSL 无法便捷产出 BER 不定长 PKCS#7。
  `pkcs7_ber_unsupported` 读取 `chain.p7b` 并把长度字节 `p7[1]` 改成 `0x80` 在测试内合成。
- **`random_unrecognized`**：固定字节 `4F 2A 99 00 FF 7E 01`（**不以 `0x30` 开头**，无已知魔数），内联于测试，
  避免落入 DER 分支。
- **`corrupt_p7_malformed` 的 (b) 分支**：合成 `SignedData` 且 `certificates [0]` 为空 → `malformed(Pkcs7)`。
- `pkcs7_ber_unsupported` / `extension_unparseable_still_ok` 的破坏逻辑同样在测试内完成。
