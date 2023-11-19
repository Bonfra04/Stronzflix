import 'package:flutter/material.dart';
import 'package:stronzflix/home.dart';

class Stronzflix extends StatelessWidget {
    const Stronzflix({super.key});

    @override
    Widget build(BuildContext context) {
        return MaterialApp(
            title: 'Stronzflix',
            theme: ThemeData(
                colorScheme: ColorScheme.dark(
                    brightness: Brightness.dark,
                    primary: Colors.orange,
                    background: (Colors.grey[900])!,
                    surface: const Color(0xff121212),
                    surfaceTint: Colors.transparent,
                ),
                useMaterial3: true,
            ),
            home: const HomePage(),
            debugShowCheckedModeBanner: false,
        );
    }
}
