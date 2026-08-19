import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

const String kGoogleApiKey = "AIzaSyCY5cOcVAzNpNfR_uSoOpC245m6fAtqdoU";

class NuevaTortilleriaScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  const NuevaTortilleriaScreen({super.key, required this.onThemeChanged});

  @override
  State<NuevaTortilleriaScreen> createState() => _NuevaTortilleriaScreenState();
}

class _NuevaTortilleriaScreenState extends State<NuevaTortilleriaScreen> {
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _direccionController = TextEditingController();
  final FocusNode _direccionFocusNode = FocusNode();
  
  Timer? _debounce;
  String? _sessionToken;
  List<Map<String, dynamic>> _sugerencias = [];
  bool _cargandoSugerencias = false;
  bool _isSaving = false;
  
  GoogleMapController? _mapController;
  LatLng _ubicacionSeleccionada = const LatLng(19.432608, -99.133209); 
  Set<Marker> _marcadores = {};

  @override
  void dispose() {
    // 🚀 OPTIMIZACIÓN CLAVE: Destruimos todos los listeners y el mapa para liberar RAM
    _debounce?.cancel();
    _nombreController.dispose();
    _direccionController.dispose();
    _direccionFocusNode.dispose();
    _mapController?.dispose(); // 🔥 Matamos el mapa
    super.dispose();
  }

  // 🚀 LÓGICA DEL BUSCADOR ARREGLADA (Sin Bucle Infinito)
  Future<void> _buscarSugerencias(String input) async {
    if (_sessionToken == null) return;
    setState(() => _cargandoSugerencias = true);
    try {
      final url = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', {
        'input': input, 'components': 'country:mx', 'language': 'es', 'key': kGoogleApiKey, 'sessiontoken': _sessionToken,
      });
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK' && mounted) {
          setState(() {
            _sugerencias = (data['predictions'] as List).map((p) => {'texto': p['description'], 'place_id': p['place_id']}).toList();
          });
        } else {
          if (mounted) setState(() => _sugerencias = []);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _sugerencias = []);
    } finally {
      if (mounted) setState(() => _cargandoSugerencias = false);
    }
  }

  Future<void> _seleccionarLugar(String placeId, String descripcion) async {
    _direccionFocusNode.unfocus();
    setState(() { 
      _direccionController.text = descripcion; 
      _sugerencias = []; 
    }); 

    try {
      final url = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
        'place_id': placeId, 'fields': 'geometry', 'key': kGoogleApiKey, 'sessiontoken': _sessionToken!,
      });
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK') {
          final location = data['result']['geometry']['location'];
          LatLng newPos = LatLng(location['lat'], location['lng']);
          setState(() {
            _ubicacionSeleccionada = newPos;
            _marcadores = {Marker(markerId: const MarkerId('nueva_ubicacion'), position: newPos)};
          });
          _mapController?.animateCamera(CameraUpdate.newLatLngZoom(newPos, 16));
        }
      }
    } catch (e) {} finally { setState(() => _sessionToken = null); }
  }

  Future<void> _obtenerUbicacionActualGPS() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activa el GPS por favor.')));
      return;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
    }
    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      LatLng newPos = LatLng(position.latitude, position.longitude);
      
      final url = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'latlng': '${position.latitude},${position.longitude}', 'language': 'es', 'key': kGoogleApiKey,
      });
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty && mounted) {
          setState(() => _direccionController.text = data['results'][0]['formatted_address']);
        }
      }
      
      setState(() {
        _ubicacionSeleccionada = newPos;
        _marcadores = {Marker(markerId: const MarkerId('nueva_ubicacion'), position: newPos)};
      });
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(newPos, 16));
    } catch (e) { debugPrint("$e"); } 
  }

  Future<void> _guardar() async {
    if (_nombreController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor, ponle nombre al local')));
      return;
    }
    if (_marcadores.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor, selecciona una ubicación en el mapa')));
      return;
    }

    setState(() => _isSaving = true);
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiHost}/tortillerias'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'nombre': _nombreController.text.trim(), 
          'latitud': _ubicacionSeleccionada.latitude, 
          'longitud': _ubicacionSeleccionada.longitude
        })
      );
      if (res.statusCode == 200) {
        if (!mounted) return;
        Navigator.pop(context, true); 
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al guardar')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor, elevation: 0, centerTitle: true,
        title: Text('Nueva Tortillería', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text("Nombre del Local", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _nombreController,
                        decoration: InputDecoration(
                          hintText: "Ej. Tortillería El Sol",
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 24),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Ubicación", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          GestureDetector(
                            onTap: _obtenerUbicacionActualGPS,
                            child: const Row(children: [Icon(Icons.gps_fixed, color: Colors.blueAccent, size: 16), SizedBox(width: 4), Text("Usar GPS", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold))]),
                          )
                        ],
                      ),
                      const SizedBox(height: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 🚀 ELIMINAMOS EL LISTENER Y PONEMOS ONCHANGED
                          TextField(
                            controller: _direccionController,
                            focusNode: _direccionFocusNode,
                            decoration: InputDecoration(
                              isDense: true, 
                              hintText: "Buscar dirección...",
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onChanged: (value) {
                              if (_debounce?.isActive ?? false) _debounce!.cancel();
                              _debounce = Timer(const Duration(milliseconds: 700), () {
                                if (value.length > 2) {
                                  if(_sessionToken == null) setState(() { _sessionToken = DateTime.now().millisecondsSinceEpoch.toString(); });
                                  _buscarSugerencias(value);
                                } else {
                                  setState(() { _sugerencias = []; _sessionToken = null; });
                                }
                              });
                            },
                            onSubmitted: (_) { setState(() => _sugerencias = []); _direccionFocusNode.unfocus(); },
                          ),
                          if (_cargandoSugerencias || _sugerencias.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(top: 4.0), constraints: const BoxConstraints(maxHeight: 160),
                              decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))]),
                              child: _cargandoSugerencias
                                  ? const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()))
                                  : Material( 
                                      color: Colors.transparent,
                                      child: ListView.builder(
                                        padding: EdgeInsets.zero, shrinkWrap: true, itemCount: _sugerencias.length,
                                        itemBuilder: (context, index) {
                                          final sugerencia = _sugerencias[index];
                                          return ListTile(
                                              title: Text(sugerencia['texto'], maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)), 
                                              onTap: () => _seleccionarLugar(sugerencia['place_id'], sugerencia['texto']) 
                                          );
                                        },
                                      ),
                                    ),
                            ),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      const Text('Toca en el mapa para ajustar el pin:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 8),
                      
                      Container(
                        height: 250,
                        decoration: BoxDecoration(border: Border.all(color: Colors.blueAccent, width: 2), borderRadius: BorderRadius.circular(8)),
                        clipBehavior: Clip.hardEdge,
                        child: GoogleMap(
                          initialCameraPosition: CameraPosition(target: _ubicacionSeleccionada, zoom: 12),
                          mapType: MapType.normal,
                          markers: _marcadores,
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          onMapCreated: (controller) => _mapController = controller,
                          onTap: (pos) {
                            setState(() {
                              _ubicacionSeleccionada = pos;
                              _marcadores = {Marker(markerId: const MarkerId('nueva_ubicacion'), position: pos)};
                            });
                            _mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
                          },
                        ),
                      )
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _isSaving
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00C853), 
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                      ),
                      onPressed: _guardar,
                      child: const Text('GUARDAR TORTILLERÍA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}