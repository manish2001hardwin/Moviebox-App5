import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'downloads.dart';
import 'library.dart';
import 'native.dart';
import 'screens/home.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  String? fatal;
  try {
    final dir = await getApplicationSupportDirectory();
    Api.init(dir.path);
    await Library.init();
    await Downloads.I.init();
  } catch (e) {
    fatal = '$e';
  }
  runApp(MovieApp(fatal: fatal));
}

class MovieApp extends StatelessWidget {
  final String? fatal;
  const MovieApp({super.key, this.fatal});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Melyqon Movies',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: fatal != null
          ? Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Startup error:\n$fatal', textAlign: TextAlign.center),
                ),
              ),
            )
          : const HomeShell(),
    );
  }
}
