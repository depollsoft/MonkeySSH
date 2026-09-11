import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

Future<String> _buildSolidPngBase64(Color color, int size) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(size, size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return base64.encode(bytes!.buffer.asUint8List());
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<bool> _boundaryHasRed(GlobalKey key) async =>
    await _boundaryRedPixelCount(key) > 0;

Future<int> _boundaryRedPixelCount(GlobalKey key) =>
    _boundaryPixelCount(key, (r, g, b) => r > 150 && g < 90 && b < 90);

/// Counts red pixels within the vertical pixel band [topY, bottomY).
Future<int> _boundaryRedPixelCountInBand(
  GlobalKey key,
  int topY,
  int bottomY,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final shot = await boundary.toImage();
  try {
    final width = shot.width;
    final data = (await shot.toByteData())!;
    var count = 0;
    for (var y = topY; y < bottomY; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        if (i + 4 > data.lengthInBytes) {
          continue;
        }
        final r = data.getUint8(i);
        final g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2);
        if (r > 150 && g < 90 && b < 90) {
          count += 1;
        }
      }
    }
    return count;
  } finally {
    shot.dispose();
  }
}

/// Counts boundary pixels matching [predicate] (r, g, b).
Future<int> _boundaryPixelCount(
  GlobalKey key,
  bool Function(int r, int g, int b) predicate,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final shot = await boundary.toImage();
  try {
    final data = (await shot.toByteData())!;
    var count = 0;
    for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
      if (predicate(
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      )) {
        count += 1;
      }
    }
    return count;
  } finally {
    shot.dispose();
  }
}

bool _isBlue(int r, int g, int b) => b > 150 && r < 90 && g < 90;

bool _isLight(int r, int g, int b) => r > 150 && g > 150 && b > 150;

class _TopResettingScrollController extends ScrollController {
  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    position.correctPixels(0);
  }
}

const _animatedGifBase64 =
    'R0lGODlhAwADAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQE'
    'BwAAACwAAAAAAwADAAAIBwABCBw4MCAAIfkEBA0AAAAsAAAAAAMAAwCBAAD/AAAA'
    'AAAAAAAACAcAAQgcODAgADs=';

/// Builds a PNG whose left half is [left] and right half is [right], used to
/// verify source-rectangle cropping selects the requested region.
Future<String> _buildSplitPngBase64(
  Color left,
  Color right,
  int width, [
  int? height,
]) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final imageHeight = height ?? width;
  final half = width / 2;
  canvas
    ..drawRect(
      Rect.fromLTWH(0, 0, half, imageHeight.toDouble()),
      Paint()..color = left,
    )
    ..drawRect(
      Rect.fromLTWH(half, 0, half, imageHeight.toDouble()),
      Paint()..color = right,
    );
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, imageHeight);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return base64.encode(bytes!.buffer.asUint8List());
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

/// Kitty row/column placeholder diacritics (rowcolumn-diacritics order),
/// enough to drive placeholder grids up to 24 cells tall/wide in tests.
const _kittyDiacritics = <int>[
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
  0x0346,
  0x034A,
  0x034B,
  0x034C,
  0x0350,
  0x0351,
  0x0352,
  0x0357,
  0x035B,
  0x0363,
  0x0364,
  0x0365,
  0x0366,
  0x0367,
  0x0368,
  0x0369,
];

/// Writes the placeholder cells for a single image [row] (all [cols] columns) at
/// the current cursor position, used to redraw individual rows in tests.
String _placeholderRow(int imageId, {required int row, required int cols}) {
  final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
  final r = (imageId >> 16) & 0xFF;
  final g = (imageId >> 8) & 0xFF;
  final b = imageId & 0xFF;
  final buffer = StringBuffer()..write('\x1b[38;2;$r;$g;${b}m');
  for (var col = 0; col < cols; col++) {
    buffer
      ..write(placeholder)
      ..writeCharCode(_kittyDiacritics[row])
      ..writeCharCode(_kittyDiacritics[col]);
  }
  return (buffer..write('\x1b[39m')).toString();
}

/// Builds the Kitty Unicode-placeholder cells for an [imageId] laid out across
/// [rows] x [cols] cells, exactly as a kitty-aware client (e.g. Copilot CLI)
/// emits them: a 24-bit foreground color carrying the image id, then a
/// U+10EEEE cell per position carrying its row/column diacritics.
String _placeholderGrid(int imageId, {required int cols, required int rows}) =>
    List.generate(
      rows,
      (row) => _placeholderRow(imageId, row: row, cols: cols),
    ).join('\r\n');

