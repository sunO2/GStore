/// Typed failure for an unavailable download core/module.
///
/// The download bundle is Rust-only: there is no Dart fallback. When the
/// bootstrap gate cannot acquire the `download` module (not bundled, ABI
/// mismatch, mount/instance failure), callers observe this exception carrying
/// [code] = `CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`.
///
/// Extends [StateError] so existing callers that only distinguish "state error"
/// keep working while the typed code becomes observable via [toString].
class DownloadModuleUnavailableException extends StateError {
  /// Stable, Dart-observable error code (also emitted by the Rust bridge).
  static const String code = 'CORE_E_DOWNLOAD_MODULE_UNAVAILABLE';

  /// Underlying cause (typically `ModuleInstallFailedException`), when known.
  final Object? cause;

  DownloadModuleUnavailableException([this.cause])
      : super('RustDownloadService: download 模块不可用');

  @override
  String toString() =>
      '$code: $message${cause == null ? '' : ' ($cause)'}';
}
