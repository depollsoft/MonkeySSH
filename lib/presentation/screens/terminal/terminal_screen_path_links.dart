part of '../terminal_screen.dart';

/// Terminal link/file-path detection, hover/tap tracking, and visible path underlines.
extension _TerminalScreenPathLinks on _TerminalScreenState {
  String? _resolveTerminalLinkTap(CellOffset offset) {
    var target = _resolveTerminalExternalLinkAtOffset(
      offset,
      forgiving: _isMobilePlatform,
    );
    if (target == null && ref.read(terminalPathLinksNotifierProvider)) {
      final detectedPath = _resolveTerminalFilePathAtOffset(
        offset,
        forgiving: _isMobilePlatform,
      );
      if (detectedPath != null) {
        target = '$_terminalSftpPathPrefix$detectedPath';
      } else {
        final pendingTarget = _pendingTerminalTargetTap;
        if (pendingTarget != null &&
            pendingTarget.startsWith(_terminalSftpPathPrefix) &&
            _pathVerifier.isInteractiveTerminalFilePath(
              pendingTarget.substring(_terminalSftpPathPrefix.length),
            )) {
          target = pendingTarget;
        }
      }
    }
    // Leave the pointer-level pending tap alone. With system selection the
    // selection recognizer wins the arena, so that tap is the only one that
    // opens the link; this resolver still runs when the losing tap recognizer
    // reports its tap down 100 ms into the press.
    return target;
  }

  /// Opens a link for the terminal's own tap recognizer, unless the pointer
  /// listener already opened a target for the same touch. The two can resolve
  /// different targets (the listener also looks at neighbouring cells), so the
  /// check does not compare them.
  void _handleTerminalGestureLinkTap(String link) {
    if (_terminalTargetTapOpenedByPointer) {
      _terminalTargetTapOpenedByPointer = false;
      return;
    }
    _clearPendingTerminalTargetTap();
    _handleTerminalLinkTap(link);
  }

  String? _resolveTerminalExternalLinkAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    if (!shouldResolveTerminalTapLinks(
      showsNativeSelectionOverlay: _isNativeSelectionMode,
    )) {
      return null;
    }

    final candidateOffsets = forgiving
        ? resolveForgivingTerminalTapOffsets(
            offset,
            shownRows: _terminalViewKey.currentState?.renderTerminal.shownRows,
          )
        : <CellOffset>[offset];
    for (final candidateOffset in candidateOffsets) {
      final trackedHyperlink = _terminalHyperlinkTracker?.resolveLinkAt(
        candidateOffset,
      );
      if (trackedHyperlink != null) {
        return trackedHyperlink;
      }

      final row = candidateOffset.y.clamp(0, _terminal.buffer.height - 1);
      final column = candidateOffset.x.clamp(0, _terminal.buffer.viewWidth - 1);
      final line = _terminal.buffer.lines[row];
      if (line.getCodePoint(column) == 0) {
        continue;
      }

      // Use the cross-rendered-line snapshot (the same one that reconstructs
      // wrapped file paths) so a URL split across a program's bordered TUI
      // lines is rejoined before detection.
      final linkSnapshot = _buildTerminalPathTapSnapshot(row);
      if (linkSnapshot == null) {
        continue;
      }

      final rowIndex = row - linkSnapshot.startRow;
      if (rowIndex < 0 || rowIndex >= linkSnapshot.columnOffsets.length) {
        continue;
      }
      final rowColumnOffsets = linkSnapshot.columnOffsets[rowIndex];
      if (column >= rowColumnOffsets.length) {
        continue;
      }
      final textOffset =
          linkSnapshot.rowStarts[rowIndex] + rowColumnOffsets[column];
      final detectedLink = detectTerminalLinkAtTextOffset(
        linkSnapshot.text,
        textOffset,
      );
      if (detectedLink != null) {
        return detectedLink.uri.toString();
      }
    }

    // Forgiving touch fallback: a short OSC 8 label such as `#587` is easy to
    // miss with a finger, so open the link when the tapped row carries exactly
    // one tracked hyperlink.
    if (forgiving) {
      final rowLink = _terminalHyperlinkTracker?.resolveLinkOnRow(
        offset.y.clamp(0, _terminal.buffer.height - 1),
      );
      if (rowLink != null) {
        return rowLink;
      }
    }

