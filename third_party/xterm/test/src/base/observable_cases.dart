import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/base/observable.dart';

class _TestObservable with Observable {}

void registerObservableTests() {
  test('listeners may be added and removed during notification', () {
    final observable = _TestObservable();
    var removedCalls = 0;
    var addedCalls = 0;

    void removed() => removedCalls++;
    void added() => addedCalls++;

    observable
      ..addListener(removed)
      ..addListener(() {
        observable
          ..removeListener(removed)
          ..addListener(added);
      });

    observable.notifyListeners();
    expect(removedCalls, 1);
    expect(addedCalls, 0);

    observable.notifyListeners();
    expect(removedCalls, 1);
    expect(addedCalls, 1);
  });
}
