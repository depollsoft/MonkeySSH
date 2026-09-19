import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

Future<String> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = Paint();
  const colors = [
    Color(0xFFF44336),
    Color(0xFFFF9800),
    Color(0xFFFFEB3B),
    Color(0xFF4CAF50),
    Color(0xFF2196F3),
    Color(0xFF9C27B0),
    Color(0xFF00BCD4),
  ];
  for (var i = 0; i < colors.length; i++) {
    canvas.drawRect(Rect.fromLTWH(i * 8, 0, 8, 24), paint..color = colors[i]);
  }
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(56, 24);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return base64.encode(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Future<String> _demoPayload() async {
  const esc = '\x1b';
  const reset = '$esc[0m';
  final image = await _png();
  return [
    '\r\n1) Truecolor via colon sub-parameters\r\n',
    '   $esc[38:2::255:80:80mred$reset  $esc[38:2::80:255:120mgreen$reset  $esc[38:2::90:160:255mblue$reset\r\n',
    '\r\n2) 256-color via colon form\r\n',
    '   $esc[38:5:202m#202$reset $esc[38:5:51m#51$reset $esc[38:5:201m#201$reset $esc[38:5:46m#46$reset\r\n',
    '\r\n3) Underline styles\r\n',
    '   $esc[4:1msingle$reset   $esc[4:2mdouble$reset   $esc[4:3mcurly$reset   $esc[4:4mdotted$reset   $esc[4:5mdashed$reset\r\n',
    '   $esc[21mdouble underline via SGR 21$reset\r\n',
    '\r\n4) Colored underline\r\n',
    '   $esc[4:3;58:2::255:60:60mred curly (error)$reset   $esc[4:3;58:5:226myellow curly (warning)$reset\r\n',
    '   $esc[4;58:2::90:160:255mblue straight underline$reset\r\n',
    '\r\n5) Overline\r\n',
    '   $esc[53moverlined text$reset\r\n',
    '\r\n6) Strikethrough\r\n',
    '   $esc[9mcrossed out$reset\r\n',
    '\r\n7) Conceal\r\n',
    '   password: [$esc[8mhunter2 is concealed$reset]\r\n',
    '\r\n8) Combinations\r\n',
    '   $esc[1;3;4:3;38:2::255:120:0mbold + italic + curly underline + truecolor$reset\r\n',
    '   $esc[9;53mstrikethrough + overline$reset\r\n',
    '\r\n9) Inline image\r\n',
    '${esc}_Ga=T,f=100,c=24,r=6;$image$esc\\',
    '\r\n\r\n10) Desktop notifications\r\n',
    '    Sending OSC 9...\r\n',
    '$esc]9;MonkeySSH: build finished\x07',
    '    Sending OSC 777...\r\n',
    '$esc]777;notify;Deploy complete;3 services updated\x07',
    '    Sending OSC 99...\r\n',
    '$esc]99;i=1:d=0;Tests passed$esc\\',
    '$esc]99;i=1:p=body;412 ok, 0 failed$esc\\',
    '\r\nprompt % ',
  ].join();
}

void registerMonkeyTerminalDemoReplayTests() {
  group('monkey_terminal_demo_replay', () {
    testWidgets(
      'demo payload survives repeated replay clears and zoom sweeps',
      (tester) async {
        final key = GlobalKey();
        final terminal = Terminal(maxLines: 10000);
        var fontSize = 14.0;
        final payload = (await tester.runAsync(_demoPayload))!;

        Widget build() => MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: MonkeyTerminalView(
                terminal,
                hardwareKeyboardOnly: true,
                textStyle: TerminalStyle(fontSize: fontSize),
              ),
            ),
          ),
        );

        await tester.pumpWidget(build());
        await tester.pump();

        Future<void> raster() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            await image.toByteData();
          } finally {
            image.dispose();
          }
        }

        // Initial demo.
        terminal.write(payload);
        await tester.pump();
        await tester.runAsync(raster);
        expect(tester.takeException(), isNull);

        for (var cycle = 0; cycle < 5; cycle++) {
          // MonkeyMux replay clear + retained history.
          terminal
            ..write('\x1b[H\x1b[2J\x1b[3J')
            ..write(payload);
          await tester.pump();

          for (final fs in [8.0, 10.0, 14.0, 20.0, 28.0, 32.0, 24.0, 16.0]) {
            fontSize = fs;
            await tester.pumpWidget(build());
            await tester.pump();
            await tester.runAsync(raster);
            expect(
              tester.takeException(),
              isNull,
              reason: 'cycle=$cycle fs=$fs',
            );
          }
        }
      },
    );
  });
}
