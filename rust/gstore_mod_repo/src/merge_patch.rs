//! RFC 7396 JSON Merge Patch
//!
//! F-Droid 的增量更新（index-v2 的 diff 文件）就是这个格式：
//! 客户端把 diff 合并到本地基线的索引 JSON 上，得到最新索引。
//!
//! 规则（RFC 7396）：
//! - patch 是对象、target 也是对象 → 逐键递归；键值为 `null` 表示**删除**该键
//! - 其它情况 → 直接用 patch 替换 target
//!
//! 自己实现而不引依赖：逻辑只有十几行，且可用规范自带的用例验证。

use serde_json::Value;

/// 就地应用 merge patch
pub fn apply(target: &mut Value, patch: &Value) {
    match (target, patch) {
        (Value::Object(t), Value::Object(p)) => {
            for (key, value) in p {
                if value.is_null() {
                    // 显式 null = 删除该键（RFC 7396 §2）
                    t.remove(key);
                } else {
                    apply(t.entry(key.clone()).or_insert(Value::Null), value);
                }
            }
        }
        (t, p) => {
            *t = p.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rfc7396_example_1_replaces_scalars_and_arrays() {
        // 规范 §1 示例：数组不递归合并，整体替换
        let mut target = json!({"a":"b","c":{"d":"e","f":"g"}});
        apply(&mut target, &json!({"a":"z","c":{"f":null}}));
        assert_eq!(target, json!({"a":"z","c":{"d":"e"}}));
    }

    #[test]
    fn rfc7396_example_2_array_is_replaced_wholesale() {
        let mut target = json!({"a":["b"],"c":"d"});
        apply(&mut target, &json!({"a":"z"}));
        assert_eq!(target, json!({"a":"z","c":"d"}));

        let mut target = json!({"a":["b"],"c":"d"});
        apply(&mut target, &json!({"a":["c","d","e"]}));
        assert_eq!(target, json!({"a":["c","d","e"],"c":"d"}));
    }

    #[test]
    fn rfc7396_example_3_new_nested_object() {
        let mut target = json!({"a":{"b":"c"}});
        apply(&mut target, &json!({"a":{"b":"d","c":null}}));
        assert_eq!(target, json!({"a":{"b":"d"}}));

        let mut target = json!({"a":[{"b":"c"}]});
        apply(&mut target, &json!({"a":[1]}));
        assert_eq!(target, json!({"a":[1]}));
    }

    #[test]
    fn null_creates_then_removes_key() {
        let mut target = json!({"a":"b"});
        apply(&mut target, &json!({"b":"c"}));
        assert_eq!(target, json!({"a":"b","b":"c"}));

        let mut target = json!({"a":"b","b":"c"});
        apply(&mut target, &json!({"b":null}));
        assert_eq!(target, json!({"a":"b"}));
    }

    #[test]
    fn non_object_patch_replaces_everything() {
        let mut target = json!({"a":"b"});
        apply(&mut target, &json!("string"));
        assert_eq!(target, json!("string"));
    }

    #[test]
    fn packages_map_merges_per_package_without_touching_others() {
        // 贴近 F-Droid diff 的真实形态：packages 是包名 → 应用对象的映射
        let mut target = json!({
            "packages": {
                "com.a": {"suggestedVersionCode": 1, "versions": {"1": {"file": {"size": 10}}}},
                "com.b": {"suggestedVersionCode": 5}
            },
            "repo": {"name": "R", "timestamp": 100}
        });
        let patch = json!({
            "packages": {
                "com.a": {"suggestedVersionCode": 2, "versions": {"2": {"file": {"size": 20}}}},
                "com.c": {"suggestedVersionCode": 1}
            },
            "repo": {"timestamp": 200}
        });
        apply(&mut target, &patch);
        // com.b 未被 patch 触及 → 保留
        assert_eq!(target["packages"]["com.b"]["suggestedVersionCode"], json!(5));
        // com.a 被合并：versions 递归合并（键 "1" 保留、"2" 新增）
        assert_eq!(target["packages"]["com.a"]["suggestedVersionCode"], json!(2));
        assert!(target["packages"]["com.a"]["versions"]["1"].is_object());
        assert_eq!(
            target["packages"]["com.a"]["versions"]["2"]["file"]["size"],
            json!(20)
        );
        assert_eq!(target["packages"]["com.c"]["suggestedVersionCode"], json!(1));
        assert_eq!(target["repo"]["name"], json!("R"));
        assert_eq!(target["repo"]["timestamp"], json!(200));
    }
}
