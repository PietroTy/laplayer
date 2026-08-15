import 'dart:io';
import 'package:dio/dio.dart';

void main() async {
  final _dio = Dio();
  try {
    final response = await _dio.get(
      'https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT',
      options: Options(
        validateStatus: (status) => true,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36',
        }
      ),
    );
    
    final html = response.data.toString();
    final match = RegExp(r'"accessToken":"([^"]+)"').firstMatch(html);
    
    if (match != null) {
      print('TOKEN FOUND: ' + match.group(1)!.substring(0, 20) + '...');
    } else {
      print('TOKEN NOT FOUND IN HTML!');
    }
  } catch (e) {
    print('ERROR: $e');
  }
}
