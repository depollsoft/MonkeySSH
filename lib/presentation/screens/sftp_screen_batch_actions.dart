part of 'sftp_screen.dart';

const _batchSelectionConstraints = RemoteFilePickerConstraints(
  allowMultiple: true,
);

/// View settings, filtering, selection-mode batch actions and archive
/// extraction for the SFTP browser.
extension _SftpScreenBatchActions on _SftpScreenState {
  RemoteFilePickerConstraints? get _activeSelectionConstraints =>
      widget.selectionConstraints ??
      (_isBatchSelecting ? _batchSelectionConstraints : null);

  bool get _selectionActive => _activeSelectionConstraints != null;

  bool get _batchRunning => _batchProgress != null;

  /// Entries after hidden-file, filter and sort settings.
  List<SftpName> get _visibleFiles {
    final alwaysShow = _highlightedDirectoryPath == _currentPath
        ? _highlightedFileName
        : null;
    final cache = _visibleFilesCache;
    if (cache != null &&
        identical(cache.files, _files) &&
        cache.settings == _viewSettings &&
        cache.filter == _filterQuery &&
        cache.alwaysShow == alwaysShow) {
      return cache.visible;
    }
    final visible = applySftpBrowserView(
      _files,
      _viewSettings,
      filter: _filterQuery,
      alwaysShow: alwaysShow,
    );
    _visibleFilesCache = (
      files: _files,
      settings: _viewSettings,
      filter: _filterQuery,
      alwaysShow: alwaysShow,
      visible: visible,
    );
    return visible;
  }

