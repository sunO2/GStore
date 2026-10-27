//! 传感器枚举：Android NDK `ASensorManager`（**只读元数据**）。
//!
//! 仅枚举传感器清单及静态规格：无需运行时权限、无需 `ALooper` / 事件队列。
//! 实时读数（加速度 / 陀螺仪数值等）需要另建事件队列并受权限约束，本模块不采集。
//!
//! 非 Android（宿主机单测）下 [collect] 返回空列表；纯映射函数可独立单测。

use serde::Serialize;

/// 单个传感器的静态信息。
#[derive(Debug, Clone, Serialize)]
pub struct SensorInfo {
    /// 传感器名称（厂商实现名，如 `LSM6DSO Accelerometer`）。
    pub name: String,
    /// 厂商。
    pub vendor: String,
    /// NDK 数值类型（`ASENSOR_TYPE_*` / 厂商自定义 `0x0001xxxx`）。
    pub type_id: i32,
    /// 可读类型名（常见类型中文化；未知 → `其他`）。
    pub type_name: String,
    /// `ASensor_getStringType()`（如 `android.sensor.accelerometer`）；旧设备可能为 `null`。
    pub string_type: Option<String>,
    /// 分辨率（传感器单位）。
    pub resolution: f32,
    /// 最小采样间隔（微秒；越小越快）。
    pub min_delay_us: i32,
    /// FIFO 最大事件数。
    pub fifo_max_event_count: i32,
    /// FIFO 预留事件数。
    pub fifo_reserved_event_count: i32,
    /// 上报模式（`AREPORTING_MODE_*`）。
    pub reporting_mode: i32,
    /// 上报模式可读名。
    pub reporting_mode_name: String,
    /// 是否为唤醒传感器（可在 AP 休眠时唤醒）。
    pub wake_up: bool,
}

/// `perf.sensors` 响应。
#[derive(Debug, Clone, Serialize)]
pub struct SensorsReport {
    pub count: usize,
    pub sensors: Vec<SensorInfo>,
}

/// NDK 传感器类型 → 中文名（未知类型返回 `其他`）。
pub fn type_name(type_id: i32) -> &'static str {
    match type_id {
        1 => "加速度计",
        2 => "磁力计",
        4 => "陀螺仪",
        5 => "光线",
        6 => "气压",
        8 => "距离感应",
        9 => "重力",
        10 => "线性加速度",
        11 => "旋转矢量",
        12 => "相对湿度",
        13 => "环境温度",
        14 => "未校准磁力计",
        15 => "游戏旋转矢量",
        16 => "未校准陀螺仪",
        17 => "显著运动",
        18 => "步伐检测",
        19 => "计步器",
        20 => "地磁旋转矢量",
        21 => "心率",
        28 => "6DoF 姿态",
        29 => "静止检测",
        30 => "运动检测",
        31 => "心跳",
        32 => "动态传感器元数据",
        33 => "附加信息",
        34 => "离体检测",
        35 => "未校准加速度计",
        36 => "折叠角度",
        37 => "头部追踪",
        38 => "有限轴加速度计",
        39 => "有限轴陀螺仪",
        40 => "有限轴未校准加速度计",
        41 => "有限轴未校准陀螺仪",
        42 => "朝向",
        _ => "其他",
    }
}

/// `AREPORTING_MODE_*` → 中文名。
pub fn reporting_mode_name(mode: i32) -> &'static str {
    match mode {
        0 => "连续",
        1 => "变化时",
        2 => "单次",
        3 => "特殊触发",
        _ => "未知",
    }
}

/// 采集传感器清单；非 Android / NDK 不可用 → 空报告（绝不 panic）。
pub fn report() -> SensorsReport {
    let mut sensors = collect();
    sensors.sort_by(|a, b| {
        a.type_id
            .cmp(&b.type_id)
            .then_with(|| a.name.cmp(&b.name))
    });
    SensorsReport {
        count: sensors.len(),
        sensors,
    }
}

#[cfg(target_os = "android")]
fn collect() -> Vec<SensorInfo> {
    android_ffi::collect()
}

#[cfg(not(target_os = "android"))]
fn collect() -> Vec<SensorInfo> {
    Vec::new()
}

