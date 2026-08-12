/// 更新检测时间格式化（纯函数，便于测试）
///
/// - 未检测（null）：'尚未检测'
/// - 1 分钟内：'刚刚'
/// - 1 小时内：'x 分钟前'
/// - 超过 1 小时：实际日期时间 'yyyy-MM-dd HH:mm'
String formatLastChecked(DateTime? last, DateTime now) {
  if (last == null) return '尚未检测';
  final diff = now.difference(last);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${last.year}-${pad(last.month)}-${pad(last.day)} '
      '${pad(last.hour)}:${pad(last.minute)}';
}
