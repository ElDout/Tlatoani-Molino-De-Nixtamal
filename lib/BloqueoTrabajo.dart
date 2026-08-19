import 'dart:async';
import 'dart:convert';
import 'dart:typed_data'; 
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:molino_app/Trabajadadores.dart'; 

const String kGoogleApiKey = "AIzaSyCY5cOcVAzNpNfR_uSoOpC245m6fAtqdoU";

class BloqueoTrabajoScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final Map<String, dynamic> ordenInicial; 
  
  const BloqueoTrabajoScreen({
    super.key, 
    required this.onThemeChanged,
    required this.ordenInicial,
  });

  @override
  State<BloqueoTrabajoScreen> createState() => _BloqueoTrabajoScreenState();
}

class _BloqueoTrabajoScreenState extends State<BloqueoTrabajoScreen> {
  Map<String, dynamic>? _ordenActual;
  IO.Socket? _socket;
  bool _isLoading = false; 

  GoogleMapController? _mapController;
  LatLng? _ubicacionRepartidor;
  LatLng? _destinoCliente;

  Set<Polyline> _rutas = {};
  Set<Marker> _marcadores = {}; 
  String _tiempoEstimado = "";
  bool _trazandoRuta = false;
  DateTime? _ultimaVezRuta;
  LatLngBounds? _boundsActuales;
  BitmapDescriptor? _iconoMoto;

  Uint8List? _fotoRepartidorBytes;
  List<dynamic> _masas = [];
  List<dynamic> _mercancia = [];

  // 🚀 FUNCIÓN MEJORADA: DETECTA EL CAMBIO DE UBICACIÓN
  void _prepararMapa() {
    if (_ordenActual == null) return;

    double lat = double.tryParse(_ordenActual!['lat_custom']?.toString() ?? _ordenActual!['latitud']?.toString() ?? '19.4') ?? 19.4;
    double lng = double.tryParse(_ordenActual!['lng_custom']?.toString() ?? _ordenActual!['longitud']?.toString() ?? '-99.1') ?? -99.1;
    
    LatLng nuevoDestino = LatLng(lat, lng);
    
    // Verificamos si la ubicación se corrigió
    bool destinoCambio = _destinoCliente == null ||
        (_destinoCliente!.latitude != nuevoDestino.latitude || _destinoCliente!.longitude != nuevoDestino.longitude);

    _destinoCliente = nuevoDestino;

    final nuevosMarcadores = Set<Marker>.from(_marcadores);

    nuevosMarcadores.removeWhere((m) => m.markerId.value == 'destino');
    nuevosMarcadores.add(Marker(
      markerId: const MarkerId('destino'),
      position: _destinoCliente!,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: const InfoWindow(title: "Tu local"),
    ));

    if (_ubicacionRepartidor != null) {
      nuevosMarcadores.removeWhere((m) => m.markerId.value == 'repartidor');
      nuevosMarcadores.add(Marker(
        markerId: const MarkerId('repartidor'),
        position: _ubicacionRepartidor!,
        icon: _iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: "Repartidor"),
        zIndex: 2, 
      ));
    }

    _marcadores = nuevosMarcadores;

