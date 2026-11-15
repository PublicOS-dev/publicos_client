import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
import 'package:publicos_client/widgets/fullscreen_overlay.dart';
import 'package:publicos_client/widgets/publicos_bytes_video.dart';
import 'package:publicos_client/widgets/publicos_video.dart';
import 'package:publicos_client/widgets/video_controls_pill.dart';
import 'package:publicos_client/widgets/video_url_thumbnail.dart';
import 'package:publicos_client/utils/media_mime.dart';
import 'package:zero_cached_image/zero_cached_image.dart';
import 'package:video_player/video_player.dart';
import 'package:zero_cached_video/zero_cached_video.dart';

/// Full-screen media viewer. Dispatches on URL extension or explicit `kind`
/// override: image branch keeps `InteractiveViewer` + adds double-tap zoom;
/// video branch uses `PublicOSVideo` with `autoLoadThresholdMb: infinity`
/// (the user already opted in by tapping). Save action (gallery) works for
/// both kinds via `gal`.
enum MediaKind { image, video }

/// One entry of a post's media gallery: the URL the carousel tile shows and
/// the hero tag that tile carries, so the overlay page flies to and from it.
/// Image vs video is decided by the URL extension, like the tile itself.
class MediaGalleryItem {
  final String url;
  final String heroTag;
  const MediaGalleryItem({required this.url, required this.heroTag});
  bool get isVideo => isVideoUrl(url);
}

/// What travels with a video from one surface to the next (the playback
/// moment and the current settings, loop
/// or not, muted or not): read off the live player as the user leaves,
/// applied to the next player's start. The inline tile hands one to the
/// focused media screen and to the focused post; the focused media screen
/// hands one back when it closes.
class VideoHandoff {
  final Duration position;
  final bool muted;
  final bool looping;
  const VideoHandoff({
    required this.position,
    required this.muted,
    required this.looping,
  });

  /// The player's state now; null until it is initialized (or once it is
  /// disposed). A clip that ran to the end hands over zero, so the next
  /// player restarts it.
  static VideoHandoff? of(VideoPlayerController c) {
    try {
      final v = c.value;
      if (!v.isInitialized) return null;
      return VideoHandoff(
        position: v.isCompleted ? Duration.zero : v.position,
        muted: v.volume == 0,
        looping: v.isLooping,
      );
    } catch (_) {
      return null;
    }
  }
}

/// What one overlay page shows. Built from the single-item constructor
/// (chat, avatars, a lone tile) or from a [MediaGalleryItem] list.
class _OverlayItem {
  final String? imageUrl;
  final Uint8List? imageData;
  final String? videoUrl;
  final Uint8List? videoBytes;
  final String? filename;
  final String heroTag;
  const _OverlayItem({
    this.imageUrl,
    this.imageData,
    this.videoUrl,
    this.videoBytes,
    this.filename,
    required this.heroTag,
  });
  MediaKind get kind => (videoUrl != null || videoBytes != null)
      ? MediaKind.video
      : MediaKind.image;
}

class MediaOverlay extends StatefulWidget {
  final String? imageUrl;
  final Uint8List? imageData;
  final String? videoUrl;
  final Uint8List? videoBytes;
  final String? filename;
  final String heroTag;
  final VoidCallback onClose;

  /// A post's whole media list (all of the items and the
  /// starting position): the overlay pages through it from [initialIndex],
  /// with navigation dots at the bottom, one hero tag per page, and a video
  /// player mounted only on the page being looked at. Null = one item.
  final List<MediaGalleryItem>? gallery;
  final int initialIndex;

  /// The expand handoff (the expanded version resumes where the user was
  /// watching before, so it feels seamless; mute
  /// and loop travel too). The video this overlay opens on starts as
  /// [handoff] says (position, muted, looping), and when the overlay closes
  /// [onVideoHandoff] receives that same video's state, so the inline player
  /// picks it up from there. Null = the player's defaults, report nothing.
  final VideoHandoff? handoff;
  final ValueChanged<VideoHandoff>? onVideoHandoff;

  /// The post's header row, data only (a copy of the
  /// post's header, contact icon, display name, etc., fixed so it does not
  /// move when the user scrolls, with no '...' or other buttons). Sits under
  /// the back row, above the media, on every page. Null = no row.
  final Widget? header;

