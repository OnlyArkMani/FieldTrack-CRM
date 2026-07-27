import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_time_picker.dart';
import '../../../../core/widgets/state_views.dart';
import '../../farmers/models/farmer.dart'
    show CustomerType, LeadStatus, LivestockProfile;
import '../../farmers/providers/farmer_provider.dart';
import '../../farmers/utils.dart';
import '../../followups/data/follow_up_repository.dart' show myFollowUpsProvider;
import '../../leads/data/lead_repository.dart' show myLeadsProvider;
import '../../planning/providers/visit_plan_provider.dart';
import '../../planning/widgets/plan_item_card.dart' show purposeLabel;
import '../../vet/data/vet_repository.dart' show vetRequestsProvider;
import '../data/visit_repository.dart';
import '../models/visit.dart';
import '../widgets/step_indicator.dart';
import '../widgets/visit_extras.dart';
import '../../../../services/sync/connectivity_service.dart';

const _breeds = ['Sahiwal', 'Murrah', 'HF Cross', 'Gir', 'Local', 'Other'];
const _ageGroups = ['Calf', 'Heifer', 'Adult', 'Senior'];
const _healthLevels = ['Excellent', 'Good', 'Fair', 'Poor'];
const _payModes = [('CASH', 'Cash'), ('UPI', 'UPI'), ('CREDIT', 'Credit')];
const _visitPurposes = [
  'FIRST_VISIT',
  'FOLLOW_UP',
  'ORDER_COLLECTION',
  'RELATIONSHIP_VISIT',
];

/// The guided visit form: check-in (step 0) then 4 sequential steps
/// (Notes → Livestock → Order → Lead). Progress is saved to the backend after
/// each step; notes auto-save every 30s.
class VisitFlowScreen extends ConsumerStatefulWidget {
  const VisitFlowScreen({
    super.key,
    required this.farmerId,
    this.planItemId,
    this.planTargetOrderBags,
    this.planPurpose,
  });

  final int farmerId;
  final int? planItemId;
  final int? planTargetOrderBags;
  final String? planPurpose;

  @override
  ConsumerState<VisitFlowScreen> createState() => _VisitFlowScreenState();
}

class _VisitFlowScreenState extends ConsumerState<VisitFlowScreen> {
  int _step = 0; // 0 = check-in; 1..4 = the guided steps
  int? _visitId;
  bool _busy = false;
  String? _error;

  // check-in / warning
  CheckInResult? _checkIn;
  bool _showWarning = false;
  final _remark = TextEditingController();
  final _targetBags = TextEditingController();
  String _purpose = 'FIRST_VISIT';

  // notes
  final _highlights = TextEditingController();
  final _concerns = TextEditingController();
  final _interest = TextEditingController();
  Timer? _autosave;

  // livestock. Bags/month, kg/animal/day and current price are gated behind
  // "Use cattle feed?" — meaningless if the farmer doesn't use any. Willing
  // to pay (min/max) is further gated behind "Interested in Sanjeevni?".
  final _cattle = TextEditingController();
  bool _usesCattleFeed = false;
  bool _interestedInNewFeed = false;
  final _bagsPerMonth = TextEditingController();
  final _kgPerAnimal = TextEditingController();
  final _pricePerBag = TextEditingController();
  final _payMin = TextEditingController();
  final _payMax = TextEditingController();
  final _healthNotes = TextEditingController();
  String? _breed;
  String? _ageGroup;
  String? _health;

  // org answers — none of FPO/VLCC/Retailer collect total cattle anymore.
  // _orgBrand ("Current feed brand") + monthly bags + interested-in-supply +
  // notes are shared by all three; Retailer additionally gets a price range
  // (_sellPriceMin/_sellPriceMax) instead of the single _orgPricePerBag.
  final _orgMembers = TextEditingController();
  final _orgBrand = TextEditingController();
  final _orgMonthlyBags = TextEditingController();
  final _orgInterestedBags = TextEditingController();
  final _orgPricePerBag = TextEditingController();
  final _orgNotes = TextEditingController();
  bool _orgInterested = false;

  // Retailer: the price range they resell feed to farmers at.
  final _sellPriceMin = TextEditingController();
  final _sellPriceMax = TextEditingController();

  // vet requirement (captured on step 2, for both farmer & org customers)
  bool _vetRequired = false;
  final _vetCattle = TextEditingController();
  final _vetNotes = TextEditingController();

  // order
  bool _orderEnabled = false;
  final _bagsCount = TextEditingController();
  final _deliveryAddress = TextEditingController();
  final _orderNotes = TextEditingController();
  String? _payMode;
  DateTime? _deliveryDate;

  // lead
  LeadStatus? _lead;
  DateTime? _followUpDate;
  TimeOfDay? _followUpTime;
  final _followUpPurpose = TextEditingController();

  VisitRepository get _repo => ref.read(visitRepositoryProvider);
  DateTime get _earliestDelivery =>
      DateTime.now().add(const Duration(days: 7));

  /// Customer type of the current farmer (loaded via farmerDetailProvider).
  /// Farmers get the livestock step; FPO/VLCC get the org-answers step.
  CustomerType get _customerType =>
      ref.read(farmerDetailProvider(widget.farmerId)).value?.customerType ??
      CustomerType.farmer;
  bool get _isOrg => _customerType.isOrg;
  bool get _isSpecialOrg =>
      _customerType == CustomerType.fpo ||
      _customerType == CustomerType.vlcc ||
      _customerType == CustomerType.distributor ||
      _customerType == CustomerType.retailer;

