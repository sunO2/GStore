// gstore_contract build.rs：用 prost 编译 envelope.proto 生成代码
// 使用 protoc-bin-vendored（随 cargo 下载预编译 protoc），任何平台/交叉编译无需系统 protoc。

use std::env;
use std::path::PathBuf;

fn main() {
    let proto_file = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("proto")
        .join("envelope.proto");

    // 输出到 OUT_DIR（src/proto_gen 由生成脚本 fallback 使用；常规构建用 OUT_DIR）
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    let protoc = protoc_bin_vendored::protoc_bin_path().expect("vendored protoc");
    env::set_var("PROTOC", &protoc);

    prost_build::Config::new()
        .compile_protos(&[&proto_file], &[proto_file.parent().unwrap()])
        .expect("compile envelope.proto");

    // 记录输出目录供 runtime 定位（prost 生成的模块在此）
    println!("cargo:rerun-if-changed={}", proto_file.display());
    let _ = out_dir;
}