#[cfg(target_os = "android")]
mod android_ffi {
    use std::ffi::{c_char, c_float, c_int, CStr};

    use super::{reporting_mode_name, type_name, SensorInfo};

    #[repr(C)]
    struct ASensorManager {
        _private: [u8; 0],
    }

    #[repr(C)]
    struct ASensor {
        _private: [u8; 0],
    }

    #[link(name = "android")]
    extern "C" {
        fn ASensorManager_getInstance() -> *mut ASensorManager;
        fn ASensorManager_getSensorList(
            manager: *mut ASensorManager,
            list: *mut *const *const ASensor,
        ) -> c_int;
        fn ASensor_getName(sensor: *const ASensor) -> *const c_char;
        fn ASensor_getVendor(sensor: *const ASensor) -> *const c_char;
        fn ASensor_getType(sensor: *const ASensor) -> c_int;
        fn ASensor_getStringType(sensor: *const ASensor) -> *const c_char;
        fn ASensor_getResolution(sensor: *const ASensor) -> c_float;
        fn ASensor_getMinDelay(sensor: *const ASensor) -> c_int;
        fn ASensor_getFifoMaxEventCount(sensor: *const ASensor) -> c_int;
        fn ASensor_getFifoReservedEventCount(sensor: *const ASensor) -> c_int;
        fn ASensor_getReportingMode(sensor: *const ASensor) -> c_int;
        fn ASensor_isWakeUpSensor(sensor: *const ASensor) -> bool;
    }

    fn cstr(ptr: *const c_char) -> String {
        if ptr.is_null() {
            return String::new();
        }
        // NDK 保证返回以 NUL 结尾的静态字符串；非法 UTF-8 用替换字符兜底。
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned()
    }

    pub(super) fn collect() -> Vec<SensorInfo> {
        // SAFETY: 全部指针来自 NDK 的只读 API；列表在本次调用内有效，
        // 逐项读取元数据后立即复制为 Rust 字符串，不保留指针。
        unsafe {
            let manager = ASensorManager_getInstance();
            if manager.is_null() {
                return Vec::new();
            }
            let mut list: *const *const ASensor = std::ptr::null();
            let count = ASensorManager_getSensorList(manager, &mut list);
            if count <= 0 || list.is_null() {
                return Vec::new();
            }

            let sensors = std::slice::from_raw_parts(list, count as usize);
            let mut out = Vec::with_capacity(sensors.len());
            for &sensor in sensors {
                if sensor.is_null() {
                    continue;
                }
                let type_id = ASensor_getType(sensor) as i32;
                let raw_type = cstr(ASensor_getStringType(sensor));
                let mode = ASensor_getReportingMode(sensor) as i32;
                out.push(SensorInfo {
                    name: cstr(ASensor_getName(sensor)),
                    vendor: cstr(ASensor_getVendor(sensor)),
                    type_id,
                    type_name: type_name(type_id).to_string(),
                    string_type: if raw_type.is_empty() {
                        None
                    } else {
                        Some(raw_type)
                    },
                    resolution: ASensor_getResolution(sensor) as f32,
                    min_delay_us: ASensor_getMinDelay(sensor) as i32,
                    fifo_max_event_count: ASensor_getFifoMaxEventCount(sensor) as i32,
                    fifo_reserved_event_count: ASensor_getFifoReservedEventCount(sensor)
                        as i32,
                    reporting_mode: mode,
                    reporting_mode_name: reporting_mode_name(mode).to_string(),
                    wake_up: ASensor_isWakeUpSensor(sensor),
                });
            }
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_common_sensor_types() {
        assert_eq!(type_name(1), "加速度计");
        assert_eq!(type_name(4), "陀螺仪");
        assert_eq!(type_name(19), "计步器");
        assert_eq!(type_name(65536), "其他");
    }

    #[test]
    fn maps_reporting_modes() {
        assert_eq!(reporting_mode_name(0), "连续");
        assert_eq!(reporting_mode_name(1), "变化时");
        assert_eq!(reporting_mode_name(2), "单次");
        assert_eq!(reporting_mode_name(9), "未知");
    }

    #[test]
    fn report_is_empty_on_host() {
        let r = report();
        assert_eq!(r.count, r.sensors.len());
    }
}