  Future<void> _loadViewSettings() async {
    try {
      final settings = await ref
          .read(sftpBrowserViewStoreProvider)
          .load(widget.hostId);
      if (mounted && !_viewSettingsChangedLocally) {
        _update(() => _viewSettings = settings);
      }
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'sftp.view',
        'load_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  Future<void> _showViewOptions() async {
    final next = await showSftpBrowserViewOptions(context, _viewSettings);
    if (next == null || !mounted) return;
    await _applyViewSettings(next);
  }

  /// Shows [next] now and saves it for this host.
  Future<void> _applyViewSettings(SftpBrowserViewSettings next) async {
    _viewSettingsChangedLocally = true;
    _update(() => _viewSettings = next);
    try {
      await ref.read(sftpBrowserViewStoreProvider).save(widget.hostId, next);
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'sftp.view',
        'save_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  void _onFilterChanged(String query) {
    _update(() {
      _filterQuery = query;
      _filterDirectory = _currentPath;
    });
    final filters = ref.read(sftpBrowserFiltersProvider.notifier);
    final next = Map<int, SftpBrowserFilter>.of(filters.state);
    if (query.trim().isEmpty) {
      next.remove(widget.hostId);
    } else {
      next[widget.hostId] = (directory: _currentPath, query: query);
    }
    filters.state = next;
  }

  /// Keeps the filter scoped to one directory: entering another clears it,
  /// and returning to the remembered one restores it. Runs inside setState.
  void _syncFilterWithDirectory(String path) {
    if (_filterDirectory == path) return;
    _filterDirectory = path;
    final remembered = ref.read(sftpBrowserFiltersProvider)[widget.hostId];
    final query = remembered?.directory == path ? remembered!.query : '';
    _filterQuery = query;
    if (_filterController.text != query) _filterController.text = query;
    if (remembered != null && query.isEmpty) {
      final filters = ref.read(sftpBrowserFiltersProvider.notifier);
      filters.state = Map.of(filters.state)..remove(widget.hostId);
    }
  }

  void _clearFilter() {
    _filterController.clear();
    _onFilterChanged('');
  }

  void _startBatchSelection([SftpName? file]) {
    _clearHighlightedFile();
    _update(() {
      _isBatchSelecting = true;
      _selectedFiles = const [];
    });
    if (file != null) _toggleRemoteFileSelection(file);
  }

  void _endBatchSelection() {
    _update(() {
      _isBatchSelecting = false;
      _selectedFiles = const [];
    });
  }

  void _beginBatch(SftpBatchProgress progress) {
    _update(() => _batchProgress = progress);
  }

  void _endBatch(SftpBatchProgress progress) {
    if (mounted && identical(_batchProgress, progress)) {
      _update(() => _batchProgress = null);
    }
    // The bar unsubscribes on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  }

  /// Reports a finished batch: a summary snackbar with a details action, or
  /// the per-file list straight away when anything failed.
  void _reportBatch(
    SftpBatchReport report, {
    required String title,
    required String pastVerb,
    String? message,
  }) {
    if (!mounted) return;
    final summary = message ?? sftpBatchSummary(pastVerb, report);
    if (!report.allDone && !report.cancelled) {
      unawaited(showSftpBatchResults(context, title: title, report: report));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(summary),
        action: report.results.length > 1 || !report.allDone
            ? SnackBarAction(
                label: 'Details',
                onPressed: () => unawaited(
                  showSftpBatchResults(context, title: title, report: report),
                ),
              )
            : null,
      ),
    );
  }

  Future<void> _deleteSelection() async {
    final sftp = _sftp;
    final files = List<RemoteFileSelection>.of(_selectedFiles);
    if (sftp == null || files.isEmpty || _batchRunning) return;
    final noun = files.length == 1 ? 'file' : 'files';
    final confirmed = await showDeleteConfirmationDialog(
      context,
      title: 'Delete ${files.length} $noun',
      message: files.length == 1
          ? 'Delete "${files.single.displayName}"? This cannot be undone.'
          : 'Delete ${files.length} selected files? This cannot be undone.',
    );
    if (!confirmed || !mounted) return;
    final progress = SftpBatchProgress(verb: 'Deleting', total: files.length);
    _beginBatch(progress);
    final SftpBatchReport report;
    try {
      report = await runSftpBatch<RemoteFileSelection>(
        items: files,
        nameOf: (file) => file.displayName,
        progress: progress,
        run: (file, _) => sftp.remove(file.remotePath),
      );
    } finally {
      _endBatch(progress);
    }
    _logBatch('delete', report);
    if (!mounted) return;
    final deleted = {
      for (final (index, result) in report.results.indexed)
        if (result.outcome == SftpBatchOutcome.done) files[index].remotePath,
    };
    _update(() {
      _selectedFiles = List.unmodifiable(
        _selectedFiles.where((file) => !deleted.contains(file.remotePath)),
      );
      if (_selectedFiles.isEmpty) _isBatchSelecting = false;
    });
    await _loadDirectory(_currentPath);
    _reportBatch(report, title: 'Delete results', pastVerb: 'Deleted');
  }

  void _startMove() {
    if (_selectedFiles.isEmpty || _batchRunning) return;
    _update(() {
      _movingFiles = List.unmodifiable(_selectedFiles);
      _isBatchSelecting = false;
      _selectedFiles = const [];
    });
  }

  void _cancelMove() {
    _update(() => _movingFiles = null);
  }

  Future<void> _moveHere() async {
    final sftp = _sftp;
    final files = _movingFiles;
    if (sftp == null || files == null || _batchRunning) return;
    final destination = _currentPath;
    _update(() => _movingFiles = null);
    final progress = SftpBatchProgress(verb: 'Moving', total: files.length);
    _beginBatch(progress);
    final SftpBatchReport report;
    try {
      report = await runSftpBatch<RemoteFileSelection>(
        items: files,
        nameOf: (file) => file.displayName,
        progress: progress,
        run: (file, _) async {
          if (parentSftpPath(file.remotePath) == destination) {
            throw const SftpBatchItemSkipped('Already in this folder');
          }
          final target = joinRemotePath(destination, file.displayName);
          if (await _remoteEntryExists(sftp, target)) {
            // posix-rename would replace it, so never rename onto a name.
            throw const SftpBatchItemFailure(
              'A file with this name is already here',
            );
          }
          await sftp.rename(file.remotePath, target);
        },
      );
    } finally {
      _endBatch(progress);
    }
    _logBatch('move', report);
    if (!mounted) return;
    await _loadDirectory(_currentPath);
    _reportBatch(report, title: 'Move results', pastVerb: 'Moved');
  }

  Future<bool> _remoteEntryExists(SftpClient sftp, String remotePath) async {
    try {
      await sftp.stat(remotePath, followLink: false);
      return true;
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return false;
      rethrow;
    }
  }

  Future<void> _downloadSelection() async {
    final sftp = _sftp;
    final files = List<RemoteFileSelection>.of(_selectedFiles);
    if (sftp == null || files.isEmpty || _batchRunning) return;
    if (files.length == 1) {
      final file = files.single;
      await _downloadFile(
        SftpName(
          filename: file.displayName,
          longname: file.displayName,
          attr: SftpFileAttrs(size: file.sizeBytes),
        ),
        target: (sftp: sftp, remotePath: file.remotePath),
      );
      return;
    }

    final telemetryService = ref.read(telemetryServiceProvider);
    final remoteFileService = ref.read(remoteFileServiceProvider);
    final sizes = files.map((file) => file.sizeBytes);
    final sizeBytes = sizes.contains(null)
        ? null
        : sizes.fold<int>(0, (total, size) => total + size!);
    final startedAt = DateTime.now();
    unawaited(
      telemetryService.logSftpTransferStarted(
        direction: 'download',
        fileCount: files.length,
        sizeBytes: sizeBytes,
      ),
    );
    final staging = await (await getTemporaryDirectory()).createTemp(
      'sftp-export-',
    );
    var keepStaging = false;
    final downloaded = <({String name, File file})>[];
    final progress = SftpBatchProgress(
      verb: 'Downloading',
      total: files.length,
    );
    _beginBatch(progress);
    try {
      final SftpBatchReport report;
      try {
        report = await runSftpBatch<RemoteFileSelection>(
          items: files,
          nameOf: (file) => file.displayName,
          progress: progress,
          run: (file, index) async {
            progress.start(index, file.displayName, totalBytes: file.sizeBytes);
            // One folder per item keeps same-named files from two folders
            // apart until they are exported.
            final local = File(
              path.join(
                staging.path,
                '$index',
                path.basename(file.displayName),
              ),
            );
            await local.parent.create();
            final cancelToken = RemoteFileDownloadCancelToken();
            final removeCancel = progress.onCancel(cancelToken.cancel);
            try {
              await remoteFileService.downloadFile(
                sftp: sftp,
                remotePath: file.remotePath,
                localPath: local.path,
                onProgress: progress.updateBytes,
                cancelToken: cancelToken,
              );
            } finally {
              removeCancel();
            }
            downloaded.add((name: file.displayName, file: local));
          },
        );
      } finally {
        _endBatch(progress);
      }
      if (report.firstError case final error?) {
        unawaited(
          telemetryService.logSftpTransferFailed(
            direction: 'download',
            fileCount: files.length,
            sizeBytes: sizeBytes,
            duration: DateTime.now().difference(startedAt),
            failureCategory: _sftpTelemetryFailureCategory(error),
          ),
        );
      }
      _logBatch('download', report);
      if (!mounted) return;
      if (downloaded.isEmpty) {
        _reportBatch(report, title: 'Download results', pastVerb: 'Downloaded');
        return;
      }
      final exported = await _exportLocalFiles(downloaded);
      keepStaging = exported == _LocalFileExport.shared;
      if (exported == _LocalFileExport.cancelled) return;
      if (report.allDone) {
        unawaited(
          telemetryService.logSftpTransferCompleted(
            direction: 'download',
            fileCount: files.length,
            sizeBytes: sizeBytes,
            duration: DateTime.now().difference(startedAt),
          ),
        );
      }
      _reportBatch(report, title: 'Download results', pastVerb: 'Downloaded');
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) rethrow;
      _showSftpFailureSnackBar(
        message: 'Could not save the downloaded files. Try again.',
        eventName: 'batch_export_failed',
        error: error,
      );
    } finally {
      if (!keepStaging) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // Temporary storage may already have removed the staging folder.
        }
      }
    }
  }

  /// Hands several downloaded files to the user: the share sheet on phones,
  /// or a chosen folder on desktops, where existing files are never replaced.
  Future<_LocalFileExport> _exportLocalFiles(
    List<({String name, File file})> files,
  ) async {
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    if (mobile) {
      final box = context.findRenderObject() as RenderBox?;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [
            for (final entry in files)
              XFile(
                entry.file.path,
                name: entry.name,
                mimeType: inferRemoteFileMimeType(entry.name),
              ),
          ],
          sharePositionOrigin: box != null && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
      return result.status == ShareResultStatus.dismissed
          ? _LocalFileExport.cancelled
          : _LocalFileExport.shared;
    }
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Save ${files.length} files',
    );
    if (directory == null) return _LocalFileExport.cancelled;
    for (final entry in files) {
      await entry.file.copy(_freeLocalPath(directory, entry.name));
    }
    return _LocalFileExport.saved;
  }

  String _freeLocalPath(String directory, String name) {
    final extension = path.extension(name);
    final stem = path.basenameWithoutExtension(name);
    for (var attempt = 1; ; attempt++) {
      final candidate = path.join(
        directory,
        attempt == 1 ? name : '$stem ($attempt)$extension',
      );
      if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
  }

  /// Whether "Extract here" applies to [file] on this host.
  bool _canExtract(SftpName file) =>
      !file.attr.isDirectory &&
      remoteArchiveKindForName(file.filename) != null &&
      !RegExp(r'^/?[A-Za-z]:(?:/|$)').hasMatch(_currentPath);

  Future<void> _extractArchive(SftpName file) async {
    final sftp = _sftp;
    final kind = remoteArchiveKindForName(file.filename);
    final connectionId = _connectionId;
    if (sftp == null || kind == null || connectionId == null || _batchRunning) {
      return;
    }
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(connectionId);
    if (session == null) {
      _showMessage('Reconnect to extract archives on this host.');
      return;
    }
    final extractor = RemoteArchiveExtractor(
      runCommand: ref.read(remoteCommandRunnerFactoryProvider)(session),
    );
    final progress = SftpBatchProgress(
      verb: 'Extracting',
      total: 1,
      cancellable: false,
      indeterminate: true,
    )..start(0, file.filename);
    _beginBatch(progress);
    try {
      final result = await extractor.extractHere(
        sftp: sftp,
        archivePath: joinRemotePath(_currentPath, file.filename),
        kind: kind,
      );
      if (!mounted) return;
      await _loadDirectory(_currentPath);
      _highlightFile(_currentPath, result.name);
      _showMessage(
        result.isDirectory
            ? 'Extracted into "${result.name}"'
            : 'Extracted "${result.name}"',
      );
    } on RemoteArchiveException catch (error) {
      _showMessage(error.message);
    } on Object catch (error) {
      if (error is! Exception && !isExpectedSshOperationError(error)) rethrow;
      _showSftpFailureSnackBar(
        message:
            'Could not extract the archive. Check the connection and '
            'try again.',
        eventName: 'extract_failed',
        error: error,
      );
    } finally {
      _endBatch(progress);
    }
  }

  void _logBatch(String action, SftpBatchReport report) {
    DiagnosticsLogService.instance.info(
      'sftp.batch',
      action,
      fields: {
        'count': report.results.length,
        'done': report.doneCount,
        'cancelled': report.cancelled,
        if (report.firstError case final error?) 'errorType': error.runtimeType,
      },
    );
  }
}
