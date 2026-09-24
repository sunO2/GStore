import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class WebPage extends StatelessWidget {
  const WebPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // body: WebViewWidget(controller: logic.controller),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Icon(TablerIcons.x),
      ),
    );
  }
}