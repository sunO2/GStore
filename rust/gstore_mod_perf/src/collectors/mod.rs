//! 纯逻辑采集器集合。
//!
//! 每个子模块都可独立单测（fixture 字符串 → 解析/换算断言），I/O 与纯计算分离：
//! `parse_*`/`scale_*` 为纯函数，`collect()` 只负责读 `/proc`、`/sys` 并调用纯函数。

pub mod app_activity;
pub mod app_crash;
pub mod app_dumps;
pub mod app_info;
pub mod app_power;
pub mod app_render;
pub mod app_smaps;
pub mod app_startup;
pub mod battery;
pub mod battery_health;
pub mod cooling;
pub mod cpu;
pub mod device;
pub mod gpu;
pub mod memory;
pub mod network;
pub mod pressure;
pub mod processes;
pub mod storage;
pub mod thermal;
pub mod util;
