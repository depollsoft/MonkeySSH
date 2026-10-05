mixin Disposable {
  final _disposeCallbacks = <void Function()>[];

  bool get disposed => _disposed;
  bool _disposed = false;

  void registerCallback(void Function() callback) {
    assert(!_disposed);
    _disposeCallbacks.add(callback);
  }

  void dispose() {
    _disposed = true;
    for (final callback in _disposeCallbacks) {
      callback();
    }
  }
}
