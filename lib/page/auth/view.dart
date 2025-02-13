import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'logic.dart';
import 'state.dart';

class AuthPage extends StatelessWidget {
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(AuthPageLogic());
    return Scaffold(
      body: InAppWebView(
        onWebViewCreated: (controller) {
          logic.webViewController = controller;
        },
        initialSettings:
            InAppWebViewSettings(isInspectable: false, javaScriptEnabled: true),
      ),
      floatingActionButton: Obx(() {
        if (logic.state.status.value == AuthStatus.initial) {
          return FloatingActionButton.extended(
            onPressed: () => logic.getDeviceCode(),
            label: const Text("立即登陆"),
          );
        }

        final progress = logic.state.remainingSeconds.value / 900;
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: logic.copyVerificationCode,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '验证码: ${logic.state.verificationCode.value}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(
                            width: 4,
                          ),
                          const Icon(
                            Icons.copy,
                            size: 10,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: progress,
                                backgroundColor: Colors.grey[300],
                              ),
                              Text(
                                '${(logic.state.remainingSeconds.value / 60).floor()}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
