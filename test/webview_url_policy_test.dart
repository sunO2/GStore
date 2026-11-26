import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/webview_url_policy.dart';

void main() {
  test('主框架只允许公网 http/https', () async {
    final policy = WebViewUrlPolicy(enforcePublicHosts: false);
    expect(await policy.allowMainFrame(Uri.parse('https://example.com/')), true);
    expect(await policy.allowMainFrame(Uri.parse('http://example.com/')), true);
    expect(await policy.allowMainFrame(Uri.parse('file:///etc/passwd')), false);
    expect(await policy.allowMainFrame(Uri.parse('content://x/y')), false);
    expect(await policy.allowMainFrame(Uri.parse('javascript:alert(1)')), false);
    expect(await policy.allowMainFrame(Uri.parse('data:text/html,x')), false);
  });

  test('子资源允许 data/blob，仍拒绝本地与危险 scheme', () async {
    final policy = WebViewUrlPolicy(enforcePublicHosts: false);
    expect(await policy.allowSubresource(Uri.parse('data:image/png;base64,AA')), true);
    expect(await policy.allowSubresource(Uri.parse('blob:https://example.com/x')), true);
    expect(await policy.allowSubresource(Uri.parse('file:///etc/passwd')), false);
    expect(await policy.allowSubresource(Uri.parse('intent://x')), false);
  });

  test('默认策略拒绝回环/私网和带 userinfo 的 URL', () async {
    final policy = WebViewUrlPolicy();
    expect(await policy.allowMainFrame(Uri.parse('http://127.0.0.1/')), false);
    expect(await policy.allowMainFrame(Uri.parse('http://10.0.0.1/')), false);
    expect(await policy.allowMainFrame(Uri.parse('http://169.254.169.254/')), false);
    expect(
      await policy.allowMainFrame(Uri.parse('https://user:pass@example.com/')),
      false,
    );
    expect(
      await policy.allowMainFrame(Uri.parse('https://93.184.216.34/')),
      true,
    );
  });
}
