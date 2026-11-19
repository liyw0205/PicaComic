import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/file_type.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:share_plus/share_plus.dart';

import '../foundation/app.dart';

///保存图片
Future<void> saveImage(File file) async {
  try {
    final imageSaver = ImageGallerySaver();
    var data = await file.readAsBytes();
    var type = detectFileType(data);
    var fileName = file.name;
    if (!fileName.contains('.')) {
      fileName += type.ext;
    }
    if (App.isAndroid || App.isIOS) {
      await imageSaver.saveImage(data);
      showToast(message: "已保存".tl);
    } else if (App.isDesktop) {
      final String? path =
          (await getSaveLocation(suggestedName: fileName))?.path;
      if (path != null) {
        final mimeType = type.mime;
        final XFile xFile =
            XFile.fromData(data, mimeType: mimeType, name: fileName);
        await xFile.saveTo(path);
      }
    }
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "Save Image", "${safeNetworkError(e)}\n$s");
    showToast(message: "保存失败".tl);
  }
}

Future<String> persistentCurrentImage(File file) async {
  final data = await file.readAsBytes();
  final name = file.name;
  final extensionIndex = name.lastIndexOf('.');
  final extension = extensionIndex > 0 ? name.substring(extensionIndex) : '';
  final digest = sha256.convert(data);
  final newFile = File("${App.dataPath}/images/$digest$extension");
  if (!(await newFile.exists())) {
    await newFile.parent.create(recursive: true);
    await newFile.writeAsBytes(data, flush: true);
  }
  return newFile.path;
}

Future<void> shareImage(File file) async {
  try {
    await Share.shareXFiles([XFile(file.path)]);
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "Share Image", "${safeNetworkError(e)}\n$s");
    showToast(message: "分享失败".tl);
  }
}
