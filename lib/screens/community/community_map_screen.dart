import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class CommunityMapScreen extends StatefulWidget {
  const CommunityMapScreen({super.key});

  @override
  State<CommunityMapScreen> createState() => _CommunityMapScreenState();
}

class _CommunityMapScreenState extends State<CommunityMapScreen> {
  final MapController _mapController = MapController();

  LatLng? _currentLocation;

  bool _isLoading = true;
  bool _isLoadingPlaces = false;
  bool _locationPermissionDenied = false;
  bool _locationServiceDisabled = false;

  String _selectedCategory = 'All';

  List<NearbyPlace> _places = [];

  final List<String> _categories = ['All', 'Blood', 'Hospitals', 'Labs'];

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  // ============================================================
  // INITIALIZE
  // ============================================================

  Future<void> _initializeMap() async {
    await _getCurrentLocation();
  }

  // ============================================================
  // GET CURRENT LOCATION
  // ============================================================

  Future<void> _getCurrentLocation() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _locationPermissionDenied = false;
      _locationServiceDisabled = false;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        if (!mounted) return;

        setState(() {
          _isLoading = false;
          _locationServiceDisabled = true;
        });

        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;

        setState(() {
          _isLoading = false;
          _locationPermissionDenied = true;
        });

        return;
      }

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final location = LatLng(position.latitude, position.longitude);

      if (!mounted) return;

      setState(() {
        _currentLocation = location;
        _isLoading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _currentLocation == null) return;

        _mapController.move(_currentLocation!, 14);
      });

      await _loadNearbyPlaces();
    } catch (e) {
      debugPrint('Location error: $e');

      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      _showMessage('Unable to get your current location.', isError: true);
    }
  }

  // ============================================================
  // LOAD NEARBY PLACES FROM OPENSTREETMAP
  // ============================================================

  Future<void> _loadNearbyPlaces() async {
    if (_currentLocation == null) return;

    if (mounted) {
      setState(() {
        _isLoadingPlaces = true;
      });
    }

    try {
      final lat = _currentLocation!.latitude;
      final lon = _currentLocation!.longitude;

      const radius = 5000;

      final query =
          '''
[out:json][timeout:25];

(
  nwr["amenity"="hospital"](around:$radius,$lat,$lon);
  nwr["healthcare"="hospital"](around:$radius,$lat,$lon);

  nwr["healthcare"="blood_bank"](around:$radius,$lat,$lon);
  nwr["healthcare"="blood_donation"](around:$radius,$lat,$lon);

  nwr["healthcare"="laboratory"](around:$radius,$lat,$lon);
  nwr["amenity"="clinic"](around:$radius,$lat,$lon);
);

out center tags;
''';

      final uri = Uri.parse('https://overpass-api.de/api/interpreter')
          .replace(queryParameters: {'data': query});

      final response = await http.get(
        uri,
        headers: {'User-Agent': 'BloodConnect/1.0'},
      );

      if (response.statusCode != 200) {
        throw Exception('Overpass API error: ${response.statusCode}');
      }

      final Map<String, dynamic> json = jsonDecode(response.body);

      final List<dynamic> elements = json['elements'] ?? [];

      final List<NearbyPlace> loadedPlaces = [];

      for (final element in elements) {
        final tags = Map<String, dynamic>.from(element['tags'] ?? {});

        double? placeLat;
        double? placeLon;

        if (element['type'] == 'node') {
          placeLat = (element['lat'] as num?)?.toDouble();
          placeLon = (element['lon'] as num?)?.toDouble();
        } else {
          final center = element['center'];

          if (center != null) {
            placeLat = (center['lat'] as num?)?.toDouble();

            placeLon = (center['lon'] as num?)?.toDouble();
          }
        }

        if (placeLat == null || placeLon == null) {
          continue;
        }

        final category = _detectCategory(tags);

        if (category == null) {
          continue;
        }

        final distance = _calculateDistanceKm(lat, lon, placeLat, placeLon);

        loadedPlaces.add(
          NearbyPlace(
            id: '${element['type']}_${element['id']}',
            name: _getPlaceName(tags, category),
            category: category,
            latitude: placeLat,
            longitude: placeLon,
            distanceKm: distance,
            phone:
                tags['phone']?.toString() ?? tags['contact:phone']?.toString(),
            address: _getAddress(tags),
          ),
        );
      }

      loadedPlaces.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

      final uniquePlaces = <String, NearbyPlace>{};

      for (final place in loadedPlaces) {
        final key = '${place.name.toLowerCase()}_${place.category}';

        if (!uniquePlaces.containsKey(key)) {
          uniquePlaces[key] = place;
        }
      }

      if (!mounted) return;

      setState(() {
        _places = uniquePlaces.values.toList();
        _isLoadingPlaces = false;
      });
    } catch (e) {
      debugPrint('Nearby places error: $e');

      if (!mounted) return;

      setState(() {
        _isLoadingPlaces = false;
      });

      _showMessage(
        'Nearby facilities could not be loaded. Please try again.',
        isError: true,
      );
    }
  }

  // ============================================================
  // DETECT CATEGORY
  // ============================================================

  String? _detectCategory(Map<String, dynamic> tags) {
    final healthcare = tags['healthcare']?.toString().toLowerCase();

    final amenity = tags['amenity']?.toString().toLowerCase();

    if (healthcare == 'blood_bank' || healthcare == 'blood_donation') {
      return 'Blood';
    }

    if (healthcare == 'laboratory') {
      return 'Labs';
    }

    if (amenity == 'hospital' || healthcare == 'hospital') {
      return 'Hospitals';
    }

    if (amenity == 'clinic') {
      return 'Hospitals';
    }

    return null;
  }

  // ============================================================
  // PLACE NAME
  // ============================================================

  String _getPlaceName(Map<String, dynamic> tags, String category) {
    final name = tags['name']?.toString().trim();

    if (name != null && name.isNotEmpty) {
      return name;
    }

    switch (category) {
      case 'Blood':
        return 'Blood Bank / Donation Center';

      case 'Hospitals':
        return 'Hospital / Clinic';

      case 'Labs':
        return 'Medical Laboratory';

      default:
        return 'Healthcare Facility';
    }
  }

  // ============================================================
  // ADDRESS
  // ============================================================

  String _getAddress(Map<String, dynamic> tags) {
    final parts = <String>[];

    final houseNumber = tags['addr:housenumber']?.toString();

    final street = tags['addr:street']?.toString();

    final city = tags['addr:city']?.toString();

    if (houseNumber != null && houseNumber.isNotEmpty) {
      parts.add(houseNumber);
    }

    if (street != null && street.isNotEmpty) {
      parts.add(street);
    }

    if (city != null && city.isNotEmpty) {
      parts.add(city);
    }

    if (parts.isEmpty) {
      return 'Address not available';
    }

    return parts.join(', ');
  }

  // ============================================================
  // DISTANCE
  // ============================================================

  double _calculateDistanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371.0;

    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a =
        pow(sin(dLat / 2), 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            pow(sin(dLon / 2), 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  // ============================================================
  // FILTER
  // ============================================================

  List<NearbyPlace> get _filteredPlaces {
    if (_selectedCategory == 'All') {
      return _places;
    }

    return _places
        .where((place) => place.category == _selectedCategory)
        .toList();
  }

  // ============================================================
  // MAP MARKERS
  // ============================================================

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    if (_currentLocation != null) {
      markers.add(
        Marker(
          point: _currentLocation!,
          width: 58,
          height: 58,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFE53935),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(
              Icons.person_pin_circle,
              color: Colors.white,
              size: 32,
            ),
          ),
        ),
      );
    }

    for (final place in _filteredPlaces) {
      markers.add(
        Marker(
          point: LatLng(place.latitude, place.longitude),
          width: 48,
          height: 48,
          child: GestureDetector(
            onTap: () {
              _showPlaceDetails(place);
            },
            child: Container(
              decoration: BoxDecoration(
                color: _categoryColor(place.category),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Icon(
                _categoryIcon(place.category),
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      );
    }

    return markers;
  }

  // ============================================================
  // CATEGORY ICON
  // ============================================================

  IconData _categoryIcon(String category) {
    switch (category) {
      case 'Blood':
        return Icons.bloodtype_rounded;

      case 'Hospitals':
        return Icons.local_hospital_rounded;

      case 'Labs':
        return Icons.science_rounded;

      default:
        return Icons.location_on_rounded;
    }
  }

  // ============================================================
  // CATEGORY COLOR
  // ============================================================

  Color _categoryColor(String category) {
    switch (category) {
      case 'Blood':
        return const Color(0xFFE53935);

      case 'Hospitals':
        return const Color(0xFF1976D2);

      case 'Labs':
        return const Color(0xFF7B1FA2);

      default:
        return Colors.grey;
    }
  }

  // ============================================================
  // PLACE DETAILS
  // ============================================================

  void _showPlaceDetails(NearbyPlace place) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: _categoryColor(place.category)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Icon(
                        _categoryIcon(place.category),
                        color: _categoryColor(place.category),
                        size: 28,
                      ),
                    ),

                    const SizedBox(width: 14),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            place.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),

                          const SizedBox(height: 4),

                          Text(
                            '${place.category} • ${place.distanceKm.toStringAsFixed(1)} km away',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurface
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 18),

                _PlaceInfoRow(
                  icon: Icons.location_on_outlined,
                  text: place.address,
                ),

                if (place.phone != null && place.phone!.isNotEmpty) ...[
                  const SizedBox(height: 10),

                  _PlaceInfoRow(icon: Icons.phone_outlined, text: place.phone!),
                ],

                const SizedBox(height: 20),

                Row(
                  children: [
                    if (place.phone != null && place.phone!.isNotEmpty)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _callPlace(place.phone!);
                          },
                          icon: const Icon(Icons.call_rounded),
                          label: const Text('Call'),
                        ),
                      ),

                    if (place.phone != null && place.phone!.isNotEmpty)
                      const SizedBox(width: 10),

                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE53935),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          _openDirections(place);
                        },
                        icon: const Icon(Icons.directions_rounded),
                        label: const Text('Directions'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // CALL
  // ============================================================

  Future<void> _callPlace(String phone) async {
    final cleanedPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');

    final uri = Uri(scheme: 'tel', path: cleanedPhone);

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        _showMessage('Unable to open phone dialer.', isError: true);
      }
    } catch (e) {
      debugPrint('Call error: $e');

      _showMessage('Unable to make the call.', isError: true);
    }
  }

  // ============================================================
  // DIRECTIONS
  // ============================================================

  Future<void> _openDirections(NearbyPlace place) async {
    if (_currentLocation == null) return;

    final originLat = _currentLocation!.latitude;

    final originLon = _currentLocation!.longitude;

    final destinationLat = place.latitude;

    final destinationLon = place.longitude;

    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=$originLat,$originLon'
      '&destination=$destinationLat,$destinationLon'
      '&travelmode=driving',
    );

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _showMessage('Unable to open directions.', isError: true);
      }
    } catch (e) {
      debugPrint('Directions error: $e');

      _showMessage('Unable to open directions.', isError: true);
    }
  }

  // ============================================================
  // LOCATION BUTTON
  // ============================================================

  Future<void> _goToCurrentLocation() async {
    if (_currentLocation == null) {
      await _getCurrentLocation();
      return;
    }

    _mapController.move(_currentLocation!, 15);
  }

  // ============================================================
  // LOCATION SETTINGS
  // ============================================================

  Future<void> _openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  Future<void> _openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  // ============================================================
  // REFRESH
  // ============================================================

  Future<void> _refreshAll() async {
    await _getCurrentLocation();
  }

  // ============================================================
  // LOCATION PERMISSION CARD
  // ============================================================

  Widget _buildLocationPermissionCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_off_rounded, size: 56, color: Colors.red),

                const SizedBox(height: 16),

                Text(
                  _locationServiceDisabled
                      ? 'Location Services Are Off'
                      : 'Location Permission Needed',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 10),

                Text(
                  _locationServiceDisabled
                      ? 'Please turn on location services so BloodConnect can find nearby facilities.'
                      : 'BloodConnect needs your location to show nearby blood facilities, hospitals and laboratories.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _locationServiceDisabled
                        ? _openLocationSettings
                        : _openAppSettings,
                    icon: Icon(
                      _locationServiceDisabled
                          ? Icons.location_on
                          : Icons.settings,
                    ),
                    label: Text(
                      _locationServiceDisabled
                          ? 'Turn On Location'
                          : 'Open App Settings',
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                TextButton(
                  onPressed: _getCurrentLocation,
                  child: const Text('Try Again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // FILTER BAR
  // ============================================================

  Widget _buildFilterBar() {
    return Positioned(
      left: 12,
      right: 12,
      top: 86,
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _categories.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final category = _categories[index];

            final selected = _selectedCategory == category;

            return ChoiceChip(
              label: Text(category),
              selected: selected,
              onSelected: (_) {
                setState(() {
                  _selectedCategory = category;
                });
              },
              selectedColor: const Color(0xFFE53935),
              backgroundColor: Theme.of(context).cardColor,
              labelStyle: TextStyle(
                color: selected
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            );
          },
        ),
      ),
    );
  }

  // ============================================================
  // PLACES LIST
  // ============================================================

  Widget _buildPlacesList() {
    final places = _filteredPlaces;

    return Positioned(
      left: 12,
      right: 12,
      bottom: 16,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 230),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: places.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'No nearby facilities found in this category.',
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.all(8),
                itemCount: places.length > 5 ? 5 : places.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final place = places[index];

                  return ListTile(
                    dense: true,
                    onTap: () {
                      _mapController.move(
                        LatLng(place.latitude, place.longitude),
                        16,
                      );

                      _showPlaceDetails(place);
                    },
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _categoryColor(place.category)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _categoryIcon(place.category),
                        color: _categoryColor(place.category),
                      ),
                    ),
                    title: Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: Text(
                      '${place.distanceKm.toStringAsFixed(1)} km • ${place.category}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 14,
                    ),
                  );
                },
              ),
      ),
    );
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Nearby Community',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isLoadingPlaces)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFE53935),
                  ),
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refreshAll,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFE53935)),
            )
          : _currentLocation == null
          ? _buildLocationPermissionCard()
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentLocation!,
                    initialZoom: 14,
                    minZoom: 3,
                    maxZoom: 19,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.bloodconnect.app',
                    ),

                    MarkerLayer(markers: _buildMarkers()),

                    RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('OpenStreetMap contributors'),
                      ],
                    ),
                  ],
                ),

                // ==================================================
                // TOP LOCATION CARD
                // ==================================================
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: Card(
                    elevation: 4,
                    color: theme.cardColor,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEBEE),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.location_on,
                              color: Color(0xFFE53935),
                            ),
                          ),

                          const SizedBox(width: 12),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Nearby BloodConnect Facilities',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),

                                const SizedBox(height: 3),

                                Text(
                                  '${_filteredPlaces.length} places found nearby',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                _buildFilterBar(),

                _buildPlacesList(),

                // ==================================================
                // CURRENT LOCATION BUTTON
                // ==================================================
                Positioned(
                  right: 16,
                  bottom: 255,
                  child: FloatingActionButton(
                    heroTag: 'currentLocationButton',
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFFE53935),
                    elevation: 5,
                    onPressed: _goToCurrentLocation,
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
    );
  }
}

// ================================================================
// NEARBY PLACE MODEL
// ================================================================

class NearbyPlace {
  final String id;
  final String name;
  final String category;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final String? phone;
  final String address;

  const NearbyPlace({
    required this.id,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    required this.phone,
    required this.address,
  });
}

// ================================================================
// PLACE INFO ROW
// ================================================================

class _PlaceInfoRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PlaceInfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xFFE53935)),

        const SizedBox(width: 10),

        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4)),
        ),
      ],
    );
  }
}