  const MediaOverlay({
    super.key,
    this.imageUrl,
    this.imageData,
    this.videoUrl,
    this.videoBytes,
    this.filename,
    this.gallery,
    this.initialIndex = 0,
    this.handoff,
    this.onVideoHandoff,
    this.header,
    required this.heroTag,
    required this.onClose,
  }) : assert(
          (imageUrl != null ? 1 : 0) +
                  (imageData != null ? 1 : 0) +
                  (videoUrl != null ? 1 : 0) +
                  (videoBytes != null ? 1 : 0) +
                  (gallery != null ? 1 : 0) ==
              1,
          'Provide exactly one of imageUrl, imageData, videoUrl, videoBytes, or gallery.',
        );

  MediaKind get kind => (videoUrl != null || videoBytes != null)
      ? MediaKind.video
      : MediaKind.image;

  @override
  State<MediaOverlay> createState() => _MediaOverlayState();
}

class _MediaOverlayState extends State<MediaOverlay> {
  bool _isSaving = false;
  late final List<_OverlayItem> _items;
  late int _index;
  late final PageController _pages;
  // A zoomed image owns the horizontal drag; the pager yields until it is
  // back at 1:1 (otherwise every pan of a zoomed photo turns the page).
  bool _zoomed = false;

  // The live player of the page on screen: the controls row draws its pill,
  // and when the overlay pops the inline tile resumes where it is (only if
  // it is the page the overlay opened on). Cleared when the page turns; the
  // next page's player reports itself from its own build.
  VideoPlayerController? _video;
  int? _videoIndex;
  bool _controlsDirty = false;

  /// The fixed column (from top to bottom: back row,
  /// media content, navigation dots, controls): every page's controls land
  /// on the same line, the dots row is kept even when there is one item, so
  /// the media area is the same size on every page.
  static const double _backRow = 48;
  static const double _dotsRow = 20;
  static const double _dotsGap = 12;
  static const double _controlsRow = 52;
  static const double _bottomPad = 12;

  _OverlayItem get _item => _items[_index];

