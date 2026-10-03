import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/controllers/platform_display_features_controller.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';
import 'package:monkeyssh/presentation/widgets/display_fold.dart';

// iPhone Duo's inner display, open wide, in points.
const _openWide = Size(951, 669);
const _bookFold = DisplayFeature(
  bounds: Rect.fromLTWH(475, 0, 0, 669),
  type: DisplayFeatureType.fold,
  state: DisplayFeatureState.postureHalfOpened,
);

MediaQueryData _window(Size size, List<DisplayFeature> features) =>
    MediaQueryData(size: size, displayFeatures: features);

void main() {
  group('resolveDisplayFold', () {
    test('finds a half-opened fold running top to bottom', () {
      final fold = resolveDisplayFold(_window(_openWide, const [_bookFold]));

      expect(fold, isNotNull);
      expect(fold!.isVertical, isTrue);
      expect(fold.leadingPageExtent, 475);
      expect(fold.trailingPageStart, 475);
      expect(fold.thickness, 0);
      expect(fold.leadingPage(_openWide), const Rect.fromLTRB(0, 0, 475, 669));
      expect(
        fold.trailingPage(_openWide),
        const Rect.fromLTRB(475, 0, 951, 669),
      );
    });

    test('finds a fold running across a window turned upright', () {
      final fold = resolveDisplayFold(
        _window(const Size(669, 951), const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 470, 669, 10),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ]),
      );

      expect(fold?.axis, Axis.horizontal);
      expect(fold?.leadingPageExtent, 470);
      expect(fold?.trailingPageStart, 480);
      expect(fold?.thickness, 10);
    });

    test('treats a hinge as separating even when flat', () {
      final fold = resolveDisplayFold(
        _window(_openWide, const [
          DisplayFeature(
            bounds: Rect.fromLTWH(470, 0, 10, 669),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ]),
      );

      expect(fold?.isVertical, isTrue);
    });

    test('ignores a flat fold, cutouts, and folds missing the window', () {
      expect(
        resolveDisplayFold(
          _window(_openWide, const [
            DisplayFeature(
              bounds: Rect.fromLTWH(475, 0, 0, 669),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureFlat,
            ),
          ]),
        ),
        isNull,
      );
      expect(
        resolveDisplayFold(
          _window(_openWide, const [
            DisplayFeature(
              bounds: Rect.fromLTWH(800, 0, 80, 40),
              type: DisplayFeatureType.cutout,
              state: DisplayFeatureState.unknown,
            ),
          ]),
        ),
        isNull,
      );
      // A Split View window that only reaches partway down the fold.
      expect(
        resolveDisplayFold(
          _window(_openWide, const [
            DisplayFeature(
              bounds: Rect.fromLTWH(475, 200, 0, 469),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ]),
        ),
        isNull,
      );
    });

    test('keeps one page when either side is too small to use', () {
      expect(
        resolveDisplayFold(
          _window(const Size(500, 669), const [
            DisplayFeature(
              bounds: Rect.fromLTWH(400, 0, 0, 669),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ]),
        ),
        isNull,
      );
    });
  });

  test('page media query keeps only the insets along its own edges', () {
    const window = MediaQueryData(
      size: _openWide,
      padding: EdgeInsets.only(right: 84, bottom: 34),
      viewPadding: EdgeInsets.only(right: 84, bottom: 34),
      displayFeatures: [_bookFold],
    );
    final fold = resolveDisplayFold(window)!;

    final left = displayFoldPageMediaQuery(window, fold.leadingPage(_openWide));
    expect(left.size, const Size(475, 669));
    expect(left.padding, const EdgeInsets.only(bottom: 34));
    expect(left.displayFeatures, isEmpty);

    final right = displayFoldPageMediaQuery(
      window,
      fold.trailingPage(_openWide),
    );
    expect(right.size, const Size(476, 669));
    expect(right.padding, const EdgeInsets.only(right: 84, bottom: 34));
    expect(right.displayFeatures, isEmpty);
  });

  test('terminal fold layout needs a mux navigator for the second page', () {
    final book = resolveDisplayFold(_window(_openWide, const [_bookFold]));
    final propped = resolveDisplayFold(
      _window(const Size(669, 951), const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 475, 669, 0),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ]),
    );

    expect(
      resolveTerminalFoldLayout(book, showsMuxNavigator: true),
      TerminalFoldLayout.book,
    );
    expect(
      resolveTerminalFoldLayout(propped, showsMuxNavigator: true),
      TerminalFoldLayout.propped,
    );
    expect(
      resolveTerminalFoldLayout(book, showsMuxNavigator: false),
      TerminalFoldLayout.none,
    );
    expect(
      resolveTerminalFoldLayout(null, showsMuxNavigator: true),
      TerminalFoldLayout.none,
    );
  });

  test('parses native display features and skips malformed entries', () {
    final features = parsePlatformDisplayFeatures([
      {
        'left': 475,
        'top': 0,
        'width': 0,
        'height': 669.0,
        'type': 'fold',
        'state': 'halfOpened',
      },
      {
        'left': 0,
        'top': 470,
        'width': 669,
        'height': 10,
        'type': 'hinge',
        'state': 'flat',
      },
      {'left': 1, 'top': 2, 'width': -3, 'height': 4},
      {'left': 'x', 'top': 0, 'width': 0, 'height': 0},
      'not a map',
    ]);

    expect(features, const [
      _bookFold,
      DisplayFeature(
        bounds: Rect.fromLTWH(0, 470, 669, 10),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    expect(parsePlatformDisplayFeatures(null), isEmpty);
    expect(parsePlatformDisplayFeatures({'left': 0}), isEmpty);
  });

  group('PlatformDisplayFeaturesMediaQuery', () {
    final controller = PlatformDisplayFeaturesController.instance;
    const channel = MethodChannel('xyz.depollsoft.monkeyssh/display_features');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    });

    tearDown(() {
      controller.debugSetFeatures(const []);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('adds platform features to the engine-reported ones', (
      tester,
    ) async {
      const engineFeature = DisplayFeature(
        bounds: Rect.fromLTWH(0, 0, 80, 30),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      );
      List<DisplayFeature>? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: _openWide,
            displayFeatures: [engineFeature],
          ),
          child: PlatformDisplayFeaturesMediaQuery(
            child: Builder(
              builder: (context) {
                seen = MediaQuery.of(context).displayFeatures;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(seen, const [engineFeature]);

      controller.debugSetFeatures(const [_bookFold]);
      await tester.pump();
      expect(seen, const [engineFeature, _bookFold]);

      controller.debugSetFeatures(const []);
      await tester.pump();
      expect(seen, const [engineFeature]);
    });

    testWidgets('applies features the platform pushes over the channel', (
      tester,
    ) async {
      DisplayFold? fold;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: _openWide),
          child: PlatformDisplayFeaturesMediaQuery(
            child: Builder(
              builder: (context) {
                fold = resolveDisplayFold(MediaQuery.of(context));
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(fold, isNull);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              const MethodCall('onDisplayFeaturesChanged', [
                {
                  'left': 475,
                  'top': 0,
                  'width': 0,
                  'height': 669,
                  'type': 'fold',
                  'state': 'halfOpened',
                },
              ]),
            ),
            (_) {},
          );
      await tester.pump();
      expect(fold?.isVertical, isTrue);
    });
  });
}
