//! 判重设计（判重键 + 冲突策略 + 落盘路径兜底）的端到端验证。
//!
//! 这些用例直接对应"下载 id/判重怎么定"的设计决定：
//! - id 是代理键（DB 自增），与业务无关；
//! - dedup_key 才是"什么算同一个下载"；
//! - 换镜像不产生重复任务；
//! - 同一落盘路径不允许两个活动任务。

#[cfg(test)]
mod tests {
    use crate::dedup::{derive_dedup_key, DedupInput, ConflictPolicy};
    use crate::model::TaskStatus;
    use crate::scheduler::{NewTask, Scheduler, SchedulerConfig};
    use crate::store::{self, SharedConn};
    use std::sync::Arc;

    struct Silent;
    impl crate::scheduler::TaskEmitter for Silent {
        fn progress(&self, _e: crate::model::ProgressEvent) {}
        fn terminal(&self, _t: &crate::model::Task) {}
        fn log(&self, _m: &str) {}
    }

    fn harness(cap: usize) -> (Arc<Scheduler>, SharedConn, tokio::runtime::Runtime) {
        let conn = store::open(":memory:").unwrap();
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let sched = Scheduler::new(
            conn.clone(),
            rt.handle().clone(),
            SchedulerConfig {
                max_concurrent: cap,
                ..Default::default()
            },
            Arc::new(Silent),
        );
        sched.start();
        (sched, conn, rt)
    }

    /// 一个"应用下载"的入参：包名 + 版本（身份），URL 只是来源。
    fn app_task(url: &str, dest: &str) -> NewTask {
        NewTask {
            kind: "app".into(),
            resource_id: "com.example.app".into(),
            resource_version: "1.2.3".into(),
            app_id: "com.example.app".into(),
            app_name: "示例应用".into(),
            version: "1.2.3".into(),
            file_name: "app.apk".into(),
            url: url.into(),
            file_path: dest.into(),
            ..Default::default()
        }
    }

    #[test]
    fn mirror_switch_reuses_the_same_task_instead_of_duplicating() {
        let (sched, conn, rt) = harness(1);
        rt.block_on(async {
            // 先用官方源建任务（不会真的下载完成，只验证判重）
            let official = sched
                .add(app_task("https://f-droid.org/repo/app.apk", "/tmp/a1/app.apk"))
                .unwrap();
            // 再"切镜像"重新点一次下载：身份相同 → 必须复用同一条
            let mirror = sched
                .add(app_task("https://mirror.example/fdroid/app.apk", "/tmp/a2/app.apk"))
                .unwrap();

            assert_eq!(
                official.id, mirror.id,
                "换镜像不该产生第二个任务（这正是键里不放 URL 的原因）"
            );
            assert_eq!(mirror.dedup_key, "app:com.example.app:1.2.3:app.apk");
            let all = store::list_tasks(&conn, &[]).unwrap();
            assert_eq!(all.len(), 1, "库里只能有一条");
        });
    }

    #[test]
    fn app_name_locale_change_does_not_affect_identity() {
        // 展示名变了（例如中英文切换）不该改变身份
        let a = app_task("https://x/app.apk", "/tmp/l/app.apk");
        let mut b = a.clone();
        b.app_name = "Example App".into();
        let k = |t: &NewTask| {
            derive_dedup_key(&DedupInput {
                explicit_key: t.dedup_key.clone(),
                kind: t.kind.clone(),
                resource_id: t.resource_id.clone(),
                resource_version: t.resource_version.clone(),
                file_name: t.file_name.clone(),
                url: t.url.clone(),
                dest_path: t.file_path.clone(),
            })
        };
        assert_eq!(k(&a), k(&b), "展示字段（随语言变化）绝不能进判重键");
    }

    #[test]
    fn same_dest_path_cannot_be_held_by_two_active_tasks() {
        let (sched, _conn, rt) = harness(1);
        rt.block_on(async {
            let mut a = app_task("https://x/a.apk", "/tmp/shared/out.apk");
            a.resource_id = "com.a".into();
            a.dedup_key = Some("app:com.a".into());
            sched.add(a).unwrap();

            // 另一个"资源"（不同判重键）却指向同一目标路径 → 必须拒绝
            let mut b = app_task("https://x/b.apk", "/tmp/shared/out.apk");
            b.resource_id = "com.b".into();
            b.dedup_key = Some("app:com.b".into());
            let err = sched.add(b).unwrap_err();
            let msg = format!("{err:?}");
            assert!(
                msg.contains("目标路径"),
                "应给出可读的路径冲突错误，实际：{msg}"
            );
        });
    }

