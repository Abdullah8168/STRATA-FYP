/// Generates Phase H placeholder branding PNGs under `lib/assets/branding/`.
///
/// Replace these assets with final artwork before submission.
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final dir = Directory('lib/assets/branding');
  dir.createSync(recursive: true);

  final teal = img.ColorRgb8(0, 191, 165);
  final black = img.ColorRgb8(10, 10, 10);

  void write(String name, img.Image image) {
    File('${dir.path}/$name')
        .writeAsBytesSync(img.encodePng(image), flush: true);
    // ignore: avoid_print
    print('wrote lib/assets/branding/$name');
  }

  final icon1024 = img.Image(width: 1024, height: 1024);
  img.fill(icon1024, color: black);
  img.fillRect(icon1024,
      x1: 80, y1: 360, x2: 944, y2: 664, color: teal);

  write('icon-1024.png', icon1024);

  final foreground = img.Image(width: 432, height: 432);
  img.fill(foreground, color: img.ColorRgb8(0, 0, 0));
  final cx = foreground.width ~/ 2;
  final cy = foreground.height ~/ 2;
  const r = 160;
  img.fillCircle(foreground, x: cx, y: cy, radius: r, color: teal);

  write('icon-foreground.png', foreground);

  final splash = img.Image(width: 1152, height: 1152);
  img.fill(splash, color: black);
  img.fillRect(splash,
      x1: 0, y1: 480, x2: splash.width, y2: 680, color: teal);
  write('splash-foreground.png', splash);

  final a12 = img.Image(width: 1152, height: 1152);
  img.fill(a12, color: black);
  img.fillCircle(a12, x: 576, y: 576, radius: 280, color: teal);
  write('splash-android12.png', a12);
}
