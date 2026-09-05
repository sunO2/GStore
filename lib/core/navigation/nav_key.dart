import 'package:flutter/material.dart';

/// 全局 Navigator key：GoRouter 与 AppDialogs 等无 context overlay 操作共享。
///
/// 独立文件、零业务依赖：router（lib/core/router）、design（AppDialogs）与
/// main 都引用同一实例，避免 design → router → page → design 的循环依赖。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
