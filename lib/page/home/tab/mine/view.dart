import 'package:flutter/material.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MinePage extends StatelessWidget {
  TextEditingController controller = TextEditingController();

  MinePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: "输入",
            ),
          ),
          MaterialButton(
            onPressed: () async {
              final SharedPreferencesAsync prefs = SharedPreferencesAsync();
              await prefs.setString("github_token", controller.text);
              DioClient().setAuthorization(controller.text);
            },
            child: Text("保存"),
          )
        ],
      ),
    );
  }

  Future<List<DownloadStatus>> getAll() async {
    var s = await downloadStatusDatabase;
    var dao = s.downloadStatusDao;
    return dao.findAllPeople();
  }
}
