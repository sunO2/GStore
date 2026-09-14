#!/usr/bin/env bash
# =============================================================================
# GStore 渠道包打包脚本
# =============================================================================
# 用法:
#   ./pack.sh                    # 打包 src/ 下全部渠道
#   ./pack.sh pingan vivo        # 打包指定渠道
#   ./pack.sh --clean            # 清理所有生成的 zip 文件
#   ./pack.sh --help             # 显示帮助
#
# 目录结构:
#   src/<channel>/
#   ├── entry.js    (必须: 发现页脚本)
#   ├── detail.js   (必须: 详情页脚本)
#   ├── meta.json   (可选: 渠道元信息)
#   └── icons/      (可选: 图标资源)
#
# 输出: <channel>.zip (与 scripts/channels/ 同级)
# =============================================================================

# 兼容性：检查是否支持 pipefail
if set -o pipefail 2>/dev/null; then
  set -euo pipefail
else
  set -eu
fi

# ==================== 颜色输出 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 工具函数 ====================
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ==================== 帮助信息 ====================
show_help() {
  cat << 'EOF'
GStore 渠道包打包脚本

用法:
  ./pack.sh [选项] [渠道名...]

选项:
  -c, --clean     清理所有生成的 zip 文件
  -h, --help      显示此帮助信息
  -v, --verbose   显示详细输出

参数:
  渠道名          要打包的渠道名称（src/ 下的目录名）
                  不指定则打包全部渠道

示例:
  ./pack.sh                    # 打包全部渠道
  ./pack.sh pingan vivo        # 打包 pingan 和 vivo
  ./pack.sh --clean            # 清理旧 zip 文件
  ./pack.sh -v pingan          # 详细模式打包 pingan

目录结构:
  src/<channel>/
  ├── entry.js    (必须: 发现页脚本)
  ├── detail.js   (必须: 详情页脚本)
  ├── meta.json   (可选: 渠道元信息)
  └── icons/      (可选: 图标资源)

输出:
  <channel>.zip (与 scripts/channels/ 同级)
EOF
}

# ==================== 清理函数 ====================
clean_zips() {
  info "清理生成的 zip 文件..."
  local count=0
  for f in *.zip; do
    if [ -f "$f" ] && [ "$f" != "*.zip" ]; then
      rm -f "$f"
      count=$((count + 1))
    fi
  done
  ok "已清理 $count 个 zip 文件"
}

# ==================== 检查依赖 ====================
check_deps() {
  local missing=()
  command -v node >/dev/null 2>&1 || missing+=("node")
  command -v zip >/dev/null 2>&1 || missing+=("zip")
  command -v unzip >/dev/null 2>&1 || missing+=("unzip")

  if [ ${#missing[@]} -gt 0 ]; then
    error "缺少依赖: ${missing[*]}"
    error "请先安装: sudo apt install ${missing[*]}"
    exit 1
  fi
}

# ==================== 验证渠道源码 ====================
validate_channel() {
  local dir="$1"
  local name
  name=$(basename "$dir")

  # 检查目录是否存在
  if [ ! -d "$dir" ]; then
    error "渠道目录不存在: $dir"
    return 1
  fi

  # 检查必须文件
  if [ ! -f "$dir/entry.js" ]; then
    error "[$name] 缺少 entry.js"
    return 1
  fi

  if [ ! -f "$dir/detail.js" ]; then
    error "[$name] 缺少 detail.js"
    return 1
  fi

  # 语法检查
  info "[$name] 检查 JS 语法..."
  if ! node --check "$dir/entry.js" 2>&1; then
    error "[$name] entry.js 语法错误"
    return 1
  fi
  if ! node --check "$dir/detail.js" 2>&1; then
    error "[$name] detail.js 语法错误"
    return 1
  fi

  # 检查 meta.json (可选)
  if [ -f "$dir/meta.json" ]; then
    if ! node -e "JSON.parse(require('fs').readFileSync('$dir/meta.json', 'utf8'))" 2>&1; then
      error "[$name] meta.json 格式错误"
      return 1
    fi
  fi

  return 0
}

# ==================== 打包单个渠道 ====================
pack_channel() {
  local dir="$1"
  local name
  name=$(basename "$dir")
  local zip_file="$name.zip"

  info "打包 [$name]..."

  # 验证源码
  if ! validate_channel "$dir"; then
    return 1
  fi

  # 删除旧 zip
  rm -f "$zip_file"

  # 收集要打包的文件
  local files=()
  files+=("entry.js")
  files+=("detail.js")

  if [ -f "$dir/meta.json" ]; then
    files+=("meta.json")
  fi

  # 打包 icons/ 目录（如果存在）
  if [ -d "$dir/icons" ]; then
    info "[$name] 包含 icons/ 目录..."
    (cd "$dir" && zip -q -X -r "../../$zip_file" icons/)
    # 追加其他文件到已有的 zip
    (cd "$dir" && zip -q -X "../../$zip_file" "${files[@]}")
  else
    (cd "$dir" && zip -q -X "../../$zip_file" "${files[@]}")
  fi

  # 验证 zip 内容
  if [ ! -f "$zip_file" ]; then
    error "[$name] 打包失败"
    return 1
  fi

  # 显示 zip 内容
  info "[$name] zip 内容:"
  unzip -l "$zip_file" | tail -n +4 | head -n -2 | while IFS= read -r line; do
    echo "  $line"
  done

  # 显示文件大小
  local size
  size=$(du -h "$zip_file" | cut -f1)
  ok "[$name] 打包完成: $zip_file ($size)"
}

# ==================== 主流程 ====================
main() {
  local verbose=false
  local do_clean=false
  local names=()

  # 解析参数
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -c|--clean)
        do_clean=true
        shift
        ;;
      -v|--verbose)
        verbose=true
        shift
        ;;
      -*)
        error "未知选项: $1"
        show_help
        exit 1
        ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done

  # 切换到脚本所在目录
  cd "$(dirname "$0")"

  # 清理模式
  if [ "$do_clean" = true ]; then
    clean_zips
    exit 0
  fi

  # 检查依赖
  check_deps

  # 获取要打包的渠道列表
  if [ ${#names[@]} -eq 0 ]; then
    mapfile -t names < <(find src -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    info "未指定渠道，打包全部: ${names[*]}"
  fi

  # 打包
  local success=0
  local failed=0

  for n in "${names[@]}"; do
    if pack_channel "src/$n"; then
      success=$((success + 1))
    else
      failed=$((failed + 1))
    fi
  done

  # 汇总
  echo ""
  echo "=============================="
  if [ $failed -eq 0 ]; then
    ok "全部打包成功: $success 个渠道"
  else
    warn "打包完成: $success 成功, $failed 失败"
    exit 1
  fi
}

main "$@"