    #[test]
    fn replace_policy_resets_progress_but_keeps_the_same_id() {
        let (sched, conn, rt) = harness(1);
        rt.block_on(async {
            let t = sched.add(app_task("https://x/a.apk", "/tmp/r/a.apk")).unwrap();
            // 伪造一些进度与分段
            let mut cur = store::get_task(&conn, t.id).unwrap().unwrap();
            cur.received = 500;
            cur.total = 1000;
            store::upsert_task(&conn, &cur).unwrap();
            store::save_segments(
                &conn,
                t.id,
                &[crate::model::Segment {
                    index: 0,
                    start_byte: 0,
                    end_byte: 999,
                    received: 500,
                    done: false,
                }],
            )
            .unwrap();

            let mut again = app_task("https://x/a.apk", "/tmp/r/a.apk");
            again.conflict = ConflictPolicy::Replace;
            let t2 = sched.add(again).unwrap();

            assert_eq!(t2.id, t.id, "replace 沿用同一行/同一 id（外部持有的 id 不作废）");
            assert_eq!(t2.received, 0, "replace 必须清零进度");
            assert!(t2.segments.is_empty(), "replace 必须清掉分段");
        });
    }

    #[test]
    fn append_policy_creates_a_second_row_with_a_unique_key() {
        let (sched, conn, rt) = harness(1);
        rt.block_on(async {
            let t1 = sched.add(app_task("https://x/a.apk", "/tmp/p/one.apk")).unwrap();

            // 明确要存第二份：目标路径必须不同（同一路径两个 writer 是被禁止的）
            let mut second = app_task("https://x/a.apk", "/tmp/p/two.apk");
            second.conflict = ConflictPolicy::Append;
            let t2 = sched.add(second).unwrap();

            assert_ne!(t2.id, t1.id, "append 应新建一行");
            assert_eq!(t2.dedup_key, "app:com.example.app:1.2.3:app.apk#2");
            assert_eq!(store::list_tasks(&conn, &[]).unwrap().len(), 2);
        });
    }

    #[test]
    fn append_requires_a_distinct_destination() {
        let (sched, _conn, rt) = harness(1);
        rt.block_on(async {
            sched.add(app_task("https://x/a.apk", "/tmp/q/same.apk")).unwrap();
            let mut second = app_task("https://x/a.apk", "/tmp/q/same.apk");
            second.conflict = ConflictPolicy::Append;
            let err = sched.add(second).unwrap_err();
            assert!(
                format!("{err:?}").contains("目标路径"),
                "append 到同一路径应被拒绝（那不是'两份'，是两个 writer 抢同一文件）"
            );
        });
    }

    #[test]
    fn generic_resource_without_app_fields_works() {
        let (sched, conn, rt) = harness(1);
        rt.block_on(async {
            // 下载不一定是应用：模型文件没有包名/版本
            let model = NewTask {
                kind: "model".into(),
                resource_id: "qwen2-0.5b-q4".into(),
                url: "https://modelscope.cn/models/x/resolve/master/q.bin".into(),
                file_path: "/tmp/m/q.bin".into(),
                ..Default::default()
            };
            let t = sched.add(model).unwrap();
            assert_eq!(t.dedup_key, "model:qwen2-0.5b-q4");
            assert_eq!(t.kind, "model");
            assert_eq!(t.status, TaskStatus::Queued);

            let again = store::find_by_dedup_key(&conn, "model:qwen2-0.5b-q4")
                .unwrap()
                .unwrap();
            assert_eq!(again.id, t.id);
        });
    }
}

/// 用**文件名**区分"同版本多构建"、同时保持"换镜像不重复"。
#[cfg(test)]
mod file_name_identity_tests {
    use crate::dedup::{derive_dedup_key, DedupInput};

    fn base() -> DedupInput {
        DedupInput {
            kind: "app".into(),
            resource_id: "com.pingan.pabank".into(),
            resource_version: "8.9.1".into(),
            file_name: "PABank-Debug-8.9.1-20260915094838.apk".into(),
            url: "https://test-b-fat.pingan.com.cn/a/PABank-Debug-8.9.1-20260915094838.apk".into(),
            dest_path: "/tmp/pabank.apk".into(),
            ..Default::default()
        }
    }

    #[test]
    fn same_version_different_build_file_is_a_distinct_download() {
        // 实测场景：平安渠道包同版本多构建——包名/版本相同，
        // 文件名与 URL 都不同（文件名里带构建时间）。不能互相覆盖。
        let a = base();
        let mut b = base();
        b.file_name = "PABank-Debug-8.9.1-20260916000000.apk".into();
        b.url = "https://test-b-fat.pingan.com.cn/a/PABank-Debug-8.9.1-20260916000000.apk".into();
        assert_ne!(
            derive_dedup_key(&a),
            derive_dedup_key(&b),
            "同版本不同构建被判成同一个下载 → 会互相覆盖"
        );
    }

    #[test]
    fn mirror_switch_keeps_same_identity() {
        // 换镜像：文件名不变、只有域名不同 → 仍应是同一个下载（不产生重复任务）
        let a = base();
        let mut b = base();
        b.url = "https://mirror.example.com/a/PABank-Debug-8.9.1-20260915094838.apk".into();
        assert_eq!(derive_dedup_key(&a), derive_dedup_key(&b));
    }
}