  @override
  void initState() {
    super.initState();
    final g = widget.gallery;
    if (g != null && g.isNotEmpty) {
      _items = [
        for (final e in g)
          e.isVideo
              ? _OverlayItem(videoUrl: e.url, heroTag: e.heroTag)
              : _OverlayItem(imageUrl: e.url, heroTag: e.heroTag),
      ];
      _index = widget.initialIndex.clamp(0, _items.length - 1);
    } else {
      _items = [
        _OverlayItem(
          imageUrl: widget.imageUrl,
          imageData: widget.imageData,
          videoUrl: widget.videoUrl,
          videoBytes: widget.videoBytes,
          filename: widget.filename,
          heroTag: widget.heroTag,
        ),
      ];
      _index = 0;
    }
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _dismiss() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context);
  }

  /// Called from the player's build with its controller; the controls row
  /// rebuilds on the next frame (a setState inside a build is not allowed).
  void _adopt(VideoPlayerController c, int i) {
    if (identical(_video, c) && _videoIndex == i) return;
    _video = c;
    _videoIndex = i;
    if (_controlsDirty) return;
    _controlsDirty = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controlsDirty = false;
      if (mounted) setState(() {});
    });
  }

  /// Runs inside the pop, whichever exit took it (back button, backdrop tap,
  /// system back or Escape), before the inline tile below remounts.
  void _reportPosition() {
    final report = widget.onVideoHandoff;
    final c = _video;
    if (report == null || c == null || _videoIndex != widget.initialIndex) {
      return;
    }
    final h = VideoHandoff.of(c);
    if (h != null) report(h);
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final l10n = context.l10n;
    setState(() => _isSaving = true);

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          _snack(l10n.mediaOverlayGalleryPermissionDenied);
          return;
        }
      }

      switch (_item.kind) {
        case MediaKind.image:
          await _saveImage();
          break;
        case MediaKind.video:
          await _saveVideo();
          break;
      }

      _snack(_item.kind == MediaKind.video
          ? l10n.mediaOverlayVideoSaved
          : l10n.mediaOverlayImageSaved);
    } catch (e) {
      _snack(localizedError(l10n, e, fallback: l10n.mediaOverlaySaveFailed));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveImage() async {
    Uint8List bytes;
    String filename;
    if (_item.imageData != null) {
      bytes = _item.imageData!;
      filename = 'publicos_${DateTime.now().millisecondsSinceEpoch}.png';
    } else {
      final response = await http.get(Uri.parse(_item.imageUrl!));
      if (response.statusCode != 200) {
        throw Exception('Failed to download image');
      }
      bytes = response.bodyBytes;
      final ext = _filenameExt(_item.imageUrl!) ?? 'png';
      filename = 'publicos_${DateTime.now().millisecondsSinceEpoch}.$ext';
    }
    await Gal.putImageBytes(bytes, name: filename);
  }

  Future<void> _saveVideo() async {
    // Bytes branch: PublicOSBytesVideo already wrote the bytes to a temp
    // file keyed by sha256 — but we don't have its path here. Just write
    // the bytes to a fresh temp file and save from there.
    if (_item.videoBytes != null) {
      final dir = await Directory.systemTemp.createTemp('publicos_save_');
      final ext = (_item.filename != null && _item.filename!.contains('.'))
          ? _item.filename!.substring(_item.filename!.lastIndexOf('.'))
          : '.mp4';
      final path =
          '${dir.path}/publicos_${DateTime.now().millisecondsSinceEpoch}$ext';
      final f = File(path);
      await f.writeAsBytes(_item.videoBytes!, flush: true);
      try {
        await Gal.putVideo(path);
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      return;
    }
    // Resolve to a local file path. The cache will serve a hit instantly
    // (the user already played the video to reach this overlay). On miss
    // it downloads — slow but expected once-per-video.
    final path =
        await ZeroVideoCacheManager.instance.getFilePath(_item.videoUrl!);
    await Gal.putVideo(path);
  }

  String? _filenameExt(String url) {
    try {
      final last = Uri.parse(url).pathSegments.last;
      final dot = last.lastIndexOf('.');
      if (dot == -1 || dot == last.length - 1) return null;
      return last.substring(dot + 1).toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// One page: the hero of that tile around its branch. A video page that is
  /// not the one being looked at shows its poster frame and mounts no player
  /// (one decoder in the overlay, however many clips the post has).
  Widget _page(int i, {required bool current}) {
    final item = _items[i];
    final Widget branch;
    if (item.kind == MediaKind.video) {
      if (item.videoBytes != null) {
        branch = _BytesVideoBranch(
          videoBytes: item.videoBytes!,
          filename: item.filename,
          onController: (c) => _adopt(c, i),
        );
      } else if (current) {
        branch = _VideoBranch(
          videoUrl: item.videoUrl!,
          handoff: i == widget.initialIndex ? widget.handoff : null,
          onController: (c) => _adopt(c, i),
        );
      } else {
        branch =
            VideoUrlThumbnail(videoUrl: item.videoUrl!, fit: BoxFit.contain);
      }
    } else {
      branch = _ImageBranch(
        imageUrl: item.imageUrl,
        imageData: item.imageData,
        onZoomChanged: _items.length > 1
            ? (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              }
            : null,
      );
    }
    return Center(child: Hero(tag: item.heroTag, child: branch));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _reportPosition();
      },
      child: FullscreenOverlay(
        dismissible: true,
        opacity: 0.96,
        child: Stack(
          children: [
            // Tap outside the media dismisses. Bottom-most Stack
            // child, so anything hittable above it wins — the image's
            // InteractiveViewer (opaque within the fitted image bounds), the
            // video texture (tap = play/pause), the controls pill, the buttons.
            // Only the empty backdrop / letterbox reaches this.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismiss,
              ),
            ),
            // The media has the WHOLE screen, edge to edge, and is centred in
            // it; the back arrow, the post's header, the dots and the controls
            // are laid over it inside the safe areas, each on a soft scrim
            // (the usual full-screen viewer layout). If the media area
            // started under the status bar and the back row instead, a tall
            // clip would sit low: a black band above it and almost none below.
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRect(
                      child: _items.length == 1
                          ? _page(0, current: true)
                          : PageView.builder(
                              controller: _pages,
                              physics: _zoomed
                                  ? const NeverScrollableScrollPhysics()
                                  : const PageScrollPhysics(),
                              itemCount: _items.length,
                              onPageChanged: (i) => setState(() {
                                _index = i;
                                _zoomed = false;
                                // The leaving page's player is gone
                                // with it.
                                _video = null;
                                _videoIndex = null;
                              }),
                              itemBuilder: (context, i) =>
                                  _page(i, current: i == _index),
                            ),
                    ),
                  ),
                  // Top chrome: back row, then the post's header in a fixed
                  // spot under it, whatever the post or the media.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xB3000000),
                            Color(0x00000000),
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(height: pad.top),
                          SizedBox(
                            height: _backRow,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: IconButton(
                                  color: Colors.white,
                                  iconSize: 24,
                                  icon: const Icon(Icons.arrow_back),
                                  onPressed: _dismiss,
                                  tooltip: context.l10n.mediaOverlayBack,
                                ),
                              ),
                            ),
                          ),
                          // Data only, nothing in it taps, and a tap on it
                          // does not reach the media or the backdrop. Dark
                          // tokens whatever the app's theme.
                          if (widget.header != null)
                            AbsorbPointer(
                              child: Theme(
                                data: GlassTheme.darkTheme,
                                child: widget.header!,
                              ),
                            ),
                          const SizedBox(height: 18),
                        ],
                      ),
                    ),
                  ),
                  // The dots and the controls row lie OVER the bottom of
                  // the media too: a tall clip or picture does not
                  // give up their 96 px plus the safe inset, which
                  // would pinch 9:16 media into side bars. A scrim
                  // that ignores the pointer keeps them readable; the
                  // rows themselves only hit-test their own buttons,
                  // so a tap on empty space still reaches the media.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: _dotsRow +
                        _dotsGap +
                        _controlsRow +
                        _bottomPad +
                        pad.bottom +
                        40,
                    child: const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Color(0xB3000000),
                              Color(0x00000000),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: _dotsRow,
                          child:
                              _items.length > 1 ? Center(child: _dots()) : null,
                        ),
                        const SizedBox(height: _dotsGap),
                        SizedBox(
                          height: _controlsRow,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: _controls(),
                          ),
                        ),
                        SizedBox(height: _bottomPad + pad.bottom),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dots() {
    return IgnorePointer(
      child: Semantics(
        label: '${_index + 1} / ${_items.length}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _items.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: i == _index ? 8 : 6,
                height: i == _index ? 8 : 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(
                    alpha: i == _index ? 1.0 : 0.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The bottom row: a video page's playback pill (once its player has
  /// reported itself), an image page's save button at the right. Same row,
  /// same height, whichever page is on screen.
  Widget _controls() {
    if (_item.kind == MediaKind.video) {
      final c = _video;
      if (c == null || _videoIndex != _index) return const SizedBox.shrink();
      return Center(
        child: VideoControlsPill(
          key: ValueKey(c),
          controller: c,
          onSave: _save,
          isSaving: _isSaving,
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: _isSaving
          ? const PhigitalLoadingWidget(size: 16, showShadows: false)
          : IconButton(
              icon: const Icon(Icons.save_alt, color: Colors.white),
              onPressed: _save,
            ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Image branch — InteractiveViewer with double-tap-to-zoom-at-point.
// ───────────────────────────────────────────────────────────────────────

class _ImageBranch extends StatefulWidget {
  final String? imageUrl;
  final Uint8List? imageData;

  /// Reports whether the image is zoomed past 1:1, so a pager above can
  /// yield the horizontal drag to the pan.
  final ValueChanged<bool>? onZoomChanged;

  const _ImageBranch({this.imageUrl, this.imageData, this.onZoomChanged});

  @override
  State<_ImageBranch> createState() => _ImageBranchState();
}

class _ImageBranchState extends State<_ImageBranch>
    with SingleTickerProviderStateMixin {
  static const double _zoomLevel = 2.5;

  final TransformationController _transform = TransformationController();
  late final AnimationController _animController;
  Animation<Matrix4>? _animation;
  TapDownDetails? _doubleTapDetails;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(() {
        if (_animation != null) {
          _transform.value = _animation!.value;
        }
      });
  }

  @override
  void dispose() {
    _animController.dispose();
    _transform.dispose();
    super.dispose();
  }

  bool get _isZoomed {
    final m = _transform.value;
    // Identity scale (1.0) means not zoomed; anything else counts.
    return (m.getMaxScaleOnAxis() - 1.0).abs() > 0.01;
  }

  void _handleDoubleTap() {
    final tapPos = _doubleTapDetails?.localPosition;
    Matrix4 endMatrix;

    if (_isZoomed) {
      endMatrix = Matrix4.identity();
    } else if (tapPos != null) {
      // Translate so the tap point ends up roughly under the same finger
      // position after scaling.
      endMatrix = Matrix4.identity()
        ..translate(
            -tapPos.dx * (_zoomLevel - 1), -tapPos.dy * (_zoomLevel - 1))
        ..scale(_zoomLevel);
    } else {
      endMatrix = Matrix4.identity()..scale(_zoomLevel);
    }

    _animation = Matrix4Tween(
      begin: _transform.value,
      end: endMatrix,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));
    _animController.forward(from: 0);
    widget.onZoomChanged?.call(!_isZoomed);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transform,
        clipBehavior: Clip.none,
        panEnabled: true,
        onInteractionEnd: (_) => widget.onZoomChanged?.call(_isZoomed),
        minScale: 0.5,
        maxScale: 4.0,
        child: _buildImage(),
      ),
    );
  }

  Widget _buildImage() {
    if (widget.imageData != null) {
      return Image.memory(
        widget.imageData!,
        fit: BoxFit.contain,
        errorBuilder: (context, _, __) => Center(
          child: Icon(
            Icons.broken_image,
            color: ThemeProvider.errorDark,
            size: 48.0,
          ),
        ),
      );
    }
    return ZeroCachedImage(
      imageUrl: widget.imageUrl!,
      fit: BoxFit.contain,
      placeholder: (context, _) => const Center(
        child: PhigitalLoadingWidget(size: 16, showShadows: false),
      ),
      errorWidget: (context, _, __) => Center(
        child: Icon(
          Icons.error_outline,
          color: ThemeProvider.errorDark,
          size: 48.0,
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Video branch — PublicOSVideo with threshold override (user opted in).
// ───────────────────────────────────────────────────────────────────────

class _VideoBranch extends StatelessWidget {
  final String videoUrl;
  final VideoHandoff? handoff;
  final ValueChanged<VideoPlayerController> onController;
  const _VideoBranch({
    required this.videoUrl,
    required this.handoff,
    required this.onController,
  });

  @override
  Widget build(BuildContext context) {
    return PublicOSVideo(
      videoUrl: videoUrl,
      fit: BoxFit.contain,
      autoplay: true,
      // Show the decoded frame immediately while the player initializes — the
      // thumbnail shares the same cached file the player streams from.
      poster: VideoUrlThumbnail(videoUrl: videoUrl, fit: BoxFit.contain),
      // The user opted in by opening the overlay; never gate here.
      thresholdOverrideMb: double.infinity,
      // Picks up where the inline player was when it handed off, muted and
      // looping as it was. With no handoff (a poster tile, a chat clip) the
      // sound is on: the user opted in by opening the clip.
      initialPosition: handoff?.position,
      startMuted: handoff?.muted ?? false,
      loop: handoff?.looping ?? false,
      // The controls live in the overlay's bottom row, not over the video:
      // hand the controller up and draw nothing here.
      controlsBuilder: (ctx, c) {
        onController(c as VideoPlayerController);
        return const SizedBox.shrink();
      },
      placeholder: (_, __) => const Center(
        child: PhigitalLoadingWidget(size: 16, showShadows: false),
      ),
      errorWidget: (_, __, ___) => Center(
        child: Icon(
          Icons.error_outline,
          color: ThemeProvider.errorDark,
          size: 48.0,
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Bytes-video branch — same fullscreen treatment, different player.
// ───────────────────────────────────────────────────────────────────────

class _BytesVideoBranch extends StatelessWidget {
  final Uint8List videoBytes;
  final String? filename;
  final ValueChanged<VideoPlayerController> onController;

  const _BytesVideoBranch({
    required this.videoBytes,
    this.filename,
    required this.onController,
  });

  @override
  Widget build(BuildContext context) {
    return PublicOSBytesVideo(
      data: videoBytes,
      filename: filename,
      fit: BoxFit.contain,
      autoplay: true,
      showBuiltInPlayPause: true,
      // No autoplay-mute in overlay — user opted in by tapping expand.
      // Same as the URL branch: the pill is the overlay's bottom row.
      controlsBuilder: (ctx, c) {
        onController(c);
        return const SizedBox.shrink();
      },
      placeholder: (_) => const Center(
        child: PhigitalLoadingWidget(size: 16, showShadows: false),
      ),
      errorWidget: (_, __) => Center(
        child: Icon(
          Icons.error_outline,
          color: ThemeProvider.errorDark,
          size: 48.0,
        ),
      ),
    );
  }
}
