import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Handler chamado pelo FlutterForegroundTask quando o serviço está ativo.
/// Na v8+, este handler roda no isolate principal (não separado).
@pragma('vm:entry-point')
void startDownloadForegroundTask() {
  FlutterForegroundTask.setTaskHandler(DownloadTaskHandler());
}

class DownloadTaskHandler extends TaskHandler {
  // Callback injetado pelo DownloadForegroundService para executar o download
  static void Function()? _onStart;
  static void Function()? _onStop;

  static void setCallbacks({
    required void Function() onStart,
    required void Function() onStop,
  }) {
    _onStart = onStart;
    _onStop = onStop;
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _onStart?.call();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Nenhuma ação periódica necessária — os downloads são event-driven
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _onStop?.call();
  }

  @override
  void onReceiveData(Object data) {
    // Recebe mensagens do isolate principal se necessário
  }
}
