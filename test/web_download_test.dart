import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_download.dart';

void main() {
  test('优先使用 suggestedFilename', () {
    expect(
      resolveWebDownloadFileName(
        suggestedFilename: 'termux.apk',
        mimeType: 'application/vnd.android.package-archive',
        url: Uri.parse('https://example.com/download?id=1'),
      ),
      'termux.apk',
    );
  });

  test('解析 Content-Disposition（含 UTF-8 文件名）', () {
    expect(
      resolveWebDownloadFileName(
        contentDisposition:
            "attachment; filename*=UTF-8''%E5%AE%89%E8%A3%85%E5%8C%85.apk",
        url: Uri.parse('https://example.com/file'),
      ),
      '安装包.apk',
    );
    expect(
      resolveWebDownloadFileName(
        contentDisposition: 'attachment; filename="report 2026.pdf"; size=1',
        url: Uri.parse('https://example.com/file'),
      ),
      'report 2026.pdf',
    );
  });

  test('回退到 URL 最后一段', () {
    expect(
      resolveWebDownloadFileName(
        url: Uri.parse('https://example.com/files/app-v1.2.apk?token=abc'),
      ),
      'app-v1.2.apk',
    );
  });

  test('没有后缀时按 MIME 补齐', () {
    expect(
      resolveWebDownloadFileName(
        suggestedFilename: 'download',
        mimeType: 'application/vnd.android.package-archive',
        url: Uri.parse('https://example.com/x'),
      ),
      'download.apk',
    );
  });

  test('替换非法字符并限制长度', () {
    final name = resolveWebDownloadFileName(
      suggestedFilename: 'a/b:c*?"<>|d'.padRight(200, 'x'),
      url: Uri.parse('https://example.com/x'),
    );
    expect(name.contains('/'), isFalse);
    expect(name.contains(':'), isFalse);
    expect(name.length, lessThanOrEqualTo(120));
  });

  test('全部缺失时给出时间戳文件名', () {
    final name = resolveWebDownloadFileName(
      url: Uri.parse('https://example.com/'),
    );
    expect(name, startsWith('download_'));
  });
}