  @override
  void dispose() {
    _autosave?.cancel();
    for (final c in [
      _remark, _targetBags, _highlights, _concerns, _interest, _cattle,
      _bagsPerMonth, _kgPerAnimal, _pricePerBag, _payMin, _payMax, _healthNotes,
      _orgMembers, _orgBrand, _orgMonthlyBags,
      _orgInterestedBags, _orgPricePerBag, _orgNotes,
      _sellPriceMin, _sellPriceMax,
      _vetCattle, _vetNotes,
      _bagsCount, _deliveryAddress, _orderNotes, _followUpPurpose,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── check-in ────────────────────────────────────────────────────────────
  Future<({double lat, double lng})?> _position() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    // In offline mode, Android can't use network-assisted GPS (A-GPS) so a
    // raw satellite fix can take 30–90 s on the original 45 s timeout, making
    // the loading spinner appear to freeze.  We try for 8 s instead; if we
    // still can't get a fresh fix we fall back to the last cached position
    // (always available once GPS has ever been used on the device), which is
    // accurate enough for an offline check-in that will be verified server-side
    // once connectivity is restored.
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return (lat: last.latitude, lng: last.longitude);
      rethrow; // no cached fix either — surface the error to the user
    }
  }

  Future<void> _doCheckIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Try to get device GPS position. On failure (timeout or no cached fix)
      // fall back to the farmer's stored coordinates when offline — the server
      // runs the distance check server-side once the visit syncs, so using the
      // farmer's own pin is safe for an offline check-in.
      ({double lat, double lng}) pos;
      try {
        final p = await _position();
        if (!mounted) return;
        if (p == null) {
          // Permission denied — only hard-block when online (server enforces
          // distance). Offline we still want the visit queued.
          final isOnline = ref.read(connectivityServiceProvider).current;
          if (isOnline) {
            setState(() {
              _busy = false;
              _error = 'Location permission is required to check in.';
            });
            return;
          }
          // Offline: fall through to farmer-coords fallback below.
          throw Exception('permission_denied');
        }
        pos = p;
      } catch (_) {
        // GPS failed (timeout + no last-known-position) OR permission denied
        // while offline → use the farmer's stored pin.
        final farmer = ref.read(farmerDetailProvider(widget.farmerId)).value;
        pos = (lat: farmer?.lat ?? 0.0, lng: farmer?.lng ?? 0.0);
      }

      if (!mounted) return;
      final result = await _repo.checkIn(
        farmerId: widget.farmerId,
        lat: pos.lat,
        lng: pos.lng,
        planItemId: widget.planItemId,
        targetOrderBags: widget.planItemId == null
            ? int.tryParse(_targetBags.text.trim())
            : widget.planTargetOrderBags,
        purpose: widget.planItemId == null ? _purpose : widget.planPurpose,
        farmerName: ref.read(farmerDetailProvider(widget.farmerId)).value?.name,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      _visitId = result.visitId;
      _checkIn = result;
      if (result.isPending) {
        // Checked in offline — the rest of the guided flow (notes,
        // livestock, orders, complete) is offline-capable too (see
        // docs/OFFLINE_SYNC_PLAN.md), so just continue normally. No
        // location-warning distance to show yet — that's computed
        // server-side once check-in syncs.
        HapticFeedback.selectionClick();
        _enterStep(1);
        return;
      }
      if (result.warningRequired) {
        setState(() {
          _busy = false;
          _showWarning = true;
        });
      } else {
        _enterStep(1);
      }
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
        _error = 'Could not get your location. Try again.';
      });
    }
  }

  Future<void> _continueAfterWarning() async {
    if (_remark.text.trim().isEmpty) {
      setState(() => _error = 'Please add a remark to explain.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repo.locationRemark(_visitId!, _remark.text.trim());
      if (!mounted) return;
      _enterStep(1);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  // ── step transitions ─────────────────────────────────────────────────────
  void _enterStep(int step) {
    setState(() {
      _step = step;
      _busy = false;
      _showWarning = false;
      _error = null;
    });
    if (step == 1) {
      _autosave?.cancel();
      _autosave = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _saveNotes(step: 1, silent: true),
      );
    } else {
      _autosave?.cancel();
    }
  }

  Future<void> _saveNotes({required int step, bool silent = false}) async {
    if (_visitId == null) return;
    try {
      await _repo.saveNotes(
        _visitId!,
        meetingHighlights: _highlights.text.trim(),
        farmerConcerns: _concerns.text.trim(),
        productInterest: _interest.text.trim(),
        stepCompleted: step,
      );
    } on ApiException {
      if (!silent) rethrow;
    }
  }

  Future<void> _next() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (_step) {
        case 1:
          await _saveNotes(step: 1);
          if (!mounted) return;
          _enterStep(2);
        case 2:
          if (_isOrg) {
            await _saveOrgAnswers();
          } else {
            await _saveLivestock();
          }
          await _saveVet();
          await _saveNotes(step: 2, silent: true);
          if (!mounted) return;
          _enterStep(3);
        case 3:
          _validateOrder();
          await _saveNotes(step: 3, silent: true);
          if (!mounted) return;
          _enterStep(4);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<void> _saveLivestock() async {
    final fields = <String, dynamic>{
      if (_cattle.text.trim().isNotEmpty)
        'total_cattle': int.tryParse(_cattle.text.trim()),
      if (_breed != null) 'breed': _breed,
      if (_ageGroup != null) 'age_group': _ageGroup,
      'uses_cattle_feed': _usesCattleFeed,
      if (_usesCattleFeed && _bagsPerMonth.text.trim().isNotEmpty)
        'bags_per_month': int.tryParse(_bagsPerMonth.text.trim()),
      if (_usesCattleFeed && _kgPerAnimal.text.trim().isNotEmpty)
        'kg_per_animal_per_day': double.tryParse(_kgPerAnimal.text.trim()),
      if (_usesCattleFeed && _pricePerBag.text.trim().isNotEmpty)
        'current_price_per_bag': double.tryParse(_pricePerBag.text.trim()),
      if (_usesCattleFeed) 'interested_in_new_feed': _interestedInNewFeed,
      if (_usesCattleFeed &&
          _interestedInNewFeed &&
          _payMin.text.trim().isNotEmpty)
        'willing_to_pay_min': double.tryParse(_payMin.text.trim()),
      if (_usesCattleFeed &&
          _interestedInNewFeed &&
          _payMax.text.trim().isNotEmpty)
        'willing_to_pay_max': double.tryParse(_payMax.text.trim()),
      if (_health != null) 'health_status': _health,
      if (_healthNotes.text.trim().isNotEmpty)
        'health_notes': _healthNotes.text.trim(),
    };
    await _repo.saveLivestock(_visitId!, fields);
  }

  /// Retailer: Number of farmers / Current feed brand / Monthly feed
  /// requirement / Price on you sell (min & max) / Interested in supply
  /// (+ bags) / Notes. No total cattle.
  Future<void> _saveRetailerAnswers() async {
    final interestedBags = int.tryParse(_orgInterestedBags.text.trim());
    await _repo.saveOrgAnswers(
      _visitId!,
      memberCount: int.tryParse(_orgMembers.text.trim()),
      currentBrand:
          _orgBrand.text.trim().isEmpty ? null : _orgBrand.text.trim(),
      monthlyBags: int.tryParse(_orgMonthlyBags.text.trim()),
      interestedInSupply: _orgInterested,
      interestedBags: _orgInterested ? interestedBags : null,
      priceMin: double.tryParse(_sellPriceMin.text.trim()),
      priceMax: double.tryParse(_sellPriceMax.text.trim()),
      notes: _orgNotes.text.trim().isEmpty ? null : _orgNotes.text.trim(),
    );
  }

  /// FPO: same fields as the original form minus total cattle.
  Future<void> _saveFpoAnswers() async {
    final interestedBags = int.tryParse(_orgInterestedBags.text.trim());
    await _repo.saveOrgAnswers(
      _visitId!,
      memberCount: int.tryParse(_orgMembers.text.trim()),
      currentBrand:
          _orgBrand.text.trim().isEmpty ? null : _orgBrand.text.trim(),
      monthlyBags: int.tryParse(_orgMonthlyBags.text.trim()),
      interestedInSupply: _orgInterested,
      interestedBags: _orgInterested ? interestedBags : null,
      currentPricePerBag: double.tryParse(_orgPricePerBag.text.trim()),
      notes: _orgNotes.text.trim().isEmpty ? null : _orgNotes.text.trim(),
    );
  }

  /// VLCC: original shared form minus total cattle.
  Future<void> _saveOrgAnswers() async {
    if (_customerType == CustomerType.retailer) return _saveRetailerAnswers();
    if (_customerType == CustomerType.fpo) return _saveFpoAnswers();
    final interestedBags = int.tryParse(_orgInterestedBags.text.trim());
    await _repo.saveOrgAnswers(
      _visitId!,
      memberCount: int.tryParse(_orgMembers.text.trim()),
      currentBrand:
          _orgBrand.text.trim().isEmpty ? null : _orgBrand.text.trim(),
      monthlyBags: int.tryParse(_orgMonthlyBags.text.trim()),
      interestedInSupply: _orgInterested,
      interestedBags: _orgInterested ? interestedBags : null,
      currentPricePerBag: double.tryParse(_orgPricePerBag.text.trim()),
      notes: _orgNotes.text.trim().isEmpty ? null : _orgNotes.text.trim(),
    );
  }

  Future<void> _skipStep2() async {
    final ok = _isOrg
        ? await _confirm('Skip the organisation form?',
            'You can record these details on a later visit.')
        : await _confirm('Skip livestock update?',
            'You can record livestock details on a later visit.');
    if (ok != true) return;
    if (!mounted) return;
    // Even when skipping the details form, persist a raised vet request.
    if (_vetRequired) await _saveVet();
    if (!mounted) return;
    await _saveNotes(step: 2, silent: true);
    if (!mounted) return;
    _enterStep(3);
  }

  Future<void> _saveVet() async {
    if (_visitId == null) return;
    // Only hit the endpoint when there's something to record (or clear).
    await _repo.setVet(
      _visitId!,
      vetRequired: _vetRequired,
      vetCattleCount:
          _vetRequired ? int.tryParse(_vetCattle.text.trim()) : null,
      vetNotes: _vetRequired ? _vetNotes.text.trim() : null,
    );
  }

  void _validateOrder() {
    if (_isSpecialOrg) {
      if (!_orgInterested) return;
      final bags = int.tryParse(_orgInterestedBags.text.trim()) ?? 0;
      if (bags < 1) {
        throw const ValidationException('Enter at least 1 bag for the order.');
      }
      if (_deliveryDate == null) {
        throw const ValidationException('Pick a delivery date.');
      }
      if (_payMode == null) {
        throw const ValidationException('Pick a payment mode.');
      }
      return;
    }

    if (!_orderEnabled) return;
    final bags = int.tryParse(_bagsCount.text.trim()) ?? 0;
    if (bags < 1) {
      throw const ValidationException('Enter at least 1 bag for the order.');
    }
    if (_deliveryDate == null) {
      throw const ValidationException('Pick a delivery date.');
    }
  }

  Future<void> _saveOrder() async {
    if (_isSpecialOrg) {
      if (!_orgInterested) return;
      final bags = int.tryParse(_orgInterestedBags.text.trim()) ?? 0;
      if (bags < 1) {
        throw const ValidationException('Enter at least 1 bag for the order.');
      }
      if (_deliveryDate == null) {
        throw const ValidationException('Pick a delivery date.');
      }
      if (_payMode == null) {
        throw const ValidationException('Pick a payment mode.');
      }
      await _repo.createOrder(
        _visitId!,
        bagsCount: bags,
        deliveryDate: _deliveryDate!,
        deliveryAddress: '',
        paymentMode: _payMode!,
        specialNotes: 'Auto-captured from FPO/VLCC/Distributor/Retailer supply interest',
        pricePerBag: null,
      );
      return;
    }

    final bags = int.tryParse(_bagsCount.text.trim()) ?? 0;
    if (bags < 1) {
      throw const ValidationException('Enter at least 1 bag for the order.');
    }
    if (_deliveryDate == null) {
      throw const ValidationException('Pick a delivery date.');
    }
    // Order value = bags * price. There's no separate price-per-bag field on
    // this step — reuse the farmer's stated "willing to pay (max)" from the
    // Livestock step as the order's price, so the DSR can show a value
    // without asking the same number twice. Left null for FPO/VLCC visits
    // (org-answers step has no equivalent price field).
    await _repo.createOrder(
      _visitId!,
      bagsCount: bags,
      deliveryDate: _deliveryDate!,
      deliveryAddress: _deliveryAddress.text.trim(),
      paymentMode: _payMode,
      specialNotes: _orderNotes.text.trim(),
      pricePerBag: double.tryParse(_payMax.text.trim()),
    );
  }

  // ── complete ──────────────────────────────────────────────────────────────
  Future<void> _complete() async {
    if (_lead == null) {
      setState(() => _error = 'Pick how the visit went.');
      return;
    }
    final needsFollowUp = _lead == LeadStatus.warm || _lead == LeadStatus.cold;
    if (needsFollowUp && _followUpDate == null) {
      setState(() => _error = 'A follow-up date is required for Warm/Cold.');
      return;
    }
    if (needsFollowUp && _followUpTime == null) {
      setState(() => _error = 'A follow-up time is required for Warm/Cold.');
      return;
    }
    final ok = await _confirmComplete();
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final shouldSave = _isSpecialOrg ? _orgInterested : _orderEnabled;
      if (shouldSave) {
        await _saveOrder();
      }

      final time = _followUpTime == null
          ? null
          : '${_followUpTime!.hour.toString().padLeft(2, '0')}:'
              '${_followUpTime!.minute.toString().padLeft(2, '0')}:00';
      await _repo.complete(
        _visitId!,
        leadStatus: _lead!,
        followUpDate: needsFollowUp ? _followUpDate : null,
        followUpTime: needsFollowUp ? time : null,
        followUpPurpose: needsFollowUp ? _followUpPurpose.text.trim() : null,
      );
      // Refresh downstream views. Always reload the plan so the completed stop
      // moves out of Active (and any fulfilled follow-up disappears) — this
      // matters for follow-up visits too, which carry no plan_item_id.
      // Leads/vet requests are invalidated too — offline, both now read
      // this visit's pending lead-status/vet data directly (see
      // LeadRepository/VetRepository), but a screen already open before
      // completing needs a nudge to actually re-fetch and pick that up.
      ref.invalidate(farmerDetailProvider(widget.farmerId));
      ref.read(farmerListProvider.notifier).refresh(isRefresh: true);
      ref.read(visitPlanProvider.notifier).load();
      ref.invalidate(myLeadsProvider);
      ref.invalidate(myFollowUpsProvider);
      ref.invalidate(vetRequestsProvider);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await _showSuccess();
      if (!mounted) return;
      context.go('/farmer/${widget.farmerId}', extra: true);
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<bool?> _confirm(String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
  }

  Future<bool?> _confirmComplete() {
    final fu = _followUpDate != null ? shortDate(_followUpDate) : null;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark this visit as complete?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Customer: ${_checkIn?.farmerName ?? ''}'),
            Text('Lead: ${_lead?.label ?? ''}'),
            if (fu != null) Text('Follow-up: $fu'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Complete')),
        ],
      ),
    );
  }

  Future<void> _showSuccess() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        Future.delayed(const Duration(milliseconds: 1300), () {
          if (ctx.mounted) Navigator.of(ctx).pop();
        });
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: _SuccessBurst(),
        );
      },
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _enterStep(_step - 1);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Field visit',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: BackButton(
            onPressed: () {
              if (_step <= 1) {
                Navigator.of(context).maybePop();
              } else {
                _enterStep(_step - 1);
              }
            },
          ),
        ),
        body: SafeArea(
          child: _step == 0 ? _checkInStep() : _guidedStep(),
        ),
      ),
    );
  }

  // ── step 0: check-in ──────────────────────────────────────────────────────
  Widget _checkInStep() {
    final farmerAsync = ref.watch(farmerDetailProvider(widget.farmerId));
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;

    return farmerAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorStateView(
        message: e.toString(),
        onRetry: () => ref.invalidate(farmerDetailProvider(widget.farmerId)),
      ),
      data: (farmer) => ListView(
        padding: const EdgeInsets.all(AppDimens.grid * 2),
        children: [
          // Distance & ETA to the customer (checklist #18) — shown before
          // check-in when we know the farmer's recorded location.
          if (!_showWarning && farmer.lat != null && farmer.lng != null)
            NextVisitEtaCard(
              farmerLat: farmer.lat!,
              farmerLng: farmer.lng!,
              farmerName: farmer.name,
            ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(farmer.name,
                    style: AppTextStyles.heading
                        .copyWith(color: scheme.onSurface)),
                if (farmer.village != null && farmer.village!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(farmer.village!,
                      style: AppTextStyles.body
                          .copyWith(color: colors.textSecondary)),
                ],
                if (_checkIn?.distanceMeters != null) ...[
                  const SizedBox(height: AppDimens.grid),
                  Text('Distance: ${_checkIn!.distanceMeters!.round()} m',
                      style: AppTextStyles.caption
                          .copyWith(color: colors.textSecondary)),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppDimens.grid * 2),
          if (_showWarning) ...[
            _WarningCard(
              distance: _checkIn?.distanceMeters,
              farmerName: _checkIn?.farmerName ?? farmer.name,
              remark: _remark,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppDimens.grid),
              Text(_error!,
                  style: AppTextStyles.caption.copyWith(color: scheme.error)),
            ],
            const SizedBox(height: AppDimens.grid * 2),
            AppButton(
              label: 'Continue anyway',
              variant: AppButtonVariant.secondary,
              isLoading: _busy,
              onPressed: _busy ? null : _continueAfterWarning,
            ),
          ] else ...[
            if (widget.planItemId == null) ...[
              DropdownButtonFormField<String>(
                initialValue: _purpose,
                decoration: const InputDecoration(labelText: 'Purpose of visit'),
                items: _visitPurposes
                    .map((p) => DropdownMenuItem(value: p, child: Text(purposeLabel(p))))
                    .toList(),
                onChanged: (v) => setState(() => _purpose = v ?? _purpose),
              ),
              const SizedBox(height: AppDimens.grid * 2),
              TextField(
                controller: _targetBags,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Target bags for this visit (optional)',
                  helperText:
                      'Set a target now to track it like a planned visit.',
                ),
              ),
              const SizedBox(height: AppDimens.grid * 2),
            ],
            if (_error != null) ...[
              Text(_error!,
                  style: AppTextStyles.caption.copyWith(color: scheme.error)),
              const SizedBox(height: AppDimens.grid),
            ],
            AppButton(
              label: 'Check In',
              icon: Icons.login_rounded,
              isLoading: _busy,
              onPressed: _busy ? null : _doCheckIn,
            ),
          ],
        ],
      ),
    );
  }

  // ── steps 1-4 scaffold ────────────────────────────────────────────────────
  Widget _guidedStep() {
    return Column(
      children: [
        StepIndicator(
          current: _step,
          labels: _isOrg
              ? const ['Notes', 'Details', 'Order', 'Lead']
              : const ['Notes', 'Livestock', 'Order', 'Lead'],
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: KeyedSubtree(
              key: ValueKey(_step),
              child: switch (_step) {
                1 => _notesStep(),
                2 => switch (_customerType) {
                    CustomerType.retailer => _retailerAnswersStep(),
                    CustomerType.fpo => _fpoAnswersStep(),
                    CustomerType.vlcc => _orgAnswersStep(),
                    CustomerType.distributor => _orgAnswersStep(),
                    CustomerType.farmer => _livestockStep(),
                  },
                3 => _orderStep(),
                _ => _leadStep(),
              },
            ),
          ),
        ),
        _navBar(),
      ],
    );
  }

  Widget _navBar() {
    final colors = context.appColors;
    return Container(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      decoration: BoxDecoration(
        color: colors.card,
        boxShadow: AppDimens.shadow(Theme.of(context).brightness),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Text(_error!,
                style: AppTextStyles.caption
                    .copyWith(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: AppDimens.grid),
          ],
          if (_step == 4)
            AppButton(
              label: 'Complete Visit',
              icon: Icons.check_circle_rounded,
              variant: AppButtonVariant.primary,
              isLoading: _busy,
              onPressed: _busy ? null : _complete,
            )
          else
            Row(
              children: [
                if (_step == 2)
                  Expanded(
                    child: AppButton(
                      label: 'Skip',
                      variant: AppButtonVariant.secondary,
                      onPressed: _busy ? null : _skipStep2,
                    ),
                  ),
                if (_step == 2) const SizedBox(width: AppDimens.grid * 1.5),
                Expanded(
                  flex: _step == 2 ? 1 : 2,
                  child: AppButton(
                    label: 'Next',
                    icon: Icons.arrow_forward_rounded,
                    isLoading: _busy,
                    onPressed: _busy ? null : _next,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ── step 1: notes ─────────────────────────────────────────────────────────
  Widget _interestBadges() {
    final colors = context.appColors;
    final isInterested = _interest.text == 'Sanjeevni Cattle Feed';

    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Interested in Sanjeevni Cattle Feed?',
            style: AppTextStyles.caption.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppDimens.grid * 0.5),
          Row(
            children: [
              Radio<bool>(
                value: true,
                groupValue: isInterested,
                onChanged: (val) {
                  setState(() {
                    _interest.text = 'Sanjeevni Cattle Feed';
                  });
                },
              ),
              Text('Yes', style: AppTextStyles.body),
              const SizedBox(width: AppDimens.grid * 3),
              Radio<bool>(
                value: false,
                groupValue: isInterested,
                onChanged: (val) {
                  setState(() {
                    _interest.text = '';
                  });
                },
              ),
              Text('No', style: AppTextStyles.body),
            ],
          ),
        ],
      ),
    );
  }

  // ── step 1: notes ─────────────────────────────────────────────────────────
  Widget _notesStep() {
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        _sectionTitle('Meeting notes'),
        _counterField(_highlights, 'Meeting highlights',
            'What was discussed?', maxLen: 1000),
        _counterField(_concerns, 'Concerns', 'Any concerns raised?',
            maxLen: 1000),
        _interestBadges(),
        Text('Auto-saves every 30 seconds.',
            style: AppTextStyles.caption
                .copyWith(color: context.appColors.textSecondary)),
        const SizedBox(height: AppDimens.grid * 2),
        const Divider(),
        const SizedBox(height: AppDimens.grid),
        // Attach up to 5 photos to this visit (checklist #24).
        if (_visitId != null) VisitPhotosSection(visitId: _visitId!),
      ],
    );
  }

  // ── step 2: livestock ─────────────────────────────────────────────────────
  Widget _livestockStep() {
    final farmer = ref.watch(farmerDetailProvider(widget.farmerId)).value;
    final last = farmer?.latestLivestock;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        if (last != null) _LastLivestockCard(profile: last),
        _sectionTitle('Livestock profile'),
        _numField(_cattle, 'Number of Cattle owned'),
        _dropdown('Breed', _breeds, _breed, (v) => setState(() => _breed = v)),
        _chipsField('Age group', _ageGroups, _ageGroup,
            (v) => setState(() => _ageGroup = v)),
        AppCard(
          child: Row(
            children: [
              Expanded(
                child: Text('Use cattle feed?',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: scheme.onSurface)),
              ),
              Switch(
                value: _usesCattleFeed,
                onChanged: (v) => setState(() => _usesCattleFeed = v),
              ),
            ],
          ),
        ),
        if (_usesCattleFeed) ...[
          const SizedBox(height: AppDimens.grid),
          _numField(_bagsPerMonth, 'Bags / month'),
          _numField(_kgPerAnimal, 'Kg / animal / day'),
          _numField(_pricePerBag, 'Current price / bag (₹)'),
          const SizedBox(height: AppDimens.grid),
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Text('Interested in using Sanjeevni cattle feed?',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: scheme.onSurface)),
                ),
                Switch(
                  value: _interestedInNewFeed,
                  onChanged: (v) => setState(() => _interestedInNewFeed = v),
                ),
              ],
            ),
          ),
          if (_interestedInNewFeed) ...[
            const SizedBox(height: AppDimens.grid),
            Row(
              children: [
                Expanded(
                    child: _numField(_payMin, 'Willing to pay — min (₹)')),
                const SizedBox(width: AppDimens.grid),
                Expanded(child: _numField(_payMax, 'max (₹)')),
              ],
            ),
          ],
        ],
        const SizedBox(height: AppDimens.grid),
        _chipsField('Health status', _healthLevels, _health,
            (v) => setState(() => _health = v)),
        _textField(_healthNotes, 'Health notes (optional)'),
        _vetSection(),
      ],
    );
  }

  // ── vet requirement (shared by farmer + org step 2) ───────────────────────
  Widget _vetSection() {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppDimens.grid),
        const Divider(),
        const SizedBox(height: AppDimens.grid),
        AppCard(
          child: Row(
            children: [
              Icon(Icons.medical_services_rounded,
                  size: 18, color: scheme.secondary),
              const SizedBox(width: AppDimens.grid),
              Expanded(
                child: Text('Needs a veterinary visit?',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: scheme.onSurface)),
              ),
              Switch(
                value: _vetRequired,
                onChanged: (v) => setState(() => _vetRequired = v),
              ),
            ],
          ),
        ),
        if (_vetRequired) ...[
          const SizedBox(height: AppDimens.grid),
          _numField(_vetCattle, 'How many cattle need the vet?'),
          _textField(_vetNotes, 'Vet notes (symptoms / details)'),
          Text('Raised requests appear on the Vet dashboard.',
              style:
                  AppTextStyles.caption.copyWith(color: colors.textSecondary)),
        ],
      ],
    );
  }

  /// Shared by all three org forms: notes, identical everywhere it appears.
  /// Supply interest is now captured in the third step to prevent duplication.
  Widget _interestedAndNotesFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _textField(_orgNotes, 'Notes (optional)'),
      ],
    );
  }

  // ── step 2 (VLCC): original shared form, minus total cattle, no Q-prefixes
  Widget _orgAnswersStep() {
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        _sectionTitle('${_customerType.label} details'),
        _numField(_orgMembers, 'Number of farmers'),
        _textField(_orgBrand, 'Current cattle feed brand'),
        _numField(_orgMonthlyBags, 'Monthly cattle feed demand'),
        _numField(_orgPricePerBag, 'Current price / bag (₹)'),
        const SizedBox(height: AppDimens.grid),
        _interestedAndNotesFields(),
        _vetSection(),
      ],
    );
  }

  // ── step 2 (FPO): same as the original form, minus total cattle ─────────
  Widget _fpoAnswersStep() {
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        _sectionTitle('FPO details'),
        _numField(_orgMembers, 'Number of farmers'),
        _textField(_orgBrand, 'Selling Cattle feed brand'),
        _numField(_orgMonthlyBags, 'Current monthly demand'),
        _numField(_orgPricePerBag, 'Price on you sell (₹)'),
        const SizedBox(height: AppDimens.grid),
        _interestedAndNotesFields(),
        _vetSection(),
      ],
    );
  }

  // ── step 2 (Retailer): Number of farmers / Current feed brand / Current
  // monthly demand / Average selling price (min & max) / Interested in
  // supply (+ bags) / Notes. No total cattle, no vet section. ─────────────
  Widget _retailerAnswersStep() {
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        _sectionTitle('Retailer details'),
        _numField(_orgMembers, 'Number of farmers'),
        _textField(_orgBrand, 'Current cattle feed brand'),
        _numField(_orgMonthlyBags, 'Current monthly demand'),
        Row(
          children: [
            Expanded(
                child:
                    _numField(_sellPriceMin, 'Average selling price — min (₹)')),
            const SizedBox(width: AppDimens.grid),
            Expanded(child: _numField(_sellPriceMax, 'max (₹)')),
          ],
        ),
        const SizedBox(height: AppDimens.grid),
        _interestedAndNotesFields(),
      ],
    );
  }

  // ── step 3: order ─────────────────────────────────────────────────────────
  Widget _orderStep() {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;

    if (_isSpecialOrg) {
      return ListView(
        padding: const EdgeInsets.all(AppDimens.grid * 2),
        children: [
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Text('Interested in supply from us?',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: scheme.onSurface)),
                ),
                Switch(
                  value: _orgInterested,
                  onChanged: (v) => setState(() => _orgInterested = v),
                ),
              ],
            ),
          ),
          if (_orgInterested) ...[
            const SizedBox(height: AppDimens.grid * 2),
            _numField(_orgInterestedBags, 'Bags they want to order'),
            const SizedBox(height: AppDimens.grid * 2),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _deliveryDate ?? _earliestDelivery,
                  firstDate: _earliestDelivery,
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => _deliveryDate = picked);
              },
              child: Container(
                padding: const EdgeInsets.all(AppDimens.grid * 1.5),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(
                      color: colors.textSecondary.withValues(alpha: 0.25)),
                  borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                ),
                child: Row(
                  children: [
                    Icon(Icons.event_rounded,
                        size: 18, color: colors.textSecondary),
                    const SizedBox(width: AppDimens.grid),
                    Text(
                      _deliveryDate == null
                          ? 'Pick delivery date'
                          : shortDate(_deliveryDate),
                      style: AppTextStyles.body.copyWith(
                          color: _deliveryDate == null
                              ? colors.textSecondary
                              : scheme.onSurface),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text('Earliest delivery: ${shortDate(_earliestDelivery)}',
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary)),
            const SizedBox(height: AppDimens.grid * 2),
            _chipsField(
                'Payment mode',
                _payModes.map((e) => e.$2).toList(),
                _payMode == null
                    ? null
                    : _payModes.firstWhere((e) => e.$1 == _payMode).$2,
                (label) => setState(() => _payMode =
                    _payModes.firstWhere((e) => e.$2 == label).$1)),
          ],
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        AppCard(
          child: Row(
            children: [
              Expanded(
                child: Text('Customer wants to place an order',
                    style: AppTextStyles.bodyMedium
                        .copyWith(color: scheme.onSurface)),
              ),
              Switch(
                value: _orderEnabled,
                onChanged: (v) => setState(() => _orderEnabled = v),
              ),
            ],
          ),
        ),
        if (_orderEnabled) ...[
          const SizedBox(height: AppDimens.grid),
          _numField(_bagsCount, 'Bags count (min 1)'),
          const SizedBox(height: AppDimens.grid),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _deliveryDate ?? _earliestDelivery,
                firstDate: _earliestDelivery,
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) setState(() => _deliveryDate = picked);
            },
            child: Container(
              padding: const EdgeInsets.all(AppDimens.grid * 1.5),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border.all(
                    color: colors.textSecondary.withValues(alpha: 0.25)),
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.event_rounded,
                      size: 18, color: colors.textSecondary),
                  const SizedBox(width: AppDimens.grid),
                  Text(
                    _deliveryDate == null
                        ? 'Pick delivery date'
                        : shortDate(_deliveryDate),
                    style: AppTextStyles.body.copyWith(
                        color: _deliveryDate == null
                            ? colors.textSecondary
                            : scheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('Earliest delivery: ${shortDate(_earliestDelivery)}',
              style: AppTextStyles.caption
                  .copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppDimens.grid),
          _textField(_deliveryAddress, 'Delivery address'),
          _chipsField(
              'Payment mode',
              _payModes.map((e) => e.$2).toList(),
              _payMode == null
                  ? null
                  : _payModes.firstWhere((e) => e.$1 == _payMode).$2,
              (label) => setState(() => _payMode =
                  _payModes.firstWhere((e) => e.$2 == label).$1)),
          _textField(_orderNotes, 'Special notes (optional)'),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: AppDimens.grid * 2),
            child: Text('No order — tap Next to continue.',
                style: AppTextStyles.body
                    .copyWith(color: colors.textSecondary)),
          ),
      ],
    );
  }

  // ── step 4: lead + complete ───────────────────────────────────────────────
  Widget _leadStep() {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final needsFollowUp = _lead == LeadStatus.warm || _lead == LeadStatus.cold;
    return ListView(
      padding: const EdgeInsets.all(AppDimens.grid * 2),
      children: [
        Text('How did the visit go?',
            style: AppTextStyles.heading.copyWith(color: scheme.onSurface)),
        const SizedBox(height: AppDimens.grid * 2),
        _leadCard(LeadStatus.hot, '🔴 Hot', 'Will buy within 7 days',
            scheme.error),
        _leadCard(LeadStatus.warm, '🟡 Warm', 'Interested, needs follow-up',
            scheme.primary),
        _leadCard(LeadStatus.cold, '🔵 Cold', 'Not interested right now',
            scheme.secondary),
        if (_lead == LeadStatus.hot) ...[
          const SizedBox(height: AppDimens.grid),
          Text('Great! Mark this visit as complete.',
              style:
                  AppTextStyles.body.copyWith(color: colors.textSecondary)),
        ],
        if (needsFollowUp) ...[
          const SizedBox(height: AppDimens.grid * 2),
          _sectionTitle('Schedule a follow-up'),
          Row(
            children: [
              Expanded(
                child: _pickerTile(
                  icon: Icons.event_rounded,
                  label: _followUpDate == null
                      ? 'Date (required)'
                      : shortDate(_followUpDate),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate:
                          _followUpDate ?? DateTime.now().add(const Duration(days: 1)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => _followUpDate = picked);
                  },
                ),
              ),
              const SizedBox(width: AppDimens.grid),
              Expanded(
                child: _pickerTile(
                  icon: Icons.schedule_rounded,
                  label: _followUpTime == null
                      ? 'Time'
                      : _followUpTime!.format(context),
                  onTap: () async {
                    final picked = await showScrollTimePicker(
                      context,
                      initialTime: _followUpTime ??
                          const TimeOfDay(hour: 10, minute: 0),
                    );
                    if (picked != null) setState(() => _followUpTime = picked);
                  },
                ),
              ),
            ],
          ),
          _textField(_followUpPurpose, 'Purpose (optional)'),
        ],
      ],
    );
  }

  Widget _leadCard(
      LeadStatus status, String title, String subtitle, Color color) {
    final selected = _lead == status;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: GestureDetector(
        onTap: () => setState(() => _lead = status),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          padding: const EdgeInsets.all(AppDimens.grid * 2),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.16) : context.appColors.card,
            borderRadius: BorderRadius.circular(AppDimens.cardRadius),
            border: Border.all(
              color: selected
                  ? color
                  : context.appColors.textSecondary.withValues(alpha: 0.2),
              width: selected ? 1.8 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTextStyles.bodyMedium.copyWith(
                            color: selected ? color : scheme.onSurface,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: AppTextStyles.caption.copyWith(
                            color: context.appColors.textSecondary)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle_rounded, color: color),
            ],
          ),
        ),
      ),
    );
  }

  // ── small field helpers ───────────────────────────────────────────────────
  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: AppDimens.grid),
        child: Text(t,
            style: AppTextStyles.bodyMedium
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
      );

  Widget _counterField(TextEditingController c, String label, String hint,
      {int maxLen = 500}) {
    final colors = context.appColors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: c,
            maxLength: maxLen,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            style: AppTextStyles.body
                .copyWith(color: theme.colorScheme.onSurface),
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                borderSide: BorderSide(color: colors.textSecondary.withValues(alpha: 0.25)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                borderSide: BorderSide(color: colors.textSecondary.withValues(alpha: 0.25)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
        child: TextField(
          controller: c,
          style: AppTextStyles.body
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _numField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: AppTextStyles.body
              .copyWith(color: Theme.of(context).colorScheme.onSurface),
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _dropdown(String label, List<String> options, String? value,
      ValueChanged<String?> onChanged) {
    final colors = context.appColors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 2,
            vertical: AppDimens.grid * 0.75,
          ),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isDense: true,
            isExpanded: true,
            style: AppTextStyles.body.copyWith(color: theme.colorScheme.onSurface),
            hint: Text(
              'Select',
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
            ),
            items: [
              for (final o in options)
                DropdownMenuItem(value: o, child: Text(o)),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Widget _chipsField(String label, List<String> options, String? selected,
      ValueChanged<String> onSelect) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.grid),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppTextStyles.caption.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppDimens.grid * 0.5),
          Wrap(
            spacing: AppDimens.grid,
            runSpacing: AppDimens.grid * 0.5,
            children: [
              for (final o in options)
                GestureDetector(
                  onTap: () => onSelect(o),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.grid * 1.25,
                        vertical: AppDimens.grid * 0.6),
                    decoration: BoxDecoration(
                      color: selected == o
                          ? scheme.secondary.withValues(alpha: 0.16)
                          : colors.card,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: selected == o
                            ? scheme.secondary
                            : colors.textSecondary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(o,
                        style: AppTextStyles.caption.copyWith(
                          color: selected == o
                              ? scheme.secondary
                              : colors.textSecondary,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pickerTile(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    final colors = context.appColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
      child: Container(
        padding: const EdgeInsets.all(AppDimens.grid * 1.5),
        decoration: BoxDecoration(
          border:
              Border.all(color: colors.textSecondary.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors.textSecondary),
            const SizedBox(width: AppDimens.grid * 0.75),
            Flexible(
              child: Text(label,
                  style: AppTextStyles.caption
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

// ── pieces ──────────────────────────────────────────────────────────────────
class _WarningCard extends StatelessWidget {
  const _WarningCard({
    required this.distance,
    required this.farmerName,
    required this.remark,
  });

  final double? distance;
  final String farmerName;
  final TextEditingController remark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      color: scheme.error.withValues(alpha: 0.08),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.error),
              const SizedBox(width: AppDimens.grid),
              Expanded(
                child: Text(
                  'You are ${distance?.round() ?? '—'}m away from '
                  "$farmerName's location.",
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: scheme.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.grid * 1.5),
          TextField(
            controller: remark,
            textCapitalization: TextCapitalization.sentences,
            style: AppTextStyles.body.copyWith(color: scheme.onSurface),
            decoration: InputDecoration(
              labelText: 'Add a remark to explain (required)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                borderSide: BorderSide(color: context.appColors.textSecondary.withValues(alpha: 0.25)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                borderSide: BorderSide(color: context.appColors.textSecondary.withValues(alpha: 0.25)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
                borderSide: BorderSide(color: scheme.primary, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LastLivestockCard extends StatelessWidget {
  const _LastLivestockCard({required this.profile});
  final LivestockProfile profile;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.grid * 1.5),
      child: AppCard(
        color: colors.textSecondary.withValues(alpha: 0.06),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last recorded ${timeAgo(profile.recordedAt)}',
                style: AppTextStyles.caption
                    .copyWith(color: colors.textSecondary)),
            const SizedBox(height: 4),
            Text(
              [
                if (profile.breed != null) 'Breed: ${profile.breed}',
                if (profile.currentBrand != null)
                  'Brand: ${profile.currentBrand}',
                if (profile.bagsPerMonth != null)
                  'Bags/mo: ${profile.bagsPerMonth}',
                if (profile.currentPricePerBag != null)
                  'Price: ${money(profile.currentPricePerBag)}',
              ].join('  ·  '),
              style: AppTextStyles.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuccessBurst extends StatefulWidget {
  @override
  State<_SuccessBurst> createState() => _SuccessBurstState();
}

class _SuccessBurstState extends State<_SuccessBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..forward();
  late final Animation<double> _scale =
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Container(
      padding: const EdgeInsets.all(AppDimens.grid * 4),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(AppDimens.cardRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: _scale,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colors.statusActive,
                shape: BoxShape.circle,
              ),
              child:
                  const Icon(Icons.check_rounded, color: Colors.white, size: 44),
            ),
          ),
          const SizedBox(height: AppDimens.grid * 2),
          Text('Visit Complete!',
              style: AppTextStyles.heading
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        ],
      ),
    );
  }
}
