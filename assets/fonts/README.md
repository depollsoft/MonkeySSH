# Bundled fonts

These variable TrueType fonts come from the Google Fonts repository:

- Inter: https://github.com/google/fonts/tree/main/ofl/inter
  Regular and italic files expose the `opsz` and `wght` axes.
- JetBrains Mono: https://github.com/google/fonts/tree/main/ofl/jetbrainsmono
  Regular and italic files expose the `wght` axis.

Both families use the SIL Open Font License 1.1. The original copyright
notices and full licenses are in `OFL-Inter.txt` and `OFL-JetBrainsMono.txt`.
The font files are unchanged apart from their filenames.

Flutter registers these files as `Inter` and `JetBrains Mono` in `pubspec.yaml`.
The app uses these bundled families without a Google Fonts runtime download.
The Flutter 3.44.8 SDK used locally and in CI maps `TextStyle.fontWeight` to
the variable `wght` axis automatically, a behavior introduced in Flutter 3.41.
No explicit weight variation is needed, including when callers change weight
with `copyWith`. Inter keeps its default optical sizing.
