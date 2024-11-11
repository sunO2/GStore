import 'package:gstore/core/core.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

import 'state.dart';

class DownloadManagerLogic extends GetxController with GithubRequestMix {
  final DownloadManagerState state = DownloadManagerState();
  final StreamController<List<DownloadStatus>> controller = StreamController();

  @override
  void onReady() async {
    var downloadList =
        await (await downloadDatabase).downloadStatusDao.getAllDownload();
    controller.sink.add(downloadList);
    super.onReady();
  }

  @override
  void onClose() {
    super.onClose();
  }
}
