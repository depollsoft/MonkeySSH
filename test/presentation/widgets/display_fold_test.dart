import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/controllers/platform_display_features_controller.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';
import 'package:monkeyssh/presentation/widgets/display_fold.dart';
import 'package:monkeyssh/presentation/widgets/system_vertical_bar.dart';

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

  test('a book fold needs a mux navigator; a propped one always splits', () {
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
    // Without a navigator the bottom page is a keyboard deck.
    expect(
      resolveTerminalFoldLayout(propped, showsMuxNavigator: false),
      TerminalFoldLayout.propped,
    );
    expect(
      resolveTerminalFoldLayout(null, showsMuxNavigator: true),
      TerminalFoldLayout.none,
    );
  });

  test('parses native display state and skips malformed entries', () {
    final state = parsePlatformDisplayState({
      'features': [
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
      ],
      'verticalBar': {
        'edge': 'right',
        'left': 396,
        'top': 174,
        'width': 44,
        'height': 470,
      },
    });

    expect(state.features, const [
      _bookFold,
      DisplayFeature(
        bounds: Rect.fromLTWH(0, 470, 669, 10),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    expect(
      state.verticalBar,
      const SystemVerticalBar(
        edge: SystemVerticalBarEdge.right,
        itemColumn: Rect.fromLTWH(396, 174, 44, 470),
      ),
    );
    expect(parsePlatformDisplayState(null).features, isEmpty);
    expect(parsePlatformDisplayState({'features': 'x'}).features, isEmpty);
    for (final bar in [
      {'edge': 'top', 'left': 0, 'top': 0, 'width': 44, 'height': 400},
      {'edge': 'left', 'left': 0, 'top': 0, 'width': 0, 'height': 400},
      {'edge': 'right', 'left': 0, 'top': 0},
    ]) {
      expect(
        parsePlatformDisplayState({'verticalBar': bar}).verticalBar,
        isNull,
        reason: '$bar',
      );
    }
  });

  group('PlatformDisplayFeaturesMediaQuery', () {
    final controller = PlatformDisplayFeaturesController.instance;
    const channel = MethodChannel('xyz.depollsoft.monkeyssh/display_features');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    });

    tearDown(() {
      controller.debugSetState();
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

      controller.debugSetState(features: const [_bookFold]);
      await tester.pump();
      expect(seen, const [engineFeature, _bookFold]);

      controller.debugSetState();
      await tester.pump();
      expect(seen, const [engineFeature]);
    });

    testWidgets('keeps the subtree as a fold comes and goes', (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(size: _openWide),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: PlatformDisplayFeaturesMediaQuery(child: _Counter()),
          ),
        ),
      );
      final state = tester.state(find.byType(_Counter));

      controller.debugSetState(features: const [_bookFold]);
      await tester.pump();
      expect(tester.state(find.byType(_Counter)), same(state));

      controller.debugSetState();
      await tester.pump();
      expect(tester.state(find.byType(_Counter)), same(state));
    });

    testWidgets('passes a flat fold band on as its centre line', (
      tester,
    ) async {
      List<DisplayFeature>? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: _openWide),
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
      const band = Rect.fromLTRB(455.5, 0, 495.5, 669);
      controller.debugSetState(
        features: const [
          DisplayFeature(
            bounds: band,
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      await tester.pump();
      // Open flat, dialogs may cross the fold.
      expect(seen, const [
        DisplayFeature(
          bounds: Rect.fromLTWH(475.5, 0, 0, 669),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureFlat,
        ),
      ]);
      expect(
        DisplayFeatureSubScreen.avoidBounds(
          MediaQueryData(size: _openWide, displayFeatures: seen!),
        ),
        isEmpty,
      );

      const halfOpened = DisplayFeature(
        bounds: band,
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      );
      controller.debugSetState(features: const [halfOpened]);
      await tester.pump();
      expect(seen, const [halfOpened]);
    });

    testWidgets('provides the reported vertical bar to the subtree', (
      tester,
    ) async {
      const bar = SystemVerticalBar(
        edge: SystemVerticalBarEdge.right,
        itemColumn: Rect.fromLTWH(396, 174, 44, 470),
      );
      SystemVerticalBar? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(466, 678)),
          child: PlatformDisplayFeaturesMediaQuery(
            child: Builder(
              builder: (context) {
                seen = SystemVerticalBarScope.maybeOf(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(seen, isNull);

      controller.debugSetState(verticalBar: bar);
      await tester.pump();
      expect(seen, bar);

      controller.debugSetState();
      await tester.pump();
      expect(seen, isNull);
    });

    testWidgets('reads the state again when the window metrics change', (
      tester,
    ) async {
      // At launch the vertical bar settles after the first read.
      var barSettled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {
              'features': const <Object?>[],
              if (barSettled)
                'verticalBar': {
                  'edge': 'right',
                  'left': 396,
                  'top': 174,
                  'width': 44,
                  'height': 470,
                },
            },
          );
      SystemVerticalBar? seen;
      await tester.pumpWidget(
        PlatformDisplayFeaturesMediaQuery(
          child: Builder(
            builder: (context) {
              seen = SystemVerticalBarScope.maybeOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();
      expect(seen, isNull);

      barSettled = true;
      tester.view.padding = const FakeViewPadding(right: 84);
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.pump();
      expect(seen?.edge, SystemVerticalBarEdge.right);
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
              const MethodCall('onDisplayStateChanged', {
                'features': [
                  {
                    'left': 475,
                    'top': 0,
                    'width': 0,
                    'height': 669,
                    'type': 'fold',
                    'state': 'halfOpened',
                  },
                ],
              }),
            ),
            (_) {},
          );
      await tester.pump();
      expect(fold?.isVertical, isTrue);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
