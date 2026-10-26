import 'package:shared_preferences/shared_preferences.dart';

/// Servidor e chave padrão vêm da build, não do código (que é público):
///   flutter build apk --dart-define=LAPLAYER_SERVER=https://... --dart-define=LAPLAYER_KEY=...
/// A versão pública sai sem nenhum dos dois; quem instala preenche em Configurações → Servidor.
/// O que estiver preenchido em Configurações vale mais que o padrão da build.
const defaultServerUrl = String.fromEnvironment('LAPLAYER_SERVER');
const defaultAccessKey = String.fromEnvironment('LAPLAYER_KEY');

Future<String> configuredServerUrl() async {
  final url = ((await SharedPreferences.getInstance()).getString('server_url') ?? '').trim();
  return (url.isNotEmpty ? url : defaultServerUrl).replaceAll(RegExp(r'/+$'), '');
}

Future<String> configuredAccessKey() async {
  final key = ((await SharedPreferences.getInstance()).getString('access_key') ?? '').trim();
  return key.isNotEmpty ? key : defaultAccessKey;
}