    // 🚀 Si el destino cambió de Iztacalco al local real, trazamos la ruta al instante
    if (destinoCambio && _ubicacionRepartidor != null && mounted) {
      _trazarRutaYCalcularTiempo();
    }
  }

  @override
  void initState() {
    super.initState();
    _ordenActual = widget.ordenInicial;
    _cargarIconoMoto();
    _prepararDatosOrden(); 
    _prepararMapa(); 

    // 🚀 MAGIA PURA: Forzamos la actualización silenciosa en el segundo cero
    // para obtener las coordenadas exactas de la base de datos de inmediato.
    _revisarEstadoOrdenSilencioso();

    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true, 
    });

    _socket!.onConnect((_) {
      debugPrint("🟢 SOCKET TRABAJADOR CONECTADO AL SERVER");
    });

    _socket!.on('actualizacion_ordenes', (_) {
      if (mounted) {
        _revisarEstadoOrdenSilencioso();
      }
    });

    _socket!.on('ubicacion_repartidor', (data) {
      if (!mounted) return;
      
      if (data != null && data['id_orden'] != null && data['lat'] != null && data['lng'] != null) {
        if (data['id_orden'].toString() == _ordenActual!['id'].toString()) {

          final double? lat = double.tryParse(data['lat'].toString());
          final double? lng = double.tryParse(data['lng'].toString());

          if (lat == null || lng == null) return;
          LatLng nuevaPos = LatLng(lat, lng);

          setState(() {
            _ubicacionRepartidor = nuevaPos;
            
            final nuevosMarcadores = Set<Marker>.from(_marcadores);
            nuevosMarcadores.removeWhere((m) => m.markerId.value == 'repartidor');
            nuevosMarcadores.add(Marker(
              markerId: const MarkerId('repartidor'),
              position: nuevaPos,
              icon: _iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
              infoWindow: const InfoWindow(title: "Repartidor"),
              zIndex: 2,
            ));
            _marcadores = nuevosMarcadores;
          });
          
          if (_ultimaVezRuta == null || DateTime.now().difference(_ultimaVezRuta!).inSeconds >= 15) {
            _trazarRutaYCalcularTiempo();
            _ultimaVezRuta = DateTime.now();
          } else {
            if (_boundsActuales == null && _ubicacionRepartidor != null) {
              _mapController?.animateCamera(CameraUpdate.newLatLng(_ubicacionRepartidor!));
            }
          }
        }
      }
    });

    _socket!.on('notify_mercancia_modificada', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      
      if ((data['id_cliente'] == miId || data['id_trabajador'] == miId) && 
          data['id_orden'].toString() == _ordenActual!['id'].toString() && 
          mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('⚠️ Pedido Modificado', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('El repartidor reportó mercancía faltante. Se han ajustado los productos de tu orden.\n\nNuevo total: \$${data['nuevo_total']} MXN.'),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853)),
                onPressed: () => Navigator.pop(ctx), 
                child: const Text('Entendido', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
              )
            ],
          )
        );
      }
    });
  }
  
  Future<void> _cargarIconoMoto() async {
    _iconoMoto = await BitmapDescriptor.fromAssetImage(
      const ImageConfiguration(size: Size(48, 48)),
      'assets/moto_icon.png', 
    );
    if (mounted) {
      setState(() {
        _prepararMapa(); 
      });
    }
  }

  void _prepararDatosOrden() {
    if (_ordenActual == null) return;

    final String? fotoBase64 = _ordenActual!['foto_repartidor'];
    if (fotoBase64 != null && fotoBase64.isNotEmpty) {
      try {
        _fotoRepartidorBytes = base64Decode(fotoBase64.replaceAll(RegExp(r'\s+'), ''));
      } catch (e) {
        _fotoRepartidorBytes = null;
      }
    }

    final dynamic prodsRaw = _ordenActual!['productos'];
    final List<dynamic> productos = prodsRaw is String ? jsonDecode(prodsRaw) : List.from(prodsRaw ?? []);
    
    _masas.clear();
    _mercancia.clear();
    
    for (var p in productos) {
      bool esMasa = p['detalle']?.toString().toLowerCase().contains('kilo') == true || p['detalle']?.toString().toLowerCase().contains('gramo') == true;
      if (esMasa) _masas.add(p);
      else _mercancia.add(p);
    }
  }

  @override
  void dispose() { 
    _socket?.disconnect(); 
    _mapController?.dispose(); 
    super.dispose(); 
  }

  List<LatLng> _decodificarRuta(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lat += dlat;
      shift = 0; result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lng += dlng;
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  Future<void> _trazarRutaYCalcularTiempo() async {
    if (_ubicacionRepartidor == null || _destinoCliente == null || _trazandoRuta) return;
    _trazandoRuta = true;
    
    try {
      final Map<String, dynamic> body = {
        "origin": {"location": {"latLng": {"latitude": _ubicacionRepartidor!.latitude, "longitude": _ubicacionRepartidor!.longitude}}},
        "destination": {"location": {"latLng": {"latitude": _destinoCliente!.latitude, "longitude": _destinoCliente!.longitude}}},
        "travelMode": "DRIVE"
      };

      final response = await http.post(
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
        headers: {'Content-Type': 'application/json', 'X-Goog-Api-Key': kGoogleApiKey, 'X-Goog-FieldMask': 'routes.polyline.encodedPolyline,routes.duration'},
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          List<LatLng> puntosRuta = _decodificarRuta(route['polyline']['encodedPolyline']);
          
          String duracionStr = route['duration'] ?? ""; 
          int segundos = int.tryParse(duracionStr.replaceAll('s', '')) ?? 0;
          int minutos = (segundos / 60).ceil();

          double minLat = _ubicacionRepartidor!.latitude;
          double maxLat = _ubicacionRepartidor!.latitude;
          double minLng = _ubicacionRepartidor!.longitude;
          double maxLng = _ubicacionRepartidor!.longitude;
          for (LatLng p in puntosRuta) {
            if (p.latitude < minLat) minLat = p.latitude; if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLng) minLng = p.longitude; if (p.longitude > maxLng) maxLng = p.longitude;
          }

          if (mounted) {
            setState(() {
              _rutas = {Polyline(polylineId: const PolylineId('ruta_moto'), color: Colors.blueAccent, width: 6, points: puntosRuta)};
              _tiempoEstimado = minutos > 0 ? "$minutos min" : "Llegando...";
              _boundsActuales = LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
            });
            
            _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsActuales!, 60.0));
          }
        }
      }
    } catch (e) {
      debugPrint("❌ Error trazando ruta de Google Maps: $e");
    } finally {
      _trazandoRuta = false;
    }
  }

  void _centrarMapa() {
    if (_mapController == null) return;
    if (_boundsActuales != null) {
      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(_boundsActuales!, 60.0));
    } else if (_ubicacionRepartidor != null) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_ubicacionRepartidor!, 15));
    } else if (_destinoCliente != null) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_destinoCliente!, 15));
    }
  }

  Future<void> _revisarEstadoOrdenSilencioso() async {
    try {
      final int idOrden = _ordenActual!['id'];
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/$idOrden'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final ordenServer = data['orden'];
          if (ordenServer['estado'] == 'Completada') {
            _socket?.disconnect();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ ¡Trabajo completado!', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)), backgroundColor: Colors.green));
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => TrabajadoresScreen(onThemeChanged: widget.onThemeChanged)),
                (route) => false,
              );
            }
          } else {
            if (mounted) {
              setState(() { 
                _ordenActual = ordenServer;
                _prepararMapa();
                _prepararDatosOrden(); 
              });
            }
          }
        }
      }
    } catch (e) { debugPrint('Error revisando orden: $e'); }
  }

  void _mostrarDetalleConMapa(Map<String, dynamic> orden, List<dynamic> masas, List<dynamic> mercancia, String tituloViaje, bool isDarkMode) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return ModalMapaCliente(
          orden: orden,
          masas: masas,
          mercancia: mercancia,
          tituloViaje: tituloViaje,
          isDarkMode: isDarkMode,
          socket: _socket,
          iconoMoto: _iconoMoto,
          ubicacionInicial: _ubicacionRepartidor,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? const Color(0xFF2A2A2A) : const Color(0xFF003B99);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white), 
          onPressed: () { 
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => TrabajadoresScreen(onThemeChanged: widget.onThemeChanged)),
              (route) => false,
            );
          }
        ),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            itemBuilder: (context) => [
              PopupMenuItem(enabled: false, child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Modo Oscuro'), Switch(value: isDarkMode, onChanged: (value) { widget.onThemeChanged(value ? ThemeMode.dark : ThemeMode.light); Navigator.pop(context); })])),
            ],
          )
        ],
      ),
      body: _isLoading ? const Center(child: CircularProgressIndicator(color: Colors.white)) : _construirPantallaEstadoNormal(), 
    );
  }

  Widget _construirPantallaEstadoNormal() {
    final String estado = _ordenActual!['estado'];
    final bool repartidorAsignado = (estado == 'Asignado' || estado == 'En Camino' || estado == 'Pendiente' && _ordenActual!['id_repartidor'] != null);
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!repartidorAsignado) ...[
            const SizedBox(height: 20),
            const Text('Esperando asignar repartidor...', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
          ] else ...[
            Row(
              children: [
                Container(
                  width: 60, height: 60, 
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)), 
                  clipBehavior: Clip.hardEdge, 
                  child: _fotoRepartidorBytes != null 
                    ? Image.memory(
                        _fotoRepartidorBytes!, 
                        fit: BoxFit.cover,
                        cacheWidth: 150, 
                        errorBuilder: (c,e,s) => const Icon(Icons.person, color: Colors.white, size: 40)
                      ) 
                    : const Icon(Icons.person, color: Colors.white, size: 40)
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Repartidor:\n${_ordenActual!['nombre_repartidor'] ?? 'No disponible'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), 
                  const SizedBox(height: 4), 
                  Text('Teléfono:\n${_ordenActual!['tel_repartidor'] ?? 'No disponible'}', style: const TextStyle(color: Colors.white70, fontSize: 12))
                ])),
                if (estado == 'En Camino')
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.orangeAccent, borderRadius: BorderRadius.circular(20)),
                        child: const Text('En Camino', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                      if (_tiempoEstimado.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(12)),
                            child: Text('⏱ $_tiempoEstimado', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                          ),
                        ),
                    ],
                  )
              ],
            ),
            const SizedBox(height: 24),
          ],
          Text(_ordenActual!['viaje_programado'] ?? 'Viaje', textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 16),
          
          if (_masas.isNotEmpty) ...[
            const Text("Masas:", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._masas.map((prod) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.circle, color: Colors.orangeAccent, size: 10),
                  const SizedBox(width: 8),
                  Expanded(child: Text(prod['nombre_producto'], style: const TextStyle(color: Colors.white, fontSize: 14))),
                  Text('${prod['cantidad']} Kl.', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            )).toList(),
            const SizedBox(height: 12),
          ],

          if (_mercancia.isNotEmpty) ...[
            const Text("Productos:", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._mercancia.map((prod) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.circle, color: Colors.blueAccent, size: 10),
                  const SizedBox(width: 8),
                  Expanded(child: Text(prod['nombre_producto'], style: const TextStyle(color: Colors.white70, fontSize: 14))),
                  Text('${prod['cantidad']} U.', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            )).toList(),
            const SizedBox(height: 16),
          ],

          if (repartidorAsignado)
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 2),
                ),
                clipBehavior: Clip.hardEdge,
                child: Stack(
                  children: [
                    GoogleMap(
                      onMapCreated: (controller) => _mapController = controller,
                      initialCameraPosition: CameraPosition(
                        target: _ubicacionRepartidor ?? _destinoCliente ?? const LatLng(19.4, -99.1),
                        zoom: 15,
                      ),
                      myLocationEnabled: false,
                      zoomControlsEnabled: false,
                      polylines: _rutas, 
                      markers: _marcadores, 
                    ),
                    
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: FloatingActionButton(
                        mini: true,
                        backgroundColor: Colors.white,
                        onPressed: _centrarMapa,
                        child: const Icon(Icons.my_location, color: Colors.blueAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (repartidorAsignado) ...[
            const SizedBox(height: 16),
            const Text('CÓDIGO DE ENTREGA', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
            Text('${_ordenActual!['codigo_entrega']}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 36, letterSpacing: 4, fontWeight: FontWeight.bold)),
            const Text('No lo compartas hasta que el\nrepartidor entregue la orden', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 8)),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// =========================================================
// 🚀 MODAL INTERACTIVO CON MAPA EN TIEMPO REAL PARA CLIENTE/TRABAJADOR
// =========================================================
class ModalMapaCliente extends StatefulWidget {
  final Map<String, dynamic> orden;
  final List<dynamic> masas;
  final List<dynamic> mercancia;
  final String tituloViaje;
  final bool isDarkMode;
  final IO.Socket? socket;
  final BitmapDescriptor? iconoMoto;
  final LatLng? ubicacionInicial;

  const ModalMapaCliente({
    super.key,
    required this.orden,
    required this.masas,
    required this.mercancia,
    required this.tituloViaje,
    required this.isDarkMode,
    this.socket,
    this.iconoMoto,
    this.ubicacionInicial,
  });

  @override
  State<ModalMapaCliente> createState() => _ModalMapaClienteState();
}

class _ModalMapaClienteState extends State<ModalMapaCliente> {
  GoogleMapController? _mapController;
  Set<Marker> _marcadores = {};
  Set<Polyline> _rutas = {};
  String _tiempoEstimado = "";
  bool _trazandoRuta = false;

  DateTime? _ultimaVezRuta;
  LatLng? _posicionRepartidorActual;
  LatLng? _destinoCliente;

  @override
  void initState() {
    super.initState();
    _posicionRepartidorActual = widget.ubicacionInicial;
    _prepararMapa();

    if (widget.socket != null && !widget.socket!.hasListeners('ubicacion_repartidor')) {
       widget.socket!.on('ubicacion_repartidor', _onUbicacionRecibida);
    } else if (widget.socket != null) {
       widget.socket!.on('ubicacion_repartidor', _onUbicacionRecibida);
    }
  }

  void _onUbicacionRecibida(dynamic data) {
    if (!mounted) return;
    
    if (data != null && data['id_orden'] != null && data['id_orden'].toString() == widget.orden['id'].toString() && data['lat'] != null) {
      
      double? latRep = double.tryParse(data['lat'].toString());
      double? lngRep = double.tryParse(data['lng'].toString());
      
      if (latRep == null || lngRep == null) return;

      LatLng nuevaPos = LatLng(latRep, lngRep);
      
      setState(() {
        _posicionRepartidorActual = nuevaPos;
        
        final nuevosMarcadores = Set<Marker>.from(_marcadores);
        nuevosMarcadores.removeWhere((m) => m.markerId.value == 'repartidor');
        nuevosMarcadores.add(Marker(
          markerId: const MarkerId('repartidor'),
          position: nuevaPos,
          icon: widget.iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: const InfoWindow(title: "Repartidor"),
          zIndex: 2,
        ));
        _marcadores = nuevosMarcadores;
      });

      if (_ultimaVezRuta == null || DateTime.now().difference(_ultimaVezRuta!).inSeconds >= 30) {
        if (_destinoCliente != null) {
          _trazarRutaA(nuevaPos, _destinoCliente!);
          _ultimaVezRuta = DateTime.now();
        }
      } else {
          _mapController?.animateCamera(CameraUpdate.newLatLng(nuevaPos));
      }
    }
  }

  @override
  void dispose() {
    widget.socket?.off('ubicacion_repartidor', _onUbicacionRecibida); 
    _mapController?.dispose();
    super.dispose();
  }

  void _prepararMapa() {
    double lat = double.tryParse(widget.orden['lat_custom']?.toString() ?? widget.orden['latitud']?.toString() ?? '19.4') ?? 19.4;
    double lng = double.tryParse(widget.orden['lng_custom']?.toString() ?? widget.orden['longitud']?.toString() ?? '-99.1') ?? -99.1;
    
    LatLng nuevoDestino = LatLng(lat, lng);
    bool destinoCambio = _destinoCliente == null ||
        (_destinoCliente!.latitude != nuevoDestino.latitude || _destinoCliente!.longitude != nuevoDestino.longitude);

    _destinoCliente = nuevoDestino;

    final nuevosMarcadores = Set<Marker>.from(_marcadores);

    nuevosMarcadores.removeWhere((m) => m.markerId.value == 'destino');
    nuevosMarcadores.add(Marker(
      markerId: const MarkerId('destino'),
      position: _destinoCliente!,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: const InfoWindow(title: "Tu ubicación"),
    ));

    if (_posicionRepartidorActual != null) {
      nuevosMarcadores.removeWhere((m) => m.markerId.value == 'repartidor');
      nuevosMarcadores.add(Marker(
        markerId: const MarkerId('repartidor'),
        position: _posicionRepartidorActual!,
        icon: widget.iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: "Repartidor"),
        zIndex: 2,
      ));
    }
    
    _marcadores = nuevosMarcadores;

    if (destinoCambio && _posicionRepartidorActual != null && mounted) {
      _trazarRutaA(_posicionRepartidorActual!, _destinoCliente!);
    }
  }

  List<LatLng> _decodificarRuta(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lat += dlat;
      shift = 0; result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lng += dlng;
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  Future<void> _trazarRutaA(LatLng origen, LatLng destino) async {
    if (_trazandoRuta) return;
    
    setState(() => _trazandoRuta = true);
    try {
      final Map<String, dynamic> body = {
        "origin": {"location": {"latLng": {"latitude": origen.latitude, "longitude": origen.longitude}}},
        "destination": {"location": {"latLng": {"latitude": destino.latitude, "longitude": destino.longitude}}},
        "travelMode": "DRIVE"
      };

      final response = await http.post(
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'), 
        headers: {'Content-Type': 'application/json', 'X-Goog-Api-Key': kGoogleApiKey, 'X-Goog-FieldMask': 'routes.polyline.encodedPolyline,routes.duration'}, 
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          List<LatLng> puntosRuta = _decodificarRuta(route['polyline']['encodedPolyline']);
          
          String duracionStr = route['duration'].toString().replaceAll('s', '');
          int segundos = int.tryParse(duracionStr) ?? 0;
          int minutos = (segundos / 60).ceil(); 

          setState(() {
            _tiempoEstimado = minutos > 0 ? "$minutos min" : "Llegando...";
            _rutas = {Polyline(polylineId: const PolylineId('ruta_moto'), color: Colors.blueAccent, width: 6, points: puntosRuta)};
          });

          double minLat = origen.latitude, maxLat = origen.latitude, minLng = origen.longitude, maxLng = origen.longitude;
          for (LatLng p in puntosRuta) {
            if (p.latitude < minLat) minLat = p.latitude; if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLng) minLng = p.longitude; if (p.longitude > maxLng) maxLng = p.longitude;
          }
          Future.delayed(const Duration(milliseconds: 300), () {
            _mapController?.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 60.0));
          });
        }
      }
    } catch (e) {
    } finally {
      if (mounted) setState(() => _trazandoRuta = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85, 
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10)))),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.tituloViaje, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange[700])),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.person, color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Para: ${widget.orden['cliente'] ?? 'Sin nombre'}', style: TextStyle(color: widget.isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.store, color: widget.isDarkMode ? Colors.green[300] : Colors.green[700], size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Local: ${widget.orden['local'] ?? 'No especificado'}', style: TextStyle(color: widget.isDarkMode ? Colors.white70 : Colors.black, fontSize: 15))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.location_on, color: widget.isDarkMode ? Colors.red[300] : Colors.red[700], size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Ubicación: ${widget.orden['direccion'] ?? 'No especificada'}', style: TextStyle(color: widget.isDarkMode ? Colors.white70 : Colors.black, fontSize: 15))),
                    ],
                  ),
                  Divider(height: 20, thickness: 1.5, color: widget.isDarkMode ? Colors.white24 : Colors.black),
                  
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (widget.masas.isNotEmpty)
                        Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.masas.map((m) => Text("${m['nombre_producto'] ?? 'Masa'}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: widget.isDarkMode ? Colors.white : Colors.black))).toList())),
                      if (widget.masas.isNotEmpty && widget.mercancia.isNotEmpty)
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 12.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                      if (widget.mercancia.isNotEmpty)
                        Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.mercancia.map((m) => Text("${m['nombre_producto'] ?? 'Producto'}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 14, color: Colors.grey))).toList())),
                    ],
                  ),
                  const SizedBox(height: 16),
                ]
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(
                         target: _posicionRepartidorActual ?? _destinoCliente ?? const LatLng(19.4, -99.1), 
                         zoom: 16
                      ),
                      markers: _marcadores,
                      polylines: _rutas,
                      myLocationEnabled: false,
                      zoomControlsEnabled: false,
                      onMapCreated: (controller) => _mapController = controller,
                    ),
                    if (_tiempoEstimado.isNotEmpty)
                      Positioned(
                        top: 10, right: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                          child: Row(
                            children: [
                              const Icon(Icons.timer, color: Colors.blueAccent, size: 18),
                              const SizedBox(width: 6),
                              Text("Llega en $_tiempoEstimado", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
                            ],
                          ),
                        ),
                      )
                    else if (_trazandoRuta)
                      Positioned(
                        top: 10, right: 10,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                          child: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                    Positioned(
                      bottom: 16, right: 16,
                      child: FloatingActionButton(
                        mini: true, backgroundColor: Colors.white,
                        onPressed: () {
                          if (_posicionRepartidorActual != null) {
                            _mapController?.animateCamera(CameraUpdate.newLatLngZoom(_posicionRepartidorActual!, 15));
                          }
                        },
                        child: const Icon(Icons.my_location, color: Colors.blueAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}