import 'package:gstore/core/core.dart';
// import 'package:webview_flutter/webview_flutter.dart';
import 'state.dart';

class WebPageLogic extends GetxController with GithubRequestMix {
  final WebPageState state = WebPageState();
  // WebViewController controller = WebViewController()
  //   ..setJavaScriptMode(JavaScriptMode.unrestricted)
  //   ..setNavigationDelegate(
  //     NavigationDelegate(
  //       onProgress: (int progress) {
  //         // Update loading bar.
  //       },
  //       onPageStarted: (String url) {},
  //       onPageFinished: (String url) {},
  //       onHttpError: (HttpResponseError error) {},
  //       onWebResourceError: (WebResourceError error) {},
  //       onNavigationRequest: (NavigationRequest request) {
  //         log(request.url);
  //         if (request.url.startsWith('https://www.youtube.com/')) {
  //           return NavigationDecision.prevent;
  //         }
  //         return NavigationDecision.navigate;
  //       },
  //     ),
  //   )
  //   ..loadRequest(Uri.parse(
  //       "https://github.com/${Get.arguments.user}/${Get.arguments.repositories}"));
}
