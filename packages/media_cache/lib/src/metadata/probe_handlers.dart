import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;

import '../audio_cache_service.dart';
import 'tag_probe_result.dart';

/// Abstract handler for audio format probing strategies.
abstract class ProbeHandler {
  /// Returns true if this handler should be used for the given file path/extension.
  bool canHandle(String path);

  /// Executes the probing logic.
  ///
  /// Returns a [TagProbeResult] if successful, or null if it fails or decides not to handle.
  Future<TagProbeResult?> probe({
    required Uri uri,
    required Map<String, String>? headers,
    required bool includeArtwork,
    required int? totalBytes,
    required TagProbeResult? currentBest,
    required AudioCacheService audioCache,
    required Future<TagProbeResult?> Function(
      File file, {
      required bool includeArtwork,
    })
    prober,
    required Future<File?> Function(int maxBytes) downloadPartial,
    required Future<File?> Function(int maxBytes) downloadTail,
  });
}

/// Handler for formats with metadata at the start (OGG, FLAC, MP3 with ID3v2).
///
/// These formats usually have metadata at the start.
/// However, if artwork is large, it might exceed the initial probe size (e.g. 8MB).
/// This handler implements a "Progressive Head Expansion" strategy:
/// It continues to download larger chunks of the file until metadata is found,
/// rather than relying on a hard file size limit.
class ProgressiveHeadHandler implements ProbeHandler {
  @override
  bool canHandle(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.ogg' ||
        ext == '.0gg' ||
        ext == '.oga' ||
        ext == '.opus' ||
        ext == '.flac' ||
        ext == '.mp3';
  }

  @override
  Future<TagProbeResult?> probe({
    required Uri uri,
    required Map<String, String>? headers,
    required bool includeArtwork,
    required int? totalBytes,
    required TagProbeResult? currentBest,
    required AudioCacheService audioCache,
    required Future<TagProbeResult?> Function(
      File file, {
      required bool includeArtwork,
    })
    prober,
    required Future<File?> Function(int maxBytes) downloadPartial,
    required Future<File?> Function(int maxBytes) downloadTail,
  }) async {
    // Check if we have a "good enough" result.
    // For OGG, we really want artwork/lyrics if we requested them.
    final hasGoodResult =
        currentBest != null &&
        (currentBest.title != null || currentBest.artist != null) &&
        (!includeArtwork || (currentBest.artwork?.isNotEmpty ?? false));

    if (hasGoodResult) return null; // No need to fallback

    // Previous steps (in TagProbeService) tried up to 8MB.
    // We start from 16MB and double until we find tags or hit the end.
    var currentSize = 16 * 1024 * 1024;

    // Safety limit: e.g. 64MB. If headers are larger than 64MB, it's probably broken or insane.
    // Or we can go up to totalBytes.
    final limit = (totalBytes != null && totalBytes > 0)
        ? totalBytes
        : 100 * 1024 * 1024;

    while (currentSize <= limit) {
      final file = await downloadPartial(currentSize);
      if (file == null) break;

      final parsed = await prober(file, includeArtwork: includeArtwork);
      if (parsed != null) {
        // A result is "better" if it brings something we were asked for:
        // either textual tags (title/artist), or — when artwork was requested —
        // an embedded cover. The previous `&&` form required both at once,
        // which silently dropped files that have a cover but no text tags.
        final isBetter =
            (parsed.title != null || parsed.artist != null) ||
            (includeArtwork && (parsed.artwork?.isNotEmpty ?? false));

        if (isBetter) return parsed;
      }

      // If we reached the exact file size, no need to try larger
      if (totalBytes != null && currentSize >= totalBytes) break;

      currentSize *= 2;

      // Cap at totalBytes if we overshoot
      if (totalBytes != null && currentSize > totalBytes) {
        currentSize = totalBytes;
      }
    }

    return null;
  }
}

/// Handler for formats whose metadata (and embedded artwork) can live at the
/// **end** of the file — most notably M4A/AAC/MP4 where the `moov` atom is
/// often placed after the audio data by encoders that don't write
/// "fast-start". A 2 MB tail grab is enough for a moov with text tags but not
/// for one carrying a multi-megabyte cover, so we grow the tail exponentially
/// until the artwork turns up or we've pulled the whole file.
///
/// Registered after [ProgressiveHeadHandler]; for head-first formats that
/// handler returns a good result first and we never run. For M4A/AAC it's the
/// only progressive path, and for any format where the head strategy failed to
/// surface artwork we still get a chance to find it at the tail.
class ProgressiveTailHandler implements ProbeHandler {
  @override
  bool canHandle(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.m4a' ||
        ext == '.aac' ||
        ext == '.mp4' ||
        ext == '.alac' ||
        ext == '.wav';
  }

  @override
  Future<TagProbeResult?> probe({
    required Uri uri,
    required Map<String, String>? headers,
    required bool includeArtwork,
    required int? totalBytes,
    required TagProbeResult? currentBest,
    required AudioCacheService audioCache,
    required Future<TagProbeResult?> Function(
      File file, {
      required bool includeArtwork,
    })
    prober,
    required Future<File?> Function(int maxBytes) downloadPartial,
    required Future<File?> Function(int maxBytes) downloadTail,
  }) async {
    final hasGoodResult =
        currentBest != null &&
        (currentBest.title != null || currentBest.artist != null) &&
        (!includeArtwork || (currentBest.artwork?.isNotEmpty ?? false));

    if (hasGoodResult) return null;

    // TagProbeService already grabbed a 2 MB tail before handing off to
    // handlers; start the expansion from 4 MB and keep doubling.
    var currentSize = 4 * 1024 * 1024;

    final limit = (totalBytes != null && totalBytes > 0)
        ? totalBytes
        : 100 * 1024 * 1024;

    while (currentSize <= limit) {
      final file = await downloadTail(currentSize);
      if (file == null) break;

      final parsed = await prober(file, includeArtwork: includeArtwork);
      if (parsed != null) {
        // Same relaxed condition as ProgressiveHeadHandler: accept a result
        // that has either text tags or (when requested) artwork.
        final isBetter =
            (parsed.title != null || parsed.artist != null) ||
            (includeArtwork && (parsed.artwork?.isNotEmpty ?? false));

        if (isBetter) return parsed;
      }

      // Reached the whole file — no point asking for an even bigger tail.
      if (totalBytes != null && currentSize >= totalBytes) break;

      currentSize *= 2;
      if (totalBytes != null && currentSize > totalBytes) {
        currentSize = totalBytes;
      }
    }

    return null;
  }
}