/// Store-only (`a=t`) and virtual (`a=T,U=1`) images decode lazily, on the
/// first paint that references them. In a real app that paint runs in the real
/// async zone so the decode completes; a widget-test `pump()` runs in the
/// fake-async zone where `dart:ui` decodes never finish. So reference each image
/// inside [WidgetTester.runAsync] (exactly what the painter does — it triggers
/// the deferred decode), wait for it, then pump so the decoded image composites
/// before pixel assertions run.
Future<void> _pumpUntilImagesDecoded(
  WidgetTester tester,
  Terminal terminal,
  List<int> imageIds,
) async {
  await tester.runAsync(() async {
    for (final id in imageIds) {
      terminal.graphics.imageForPlacement(id);
    }
    var waited = 0;
    while (imageIds.any((id) => terminal.graphics.imageById(id) == null) &&
        waited < 2000) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      waited += 20;
    }
  });
  for (final id in imageIds) {
    expect(
      terminal.graphics.imageById(id),
      isNotNull,
      reason: 'image $id must finish decoding before layout assertions',
    );
  }
  await tester.pump();
}

void main() {
  testWidgets('pixel scanners and PNG builders dispose captured resources', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(_graphicsHost(boundaryKey, Terminal()));
    final images = <ui.Image>[];
    final pictures = <ui.Picture>[];
    final onImageCreate = ui.Image.onCreate;
    final onPictureCreate = ui.Picture.onCreate;
    addTearDown(() {
      ui.Image.onCreate = onImageCreate;
      ui.Picture.onCreate = onPictureCreate;
    });
    ui.Image.onCreate = (image) {
      images.add(image);
      onImageCreate?.call(image);
    };

    await tester.runAsync(() async {
      await _boundaryRedPixelCount(boundaryKey);
      await _boundaryPixelCount(boundaryKey, _isBlue);
      await _boundaryRedPixelCountInBand(boundaryKey, 0, 1);
      await expectLater(
        _boundaryPixelCount(boundaryKey, (_, _, _) => throw StateError('scan')),
        throwsStateError,
      );
      await expectLater(
        _boundaryRedPixelCountInBand(boundaryKey, -1, 0),
        throwsRangeError,
      );

      ui.Picture.onCreate = (picture) {
        pictures.add(picture);
        onPictureCreate?.call(picture);
      };
      await _buildSolidPngBase64(Colors.red, 2);
      await _buildSplitPngBase64(Colors.red, Colors.blue, 2);
    });

    expect(images, hasLength(7));
    expect(images.every((image) => image.debugDisposed), isTrue);
    expect(pictures, hasLength(2));
    expect(pictures.every((picture) => picture.debugDisposed), isTrue);
  });

  testWidgets('only visible pending Kitty placeholders start lazy decoding', (
    tester,
  ) async {
    const offscreenImageId = 0x010203;
    const visibleImageId = 0xA5E30B;
    final terminal = Terminal(maxLines: 200)..resize(80, 10);
    // Invalid raw dimensions complete synchronously under widget-test fake
    // async, letting the observer record which pending image paint requested.
    final invalidRawImage = base64.decode('AAAA');

    terminal.graphics.storePendingImage(
      visibleImageId,
      payload: invalidRawImage,
      format: 32,
    );
    terminal.write(_placeholderGrid(visibleImageId, cols: 1, rows: 1));
    for (var row = 0; row < 30; row++) {
      terminal.write('\r\nline $row');
    }

    terminal.graphics.storePendingImage(
      offscreenImageId,
      payload: invalidRawImage,
      format: 32,
    );
    terminal.write(
      '\r\n${_placeholderGrid(offscreenImageId, cols: 1, rows: 1)}',
    );

    final decodeAttempts = <String?>[];
    final previousObserver = terminalGraphicsDecodeObserver;
    terminalGraphicsDecodeObserver =
        ({
          required int payloadBytes,
          required int inflateMicros,
          required int decodeMicros,
          required bool compressed,
          required bool success,
          String? imageId,
          String? action,
          bool? reused,
        }) {
          if (action == 'lazy') {
            decodeAttempts.add(imageId);
          }
        };
    addTearDown(() => terminalGraphicsDecodeObserver = previousObserver);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 180,
          child: MonkeyTerminalView(
            terminal,
            autoResize: false,
            hardwareKeyboardOnly: true,
            liveOutputAutoScroll: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(decodeAttempts, [visibleImageId.toString()]);
    expect(
      terminal.graphics.hasPendingImage(offscreenImageId),
      isTrue,
      reason: 'an image outside the viewport must remain lazily encoded',
    );
  });

  testWidgets('Kitty graphics image is composited into the terminal', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();

    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal.write('\x1b_Ga=T,f=100,c=8,r=4;$png\x1b\\');

      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    final hasRed = await tester.runAsync(() => _boundaryHasRed(boundaryKey));

    expect(
      terminal.graphics.hasPlacements,
      isTrue,
      reason: 'the image should have been decoded and placed',
    );
    expect(
      hasRed,
      isTrue,
      reason: 'the placed red image should be composited into the terminal',
    );
  });

  testWidgets(
    'animated GIF advances, stops, restarts and disposes its ticker',
    (tester) async {
      final boundaryKey = GlobalKey();
      final viewKey = GlobalKey<MonkeyTerminalViewState>();
      final terminal = Terminal();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: MonkeyTerminalView(
                terminal,
                key: viewKey,
                hardwareKeyboardOnly: true,
              ),
            ),
          ),
        ),
      );
      expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);

      await tester.runAsync(() async {
        terminal.write(
          '\x1b_Ga=T,i=51,f=100,c=4,r=2;$_animatedGifBase64\x1b\\',
        );
        var waited = 0;
        while ((terminal.graphics.imageById(51)?.frameCount ?? 0) != 2 &&
            waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
      });
      await tester.pump();

      final image = terminal.graphics.imageById(51)!;
      expect(image.currentFrame, 1);
      expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
      expect(await tester.runAsync(() => _boundaryHasRed(boundaryKey)), isTrue);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 69));
      expect(image.currentFrame, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(image.currentFrame, 2);
      expect(
        await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isBlue)),
        greaterThan(0),
      );

      terminal.write('\x1b_Ga=a,i=51,s=1\x1b\\');
      await tester.pump();
      await tester.pump();
      expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);

      terminal.write('\x1b_Ga=a,i=51,s=3\x1b\\');
      await tester.pump();
      await tester.pump();
      expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('terminal swap starts a visible animation after repaint', (
    tester,
  ) async {
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final firstTerminal = Terminal();
    final secondTerminal = Terminal();

    Widget build(Terminal terminal) => MaterialApp(
      home: SizedBox(
        width: 400,
        height: 300,
        child: MonkeyTerminalView(
          terminal,
          key: viewKey,
          hardwareKeyboardOnly: true,
        ),
      ),
    );

    await tester.pumpWidget(build(firstTerminal));
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);

    await tester.runAsync(() async {
      secondTerminal.write(
        '\x1b_Ga=T,i=57,f=100,c=4,r=2;$_animatedGifBase64\x1b\\',
      );
      var waited = 0;
      while ((secondTerminal.graphics.imageById(57)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });

    await tester.pumpWidget(build(secondTerminal));
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
  });

  testWidgets(
    'animation ticker ignores a placement shifted outside its bounds',
    (tester) async {
      final viewKey = GlobalKey<MonkeyTerminalViewState>();
      final terminal = Terminal();
      await tester.runAsync(() async {
        terminal.write(
          '\x1b_Ga=T,i=58,f=100,c=4,r=2,X=10000;$_animatedGifBase64\x1b\\',
        );
        var waited = 0;
        while ((terminal.graphics.imageById(58)?.frameCount ?? 0) != 2 &&
            waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: MonkeyTerminalView(
              terminal,
              key: viewKey,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(terminal.graphics.placements, hasLength(1));
      expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);
      final image = terminal.graphics.imageById(58)!;
      await tester.pump(const Duration(milliseconds: 100));
      expect(image.currentFrame, 1);
    },
  );

  testWidgets('reduced motion keeps animated terminal images static', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final terminal = Terminal();

    await tester.runAsync(() async {
      terminal.write('\x1b_Ga=T,i=52,f=100,c=4,r=2;$_animatedGifBase64\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(52)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MonkeyTerminalView(
          terminal,
          key: viewKey,
          hardwareKeyboardOnly: true,
        ),
      ),
    );
    final image = terminal.graphics.imageById(52)!;
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);
    expect(image.currentFrame, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(image.currentFrame, 1);
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);
  });

  testWidgets('live Reduce Motion changes resynchronize terminal playback', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final terminal = Terminal();
    await tester.runAsync(() async {
      terminal.write('\x1b_Ga=T,i=60,f=100,c=4,r=2;$_animatedGifBase64\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(60)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MonkeyTerminalView(
          terminal,
          key: viewKey,
          hardwareKeyboardOnly: true,
        ),
      ),
    );
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
  });

  testWidgets('disabled UI transitions do not pause terminal GIFs', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final terminal = Terminal();

    await tester.runAsync(() async {
      terminal.write('\x1b_Ga=T,i=55,f=100,c=4,r=2;$_animatedGifBase64\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(55)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MonkeyTerminalView(
          terminal,
          key: viewKey,
          hardwareKeyboardOnly: true,
        ),
      ),
    );

    final image = terminal.graphics.imageById(55)!;
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(image.currentFrame, 2);
  });

  testWidgets('animated GIF advances through Unicode placeholders', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final terminal = Terminal();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: MonkeyTerminalView(
            terminal,
            key: viewKey,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    terminal
      ..write('\x1b_Ga=T,U=1,i=53,f=100,c=4,r=2;$_animatedGifBase64\x1b\\')
      ..write(_placeholderGrid(53, cols: 4, rows: 2));
    await tester.pump();
    await _pumpUntilImagesDecoded(tester, terminal, const [53]);
    await tester.pump();

    final image = terminal.graphics.imageById(53)!;
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
    expect(image.currentFrame, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(image.currentFrame, 2);
    expect(
      await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isBlue)),
      greaterThan(0),
    );
  });

  testWidgets('Copilot protocol animation survives a TUI redraw', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final terminal = Terminal();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: MonkeyTerminalView(
            terminal,
            key: viewKey,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      final red = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      final blue = await _buildSolidPngBase64(const Color(0xFF0000FF), 24);
      terminal
        ..write(
          '\x1b_Ga=T,i=56,f=100,c=4,r=2,C=1;'
          '$red\x1b\\',
        )
        ..write('\x1b_Ga=a,i=56,r=1,z=70,q=2\x1b\\')
        ..write(
          '\x1b_Ga=f,i=56,f=100,z=70,X=1,q=2;'
          '$blue\x1b\\',
        )
        ..write('\x1b_Ga=a,i=56,s=3,v=1,q=2\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(56)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);

    terminal.write('\x1b[2J\x1b[H\x1b[2Kprompt');
    await tester.pump();
    expect(terminal.graphics.placements, hasLength(1));
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(terminal.graphics.imageById(56)!.currentFrame, 2);
    expect(
      await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isBlue)),
      greaterThan(0),
    );
  });

  testWidgets('animation ticker stops off-screen and resumes when revealed', (
    tester,
  ) async {
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final terminal = Terminal(maxLines: 200);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 160,
          child: MonkeyTerminalView(
            terminal,
            key: viewKey,
            scrollController: scrollController,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      terminal.write('\x1b_Ga=T,i=54,f=100,c=4,r=2;$_animatedGifBase64\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(54)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);

    terminal.write(List.filled(80, 'line\r\n').join());
    await tester.pump();
    await tester.pump();
    expect(scrollController.offset, greaterThan(0));
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);

    scrollController.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
  });

  testWidgets('replacing the scroll controller resyncs animation visibility', (
    tester,
  ) async {
    final viewKey = GlobalKey<MonkeyTerminalViewState>();
    final firstController = ScrollController(keepScrollOffset: false);
    final replacementController = _TopResettingScrollController();
    addTearDown(firstController.dispose);
    addTearDown(replacementController.dispose);
    final terminal = Terminal(maxLines: 200);

    Widget build(ScrollController controller) => MaterialApp(
      home: SizedBox(
        width: 400,
        height: 160,
        child: MonkeyTerminalView(
          terminal,
          key: viewKey,
          scrollController: controller,
          hardwareKeyboardOnly: true,
          liveOutputAutoScroll: false,
        ),
      ),
    );

    await tester.pumpWidget(build(firstController));
    await tester.runAsync(() async {
      terminal.write('\x1b_Ga=T,i=59,f=100,c=4,r=2;$_animatedGifBase64\x1b\\');
      var waited = 0;
      while ((terminal.graphics.imageById(59)?.frameCount ?? 0) != 2 &&
          waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();
    terminal.write(List.filled(80, 'line\r\n').join());
    await tester.pump();
    firstController.jumpTo(firstController.position.maxScrollExtent);
    await tester.pump();
    expect(firstController.offset, greaterThan(0));
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isFalse);

    await tester.pumpWidget(build(replacementController));
    await tester.pump();
    expect(replacementController.offset, 0);
    expect(viewKey.currentState!.graphicsAnimationTickerActive, isTrue);
  });

  testWidgets(
    'Kitty Unicode placeholder image is composited into the terminal',
    (tester) async {
      final boundaryKey = GlobalKey();
      final terminal = Terminal();

      await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
      await tester.pump();

      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal.write('\x1b_Ga=T,i=42,f=100,c=8,r=4;$png\x1b\\');

        var waited = 0;
        while (!terminal.graphics.hasPlacements && waited < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          waited += 20;
        }
      });
      terminal.write('\x1b_Ga=d,d=i,i=42\x1b\\\x1b[H\x1b[2J');
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(terminal.graphics.imageById(42), isNotNull);

      final placeholder = String.fromCharCode(
        kittyGraphicsPlaceholderCodePoint,
      );
      final row = List.filled(8, '$placeholder\u0305\u0305').join();
      terminal.write('\x1b[38;5;42m$row\r\n$row\r\n$row\r\n$row\x1b[39m');
      await tester.pump();

      var hasRed = false;
      await tester.runAsync(() async {
        hasRed = await _boundaryHasRed(boundaryKey);
      });

      expect(
        hasRed,
        isTrue,
        reason: 'the placed red image should replace the Unicode placeholders',
      );
    },
  );

  testWidgets(
    'Kitty virtual placeholder image renders, then dismisses on redraw',
    (tester) async {
      final boundaryKey = GlobalKey();
      final terminal = Terminal();

      await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
      await tester.pump();

      // Copilot CLI emits the image with a virtual placement (U=1) and then
      // draws U+10EEEE placeholder cells to display it — frequently before the
      // image has finished decoding.
      const imageId = 0xA5E30B;
      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal
          ..write('\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\')
          ..write(_placeholderGrid(imageId, cols: 8, rows: 4));
      });
      // Painting the placeholder cells starts the deferred decode.
      await _pumpUntilImagesDecoded(tester, terminal, [imageId]);

      // U=1 must not create a physical placement; the placeholders display it.
      expect(terminal.graphics.hasPlacements, isFalse);
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason: 'the image must composite over the Unicode placeholder cells',
      );

      // Redrawing over the placeholder cells (here, clearing the screen) must
      // dismiss the image immediately rather than leaving it painted until an
      // unrelated repaint.
      terminal.write('\x1b[H\x1b[2J');
      await tester.pump();
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isFalse,
        reason: 'clearing the placeholder cells must dismiss the image',
      );
      expect(
        terminal.graphics.imageById(imageId),
        isNotNull,
        reason: 'the retained image bytes can back a later placeholder redraw',
      );
    },
  );

  testWidgets('Kitty Unicode placeholder image survives a scroll', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    // A short viewport so writing several rows of output scrolls the buffer,
    // which historically detached the placeholder anchors and dropped the image.
    final terminal = Terminal(maxLines: 200);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 120,
              child: RepaintBoundary(
                key: boundaryKey,
                child: MonkeyTerminalView(terminal, hardwareKeyboardOnly: true),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    const imageId = 0xA5E30B;
    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal
        ..write('\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\')
        ..write(_placeholderGrid(imageId, cols: 8, rows: 4));
    });
    await _pumpUntilImagesDecoded(tester, terminal, [imageId]);

    final placeholdersBeforeScroll = terminal.graphics.placeholders.length;
    expect(
      placeholdersBeforeScroll,
      greaterThan(0),
      reason: 'placeholder cells should be tracked after the image is drawn',
    );

    // Emit more lines than the viewport holds so the buffer scrolls.
    for (var i = 0; i < 20; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pump();

    expect(
      terminal.graphics.placeholders.every((p) => p.attached),
      isTrue,
      reason:
          'scrolling must keep placeholder anchors attached, not orphan '
          'them (otherwise the image is pruned and never renders)',
    );
    expect(
      terminal.graphics.placeholders.length,
      placeholdersBeforeScroll,
      reason: 'no placeholder should be spuriously dropped by the scroll',
    );
  });

  testWidgets('Kitty placeholder image is dismissed once mostly overwritten', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();

    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    const imageId = 0xA5E30B;
    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal
        ..write('\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\')
        ..write(_placeholderGrid(imageId, cols: 8, rows: 4));
    });
    await _pumpUntilImagesDecoded(tester, terminal, [imageId]);

    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isTrue,
      reason: 'the fully present image must render',
    );

    // Simulate the way a TUI (e.g. Copilot CLI) tears the image down: it
    // overwrites the grid's cells with other content but, relying on
    // cursor-forward movement, leaves a *scattered* subset untouched (real
    // tear-downs punch holes through the grid rather than cleanly cropping it).
    // Those scattered survivors must not be painted as stale fragments/stripes.
    // Blank a hole out of every grid row so no row stays column-complete and the
    // remaining cells are sparse within their bounding box.
    for (var row = 0; row < 4; row++) {
      terminal
        ..write('\x1b[${row + 1};3H') // mid-row of the 8-wide grid
        ..write('    '); // punch a 4-cell hole
    }
    await tester.pump();

    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isFalse,
      reason:
          'a scattered, holey remnant must be dismissed, not left as '
          'fragments/stripes of the image',
    );
  });

  testWidgets(
    'Kitty placeholder image keeps rendering as it scrolls off the alt-screen',
    (tester) async {
      final boundaryKey = GlobalKey();
      // A short alt-screen (no scrollback): scrolling discards whole rows, so a
      // surviving crop is a smaller but solid rectangle that must keep showing.
      final terminal = Terminal(maxLines: 100);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 360,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: MonkeyTerminalView(
                    terminal,
                    hardwareKeyboardOnly: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const imageId = 0xA5E30B;
      terminal
        ..resize(8, 16)
        ..write('\x1b[?1049h'); // enter the alternate screen
      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal
          ..write('\x1b_Ga=T,U=1,i=$imageId,c=8,r=12,f=100,q=2;$png\x1b\\')
          ..write(_placeholderGrid(imageId, cols: 8, rows: 12));
      });
      await _pumpUntilImagesDecoded(tester, terminal, [imageId]);
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason: 'the full image renders',
      );

      // Scroll the image more than halfway off the top: only its bottom rows
      // remain, as a clean contiguous crop.
      terminal.write('\x1b[16;1H');
      for (var i = 0; i < 8; i++) {
        terminal.write('\n');
      }
      await tester.pump();

      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason:
            'a clean scroll crop must keep rendering even when most of the '
            'image has scrolled off',
      );
    },
  );

  testWidgets(
    'Kitty placeholder image renders its visible crop with off-screen '
    'scrollback cells retained',
    (tester) async {
      // The main screen (unlike the alt screen) keeps scrolled-off rows in the
      // scrollback, so a tall image pushed up the viewport leaves many attached
      // placeholder cells above the fold. The compositor only analyses the
      // visible rows, but the image grid must still be sliced from the full
      // placement, so the on-screen bottom crop renders at the correct scale
      // rather than being dropped or mis-sliced by the off-screen remainder.
      final boundaryKey = GlobalKey();
      final terminal = Terminal(maxLines: 400);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 360,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: MonkeyTerminalView(
                    terminal,
                    hardwareKeyboardOnly: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const imageId = 0xA5E30B;
      terminal.resize(8, 20);
      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal
          ..write('\x1b_Ga=T,U=1,i=$imageId,c=8,r=12,f=100,q=2;$png\x1b\\')
          ..write(_placeholderGrid(imageId, cols: 8, rows: 12));
      });
      await _pumpUntilImagesDecoded(tester, terminal, [imageId]);
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason: 'the full image renders before scrolling',
      );
      final placeholdersBeforeScroll = terminal.graphics.placeholders.length;

      // Push the top of the image above the fold into the scrollback. The rows
      // stay attached (main-screen scrollback), so the off-screen portion is
      // exactly the "many retained placeholders" case the viewport-bounded
      // compositor must handle without dropping the visible crop.
      terminal.write('\x1b[20;1H');
      for (var i = 0; i < 10; i++) {
        terminal.write('\r\n');
      }
      await tester.pump();

      expect(
        terminal.graphics.placeholders.length,
        placeholdersBeforeScroll,
        reason: 'main-screen scrollback must retain the off-screen cells',
      );
      expect(
        terminal.graphics.placeholders.every((p) => p.attached),
        isTrue,
        reason: 'scrolled-off placeholder cells stay attached in scrollback',
      );
      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason:
            'the still-visible bottom crop must keep rendering while most of '
            'the image sits off-screen in the scrollback',
      );
    },
  );

  testWidgets(
    'Kitty same-id image: only the most recent dense copy renders (ghost gone)',
    (tester) async {
      // Reproduces the full-screen-viewer ghost: an image is shown, then the
      // app redraws it at a new position without clearing the old copy. Both
      // copies are fully intact (dense), so density alone cannot tell them
      // apart — only the most recently drawn one should render.
      final boundaryKey = GlobalKey();
      const height = 520.0;
      final terminal = Terminal(maxLines: 100);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: height,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: MonkeyTerminalView(
                    terminal,
                    hardwareKeyboardOnly: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const imageId = 0xA5E30B;
      const viewRows = 22;
      terminal
        ..resize(8, viewRows)
        ..write('\x1b[?1049h');
      await tester.runAsync(() async {
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        terminal.write('\x1b_Ga=T,U=1,i=$imageId,c=8,r=4,f=100,q=2;$png\x1b\\');
        // Older copy near the top (screen rows 1-4).
        for (var row = 0; row < 4; row++) {
          terminal
            ..write('\x1b[${row + 1};1H')
            ..write(_placeholderRow(imageId, row: row, cols: 8));
        }
        // Newer copy lower down (screen rows 14-17), written afterwards. The
        // old copy's cells are left intact (no clear) — exactly the ghost case.
        for (var row = 0; row < 4; row++) {
          terminal
            ..write('\x1b[${row + 14};1H')
            ..write(_placeholderRow(imageId, row: row, cols: 8));
        }
      });
      await _pumpUntilImagesDecoded(tester, terminal, [imageId]);

      // Terminal content has top padding, so check generous bands rather than
      // exact cell rows. The older copy sits in the top ~quarter; the current
      // copy lower down.
      final topBandBottom = (height * 0.32).round();

      final totalRed = await tester.runAsync(
        () => _boundaryRedPixelCount(boundaryKey),
      );
      final ghostRed = await tester.runAsync(
        () => _boundaryRedPixelCountInBand(boundaryKey, 0, topBandBottom),
      );

      expect(
        totalRed,
        greaterThan(100),
        reason: 'the most recent copy must render',
      );
      expect(
        ghostRed,
        lessThan(100),
        reason: 'the older ghost copy of the same image must be dismissed',
      );
      // Punch holes through the old copy while the current copy stays intact.
      for (var row = 0; row < 4; row++) {
        terminal
          ..write('\x1b[${row + 1};3H')
          ..write('    ');
      }
      await tester.pump();
      expect(
        await tester.runAsync(
          () => _boundaryRedPixelCountInBand(boundaryKey, 0, topBandBottom),
        ),
        lessThan(100),
        reason: 'the holey older copy must remain dismissed',
      );
      expect(
        await tester.runAsync(
          () => _boundaryRedPixelCountInBand(
            boundaryKey,
            topBandBottom,
            height.round(),
          ),
        ),
        greaterThan(100),
        reason: 'the intact lower copy must keep rendering',
      );
    },
  );

  testWidgets(
    'Kitty image renders when delivered in chunked, stream-decoded bytes',
    (tester) async {
      final boundaryKey = GlobalKey();
      final terminal = Terminal();

      await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
      await tester.pump();

      await tester.runAsync(() async {
        const imageId = 0xA5E30B;
        final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
        final stream =
            '\x1b_Ga=T,U=1,i=$imageId,f=100,c=8,r=4,q=2;$png\x1b\\'
            '${_placeholderGrid(imageId, cols: 8, rows: 4)}';

        // Mirror the live SSH path: split the UTF-8 *bytes* into small chunks
        // (which can land mid-code-point, e.g. inside a 4-byte U+10EEEE cell or
        // the large APC payload) and run them through a streaming UTF-8 decoder
        // before writing, exactly like Stream.transform(Utf8Decoder) does.
        final bytes = utf8.encode(stream);
        final decoder = const Utf8Decoder(allowMalformed: true)
            .startChunkedConversion(
              ChunkedConversionSink<String>.withCallback((pieces) {
                for (final piece in pieces) {
                  if (piece.isNotEmpty) {
                    terminal.write(piece);
                  }
                }
              }),
            );
        const chunkSize = 7;
        for (var i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize).clamp(0, bytes.length);
          decoder.add(bytes.sublist(i, end));
        }
        decoder.close();
      });
      await _pumpUntilImagesDecoded(tester, terminal, [0xA5E30B]);

      expect(
        await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
        isTrue,
        reason:
            'chunked, stream-decoded delivery must still composite the image',
      );
    },
  );

  testWidgets('Kitty Unicode placeholder resolves high-byte image ids', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();

    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    const imageId = 42 + (2 << 24);
    await tester.runAsync(() async {
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal.write('\x1b_Ga=t,i=$imageId,f=100;$png\x1b\\');
    });
    // Deferred until a placeholder references it.
    expect(terminal.graphics.imageById(imageId), isNull);

    final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
    final row = List.filled(8, '$placeholder\u0305\u0305\u030E').join();
    terminal.write('\x1b[38;5;42m$row\r\n$row\r\n$row\r\n$row\x1b[39m');

    // Painting the placeholders resolves the high-byte id via the low-bits
    // fallback and starts the deferred decode.
    await _pumpUntilImagesDecoded(tester, terminal, [imageId]);

    var hasRed = false;
    await tester.runAsync(() async {
      hasRed = await _boundaryHasRed(boundaryKey);
    });

    expect(
      hasRed,
      isTrue,
      reason:
          'the placeholder color should resolve the retained high-byte image',
    );
  });

  testWidgets('zoom, delete and re-place an image without crashing', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();
    var fontSize = 14.0;

    Widget build() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: RepaintBoundary(
              key: boundaryKey,
              child: MonkeyTerminalView(
                terminal,
                hardwareKeyboardOnly: true,
                textStyle: TerminalStyle(fontSize: fontSize),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pump();

    Future<void> writeImage(Color color) async {
      final png = await _buildSolidPngBase64(color, 24);
      terminal.write('\x1b_Ga=T,f=100,c=8,r=4;$png\x1b\\');
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    }

    await tester.runAsync(() => writeImage(const Color(0xFFFF0000)));
    await tester.pump();
    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isTrue,
      reason: 'image should render after placement',
    );

    // Sweep the font size the way a pinch-zoom does. Rasterizing each frame
    // exercises drawImageRect through the engine; degenerate cell metrics or a
    // disposed image would throw here.
    for (final fs in [9.0, 8.0, 20.0, 32.0, 12.0, 8.0, 16.0]) {
      fontSize = fs;
      await tester.pumpWidget(build());
      await tester.pump();
      await tester.runAsync(() => _boundaryHasRed(boundaryKey));
      expect(tester.takeException(), isNull, reason: 'zoom to $fs crashed');
    }

    // A graphics delete removes the image without disposing it out from under
    // an in-flight frame. ED only clears the surrounding text.
    final imageId = terminal.graphics.placements.single.imageId;
    terminal.write('\x1b_Ga=d,d=I,i=$imageId\x1b\\\x1b[2J\x1b[H');
    await tester.pump();
    expect(terminal.graphics.hasPlacements, isFalse);
    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isFalse,
      reason: 'image should be gone after the graphics delete',
    );
    for (final fs in [10.0, 24.0, 8.0, 14.0]) {
      fontSize = fs;
      await tester.pumpWidget(build());
      await tester.pump();
      await tester.runAsync(() => _boundaryHasRed(boundaryKey));
      expect(
        tester.takeException(),
        isNull,
        reason: 'zoom after delete at $fs crashed',
      );
    }
    expect(
      terminal.graphics.hasPlacements,
      isFalse,
      reason: 'deleted image must not reappear after zoom',
    );

    // A fresh image still renders after the delete.
    await tester.runAsync(() => writeImage(const Color(0xFFFF0000)));
    await tester.pump();
    expect(
      await tester.runAsync(() => _boundaryHasRed(boundaryKey)),
      isTrue,
      reason: 'a new image should render after a delete',
    );
  });

  testWidgets('degenerate font sizes do not crash layout or paint', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal(maxLines: 200);
    var fontSize = 14.0;

    Widget build() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: RepaintBoundary(
              key: boundaryKey,
              child: MonkeyTerminalView(
                terminal,
                hardwareKeyboardOnly: true,
                textStyle: TerminalStyle(fontSize: fontSize),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pump();

    await tester.runAsync(() async {
      terminal.write('\x1b[4:3;58:2::255:60:60mcurly\x1b[0m text gyp\r\n');
      final png = await _buildSolidPngBase64(const Color(0xFFFF0000), 24);
      terminal.write('\x1b_Ga=T,f=100,c=24,r=6;$png\x1b\\');
      var waited = 0;
      while (!terminal.graphics.hasPlacements && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    // A sub-pixel font size used to drive cellSize to ~0 and crash
    // `width ~/ cellSize.width` / `(dstHeight / cellHeight).ceil()`. (NaN/Inf
    // font sizes are prevented upstream by the zoom math; see
    // terminal_screen_zoom_test.dart.)
    for (final fs in [0.01, 0.5, 1.0, 2.0, 8.0]) {
      fontSize = fs;
      await tester.pumpWidget(build());
      await tester.pump();
      await tester.runAsync(() => _boundaryHasRed(boundaryKey));
      expect(
        tester.takeException(),
        isNull,
        reason: 'font size $fs crashed the terminal',
      );
    }
  });

  testWidgets('Kitty placement source crop (x,w) selects the region', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();
    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    await tester.runAsync(() async {
      // 16px image: left half red, right half blue.
      final png = await _buildSplitPngBase64(
        const Color(0xFFFF0000),
        const Color(0xFF0000FF),
        16,
      );
      // Display only the left (red) half via the source crop x=0,w=8.
      terminal.write('\x1b_Ga=T,i=1,f=100,c=6,r=3,x=0,y=0,w=8,h=16;$png\x1b\\');
      var waited = 0;
      while (terminal.graphics.imageById(1) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    expect(
      await tester.runAsync(() => _boundaryRedPixelCount(boundaryKey)),
      greaterThan(0),
      reason: 'the cropped-in red half must render',
    );
    expect(
      await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isBlue)),
      0,
      reason: 'cropping to the left half must exclude the blue right half',
    );
  });

  testWidgets('Kitty source crop scales into a downsampled decoded image', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();
    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    await tester.runAsync(() async {
      // The decoder bounds this 2560px source to 1280px. Crop coordinates
      // remain in the original 2560px Kitty coordinate space.
      final png = await _buildSplitPngBase64(
        const Color(0xFFFF0000),
        const Color(0xFF0000FF),
        2560,
        20,
      );
      terminal.write(
        '\x1b_Ga=T,i=2,f=100,c=6,r=3,x=1280,y=0,w=1280,h=20;$png\x1b\\',
      );
      var waited = 0;
      while (terminal.graphics.imageById(2) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
    });
    await tester.pump();

    final stored = terminal.graphics.imageById(2)!;
    expect(stored.sourceWidth, 2560);
    expect(stored.image.width, 1280);
    expect(
      await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isBlue)),
      greaterThan(0),
      reason: 'the logical right-half crop must render from the decoded image',
    );
    expect(
      await tester.runAsync(() => _boundaryRedPixelCount(boundaryKey)),
      0,
      reason: 'the logical crop must exclude the source image left half',
    );
  });

  testWidgets('Kitty placement z-index orders images, ignoring write order', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();
    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    await tester.runAsync(() async {
      final red = await _buildSolidPngBase64(const Color(0xFFFF0000), 16);
      final blue = await _buildSolidPngBase64(const Color(0xFF0000FF), 16);
      terminal
        ..write('\x1b_Ga=t,i=1,f=100;$red\x1b\\')
        ..write('\x1b_Ga=t,i=2,f=100;$blue\x1b\\')
        // Place blue (z=1) first, then red (z=0) at the same spot. Z-order, not
        // write order, must decide: blue stays on top.
        ..write('\x1b[H\x1b_Ga=p,i=2,c=6,r=3,z=1,C=1\x1b\\')
        ..write('\x1b[H\x1b_Ga=p,i=1,c=6,r=3,z=0,C=1\x1b\\');
    });
    // The placements reference both images, so painting decodes them.
    await _pumpUntilImagesDecoded(tester, terminal, [1, 2]);

    expect(
      await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isBlue)),
      greaterThan(0),
      reason: 'the higher z-index (blue) must be visible on top',
    );
    expect(
      await tester.runAsync(() => _boundaryRedPixelCount(boundaryKey)),
      0,
      reason: 'the lower z-index (red) must be fully covered by blue',
    );
  });

  testWidgets('Kitty placement with negative z renders behind the text', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final terminal = Terminal();
    await tester.pumpWidget(_graphicsHost(boundaryKey, terminal));
    await tester.pump();

    await tester.runAsync(() async {
      final red = await _buildSolidPngBase64(const Color(0xFFFF0000), 16);
      // z=-1 draws behind text; keep the cursor home (C=1) so the text lands on
      // the same cells the image covers.
      terminal.write('\x1b_Ga=T,i=1,f=100,c=6,r=1,z=-1,C=1;$red\x1b\\');
      var waited = 0;
      while (terminal.graphics.imageById(1) == null && waited < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        waited += 20;
      }
      // Bright white glyphs over the image's cells.
      terminal.write('\x1b[97mWWWW');
    });
    await tester.pump();

    expect(
      await tester.runAsync(() => _boundaryRedPixelCount(boundaryKey)),
      greaterThan(0),
      reason: 'the behind-text image must still render',
    );
    expect(
      await tester.runAsync(() => _boundaryPixelCount(boundaryKey, _isLight)),
      greaterThan(0),
      reason: 'the text must paint on top of a negative-z image',
    );
  });
}

Widget _graphicsHost(GlobalKey key, Terminal terminal) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 300,
        child: RepaintBoundary(
          key: key,
          child: MonkeyTerminalView(terminal, hardwareKeyboardOnly: true),
        ),
      ),
    ),
  ),
);
