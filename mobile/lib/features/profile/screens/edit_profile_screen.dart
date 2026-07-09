import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/indian_states.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/app_messenger.dart';
import '../../auth/providers/auth_provider.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _villageController = TextEditingController();
  final _districtController = TextEditingController();
  String? _selectedState;

  File? _pickedImage;
  String? _nameError;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final user = ref.read(authProvider).user;
      if (user != null) {
        _nameController.text = user.name;
        _phoneController.text = user.phone ?? '';
        _villageController.text = user.village ?? '';
        _districtController.text = user.district ?? '';
        final state = user.state;
        _selectedState = (state != null && state.trim().isNotEmpty) ? state.trim() : null;
      }
      ref.read(authProvider.notifier).clearError();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _villageController.dispose();
    _districtController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (source != null) {
      final file = await picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (file != null) {
        setState(() {
          _pickedImage = File(file.path);
        });
      }
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final village = _villageController.text.trim();
    final district = _districtController.text.trim();
    final stateVal = _selectedState ?? '';

    setState(() {
      _nameError = name.isEmpty ? 'Name is required' : null;
      if (phone.isNotEmpty && phone.length != 10) {
        _phoneError = 'Phone number must be exactly 10 digits';
      } else if (phone.isNotEmpty && !RegExp(r'^\d+$').hasMatch(phone)) {
        _phoneError = 'Only numbers are allowed';
      } else {
        _phoneError = null;
      }
    });

    if (name.isEmpty || _phoneError != null) {
      return;
    }

    final notifier = ref.read(authProvider.notifier);

    // If an image was picked, upload it first.
    if (_pickedImage != null) {
      final uploadOk = await notifier.uploadProfilePhoto(_pickedImage!.path);
      if (!uploadOk) {
        final err = ref.read(authProvider).error;
        if (mounted) {
          showAppSnackBar(err ?? 'Failed to upload profile photo');
        }
        return;
      }
    }

    // Update details.
    final updateOk = await notifier.updateProfile(
      name: name,
      phone: phone,
      village: village,
      district: district,
      stateVal: stateVal,
    );

    if (updateOk) {
      HapticFeedback.mediumImpact();
      if (mounted) {
        showAppSnackBar('Profile updated successfully');
        context.pop();
      }
    } else {
      final err = ref.read(authProvider).error;
      if (mounted) {
        showAppSnackBar(err ?? 'Failed to update profile');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.user;
    final scheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.grid * 3,
            vertical: AppDimens.grid * 2,
          ),
          children: [
            const SizedBox(height: AppDimens.grid * 2),

            // ── Avatar Edit Selector ───────────────────────────────────────
            Center(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: AppDimens.shadow(Theme.of(context).brightness),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.2),
                        width: 4,
                      ),
                    ),
                    child: CircleAvatar(
                      radius: 64,
                      backgroundColor: scheme.secondary.withValues(alpha: 0.1),
                      backgroundImage: _pickedImage != null
                          ? FileImage(_pickedImage!) as ImageProvider
                          : (user?.profilePhotoUrl != null
                              ? CachedNetworkImageProvider(user!.profilePhotoUrl!)
                              : null),
                      child: (_pickedImage == null && user?.profilePhotoUrl == null)
                          ? Text(
                              (user?.name.isNotEmpty ?? false)
                                  ? user!.name[0].toUpperCase()
                                  : '?',
                              style: AppTextStyles.heading.copyWith(
                                color: scheme.primary,
                                fontSize: 36,
                              ),
                            )
                          : null,
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: AppDimens.shadow(Theme.of(context).brightness),
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.camera_alt_rounded,
                          color: scheme.onPrimary,
                          size: 20,
                        ),
                        onPressed: authState.isLoading ? null : _pickImage,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.grid * 4),

            // ── Form fields ────────────────────────────────────────────────
            AppTextField(
              label: 'Full Name',
              controller: _nameController,
              hint: 'Enter your name',
              errorText: _nameError,
              prefixIcon: Icons.person_rounded,
              enabled: !authState.isLoading,
            ),
            const SizedBox(height: AppDimens.grid * 2.5),

            AppTextField(
              label: 'Phone Number',
              controller: _phoneController,
              hint: '10 digit mobile number',
              errorText: _phoneError,
              prefixIcon: Icons.phone_rounded,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              enabled: !authState.isLoading,
            ),
            const SizedBox(height: AppDimens.grid * 2.5),

            AppTextField(
              label: 'Village',
              controller: _villageController,
              hint: 'Enter village name',
              prefixIcon: Icons.home_rounded,
              enabled: !authState.isLoading,
            ),
            const SizedBox(height: AppDimens.grid * 2.5),

            AppTextField(
              label: 'District',
              controller: _districtController,
              hint: 'Enter district name',
              prefixIcon: Icons.location_city_rounded,
              enabled: !authState.isLoading,
            ),
            const SizedBox(height: AppDimens.grid * 2.5),

            Text(
              'State',
              style: AppTextStyles.bodyMedium
                  .copyWith(color: Theme.of(context).colorScheme.onSurface),
            ),
            const SizedBox(height: AppDimens.grid),
            DropdownButtonFormField<String?>(
              value: _selectedState,
              isExpanded: true,
              decoration: InputDecoration(
                hintText: 'Select state',
                prefixIcon: Icon(Icons.map_rounded, size: 20, color: colors.textSecondary),
              ),
              items: [
                if (_selectedState != null &&
                    !kIndianStatesAndUnionTerritories.contains(_selectedState))
                  DropdownMenuItem<String?>(
                    value: _selectedState,
                    child: Text(_selectedState!, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ...kIndianStatesAndUnionTerritories.map(
                  (s) => DropdownMenuItem<String?>(
                    value: s,
                    child: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: authState.isLoading
                  ? null
                  : (v) => setState(() => _selectedState = v),
            ),
            const SizedBox(height: AppDimens.grid * 3),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.grid * 3),
          child: AppButton(
            label: 'Save Changes',
            onPressed: authState.isLoading ? null : _save,
            isLoading: authState.isLoading,
            icon: Icons.check_circle_outline_rounded,
          ),
        ),
      ),
    );
  }
}
