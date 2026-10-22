import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keeps custom alarm sounds somewhere Android will not purge.
///
/// file_picker returns a path inside the app's *cache* directory, which the OS
/// may clear at any time (low storage, "clear cache"). An alarm pointing at such
/// a path would silently fall back to the default sound. This class copies the
/// picked file into `<app documents>/alarm_sounds/` and returns that stable path
/// to store in `AlarmModel.customAudioPath`.
///
/// Typical use in the alarm editor:
/// ```dart
/// final path = await AudioFileManager.pickAndImport(alarmId: alarm.id);
/// if (path != null) draft = draft.copyWith(customAudioPath: path);
/// ```
class AudioFileManager {
  AudioFileManager._();

  static const String folderName = 'alarm_sounds';

  static Future<Directory> soundsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, folderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Opens the system audio picker and imports the choice.
  /// Returns the permanent path, or null if the user cancelled.
  /// Throws [FileSystemException] if the copy fails.
  static Future<String?> pickAndImport({required int alarmId}) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.first.path;
    if (picked == null) return null;
    return importFile(picked, alarmId: alarmId);
  }

  /// Copies [sourcePath] into the managed folder and returns the new path.
  /// Already-managed files are returned unchanged.
  static Future<String> importFile(
    String sourcePath, {
    required int alarmId,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Selected audio file no longer exists', sourcePath);
    }

    final dir = await soundsDir();
    if (p.isWithin(dir.path, sourcePath)) return sourcePath;

    var ext = p.extension(sourcePath).toLowerCase();
    if (ext.isEmpty || ext.length > 6) ext = '.mp3';

    final dest = p.join(
      dir.path,
      'alarm_${alarmId}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final partial = File('$dest.part');

    try {
      // Copy to a temp name first so a crash never leaves a truncated sound.
      await source.copy(partial.path);
      if (await partial.length() == 0) {
        throw FileSystemException('Copied audio file is empty', sourcePath);
      }
      await partial.rename(dest);
    } catch (_) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    }

    await _deleteIfInCache(sourcePath);
    return dest;
  }

  /// Deletes a previously imported sound. Files outside the managed folder
  /// are never touched, so it is safe to call with any stored path.
  static Future<void> deleteImported(String? path) async {
    if (path == null || path.isEmpty) return;
    final dir = await soundsDir();
    if (!p.isWithin(dir.path, path)) return;
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  /// Removes managed files (and leftover `.part` files) that no alarm uses.
  /// Call occasionally, e.g. at startup, with every alarm's customAudioPath.
  static Future<void> pruneOrphans(Iterable<String?> inUse) async {
    final keep = inUse.whereType<String>().map(p.normalize).toSet();
    final dir = await soundsDir();
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!keep.contains(p.normalize(entity.path))) {
        try {
          await entity.delete();
        } catch (e) {
          debugPrint('AudioFileManager.pruneOrphans: $e');
        }
      }
    }
  }

  /// Tidy up file_picker's cache copy once we hold our own.
  static Future<void> _deleteIfInCache(String path) async {
    try {
      final cache = await getTemporaryDirectory();
      if (p.isWithin(cache.path, path)) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }
}