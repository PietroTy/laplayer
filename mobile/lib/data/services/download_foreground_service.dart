import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Gerencia o Foreground Service de download.
/// Inicia uma notificação persistente para que o Android não mate o processo
/// quando a tela desligar ou o app for para o background durante downloads.
class DownloadForegroundService {
  DownloadForegroundService._();
  static final instance = DownloadForegroundService._();

  bool _initialized = false;

  void _init() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'laplayer_download',
        channelName: 'لاplayer Downloads',
        channelDescription: 'Mantém os downloads ativos em background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,  // Mantém CPU ativa mesmo com tela desligada
        allowWifiLock: true,  // Mantém Wi-Fi ativo durante downloads
      ),
    );
  }

  /// Inicia o foreground service com notificação de download.
  Future<void> start({
    required String playlistName,
    required void Function() onStarted,
  }) async {
    _init();

    try {
      // Android 14+ exige serviceTypes declarado explicitamente
      await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'Baixando músicas',
        notificationText: playlistName,
        callback: _taskEntryPoint,
      );
    } catch (e) {
      // Falha silenciosa — o download continua mesmo sem o foreground service
      print('[DownloadForegroundService] Falha ao iniciar service: $e');
    }

    onStarted();
  }

  /// Atualiza o texto da notificação com o progresso atual.
  void updateNotification(String title, String body) {
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: body,
      );
    } catch (_) {}
  }

  /// Para o foreground service ao terminar todos os downloads.
  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}

@pragma('vm:entry-point')
void _taskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_NoOpHandler());
}

/// Handler mínimo — a lógica de download roda no isolate principal,
/// o service só existe para manter o processo vivo.
class _NoOpHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
