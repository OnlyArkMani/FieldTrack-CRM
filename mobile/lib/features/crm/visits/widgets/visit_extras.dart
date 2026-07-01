import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/config/env.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/storage/token_storage.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../data/visit_repository.dart';
import '../models/visit.dart';
import '../utils/geo.dart';

/// Distance & ETA to the customer being visited (checklist #18, nice-to-have).
/// Fetches the executive's current GPS fix once and shows straight-line
/// distance + a rough ETA. Renders nothing until it has both coordinates, and
/// silently hides itself if location is unavailable — it's an aid, never a
/// blocker.
class NextVisitEtaCard extends StatefulWidget {
  const NextVisitEtaCard({
    super.key,
    required this.farmerLat,
    required this.farmerLng,
    required this.farmerName,
  });

  final double farmerLat;
  final double farmerLng;
  final String farmerName;

  @override
  State<NextVisitEtaCard> createState() => _NextVisitEtaCardState();
}

class _NextVisitEtaCardState extends State<NextVisitEtaCard> {
  double? _distanceM;
  int? _etaMin;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  Future<void> _compute() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final d = distanceMeters(
          pos.latitude, pos.longitude, widget.farmerLat, widget.farmerLng);
      if (!mounted) return;
      setState(() {
        _distanceM = d;
        _etaMin = etaMinutes(d);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(bottom: AppDimens.grid * 2),
        child: SizedBox(
          height: 2,
          child: LinearProgressIndicator(minHeight: 2),
        ),
      );
    }
    if (_distanceM == null) return const SizedBox.shrink();
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 2),
      child: Container(
        padding: const EdgeInsets.all(AppDimens.grid * 1.5),
        decoration: BoxDecoration(
          color: scheme.secondary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        ),
        child: Row(
          children: [
            Icon(Icons.near_me_rounded, color: scheme.secondary, size: 20),
            const SizedBox(width: AppDimens.grid),
            Expanded(
              child: _metric('Distance', formatDistance(_distanceM!), colors),
            ),
            Expanded(
              child: _metric('ETA', formatEta(_etaMin ?? 0), colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, dynamic colors) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
          Text(value,
              style: AppTextStyles.bodyMedium.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700)),
        ],
      );
}

/// Attach up to N photos to a visit (checklist #24). Self-contained: loads its
/// own list, adds via camera/gallery, and deletes. The per-visit cap is
/// enforced server-side; this hides the add button once it's reached.
class VisitPhotosSection extends ConsumerStatefulWidget {
  const VisitPhotosSection({super.key, required this.visitId, this.maxPhotos = 5});

  final int visitId;
  final int maxPhotos;

  @override
  ConsumerState<VisitPhotosSection> createState() => _VisitPhotosSectionState();
}

class _VisitPhotosSectionState extends ConsumerState<VisitPhotosSection> {
  final _picker = ImagePicker();
  List<VisitPhoto> _photos = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  VisitRepository get _repo => ref.read(visitRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _repo.listPhotos(widget.visitId);
      if (!mounted) return;
      setState(() {
        _photos = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _add(ImageSource source) async {
    if (_busy) return;
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1600,
      );
      if (picked == null) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      final photo =
          await _repo.uploadPhoto(widget.visitId, filePath: picked.path);
      if (!mounted) return;
      setState(() {
        _photos = [..._photos, photo];
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not add the photo. Try again.';
      });
    }
  }

  Future<void> _delete(VisitPhoto p) async {
    setState(() => _busy = true);
    try {
      await _repo.deletePhoto(p.id);
      if (!mounted) return;
      setState(() {
        _photos = _photos.where((e) => e.id != p.id).toList();
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  void _pickSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _add(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _add(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    final canAdd = _photos.length < widget.maxPhotos && !_busy;
    final token = ref.read(tokenStorageProvider).accessToken;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Photos (${_photos.length}/${widget.maxPhotos})',
                style: AppTextStyles.bodyMedium
                    .copyWith(color: scheme.onSurface)),
            const Spacer(),
            if (_busy)
              const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: AppDimens.grid),
        if (_loading)
          const SizedBox(
            height: 2,
            child: LinearProgressIndicator(minHeight: 2),
          )
        else
          Wrap(
            spacing: AppDimens.grid,
            runSpacing: AppDimens.grid,
            children: [
              for (final p in _photos)
                _Thumb(
                  url: '${Env.apiBaseUrl}${p.downloadUrl}',
                  token: token,
                  onDelete: _busy ? null : () => _delete(p),
                ),
              if (canAdd)
                GestureDetector(
                  onTap: _pickSource,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(AppDimens.cardRadius),
                      border: Border.all(
                        color: colors.textSecondary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Icon(Icons.add_a_photo_rounded,
                        color: colors.textSecondary),
                  ),
                ),
            ],
          ),
        if (_error != null) ...[
          const SizedBox(height: AppDimens.grid),
          Text(_error!,
              style: AppTextStyles.caption.copyWith(color: scheme.error)),
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url, required this.token, this.onDelete});

  final String url;
  final String? token;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
          child: CachedNetworkImage(
            imageUrl: url,
            httpHeaders: token != null ? {'Authorization': 'Bearer $token'} : null,
            width: 76,
            height: 76,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(
              width: 76,
              height: 76,
              color: context.appColors.textSecondary.withValues(alpha: 0.1),
            ),
            errorWidget: (_, __, ___) => Container(
              width: 76,
              height: 76,
              color: context.appColors.textSecondary.withValues(alpha: 0.1),
              child: const Icon(Icons.broken_image_rounded, size: 20),
            ),
          ),
        ),
        if (onDelete != null)
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(2),
                child: const Icon(Icons.close_rounded,
                    size: 16, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}