    return null;
  }

  String? _resolveTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final detectedPath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: forgiving,
    );
    if (detectedPath == null) {
      return null;
    }

    // Prime verification even for optimistically active paths so the link can
    // shrink to (or drop below) the longest existing substring once resolved.
    _pathVerifier.primeTerminalFilePathVerification(detectedPath);
    return _pathVerifier.isInteractiveTerminalFilePath(detectedPath)
        ? detectedPath
        : null;
  }

  String? _detectTerminalFilePathAtOffset(
    CellOffset offset, {
    bool forgiving = false,
  }) {
    final candidateOffsets = forgiving
        ? resolveForgivingTerminalTapOffsets(
            offset,
            shownRows: _terminalViewKey.currentState?.renderTerminal.shownRows,
          )
        : <CellOffset>[offset];
    for (final candidateOffset in candidateOffsets) {
      final detectedPath = _detectTerminalFilePathAtCell(candidateOffset);
      if (detectedPath != null) {
        return detectedPath;
      }
    }
    if (forgiving) {
      final segments = _resolveInteractiveTerminalPathSegmentsOnRow(offset.y);
      return segments.length == 1 ? segments.single.path : null;
    }
    return null;
  }

  String? _detectTerminalFilePathAtCell(CellOffset offset) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    // OSC 8 hyperlinks are authoritative: only linkify text that is not already
    // a program-declared link.
    if (_terminalHyperlinkTracker?.resolveLinkAt(CellOffset(column, row)) !=
        null) {
      return null;
    }
    final pathSnapshot = _buildTerminalPathTapSnapshot(row);
    if (pathSnapshot == null) {
      return null;
    }

    return _detectTerminalFilePathInSnapshotAtCell(pathSnapshot, offset);
  }

  String? _detectTerminalFilePathInSnapshotAtCell(
    _TerminalPathTapSnapshot pathSnapshot,
    CellOffset offset,
  ) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final column = offset.x.clamp(0, _terminal.buffer.viewWidth - 1);
    final line = _terminal.buffer.lines[row];
    if (line.getCodePoint(column) == 0) {
      return null;
    }

    final pathRowIndex = row - pathSnapshot.startRow;
    if (pathRowIndex < 0 || pathRowIndex >= pathSnapshot.columnOffsets.length) {
      return null;
    }

    final rowColumnOffsets = pathSnapshot.columnOffsets[pathRowIndex];
    if (column >= rowColumnOffsets.length) {
      return null;
    }

    final pathTextOffset =
        pathSnapshot.rowStarts[pathRowIndex] + rowColumnOffsets[column];
    final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      final activePath = _pathVerifier.interactiveTerminalFilePathCandidate(
        detectedPath.path,
      );
      final activeEnd = activePath == null
          ? detectedPath.hitTestEnd
          : _resolveOriginalTerminalPathMatchEnd(
              normalizedSnapshot: snapshotAnalysis.normalizedSnapshot,
              normalizedStart: detectedPath.normalizedStart,
              normalizedLength: activePath.length,
            );
      if (activeEnd == null) {
        continue;
      }
      if (pathTextOffset >= detectedPath.start && pathTextOffset < activeEnd) {
        return detectedPath.path;
      }
    }
    return null;
  }

  _TerminalPathTapSnapshot? _buildTerminalPathTapSnapshot(int row) {
    final buffer = _terminal.buffer;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    // Locate the canonical start of the wrapped-line group so that all rows
    // in the group share the same cache key.
    var cacheKey = row;
    while (cacheKey > 0 && buffer.lines[cacheKey].isWrapped) {
      cacheKey--;
    }

    // Local resizes reflow the buffer without notifying content listeners.
    // Include geometry so hit tests cannot reuse offsets from the old grid.
    final geometry = (
      buffer,
      buffer.viewWidth,
      buffer.viewHeight,
      buffer.height,
    );
    if (_terminalPathSnapshotCacheGeneration != _terminalContentGeneration ||
        _terminalPathSnapshotCacheGeometry != geometry) {
      _terminalPathSnapshotCacheGeneration = _terminalContentGeneration;
      _terminalPathSnapshotCacheGeometry = geometry;
      _terminalPathSnapshotCache.clear();
      _terminalPathAnalysisCache.clear();
    }

    if (_terminalPathSnapshotCache.containsKey(cacheKey)) {
      return _terminalPathSnapshotCache[cacheKey];
    }

    final lineSnapshots = <int, ({String text, List<int> columnOffsets})>{};
    ({String text, List<int> columnOffsets}) lineSnapshotAt(int lineIndex) =>
        lineSnapshots.putIfAbsent(
          lineIndex,
          () => _buildNativeSelectionLineSnapshot(
            buffer.lines[lineIndex],
            buffer.viewWidth,
          ),
        );
    String lineTextAt(int lineIndex) => lineSnapshotAt(lineIndex).text;

    var startRow = cacheKey;
    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    while (startRow > 0 &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(startRow - 1),
          nextLineText: lineTextAt(startRow),
        )) {
      startRow--;
    }

    while (endRow + 1 < buffer.height &&
        isTerminalPathContinuationAcrossLines(
          previousLineText: lineTextAt(endRow),
          nextLineText: lineTextAt(endRow + 1),
        )) {
      endRow++;
    }

    final builder = StringBuffer();
    final rowStarts = <int>[];
    final columnOffsets = <List<int>>[];
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      rowStarts.add(builder.length);
      final lineSnapshot = lineSnapshotAt(lineIndex);
      builder.write(lineSnapshot.text);
      columnOffsets.add(lineSnapshot.columnOffsets);
      if (lineIndex < endRow && !buffer.lines[lineIndex + 1].isWrapped) {
        builder.write('\n');
      }
    }

    final snapshot = (
      text: builder.toString(),
      startRow: startRow,
      rowStarts: rowStarts,
      columnOffsets: columnOffsets,
    );
    _terminalPathSnapshotCache[cacheKey] = snapshot;
    return snapshot;
  }

  void _handleTerminalPathHover(PointerHoverEvent event) {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null ||
        !ref.read(terminalPathLinksNotifierProvider) ||
        !ref.read(terminalPathLinkUnderlinesNotifierProvider)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }

    final terminalLocalPosition = terminalViewState.renderTerminal
        .globalToLocal(event.position);
    final offset = terminalViewState.renderTerminal.getCellOffset(
      terminalLocalPosition,
    );
    final isSameHoveredCell =
        _lastHoveredTerminalPathOffset?.x == offset.x &&
        _lastHoveredTerminalPathOffset?.y == offset.y;
    final detectedPath = isSameHoveredCell
        ? _lastHoveredTerminalPath
        : _resolveTerminalFilePathAtOffset(offset);
    if (!isSameHoveredCell) {
      _lastHoveredTerminalPathOffset = offset;
      _lastHoveredTerminalPath = detectedPath;
    }
    if (detectedPath == null || !_shouldShowTerminalPathBadge(detectedPath)) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final hoveredSegment = _resolveInteractiveTerminalPathSegmentAtOffset(
      offset,
      path: detectedPath,
    );
    if (hoveredSegment == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final underline = _buildTerminalPathInlineUnderline(
      row: offset.y,
      startColumn: hoveredSegment.startColumn,
      endColumn: hoveredSegment.endColumn,
    );
    if (underline == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    if (_hoveredTerminalPathUnderline == underline) {
      return;
    }
    _updateState(() => _hoveredTerminalPathUnderline = underline);
  }

  void _clearPendingTerminalTargetTap() {
    _pendingTerminalTargetTap = null;
    _pendingTerminalTargetTapPointer = null;
    _pendingTerminalTargetTapDownPosition = null;
    _pendingTerminalTargetTapDownTimestamp = null;
  }

  void _clearPendingTerminalDoubleTap() {
    _pendingTerminalDoubleTapPointer = null;
    _pendingTerminalDoubleTapDownPosition = null;
    _pendingTerminalDoubleTapDownTimestamp = null;
  }

  void _clearLastTerminalTap() {
    _lastTerminalTapPosition = null;
    _lastTerminalTapTimestamp = null;
  }

  void _pauseTerminalOutputFollowForTouch(PointerDownEvent event) {
    if (!_isMobilePlatform || event.kind != PointerDeviceKind.touch) {
      return;
    }

    if (_terminalOutputPauseTouchPointers.add(event.pointer)) {
      if (_terminalScrollController.hasClients) {
        _lastTerminalScrollOffset = _terminalScrollController.offset;
        _setShouldFollowLiveOutput(
          shouldFollowTerminalOutput(
            hasScrollClients: true,
            currentOffset: _terminalScrollController.offset,
            maxScrollExtent: _terminalScrollController.position.maxScrollExtent,
          ),
        );
      }
      _syncTerminalLiveOutputAutoScroll();
      _updateState(() {});
    }
  }

  void _resumeTerminalOutputFollowForTouch(int pointer) {
    if (!_terminalOutputPauseTouchPointers.remove(pointer)) {
      return;
    }

    _syncTerminalLiveOutputAutoScroll();
    _updateState(() {});
    if (_terminalOutputPauseTouchPointers.isNotEmpty ||
        !_shouldFollowLiveOutput ||
        _isTerminalOutputFollowPaused) {
      return;
    }

    _queueTerminalScrollToBottom();
  }

  void _syncTerminalLiveOutputAutoScroll() {
    _terminalViewKey.currentState?.renderTerminal.liveOutputAutoScroll =
        _terminalLiveOutputAutoScrollEnabled;
  }

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _pauseTerminalOutputFollowForTouch(event);
    _handleTerminalTargetPointerDown(event);
    _handleTerminalDoubleTapPointerDown(
      event,
      allowDoubleTap: _pendingTerminalTargetTap == null,
    );
    _handleTerminalMouseTapPointerDown(
      event,
      allowTap:
          _pendingTerminalTargetTap == null &&
          _terminalDoubleTapConsumedPointer != event.pointer,
    );
  }

  // Pointer routing keeps the hit-test path from pointer down, so move, up and
  // cancel can still reach this listener after the terminal was disposed.
  void _handleTerminalPointerMove(PointerMoveEvent event) {
    if (!mounted) return;
    _handleTerminalTargetPointerMove(event);
    _handleTerminalDoubleTapPointerMove(event);
    _handleTerminalMouseTapPointerMove(event);
  }

  void _handleTerminalPointerUp(PointerUpEvent event) {
    if (!mounted) return;
    if (!_handleTerminalTargetPointerUp(event)) {
      _handleTerminalDoubleTapPointerUp(event);
      _handleTerminalMouseTapPointerUp(event);
    } else {
      _clearPendingTerminalMouseTap(event.pointer);
      _clearLastTerminalTap();
    }
    _resumeTerminalOutputFollowForTouch(event.pointer);
  }

  void _handleTerminalPointerCancel(PointerCancelEvent event) {
    if (!mounted) return;
    if (_pendingTerminalTargetTapPointer == event.pointer) {
      _clearPendingTerminalTargetTap();
    }
    _handleTerminalDoubleTapPointerCancel(event);
    _clearPendingTerminalMouseTap(event.pointer);
    _resumeTerminalOutputFollowForTouch(event.pointer);
  }

  void _handleTerminalTargetPointerDown(PointerDownEvent event) {
    _clearPendingTerminalTargetTap();
    _terminalTargetTapOpenedByPointer = false;
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null) {
      _clearHoveredTerminalPathUnderline();
      return;
    }
    final localPosition = terminalViewState.renderTerminal.globalToLocal(
      event.position,
    );
    final offset = terminalViewState.renderTerminal.getCellOffset(
      localPosition,
    );
    final link = event.kind == PointerDeviceKind.touch
        ? _resolveTerminalExternalLinkAtOffset(offset, forgiving: true)
        : null;
    final path = link == null
        ? _resolveTerminalPointerPath(event, offset, localPosition)
        : null;
    final target =
        link ?? (path == null ? null : '$_terminalSftpPathPrefix$path');
    if (target == null) {
      return;
    }
    if (link != null) {
      _terminalTextInputController.suppressNextTouchKeyboardRequest();
    }
    _pendingTerminalTargetTap = target;
    _pendingTerminalTargetTapPointer = event.pointer;
    _pendingTerminalTargetTapDownPosition = event.position;
    _pendingTerminalTargetTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalTargetPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalTargetTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalTargetTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalTargetTap();
    }
  }

  bool _handleTerminalTargetPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return false;
    }

    final pendingTarget = _pendingTerminalTargetTap;
    final downPosition = _pendingTerminalTargetTapDownPosition;
    final downTimestamp = _pendingTerminalTargetTapDownTimestamp;
    if (pendingTarget == null ||
        _pendingTerminalTargetTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalTargetTap();
      return pendingTarget != null;
    }

    _clearPendingTerminalTargetTap();
    // The recognizer's tap up, if it comes, arrives in this same pointer-up
    // dispatch; the next pointer down clears the flag in case no frame does.
    _terminalTargetTapOpenedByPointer = true;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _terminalTargetTapOpenedByPointer = false,
    );
    _handleTerminalLinkTap(pendingTarget);
    return true;
  }

  void _handleTerminalMouseTapPointerDown(
    PointerDownEvent event, {
    required bool allowTap,
  }) {
    _clearPendingTerminalMouseTap();
    final terminalViewState = _terminalViewKey.currentState;
    // A terminal that takes the tap itself (desktop) would see it twice.
    if (!allowTap ||
        event.buttons != kPrimaryButton ||
        terminalViewState == null ||
        !terminalViewState.leavesTapToParent(event.kind) ||
        !((event.kind == PointerDeviceKind.touch &&
                terminalViewState.shouldSendTerminalTapPointerInput) ||
            terminalViewState.canMoveTerminalPromptCursor)) {
      return;
    }

    _pendingTerminalMouseTapPointer = event.pointer;
    _pendingTerminalMouseTapDownPosition = event.position;
    _pendingTerminalMouseTapDownTimestamp = event.timeStamp;
    _pendingTerminalMouseTapHadSelection =
        _isNativeSelectionMode || _hasActiveSystemSelection;
  }

  void _handleTerminalMouseTapPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalMouseTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalMouseTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalMouseTap(event.pointer);
    }
  }

  void _handleTerminalMouseTapPointerUp(PointerUpEvent event) {
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _clearPendingTerminalMouseTap(event.pointer);
      return;
    }

    final downPosition = _pendingTerminalMouseTapDownPosition;
    final downTimestamp = _pendingTerminalMouseTapDownTimestamp;
    if (_pendingTerminalMouseTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalMouseTap(event.pointer);
      return;
    }

    final hadSelection = _pendingTerminalMouseTapHadSelection;
    _clearPendingTerminalMouseTap(event.pointer);
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null) {
      return;
    }
    // The system selection owns mouse clicks, so only a touch tap is a click
    // for mouse tracking.
    if (event.kind == PointerDeviceKind.touch &&
        terminalViewState.sendTerminalPrimaryTap(event.position)) {
      // A clicked TUI such as Claude Code moves its own cursor, so the IME's
      // copy of the text before the cursor no longer applies; later edits and
      // suggestions would otherwise replace the wrong characters.
      _terminalTextInputController.resetImeForExternalCursorMove();
    } else if (!hadSelection) {
      // Without mouse tracking, a tap on a shell prompt's input moves the
      // shell's cursor there when the prompt asked for it (OSC 133). The view
      // resets the IME for it, as for a click.
      terminalViewState.moveTerminalPromptCursor(event.position);
    }
  }

  void _clearPendingTerminalMouseTap([int? pointer]) {
    if (pointer != null && _pendingTerminalMouseTapPointer != pointer) {
      return;
    }
    _pendingTerminalMouseTapPointer = null;
    _pendingTerminalMouseTapDownPosition = null;
    _pendingTerminalMouseTapDownTimestamp = null;
    _pendingTerminalMouseTapHadSelection = false;
  }

  void _handleTerminalDoubleTapPointerDown(
    PointerDownEvent event, {
    required bool allowDoubleTap,
  }) {
    if (event.kind != PointerDeviceKind.touch || !allowDoubleTap) {
      _clearPendingTerminalDoubleTap();
      return;
    }

    final lastTapPosition = _lastTerminalTapPosition;
    final lastTapTimestamp = _lastTerminalTapTimestamp;
    final isDoubleTap =
        lastTapPosition != null &&
        lastTapTimestamp != null &&
        event.timeStamp - lastTapTimestamp <= kDoubleTapTimeout &&
        (event.position - lastTapPosition).distance <= kDoubleTapSlop;

    if (isDoubleTap) {
      // Let SelectionArea handle text selection without also forwarding the
      // second tap as terminal mouse input.
      _terminalDoubleTapConsumedPointer = event.pointer;
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
      return;
    }

    _pendingTerminalDoubleTapPointer = event.pointer;
    _pendingTerminalDoubleTapDownPosition = event.position;
    _pendingTerminalDoubleTapDownTimestamp = event.timeStamp;
  }

  void _handleTerminalDoubleTapPointerMove(PointerMoveEvent event) {
    if (_pendingTerminalDoubleTapPointer != event.pointer) {
      return;
    }
    final downPosition = _pendingTerminalDoubleTapDownPosition;
    if (downPosition != null &&
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
    }
  }

  void _handleTerminalDoubleTapPointerUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _terminalDoubleTapConsumedPointer = null;
      _clearPendingTerminalDoubleTap();
      return;
    }

    final downPosition = _pendingTerminalDoubleTapDownPosition;
    final downTimestamp = _pendingTerminalDoubleTapDownTimestamp;
    if (_pendingTerminalDoubleTapPointer != event.pointer ||
        downPosition == null ||
        downTimestamp == null ||
        event.timeStamp - downTimestamp > kLongPressTimeout ||
        (event.position - downPosition).distance > kTouchSlop) {
      _clearPendingTerminalDoubleTap();
      _clearLastTerminalTap();
      return;
    }

    _lastTerminalTapPosition = event.position;
    _lastTerminalTapTimestamp = event.timeStamp;
    _clearPendingTerminalDoubleTap();
  }

  void _handleTerminalDoubleTapPointerCancel(PointerCancelEvent event) {
    if (_pendingTerminalDoubleTapPointer == event.pointer) {
      _clearPendingTerminalDoubleTap();
    }
    if (_terminalDoubleTapConsumedPointer == event.pointer) {
      _terminalDoubleTapConsumedPointer = null;
    }
  }

  String? _resolveTerminalPointerPath(
    PointerDownEvent event,
    CellOffset offset,
    Offset terminalLocalPosition,
  ) {
    if (!ref.read(terminalPathLinksNotifierProvider)) {
      _clearHoveredTerminalPathUnderline();
      return null;
    }
    final terminalViewObject = _terminalViewKey.currentState!.context
        .findRenderObject();
    final terminalViewLocalPosition = terminalViewObject is RenderBox
        ? terminalViewObject.globalToLocal(event.position)
        : terminalLocalPosition;
    final candidatePath = _detectTerminalFilePathAtOffset(
      offset,
      forgiving: event.kind == PointerDeviceKind.touch,
    );
    final underlinePath = event.kind == PointerDeviceKind.touch
        ? resolveTerminalPathTouchTargetTap(terminalViewLocalPosition, [
            for (final underline in _visibleTerminalPathUnderlines)
              (path: underline.path, touchRect: underline.touchRect),
          ])
        : null;
    final tappedPath = candidatePath ?? underlinePath;
    if (tappedPath != null && event.kind == PointerDeviceKind.touch) {
      _terminalTextInputController.suppressNextTouchKeyboardRequest();
    }
    if (candidatePath != null &&
        !_pathVerifier.isInteractiveTerminalFilePath(candidatePath)) {
      _pathVerifier.primeTerminalFilePathVerification(candidatePath);
    }
    return tappedPath != null &&
            _pathVerifier.isInteractiveTerminalFilePath(tappedPath)
        ? tappedPath
        : null;
  }

  void _clearHoveredTerminalPathUnderline() {
    _lastHoveredTerminalPathOffset = null;
    _lastHoveredTerminalPath = null;
    if (_hoveredTerminalPathUnderline == null || !mounted) {
      return;
    }
    _updateState(() => _hoveredTerminalPathUnderline = null);
  }

  bool _shouldShowTerminalPathBadge(String path) =>
      _pathVerifier.isInteractiveTerminalFilePath(path);

  void _queueVisibleTerminalPathUnderlineRefresh() {
    if (!_isMobilePlatform ||
        _isTerminalPathUnderlineRefreshQueued ||
        !mounted) {
      return;
    }

    _isTerminalPathUnderlineRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTerminalPathUnderlineRefreshQueued = false;
      if (!mounted) {
        return;
      }
      _refreshVisibleTerminalPathUnderlines();
    });
  }

  void _refreshVisibleTerminalPathUnderlines() {
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled) {
      _refreshVisibleTerminalPathUnderlinesImpl();
      return;
    }
    final stopwatch = Stopwatch()..start();
    _refreshVisibleTerminalPathUnderlinesImpl();
    final micros = stopwatch.elapsedMicroseconds;
    if (micros < 4000) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _terminalPathUnderlineRefreshLogAtMs < 1000) {
      return;
    }
    _terminalPathUnderlineRefreshLogAtMs = nowMs;
    diagnostics.debug(
      'terminal.paths',
      'underline_refresh',
      fields: {
        'durationMs': (micros / 1000).round(),
        'underlines': _visibleTerminalPathUnderlines.length,
      },
    );
  }

  void _refreshVisibleTerminalPathUnderlinesImpl() {
    final terminalViewState = _terminalViewKey.currentState;
    final showsUnderlines =
        ref.read(terminalPathLinksNotifierProvider) &&
        ref.read(terminalPathLinkUnderlinesNotifierProvider);
    if (!_isMobilePlatform || !showsUnderlines || terminalViewState == null) {
      if (_visibleTerminalPathUnderlines.isNotEmpty) {
        _updateState(
          () => _visibleTerminalPathUnderlines =
              const <
                ({String path, TerminalTextUnderline underline, Rect touchRect})
              >[],
        );
      }
      return;
    }

    final rowRange = terminalViewState.renderTerminal.shownRows;
    if (rowRange == null) {
      return;
    }

    final underlines =
        <({String path, TerminalTextUnderline underline, Rect touchRect})>[];
    final buffer = _terminal.buffer;
    var row = rowRange.first;
    while (row <= rowRange.last) {
      // Skip single, non-wrapped rows that contain no path-like characters.
      // This avoids the expensive snapshot-building step for the majority of
      // output lines that can never match a file path.
      final isSingleRow =
          !buffer.lines[row].isWrapped &&
          (row + 1 >= buffer.height || !buffer.lines[row + 1].isWrapped);
      if (isSingleRow &&
          !terminalRowMayContainPath(buffer.lines[row], buffer.viewWidth)) {
        row++;
        continue;
      }
      final pathSnapshot = _buildTerminalPathTapSnapshot(row);
      if (pathSnapshot == null) {
        row++;
        continue;
      }
      final snapshotAnalysis = _analyzeTerminalPathSnapshot(pathSnapshot);
      final snapshotEndRow =
          pathSnapshot.startRow + pathSnapshot.columnOffsets.length - 1;
      final visibleSnapshotBottom = min(rowRange.last, snapshotEndRow);
      for (
        var snapshotRow = max(row, pathSnapshot.startRow);
        snapshotRow <= visibleSnapshotBottom;
        snapshotRow++
      ) {
        final segments = _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
          snapshotRow,
          pathSnapshot: pathSnapshot,
          snapshotAnalysis: snapshotAnalysis,
        );
        for (final segment in segments) {
          if (!_shouldShowTerminalPathBadge(segment.path)) {
            continue;
          }
          final underline = _buildTerminalPathInlineUnderline(
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          final touchRect = _buildTerminalPathTouchTargetRect(
            terminalViewState,
            row: snapshotRow,
            startColumn: segment.startColumn,
            endColumn: segment.endColumn,
          );
          if (underline != null && touchRect != null) {
            underlines.add((
              path: segment.path,
              underline: underline,
              touchRect: touchRect,
            ));
          }
        }
      }
      row = visibleSnapshotBottom + 1;
    }

    if (!listEquals(_visibleTerminalPathUnderlines, underlines)) {
      _updateState(() => _visibleTerminalPathUnderlines = underlines);
    }
  }

  TerminalTextUnderline? _buildTerminalPathInlineUnderline({
    required int row,
    required int startColumn,
    required int endColumn,
  }) => resolveTerminalPathInlineUnderline(
    row: row,
    startColumn: startColumn,
    endColumn: endColumn,
    rowCount: _terminal.buffer.height,
    columnCount: _terminal.buffer.viewWidth,
  );

  Rect? _buildTerminalPathTouchTargetRect(
    MonkeyTerminalViewState terminalViewState, {
    required int row,
    required int startColumn,
    required int endColumn,
  }) {
    final terminalViewObject = terminalViewState.context.findRenderObject();
    if (terminalViewObject is! RenderBox) {
      return null;
    }
    final renderTerminal = terminalViewState.renderTerminal;
    final lineTopLeft = renderTerminal.localToGlobal(
      renderTerminal.getOffset(CellOffset(startColumn, row)),
      ancestor: terminalViewObject,
    );
    final lineEndOffset = renderTerminal.localToGlobal(
      renderTerminal.getOffset(
        CellOffset((endColumn + 1).clamp(0, _terminal.buffer.viewWidth), row),
      ),
      ancestor: terminalViewObject,
    );
    return resolveTerminalPathTouchTargetRect(
      lineTopLeft: lineTopLeft,
      lineEndOffset: lineEndOffset,
      lineHeight: renderTerminal.lineHeight,
      viewportHeight: terminalViewObject.size.height,
    );
  }

  ({String path, String text, int startColumn, int endColumn})?
  _resolveInteractiveTerminalPathSegmentAtOffset(
    CellOffset offset, {
    String? path,
  }) {
    for (final segment in _resolveInteractiveTerminalPathSegmentsOnRow(
      offset.y,
    )) {
      if (offset.x >= segment.startColumn &&
          offset.x <= segment.endColumn &&
          (path == null || segment.path == path)) {
        return segment;
      }
    }
    return null;
  }

  _TerminalPathSnapshotAnalysis _analyzeTerminalPathSnapshot(
    _TerminalPathTapSnapshot pathSnapshot,
  ) {
    final cached = _terminalPathAnalysisCache[pathSnapshot.text];
    if (cached != null) return cached;
    final normalizedSnapshot = normalizeTerminalFilePathDetectionText(
      pathSnapshot.text,
    );
    final analysis = (
      detectedPaths: detectTerminalFilePathMatches(normalizedSnapshot),
      normalizedSnapshot: normalizedSnapshot,
    );
    _terminalPathAnalysisCache[pathSnapshot.text] = analysis;
    return analysis;
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsOnRow(int row) {
    final clampedRow = row.clamp(0, _terminal.buffer.height - 1);
    final pathSnapshot = _buildTerminalPathTapSnapshot(clampedRow);
    if (pathSnapshot == null) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    return _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
      clampedRow,
      pathSnapshot: pathSnapshot,
      snapshotAnalysis: _analyzeTerminalPathSnapshot(pathSnapshot),
    );
  }

  List<({String path, String text, int startColumn, int endColumn})>
  _resolveInteractiveTerminalPathSegmentsInSnapshotRow(
    int row, {
    required _TerminalPathTapSnapshot pathSnapshot,
    required _TerminalPathSnapshotAnalysis snapshotAnalysis,
  }) {
    final rowIndex = row - pathSnapshot.startRow;
    if (rowIndex < 0 || rowIndex >= pathSnapshot.columnOffsets.length) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }
    if (snapshotAnalysis.detectedPaths.isEmpty) {
      return const <
        ({String path, String text, int startColumn, int endColumn})
      >[];
    }

    final rowStart = pathSnapshot.rowStarts[rowIndex];
    final rowColumnOffsets = pathSnapshot.columnOffsets[rowIndex];
    final rowEnd = rowStart + rowColumnOffsets.last;
    final rowText = pathSnapshot.text.substring(rowStart, rowEnd);
    final rowNormalizedStart = snapshotAnalysis
        .normalizedSnapshot
        .originalToNormalizedOffsets[rowStart];
    final rowNormalizedEnd =
        snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets[rowEnd];
    final candidatesToPrime = <String>{};
    final segments =
        <({String path, String text, int startColumn, int endColumn})>[];
    for (final detectedPath in snapshotAnalysis.detectedPaths) {
      if (detectedPath.normalizedEnd <= rowNormalizedStart ||
          detectedPath.normalizedStart >= rowNormalizedEnd) {
        continue;
      }

      final path = detectedPath.path;
      // Verify every detected path so its link is trimmed to the longest
      // existing substring (and dropped if no substring exists remotely).
      candidatesToPrime.add(path);
      final activePath = _pathVerifier.interactiveTerminalFilePathCandidate(
        path,
      );
      if (activePath != null) {
        final visibleSegment = resolveTerminalFilePathSegmentOnRow(
          rowText: rowText,
          rowStartOffset: rowStart,
          rowColumnOffsets: rowColumnOffsets,
          originalToNormalizedOffsets:
              snapshotAnalysis.normalizedSnapshot.originalToNormalizedOffsets,
          normalizedPathStart: detectedPath.normalizedStart,
          normalizedPathEnd: detectedPath.normalizedStart + activePath.length,
        );
        if (visibleSegment == null) {
          continue;
        }
        // Don't layer heuristic file-path linkification over a program-declared
        // OSC 8 hyperlink: only linkify text that is not already a link.
        if (_terminalHyperlinkTracker?.hasLinkInRowRange(
              row,
              visibleSegment.startColumn,
              visibleSegment.endColumn,
            ) ??
            false) {
          continue;
        }
        segments.add((
          path: path,
          text: visibleSegment.text,
          startColumn: visibleSegment.startColumn,
          endColumn: visibleSegment.endColumn,
        ));
      }
    }

    for (final path in candidatesToPrime) {
      _pathVerifier.primeTerminalFilePathVerification(path);
    }

    return segments;
  }

  ({String text, int cursorOffset})? _buildWrappedTerminalCommandSnapshot() {
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY;
    if (row < 0 || row >= buffer.height) {
      return null;
    }

    var startRow = row;
    while (startRow > 0 && buffer.lines[startRow].isWrapped) {
      startRow--;
    }

    var endRow = row;
    while (endRow + 1 < buffer.height && buffer.lines[endRow + 1].isWrapped) {
      endRow++;
    }

    final builder = StringBuffer();
    final cursorColumn = buffer.cursorX.clamp(0, buffer.viewWidth);
    var cursorOffset = 0;
    for (var lineIndex = startRow; lineIndex <= endRow; lineIndex++) {
      final lineSnapshot = _buildTerminalLineSnapshot(
        buffer.lines[lineIndex],
        buffer.viewWidth,
        preserveTrailingPadding: lineIndex < endRow,
        preserveOffset: lineIndex == row ? cursorColumn : 0,
      );
      if (lineIndex == row) {
        cursorOffset =
            builder.length + lineSnapshot.columnOffsets[cursorColumn];
      }
      builder.write(lineSnapshot.text);
    }

    return (text: builder.toString(), cursorOffset: cursorOffset);
  }

  String? _terminalTextBeforeCursor() {
    final snapshot = _buildWrappedTerminalCommandSnapshot();
    if (snapshot == null) {
      return null;
    }
    return snapshot.text.substring(0, snapshot.cursorOffset);
  }

  void _handleTerminalLinkTap(String link) {
    _clearHoveredTerminalPathUnderline();
    if (link.startsWith(_terminalSftpPathPrefix)) {
      unawaited(
        _openTerminalFilePath(link.substring(_terminalSftpPathPrefix.length)),
      );
      return;
    }

    // OSC 8 file destinations can be relative paths with source-line anchors,
    // not just `file:` URIs. Open them on the connected host through SFTP.
    final filePath = resolveTerminalFileLinkPath(link);
    if (filePath != null) {
      unawaited(_openTerminalFilePath(filePath, exact: true));
      return;
    }

    unawaited(_openTerminalLink(link));
  }

  void _showTerminalLinkMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTerminalLink(String link) async {
    final normalizedLink = normalizeTerminalLinkCandidate(link);
    final uri = Uri.tryParse(normalizedLink);
    if (uri == null) {
      _showTerminalLinkMessage('Could not open $link');
      return;
    }

    if (!isLaunchableTerminalUri(uri)) {
      _showTerminalLinkMessage('Blocked unsupported link scheme: $link');
      return;
    }

    if (isPortForwardBrowserSupported() &&
        ref.read(portForwardBrowserLinksNotifierProvider)) {
      final options = _activePortForwardBrowserOptions();
      _PortForwardBrowserOption? targetOption;
      Uri? browserUri;
      for (final option in options) {
        final rewritten = rewriteUriForPortForwardBrowser(
          uri,
          sourceUri: option.sourceUri,
          browserUri: option.uri,
        );
        if (rewritten != null) {
          targetOption = option;
          browserUri = rewritten;
          break;
        }
      }
      if (targetOption != null && browserUri != null) {
        await _openPortForwardBrowserOption(
          _PortForwardBrowserOption(
            uri: browserUri,
            sourceUri: targetOption.sourceUri,
            fallbackUri: targetOption.fallbackUri,
            port: targetOption.port,
            title: targetOption.title,
            group: targetOption.group,
          ),
        );
        return;
      }
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      launched = false;
    }
    if (launched || !mounted) {
      return;
    }

    _showTerminalLinkMessage('Could not open $link');
  }

  List<_PortForwardBrowserOption> _activePortForwardBrowserOptions() {
    final sessions = ref.read(activeSessionsProvider.notifier);
    final hostTunnels = sessions.getActiveTunnelsForHost(widget.hostId);
    final fallbackSession = _sessionController.observedSession;
    final tunnels = hostTunnels.isNotEmpty
        ? hostTunnels
        : fallbackSession?.activeTunnels ?? const <ActiveTunnelInfo>[];
    final options =
        tunnels
            .map(_portForwardBrowserOptionForTunnel)
            .whereType<_PortForwardBrowserOption>()
            .toList(growable: false)
          ..sort((left, right) {
            final groupComparison = left.group.index.compareTo(
              right.group.index,
            );
            return groupComparison != 0
                ? groupComparison
                : left.port.compareTo(right.port);
          });
    return options;
  }

  _PortForwardBrowserOption? _portForwardBrowserOptionForTunnel(
    ActiveTunnelInfo tunnel,
  ) {
    final browserHost = tunnel.browserHost;
    final browserPort = tunnel.browserPort;
    if (!tunnel.isLocal ||
        !isPortForwardBrowserHost(tunnel.localHost) ||
        tunnel.localPort < 1 ||
        tunnel.localPort > 65535 ||
        browserHost == null ||
        browserPort == null ||
        browserPort < 1 ||
        browserPort > 65535) {
      return null;
    }

    final sourcePort = tunnel.isAutomatic
        ? tunnel.remotePort
        : tunnel.localPort;
    final sourceUri = buildPortForwardBrowserUriForBind(
      localHost: tunnel.isAutomatic ? tunnel.remoteHost : tunnel.localHost,
      localPort: sourcePort,
    );
    final uri = buildPortForwardBrowserUriForBind(
      localHost: browserHost,
      localPort: browserPort,
    );
    final fallbackHost = tunnel.browserFallbackHost;
    final fallbackUri = fallbackHost == null
        ? null
        : buildPortForwardBrowserUriForBind(
            localHost: fallbackHost,
            localPort: tunnel.localPort,
          );
    return _PortForwardBrowserOption(
      uri: uri,
      sourceUri: sourceUri,
      fallbackUri: fallbackUri,
      port: sourcePort,
      title: tunnel.isAutomatic
          ? 'Port ${tunnel.remotePort}'
          : sourceUri.authority,
      group: tunnel.isAutomatic
          ? (tunnel.isShellRelated
                ? PortForwardBrowserTabGroup.savedHost
                : PortForwardBrowserTabGroup.sharedHost)
          : PortForwardBrowserTabGroup.savedForward,
    );
  }

  Future<void> _openPortForwardBrowserTunnel(ActiveTunnelInfo tunnel) async {
    final option = _portForwardBrowserOptionForTunnel(tunnel);
    if (option == null) {
      _showTerminalLinkMessage('This forward is not available in the browser');
      return;
    }
    await _openPortForwardBrowserOption(option);
  }

  Future<void> _openPortForwardBrowserFromTerminal() async {
    final options = _activePortForwardBrowserOptions();
    if (options.isEmpty) {
      _showTerminalLinkMessage('No active localhost port forwards to browse');
      return;
    }

    await _openPortForwardBrowserOptions(options);
  }

  Future<void> _openPortForwardsFromTerminal() async {
    final connectionId = _connectionId;
    final session = connectionId == null
        ? null
        : ref.read(activeSessionsProvider.notifier).getSession(connectionId);
    if (connectionId == null || session == null) {
      _showTerminalLinkMessage('Connect before managing live port forwards');
      return;
    }

    final shouldRestoreKeyboard = _temporarilyDismissTerminalKeyboard();
    try {
      await showTerminalPortForwardsSheet(
        context: context,
        hostId: widget.hostId,
        connectionId: connectionId,
        session: session,
        onOpenInBrowser: _openPortForwardBrowserTunnel,
        // The user chose here, so a reconnect must not place the hold again.
        onLinkHoldEnded: () => _linkPortForwardsReleased = true,
      );
    } finally {
      _restoreTemporarilyDismissedTerminalKeyboard(shouldRestoreKeyboard);
    }
  }

  /// Opens the read-only git changes sheet for this window's directory. An
  /// "Ask agent" prompt goes to the native composer, or into the terminal
  /// through the same review as a clipboard paste, but only into the window
  /// that supplied the directory.
  Future<void> _openWorkingTreeChanges() => _runExclusiveTerminalAction(
    _TerminalExclusiveAction.workingTreeChanges,
    () async {
      final activeSession = _activeSession();
      final session =
          activeSession != null &&
              _sessionsNotifier?.getState(activeSession.connectionId) ==
                  SshConnectionState.connected
          ? activeSession
          : null;
      final nativeKey = _activeNativeAcpSessionKey;
      var directory = nativeKey == null
          ? null
          : ref
                .read(acpSessionManagerProvider)
                .state
                .byKeyValue(nativeKey.value)
                ?.cwd;
      if (directory == null && session != null && _isTmuxActive) {
        try {
          directory = await _resolveCurrentTmuxPaneDirectory();
        } on Object catch (error) {
          // The window's last known directory still works.
          DiagnosticsLogService.instance.warning(
            'git_changes',
            'pane_directory_failed',
            fields: {'errorType': error.runtimeType},
          );
        }
        if (!mounted) return;
      }
      directory ??= _workingDirectoryPath;
      final target = _workingTreePromptTarget();
      final shouldRestoreKeyboard = _temporarilyDismissTerminalKeyboard();
      String? prompt;
      try {
        prompt = await showWorkingTreeChangesSheet(
          context: context,
          service: session == null
              ? null
              : ref.read(gitWorkingTreeServiceFactoryProvider)(session),
          directory: directory,
          unavailableMessage: workingTreeChangesUnavailableReason(session),
          canAskAgent: true,
        );
      } finally {
        _restoreTemporarilyDismissedTerminalKeyboard(shouldRestoreKeyboard);
      }
      if (!mounted || prompt == null) return;
      // Another client, or an agent, can switch windows while the sheet is
      // open; the hunk belongs to the window it was read from.
      if (_workingTreePromptTarget() != target) {
        DiagnosticsLogService.instance.info(
          'git_changes',
          'prompt_dropped_window_changed',
        );
        _showClipboardMessage(
          'The window changed while the sheet was open, so the prompt was '
          'not sent.',
        );
        return;
      }
      if (_activeNativeAcpSessionKey != null) {
        _nativeComposerFocusController
          ..insertText(prompt)
          ..requestFocus();
        return;
      }
      await _pasteClipboard(promptText: prompt);
    },
  );

  /// The window a working tree prompt is meant for: the native chat, the
  /// connection and the mux window that were active.
  ({AcpSessionKey? nativeKey, int? connectionId, String? windowKey})
  _workingTreePromptTarget() => (
    nativeKey: _activeNativeAcpSessionKey,
    connectionId: _connectionId,
    windowKey: resolveTmuxBarActiveWindowKey(_currentTmuxWindowsSnapshot),
  );

  Future<void> _openPortForwardBrowserOption(
    _PortForwardBrowserOption option,
  ) => _openPortForwardBrowserOptions([option]);

  Future<void> _openPortForwardBrowserOptions(
    List<_PortForwardBrowserOption> options,
  ) async {
    await context.pushNamed<void>(
      Routes.portForwardBrowser,
      extra: PortForwardBrowserLaunch(
        tabs: [
          for (final option in options)
            PortForwardBrowserInitialTab(
              uri: option.uri,
              sourceUri: option.sourceUri,
              fallbackUri: option.fallbackUri,
              title: option.title,
              group: option.group,
            ),
        ],
      ),
    );
  }

  Future<void> _openTerminalFilePath(
    String path, {
    bool exact = false,
  }) => _runExclusiveTerminalAction(
    _TerminalExclusiveAction.sftpBrowser,
    () async {
      final normalizedPath = exact ? path : trimTerminalFilePathCandidate(path);
      if (!isSupportedTerminalFilePath(normalizedPath)) {
        _showTerminalLinkMessage('Could not open $path');
        return;
      }

      final verifiedPath = await _pathVerifier.resolveVerifiedTerminalFilePath(
        normalizedPath,
        exact: exact,
      );
      if (!mounted) {
        return;
      }
      if (verifiedPath == null) {
        if (exact) {
          _showTerminalLinkMessage('Could not open "$path" in SFTP');
        }
        return;
      }
      unawaited(ref.read(telemetryServiceProvider).logTerminalPathLinkOpened());

      final connectionId = _connectionId;
      final cwd = _workingDirectoryPath;
      final tmuxPaneDirectory = await _resolveCurrentTmuxPaneDirectory();
      if (!mounted) {
        return;
      }

      final shouldRestoreKeyboard = _temporarilyDismissTerminalKeyboard();
      String? result;
      try {
        result = await context.pushNamed<String>(
          Routes.sftp,
          pathParameters: {'hostId': widget.hostId.toString()},
          queryParameters: _buildSftpBrowserQueryParameters(
            connectionId: connectionId,
            initialPath: verifiedPath,
            workingDirectory: cwd,
            tmuxPaneDirectory: tmuxPaneDirectory,
          ),
        );
      } finally {
        _restoreTemporarilyDismissedTerminalKeyboard(shouldRestoreKeyboard);
        _resetTerminalScrollAfterSftpBrowserClosed(
          forceFullRepaint: true,
          focusAlreadyRestored: shouldRestoreKeyboard,
        );
      }

      if (mounted && result != null) {
        _showTerminalLinkMessage(result);
      }
    },
  );

  void _resetTerminalScrollAfterSftpBrowserClosed({
    bool forceFullRepaint = false,
    bool focusAlreadyRestored = false,
  }) {
    if (!mounted) {
      return;
    }

    // The terminal route stays mounted under SFTP, so reset accumulated gesture
    // deltas before the first scroll after the browser pops.
    _terminalOutputPauseTouchPointers.clear();
    _updateState(() {
      _terminalScrollResetGeneration += 1;
    });
    _syncTerminalLiveOutputAutoScroll();

    if (forceFullRepaint) {
      _terminalViewKey.currentState?.forceFullRepaint();
    }

    _rearmForegroundAppMouseReportingAfterOverlay(
      focusAlreadyRestored: focusAlreadyRestored,
    );
  }

  /// Re-emits a focus-in report after an overlay route (the SFTP browser)
  /// closes.
  ///
  /// Opening the browser calls [_temporarilyDismissTerminalKeyboard], which
  /// unfocuses the terminal and therefore emits a focus-out report. Focus-aware
  /// TUIs such as Copilot CLI in the alternate screen disable mouse-wheel
  /// reporting on focus-out, so touch scroll would stay frozen after the
  /// browser closes until the next window switch re-emits focus reports. The
  /// keyboard-restore path only refocuses when the soft keyboard was visible,
  /// so a plain scroll interaction never regained focus and never reported
  /// focus-in. Restore focus so the terminal emits the matching focus-in report
  /// (gated on the foreground app's own focus-report mode, so bare shells are
  /// unaffected) and the app re-enables mouse reporting.
  ///
  /// When [focusAlreadyRestored] is true the keyboard-restore path already
  /// requested focus (and emitted the focus-in report), so skip a second
  /// focus request to avoid scheduling a duplicate post-frame IME reset in the
  /// same frame, which can flicker or desync the soft keyboard on mobile.
  void _rearmForegroundAppMouseReportingAfterOverlay({
    bool focusAlreadyRestored = false,
  }) {
    if (!_isMobilePlatform || focusAlreadyRestored) {
      return;
    }
    _restoreTerminalFocus();
  }
}
