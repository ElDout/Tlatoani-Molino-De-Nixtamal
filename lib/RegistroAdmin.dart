import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:molino_app/config.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/NotificacionesHelper.dart';
class RegistroClientesScreen extends StatefulWidget {
  const RegistroClientesScreen({super.key});

  @override
  State<RegistroClientesScreen> createState() => _RegistroClientesScreenState();
}

class _RegistroClientesScreenState extends State<RegistroClientesScreen> {
  List<dynamic> _clientesPendientes = [];
  bool _isLoading = true;
  IO.Socket? _socket; 

  @override
  void initState() {
    super.initState();
    _obtenerClientes();
    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });
    _socket!.on('notify_nuevo_registro', (data) {
    if (mounted) {
      NotificacionesHelper.mostrarNotificacion(
        titulo: 'Nuevo Cliente Registrado 👤',
        cuerpo: '${data['cliente']} está esperando aprobación.',
        payload: {'tipo': 'admin_registro', 'id_cliente': data['id_cliente']}
      );
    }
  });
  }

  @override
  void dispose() {
    _socket?.disconnect(); 
    super.dispose();
  }

  Future<void> _obtenerClientes({bool silencioso = false}) async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/clientes/pendientes'));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _clientesPendientes = jsonDecode(response.body);
            if (!silencioso) _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error obteniendo clientes: $e');
    } finally {
      if (mounted && !silencioso) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _aprobarCliente(String id) async {
    try {
      await http.put(Uri.parse('${AppConfig.apiHost}/clientes/aprobar/$id'));
      _obtenerClientes(silencioso: true); 
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cliente aprobado ✅')));
    } catch (e) {
      debugPrint('Error aprobando: $e');
    }
  }

  Future<void> _rechazarCliente(String id) async {
    try {
      await http.delete(Uri.parse('${AppConfig.apiHost}/clientes/rechazar/$id'));
      _obtenerClientes(silencioso: true); 
      if (!mounted) return;
     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cliente eliminado 🗑️'), 
        backgroundColor: Colors.red,
      ));
    } catch (e) {
      debugPrint('Error eliminando: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registro Clientes'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _clientesPendientes.isEmpty
              ? const Center(child: Text('No hay clientes pendientes'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16.0),
                  itemCount: _clientesPendientes.length,
                  itemBuilder: (context, index) {
                    final cliente = _clientesPendientes[index];
                    final String fechaRaw = cliente['fecha_registro'] ?? '';
                    final String fecha = fechaRaw.length > 10 ? fechaRaw.substring(0, 10) : 'xx/xx/xxxx';
                    final String? imagenBase64 = cliente['imagen']; // 📸 EXTRAEMOS LA IMAGEN
                    
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12.0),
                      clipBehavior: Clip.hardEdge, 
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      color: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC),
                      child: Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          iconColor: isDarkMode ? Colors.black : Colors.white,
                          collapsedIconColor: isDarkMode ? Colors.black : Colors.white,
                          
                          // 📸 FOTOGRAFÍA DEL CLIENTE EN LA TARJETA
                          leading: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: isDarkMode ? Colors.grey[600] : const Color(0xFF003399),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            clipBehavior: Clip.hardEdge,
                            child: (imagenBase64 != null && imagenBase64.isNotEmpty)
                                ? Image.memory(
                                    base64Decode(imagenBase64.replaceAll(RegExp(r'\s+'), '')), 
                                    fit: BoxFit.cover,
                                    cacheWidth: 100, // 🚀 PROTEGE LA RAM EN LA LISTA
                                  )
                                : const Icon(Icons.person, color: Colors.white),
                          ),

                          title: Text(
                            cliente['nombre_propietario'] ?? 'Sin nombre',
                            style: TextStyle(color: isDarkMode ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(cliente['telefono'] ?? 'XX-XXXX-XXXX', style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white70)),
                              Text(cliente['correo'] ?? 'xxxxx@xxxxxx.xxx', style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white70)),
                            ],
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('Fecha:', style: TextStyle(color: isDarkMode ? Colors.black : Colors.white, fontSize: 12)),
                              Text(fecha, style: TextStyle(color: isDarkMode ? Colors.black : Colors.white, fontSize: 12)),
                            ],
                          ),
                          children: [
                            Container(
                              color: isDarkMode ? const Color(0xFF2A2A2A) : const Color(0xFF0040A0),
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildDetalle('Nombre:', cliente['nombre_propietario'], isDarkMode),
                                  _buildDetalle('Correo:', cliente['correo'], isDarkMode),
                                  _buildDetalle('Teléfono:', cliente['telefono'], isDarkMode),
                                  const SizedBox(height: 12),
                                  
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildDetalle('Ubicación:', cliente['direccion'], isDarkMode),
                                            const SizedBox(height: 8),
                                            Text('Mapa', style: TextStyle(color: isDarkMode ? Colors.white : Colors.white, fontWeight: FontWeight.bold)),
                                            const SizedBox(height: 8),
                                            GestureDetector(
                                              onTap: () {
                                                final lat = double.tryParse(cliente['latitud']?.toString() ?? '19.4326') ?? 19.4326;
                                                final lng = double.tryParse(cliente['longitud']?.toString() ?? '-99.1332') ?? -99.1332;
                                                Navigator.push(context, MaterialPageRoute(
                                                  builder: (context) => VerMapaAdminScreen(latitud: lat, longitud: lng, nombreLocal: cliente['local'])
                                                ));
                                              },
                                              child: Container(
                                                height: 100,
                                                width: 140,
                                                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
                                                clipBehavior: Clip.hardEdge,
                                                child: AbsorbPointer(
                                                  child: GoogleMap(
                                                    initialCameraPosition: CameraPosition(
                                                      target: LatLng(
                                                        double.tryParse(cliente['latitud']?.toString() ?? '19.4326') ?? 19.4326,
                                                        double.tryParse(cliente['longitud']?.toString() ?? '-99.1332') ?? -99.1332,
                                                      ),
                                                      zoom: 15,
                                                    ),
                                                    markers: {
                                                      Marker(markerId: const MarkerId('cliente'), position: LatLng(
                                                        double.tryParse(cliente['latitud']?.toString() ?? '19.4326') ?? 19.4326,
                                                        double.tryParse(cliente['longitud']?.toString() ?? '-99.1332') ?? -99.1332,
                                                      ))
                                                    },
                                                    mapType: MapType.normal,
                                                    zoomControlsEnabled: false,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildDetalle('Empresa:', cliente['empresa'], isDarkMode),
                                            const SizedBox(height: 12),
                                            _buildDetalle('Local:', cliente['local'], isDarkMode),
                                          ],
                                        ),
                                      )
                                    ],
                                  ),
                                  const SizedBox(height: 24),
                                  
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, minimumSize: const Size(120, 40)),
                                        onPressed: () => _aprobarCliente(cliente['id'].toString()),
                                        child: const Text('Aceptar'),
                                      ),
                                      const SizedBox(width: 16),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD50000), foregroundColor: Colors.white, minimumSize: const Size(120, 40)),
                                        onPressed: () => _rechazarCliente(cliente['id'].toString()),
                                        child: const Text('Eliminar'),
                                      ),
                                    ],
                                  )
                                ],
                              ),
                            )
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildDetalle(String titulo, String? valor, bool isDarkMode) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo, style: TextStyle(color: isDarkMode ? Colors.white : Colors.white, fontWeight: FontWeight.bold)),
          Text(valor ?? 'N/A', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.white70)),
        ],
      ),
    );
  }
}

// 🚀 FIX: Cambiado a StatefulWidget para asegurar la destrucción del mapa
class VerMapaAdminScreen extends StatefulWidget {
  final double latitud;
  final double longitud;
  final String? nombreLocal;

  const VerMapaAdminScreen({super.key, required this.latitud, required this.longitud, this.nombreLocal});

  @override
  State<VerMapaAdminScreen> createState() => _VerMapaAdminScreenState();
}

class _VerMapaAdminScreenState extends State<VerMapaAdminScreen> {
  GoogleMapController? _mapController;

  @override
  void dispose() {
    _mapController?.dispose(); // 🚀 LIMPIAMOS EL MAPA AL SALIR
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ubicacion = LatLng(widget.latitud, widget.longitud);
    return Scaffold(
      appBar: AppBar(title: Text(widget.nombreLocal ?? 'Ubicación del Cliente')),
      body: GoogleMap(
        onMapCreated: (controller) => _mapController = controller,
        initialCameraPosition: CameraPosition(target: ubicacion, zoom: 17),
        markers: {
          Marker(
            markerId: const MarkerId('cliente_loc'),
            position: ubicacion,
            infoWindow: InfoWindow(title: widget.nombreLocal ?? 'Local'),
          )
        },
      ),
    );
  }
}