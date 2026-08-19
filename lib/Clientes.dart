import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molino_app/Login.dart';
import 'package:molino_app/NuevaOrden.dart';
import 'package:molino_app/config.dart';
import 'package:molino_app/BloqueoCliente.dart';
import 'package:molino_app/PerfilScreen.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/NotificacionesHelper.dart';
import 'package:molino_app/BloqueoResenas.dart';
import 'dart:typed_data'; // Necesario para usar Uint8List

List<dynamic> parsearListaJson(String jsonStr) {
  final parsed = jsonDecode(jsonStr);
  return parsed is List ? parsed : [];
}

class ClientesScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final int initialTab;
  const ClientesScreen({super.key, required this.onThemeChanged, this.initialTab = 0});

  @override
  State<ClientesScreen> createState() => _ClientesScreenState();
}

class _ClientesScreenState extends State<ClientesScreen> {
  String _nombrePropietario = "Cargando...";
  Uint8List? _imagenBytes;
  
  int _currentTab = 0; 
  bool _isLoading = false;

  Map<String, List<dynamic>> _ordenesAgrupadas = {};
  List<dynamic> _listaPendientes = [];
  
  List<dynamic> _listaFaltantes = [];
  Set<int> _pedidosSeleccionadosFaltantes = {}; 
  List<dynamic> _mercanciaDB = [];
  
  IO.Socket? _socket; 

  // 🚀 FIX MAESTRO: Reloj inquebrantable en hora de CDMX (UTC-6)
  DateTime _obtenerHoraCDMX() {
    return DateTime.now().toUtc().subtract(const Duration(hours: 6));
  }

  @override
  void initState() {
    super.initState();
    _currentTab = widget.initialTab;
    _cargarDatosIniciales(); 
    
    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true, 
    });

    _socket!.onConnect((_) {
      debugPrint("🟢 SOCKET CONECTADO EN CLIENTES");
    });

    _socket!.on('actualizacion_ordenes', (_) {
      debugPrint("🔄 ACTUALIZACIÓN DE ÓRDENES RECIBIDA EN CLIENTES");
      if (mounted) {
        _obtenerTodasLasPendientes(silencioso: true);
        _obtenerOrdenesCompletadas(silencioso: true);
        _verificarResenasPendientes();
      }
    });

    _socket!.on('notify_faltante_disponible', (_) {
      if (mounted) _obtenerFaltantes(silencioso: true);
    });
    
    _socket!.on('notify_pedido_asignado', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if (data['id_cliente'] == miId && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: 'Pedido Tomado ✅',
          cuerpo: '${data['nombre_repartidor']} se dirige a recoger tu pedido.',
          payload: {'tipo': 'cliente_aviso'}
        );
      }
    });

    _socket!.on('notify_pedido_recogido', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if (data['id_cliente'] == miId && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: '¡Tu pedido va en camino! 🛵',
          cuerpo: '${data['nombre_repartidor']} ya recogió tus cosas.',
          payload: {'tipo': 'cliente_aviso'}
        );
      }
    });

    _socket!.on('notify_repartidor_llegado', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if (data['id_cliente'] == miId && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: '¡El repartidor ha llegado! 📍',
          cuerpo: 'Sal a recibir a ${data['nombre_repartidor']}.',
          payload: {'tipo': 'llegada_repartidor'}
        );
      }
    });
    
    _socket!.on('notify_cambio_repartidor', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if (data['id_cliente'] == miId && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: '🔄 Cambio de Repartidor', 
          cuerpo: 'Tu pedido ha sido transferido. Tu nuevo repartidor designado es ${data['nombre_repartidor']}.', 
          payload: {'tipo': 'cambio_repartidor'}
        );
      }
    });

    _socket!.on('notify_mercancia_modificada', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if (data['id_cliente'] == miId && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: '⚠️ Pedido Modificado', 
          cuerpo: 'El repartidor reportó mercancía faltante. Tu nuevo total es \$${data['nuevo_total']}.', 
          payload: {'tipo': 'mercancia_modificada'}
        );
      }
    });
  }

  @override
  void dispose() {
    _socket?.off('actualizacion_ordenes');
    _socket?.off('notify_faltante_disponible');
    _socket?.off('notify_pedido_asignado');
    _socket?.off('notify_pedido_recogido');
    _socket?.off('notify_repartidor_llegado');
    _socket?.off('notify_cambio_repartidor');
    _socket?.off('notify_mercancia_modificada');
    _socket?.disconnect();
    super.dispose();
  }

  Future<void> _verificarResenasPendientes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? miId = prefs.getInt('userId');
      if (miId == null) return;
      
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/pendientes-resena/cliente/$miId'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true && data['requiere_resena'] == true) {
          if (mounted) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => BloqueoResenasScreen(
                orden: data['orden'], 
                onThemeChanged: widget.onThemeChanged,
                rol: 'cliente',
              )),
              (route) => false
            );
          }
        }
      }
    } catch (e) {}
  }

  Future<void> _cargarDatosIniciales() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    await _cargarDatosUsuario();
    
    await Future.wait([
      _verificarResenasPendientes(),
      _obtenerCatalogoMercancia(),
      _obtenerTodasLasPendientes(silencioso: true),
      _obtenerOrdenesCompletadas(silencioso: true),
      _obtenerFaltantes(silencioso: true),
    ]);

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _cargarDatosUsuario() async {
  final prefs = await SharedPreferences.getInstance();
  if (!mounted) return;
  
  setState(() {
    _nombrePropietario = prefs.getString('userUser') ?? prefs.getString('userName') ?? 'Administrador';
    
    // 👈 Decodificamos SOLO UNA VEZ aquí
    String? base64Str = prefs.getString('userImage');
    if (base64Str != null && base64Str.isNotEmpty) {
      _imagenBytes = base64Decode(base64Str); 
    }
  });
}

  Future<void> _obtenerCatalogoMercancia() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia'));
      if (response.statusCode == 200) {
        final List<dynamic> datos = await compute(parsearListaJson, response.body);
        if (mounted) setState(() => _mercanciaDB = datos);
      }
    } catch(e) { }
  }

  Future<void> _obtenerFaltantes({bool silencioso = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idCliente = prefs.getInt('userId');
      if (idCliente == null) return;

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia-faltante/cliente/$idCliente'));
      if (response.statusCode == 200) {
        final List<dynamic> datos = await compute(parsearListaJson, response.body);
        if (mounted) {
          setState(() { 
            _listaFaltantes = datos; 
            _pedidosSeleccionadosFaltantes.removeWhere((idOrden) => !_listaFaltantes.any((f) => f['id_orden'] == idOrden));
          });
        }
      }
    } catch (e) { }
  }

  Future<void> _obtenerTodasLasPendientes({bool silencioso = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idCliente = prefs.getInt('userId');
      if (idCliente == null) return;

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/pendientes/cliente/$idCliente'));
      
      if (response.statusCode == 200) {
        final List<dynamic> datos = _optimizarOrdenes(jsonDecode(response.body));
        List<dynamic> ordenesHoy = [];
        List<dynamic> ordenesFuturo = [];

        for (var orden in datos) {
          if ((orden['viaje_programado'] ?? '').startsWith('Prog:')) {
            ordenesFuturo.add(orden);
          } else {
            ordenesHoy.add(orden);
          }
        }

        ordenesFuturo.sort((a, b) {
           try { return _parsearFecha(a['viaje_programado']).compareTo(_parsearFecha(b['viaje_programado'])); } 
           catch(e) { return 0; }
        });

        if (mounted) setState(() { _listaPendientes = [...ordenesHoy, ...ordenesFuturo]; });
      }
    } catch (e) { }
  }

  Future<void> _obtenerOrdenesCompletadas({bool silencioso = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idCliente = prefs.getInt('userId');
      if (idCliente == null) return;

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/completadas/cliente/$idCliente'));
      if (response.statusCode == 200) {
        final List<dynamic> ordenes = _optimizarOrdenes(jsonDecode(response.body));
        Map<String, List<dynamic>> agrupadas = {};
        
        for (var orden in ordenes) {
          DateTime dt = DateTime.parse(orden['fecha_registro']).toLocal();
          String fechaStr = "${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}";
          if (!agrupadas.containsKey(fechaStr)) agrupadas[fechaStr] = [];
          agrupadas[fechaStr]!.add(orden);
        }
        if (mounted) setState(() { _ordenesAgrupadas = agrupadas; });
      }
    } catch (e) { }
  }

  DateTime _parsearFecha(String? viajeStr) {
    if (viajeStr == null || viajeStr.isEmpty) return DateTime(2099);
    try {
      if (viajeStr.startsWith('Prog:')) {
        final parts = viajeStr.split(' ');
        if (parts.length < 6) return DateTime(2099);
        final d = parts[1].split('/');
        final t = parts[4].split(':');
        if (d.length < 3 || t.length < 2) return DateTime(2099);

        int h = int.parse(t[0]);
        if (parts[5] == 'PM' && h < 12) h += 12;
        if (parts[5] == 'AM' && h == 12) h = 0;
        return DateTime(int.parse(d[2]), int.parse(d[1]), int.parse(d[0]), h, int.parse(t[1]));
      } else if (viajeStr.startsWith('Viaje ')) {
        final parts = viajeStr.split(' ');
        if (parts.length < 3) return DateTime(2099);
        final t = parts[1].split(':');
        if (t.length < 2) return DateTime(2099);

        int h = int.parse(t[0]);
        if (parts[2] == 'PM' && h < 12) h += 12;
        if (parts[2] == 'AM' && h == 12) h = 0;
        final now = _obtenerHoraCDMX(); 
        return DateTime(now.year, now.month, now.day, h, int.parse(t[1]));
      }
    } catch (e) { return DateTime(2099); }
    return DateTime(2099);
  }

  bool _estaBloqueadoPorTiempo(String? viaje) {
    DateTime target = _parsearFecha(viaje);
    int diffMins = target.difference(_obtenerHoraCDMX()).inMinutes;
    return diffMins < 80; 
  }

  Future<void> _eliminarOrden(int idOrden) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Eliminar Pedido?'),
        content: const Text('Esta acción cancelará tu viaje y no se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Conservar', style: TextStyle(color: Colors.grey))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar', style: TextStyle(color: Colors.red))),
        ],
      )
    ) ?? false;

    if (!confirmar) return;
    try {
      await http.delete(Uri.parse('${AppConfig.apiHost}/ordenes/cliente/$idOrden'));
      _obtenerTodasLasPendientes();
    } catch (e) { }
  }

  Future<void> _eliminarFaltanteViaje(int idOrden) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Descartar Viaje Completo?'),
        content: const Text('Se eliminarán todos los productos faltantes de este viaje y ya no podrás pedirlos.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Conservar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Descartar', style: TextStyle(color: Colors.red))),
        ],
      )
    ) ?? false;

    if (!confirmar) return;
    try {
      await http.delete(Uri.parse('${AppConfig.apiHost}/mercancia-faltante/viaje/$idOrden'));
      _obtenerFaltantes();
    } catch (e) { }
  }

  Future<void> _enviarRescateAlServidor(List<Map<String, dynamic>> carrito, double total) async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final miId = prefs.getInt('userId');
    
    try {
      List<int> todosLosIds = [];
      for (var c in carrito) {
        todosLosIds.addAll(List<int>.from(c['ids_faltantes']));
      }

      final payload = {
        'id_cliente': miId,
        'total': total,
        'productos': carrito.map((c) => {
          'nombre': c['nombre'],
          'detalle': c['detalle'],
          'cantidad': c['cantidad'],
          'precio': c['precio']
        }).toList(),
        'ids_faltantes': todosLosIds
      };

      final res = await http.post(
        Uri.parse('${AppConfig.apiHost}/ordenes/rescate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload)
      );

      final data = jsonDecode(res.body);

      if (res.statusCode == 200 && data['success'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Rescate solicitado. En breve un repartidor lo tomará.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        _pedidosSeleccionadosFaltantes.clear();
        setState(() => _currentTab = 0); 
        _cargarDatosIniciales();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error al procesar el rescate.', style: const TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.red, duration: const Duration(seconds: 4)));
      }
    } catch(e) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
  List<dynamic> _optimizarOrdenes(List<dynamic> ordenesCrudas) {
  return ordenesCrudas.map((orden) {
    // 1. Convertimos el JSON String a Lista reales UNA VEZ
    if (orden['productos'] != null && orden['productos'] is String) {
      try {
        orden['productos'] = jsonDecode(orden['productos']);
      } catch(e) {
        orden['productos'] = [];
      }
    }
    
    // 2. Decodificamos las imágenes de cada producto UNA VEZ
    if (orden['productos'] is List) {
      for (var prod in orden['productos']) {
        if (prod['imagen'] != null && prod['imagen'].toString().isNotEmpty) {
          // Guardamos los bytes limpios en una nueva llave 'imagenBytes'
          prod['imagenBytes'] = base64Decode(prod['imagen'].toString().replaceAll(RegExp(r'\s+'), ''));
        }
      }
    }
    return orden;
  }).toList();
}

  void _mostrarResumenRescate() {
    List<Map<String, dynamic>> carritoFusionado = [];
    
    for (int idOrden in _pedidosSeleccionadosFaltantes) {
      final viaje = _listaFaltantes.firstWhere((e) => e['id_orden'] == idOrden);
      final List<dynamic> faltantes = viaje['faltantes'];

      for (var f in faltantes) {
        double precio = 0.0;
        String unidad = 'UNIDAD';
        try {
          final m = _mercanciaDB.firstWhere((e) => e['nombre'] == f['nombre_producto']);
          precio = double.tryParse(m['precio'].toString()) ?? 0.0;
          unidad = m['unidad']?.toString().toUpperCase() ?? 'UNIDAD';
        } catch(e) {}

        // 🚀 AQUÍ ESTÁ LA MAGIA PARA QUE NO SE ROMPA LA APP
        double cantidadFaltante = double.tryParse(f['cantidad_faltante'].toString()) ?? 0.0;

        int index = carritoFusionado.indexWhere((c) => c['nombre'] == f['nombre_producto']);
        if (index != -1) {
          carritoFusionado[index]['cantidad'] += cantidadFaltante;
          carritoFusionado[index]['cantidad_maxima'] += cantidadFaltante;
          carritoFusionado[index]['ids_faltantes'].add(f['id']);
        } else {
          carritoFusionado.add({
            'ids_faltantes': [f['id']],
            'nombre': f['nombre_producto'],
            'cantidad': cantidadFaltante,
            'cantidad_maxima': cantidadFaltante,
            'precio': precio,
            'detalle': '\$$precio MXN POR $unidad'
          });
        }
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            double total = 0;
            for(var p in carritoFusionado) {
              total += (p['cantidad'] * p['precio']);
            }

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Rescatar Mercancía', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Ajusta la cantidad que deseas pedir. Lo que elimines se descartará.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 16),
                  
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: carritoFusionado.length,
                      itemBuilder: (c, i) {
                        final item = carritoFusionado[i];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(item['nombre'] ?? 'Producto', style: const TextStyle(fontWeight: FontWeight.bold)),
  Text(item['detalle'] ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                    ],
                                  ),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                      onPressed: () {
                                        setStateModal(() {
                                          if (item['cantidad'] > 1) item['cantidad']--;
                                        });
                                      }
                                    ),
                                    // 🚀 Y AQUÍ PARA QUE EL TEXTO SALGA LIMPIO
                                    Text(
                                      item['cantidad'] == item['cantidad'].toInt() 
                                        ? '${item['cantidad'].toInt()}' 
                                        : '${item['cantidad']}'
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.add_circle_outline, color: Colors.green),
                                      onPressed: () {
                                        setStateModal(() {
                                          if (item['cantidad'] < item['cantidad_maxima']) item['cantidad']++;
                                        });
                                      }
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red),
                                      onPressed: () {
                                        setStateModal(() {
                                          carritoFusionado.removeAt(i);
                                        });
                                      }
                                    )
                                  ],
                                )
                              ],
                            ),
                          )
                        );
                      }
                    )
                  ),
                  
                  const SizedBox(height: 16),
                  Text('Total a cobrar: \$${total.toStringAsFixed(2)} MXN', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 16),
                  
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
                    onPressed: carritoFusionado.isEmpty ? null : () {
                      Navigator.pop(ctx);
                      _enviarRescateAlServidor(carritoFusionado, total);
                    },
                    child: const Text('CONFIRMAR RESCATE', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 16),
                ]
              )
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text('Ordenes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
            Text(_nombrePropietario, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.normal, color: Colors.grey)),
          ],
        ),
        leading: GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PerfilScreen(onThemeChanged: widget.onThemeChanged),
              ),
            ).then((_) => _cargarDatosUsuario());
          },
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0052CC), 
                borderRadius: BorderRadius.circular(8.0),
              ),
              clipBehavior: Clip.hardEdge,
             child: _imagenBytes != null
                  ?  Image.memory(
                       _imagenBytes!, 
                       fit: BoxFit.cover, 
                       cacheWidth: 100 // 🚀 Agregamos el límite para proteger la RAM
                     ) 
                  : const Icon(Icons.person, color: Colors.white),
            ),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildTabButton('Pendientes', 0, isDarkMode),
                _buildTabButton('Completadas', 1, isDarkMode),
                _buildTabButton('Faltantes', 2, isDarkMode),
              ],
            ),
            const SizedBox(height: 32),
            Expanded(
              child: _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : _currentTab == 0
                  ? _buildPestanaPendientes(isDarkMode)
                  : _currentTab == 1
                    ? _buildPestanaCompletadas(isDarkMode)
                    : _buildPestanaFaltantes(isDarkMode)
            ),
          ],
        ),
      ),
      
      floatingActionButton: (_currentTab == 2 && _pedidosSeleccionadosFaltantes.isNotEmpty)
        ? FloatingActionButton.extended(
            onPressed: _mostrarResumenRescate,
            backgroundColor: const Color(0xFF00C853),
            foregroundColor: Colors.white,
            icon: const Icon(Icons.check),
            label: Text('Rescatar (${_pedidosSeleccionadosFaltantes.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          )
        : FloatingActionButton.extended(
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => NuevaOrdenScreen(onThemeChanged: widget.onThemeChanged))).then((_) {
                _cargarDatosIniciales();
              });
            },
            backgroundColor: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC),
            foregroundColor: isDarkMode ? Colors.black : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
            label: const Text('Nueva Orden +', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
    );
  }

  Widget _buildPestanaPendientes(bool isDarkMode) {
    if (_listaPendientes.isEmpty) {
      return Center(child: Text('No hay ninguna orden pendiente.', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: isDarkMode ? Colors.white54 : Colors.black54)));
    }
    return ListView.builder(
      itemCount: _listaPendientes.length,
      itemBuilder: (context, index) => _buildTarjetaPendiente(_listaPendientes[index], isDarkMode),
    );
  }

  Widget _buildPestanaCompletadas(bool isDarkMode) {
    if (_ordenesAgrupadas.isEmpty) {
      return Center(child: Text('No se ha completado ninguna orden.', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: isDarkMode ? Colors.white54 : Colors.black54)));
    }
    return ListView.builder(
      itemCount: _ordenesAgrupadas.keys.length,
      itemBuilder: (context, index) {
        String fecha = _ordenesAgrupadas.keys.elementAt(index);
        String idTicket = "TK-${fecha.replaceAll('/', '')}";
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Fecha: $fecha", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
            const SizedBox(height: 5),
            GestureDetector(
              onTap: () => _abrirTicketCompletado(fecha, idTicket, _ordenesAgrupadas[fecha]!, isDarkMode),
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                decoration: BoxDecoration(
                  color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text("Ticket: $idTicket", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        );
      },
    );
  }

 Widget _buildPestanaFaltantes(bool isDarkMode) {
    if (_listaFaltantes.isEmpty) {
      return Center(child: Text("No hay mercancía por rescatar.", style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.grey)));
    }
    
    // 🚀 MAGIA: Si ya pasaron las 7 PM (19:00), muestra el aviso.
    final bool deNoche = _obtenerHoraCDMX().hour >= 19;

    return Column(
      children: [
        // 🚀 EL AVISO VISUAL QUE PIDISTE PARA LA NOCHE
        if (deNoche)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.1), 
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blueAccent)
            ),
            child: const Text('🌙 Los pedidos no entregados hoy volverán a estar disponibles mañana a primera hora.', textAlign: TextAlign.center, style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _obtenerFaltantes,
            child: ListView.builder(
              itemCount: _listaFaltantes.length,
              itemBuilder: (context, index) {
                final viaje = _listaFaltantes[index];
                final bool todosDisponibles = viaje['todos_disponibles'] == true; 
                final bool isSelected = _pedidosSeleccionadosFaltantes.contains(viaje['id_orden']);
                final List<dynamic> faltantes = viaje['faltantes'];
                
                // 🚀 BLINDAJE CONTRA FECHAS NULAS O BORRADAS
                String fechaStr = "Fecha desconocida";
                if (viaje['fecha_orden'] != null) {
                  try {
                    DateTime fechaFormat = DateTime.parse(viaje['fecha_orden'].toString()).toLocal();
                    fechaStr = "${fechaFormat.day}/${fechaFormat.month}/${fechaFormat.year}";
                  } catch(e) {}
                }
                
                return Card(
                  color: isDarkMode ? const Color(0xFF424242) : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: isSelected ? Colors.green : Colors.transparent, width: 2)
                  ),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: isSelected,
                              activeColor: Colors.green,
                              onChanged: todosDisponibles ? (val) {
                                setState(() {
                                  if (val == true) _pedidosSeleccionadosFaltantes.add(viaje['id_orden']);
                                  else _pedidosSeleccionadosFaltantes.remove(viaje['id_orden']);
                                });
                              } : null,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(viaje['viaje_programado'] ?? 'Viaje', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  Text("Fecha: $fechaStr", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                ],
                              )
                            ),
                            if (!todosDisponibles)
                              const Padding(
                                padding: EdgeInsets.only(right: 8.0),
                                child: Icon(Icons.timer, color: Colors.orange),
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _eliminarFaltanteViaje(viaje['id_orden']),
                            ),
                          ],
                        ),
                        if (!todosDisponibles)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(4),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                            child: const Text('⏳ Esperando autorización del Administrador', textAlign: TextAlign.center, style: TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        const Divider(),
                        ...faltantes.map((f) {
                          bool prodAgotado = f['estado'] == 'Agotado'; 

                          // 🚀 FIX VISUAL: Cantidades limpias sin .0
                          double cant = double.tryParse(f['cantidad_faltante'].toString()) ?? 0;
                          String cantStr = cant == cant.toInt() ? cant.toInt().toString() : cant.toString();

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
                            child: Row(
                              children: [
                                Icon(prodAgotado ? Icons.error_outline : Icons.inventory, size: 16, color: prodAgotado ? Colors.red : Colors.orange),
                                const SizedBox(width: 8),
                                Text("${cantStr}x ${f['nombre_producto']}", style: TextStyle(
                                    color: prodAgotado ? Colors.red : (isDarkMode ? Colors.white70 : Colors.black87),
                                )),
                                if (prodAgotado)
                                   const Text(" (Agotado)", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold))
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  )
                );
              }
            ),
          )
        )
      ],
    );
  }

  Widget _buildTarjetaPendiente(Map<String, dynamic> orden, bool isDarkMode) {
    final String? viaje = orden['viaje_programado'];
    final String estado = orden['estado'];
    final bool esFuturo = viaje?.startsWith('Prog:') ?? false;
    
    final bool yaEstaEnCamino = estado == 'En Camino';
    final bool bloqueado = _estaBloqueadoPorTiempo(viaje) || yaEstaEnCamino; 
    
    final bool huboFaltante = orden['hubo_faltante'] == true;

    final Color colorBorde = huboFaltante ? Colors.redAccent : (esFuturo ? Colors.grey : Colors.orangeAccent);
    
    // 🚀 REDISEÑO 1
    final String tituloViaje = esFuturo ? 'Programado: ${viaje?.replaceAll('Prog: ', '')}' : 'Entrega: $viaje';

    // 🚀 REDISEÑO 2
    final String nombreRepartidor = orden['nombre_repartidor']?.toString() ?? '';
    final bool tieneRepartidor = nombreRepartidor.isNotEmpty;

    // 🚀 REDISEÑO 3
    List<dynamic> prods = orden['productos'] is String ? jsonDecode(orden['productos']) : List.from(orden['productos'] ?? []);
    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    
    for(var p in prods) {
      bool esMasa = p['detalle'].toString().toLowerCase().contains('kilo') || p['detalle'].toString().toLowerCase().contains('gramo');
      if (esMasa) {
        masas.add(p);
      } else {
        mercancia.add(p);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: InkWell( 
        onTap: () {
          Navigator.push(context, MaterialPageRoute(builder: (context) => BloqueoClienteScreen(onThemeChanged: widget.onThemeChanged, ordenInicial: orden))).then((_) => _cargarDatosIniciales());
        },
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: colorBorde, width: huboFaltante ? 3 : 2)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: esFuturo ? Theme.of(context).colorScheme.onSurface : Colors.orange[700])),
                          const SizedBox(height: 4),
                          
                          Row(
                            children: [
                              Icon(tieneRepartidor ? Icons.motorcycle : Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                              const SizedBox(width: 4),
                              Expanded(child: Text(
                                tieneRepartidor ? 'Repartidor: $nombreRepartidor' : 'Estado: $estado', 
                                style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14)
                              )),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.touch_app, color: isDarkMode ? Colors.white54 : Colors.black38), 
                  ],
                ),
                const Divider(height: 24),
                
                if (huboFaltante)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red)),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.red),
                        SizedBox(width: 8),
                        Expanded(child: Text('¡OJO! El repartidor reportó un faltante. Se ha ajustado el pedido.', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                  ),

                // 🚀 REDISEÑO 4
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (masas.isNotEmpty)
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: masas.map((m) => Text(
                            "${m['nombre_producto']}: ${m['cantidad']} Kl.", 
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)
                          )).toList(),
                        ),
                      ),
                      
                    if (masas.isNotEmpty && mercancia.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold)),
                      ),
                      
                    if (mercancia.isNotEmpty)
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: mercancia.map((m) => Text(
                            "${m['nombre_producto']}: ${m['cantidad']} U.", 
                            style: const TextStyle(fontSize: 12, color: Colors.grey)
                          )).toList(),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 12),
                const Divider(height: 1, thickness: 1, color: Colors.black12),
                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Total:', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('\$${orden['total']} MXN', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 12),
                
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey, foregroundColor: Colors.white, minimumSize: const Size(0, 35)),
                        icon: const Icon(Icons.edit, size: 16),
                        label: const Text("Editar"),
                        onPressed: bloqueado ? null : () {
                          Navigator.push(context, MaterialPageRoute(builder: (context) => NuevaOrdenScreen(onThemeChanged: widget.onThemeChanged, ordenAEditar: orden))).then((_) => _cargarDatosIniciales());
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red[600], foregroundColor: Colors.white, minimumSize: const Size(0, 35)),
                        icon: const Icon(Icons.delete, size: 16),
                        label: const Text("Eliminar"),
                        onPressed: bloqueado ? null : () => _eliminarOrden(orden['id']),
                      ),
                    ),
                  ],
                ),
                if (bloqueado && !huboFaltante)
                   Padding(
                     padding: const EdgeInsets.only(top: 8.0),
                     child: Center(
                       child: Text(
                         yaEstaEnCamino 
                           ? "🔒 Orden en camino. El repartidor ya la recogió." 
                           // 🚀 FIX: Mensaje a 80 minutos
                           : "🔒 Orden protegida. Faltan menos de 80 min.", 
                         style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)
                       )
                     ),
                   )
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _abrirTicketCompletado(String fecha, String idTicket, List<dynamic> ordenesDelDia, bool isDarkMode) {
    double granTotal = 0;
    for (var o in ordenesDelDia) { granTotal += double.tryParse(o['total'].toString()) ?? 0; }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: isDarkMode ? const Color(0xFF383838) : Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onSurface), onPressed: () => Navigator.pop(context)),
            title: Text("Historial", style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
            centerTitle: true,
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text("Fecha: $fecha", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                    Text("Ticket: $idTicket", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                    const SizedBox(height: 20),
                    ...ordenesDelDia.map((orden) {
                      List<dynamic> productos = orden['productos'] ?? [];
                      
                      final bool huboFaltante = orden['hubo_faltante'] == true;
                      
                      // 🚀 AQUÍ CONTROLAMOS EL ESTADO VISUAL
                      String estadoTicket = orden['estado'] == 'Cobrado' ? 'Cobrado' : 'Pendiente a Cobro';
                      Color colorEstado = orden['estado'] == 'Cobrado' ? Colors.green : Colors.orange;
                      
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(orden['viaje_programado'] ?? "Viaje", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.bold)), 
                              Text(estadoTicket, style: TextStyle(color: colorEstado, fontSize: 12, fontWeight: FontWeight.bold)),
                            ]
                          ),
                          const SizedBox(height: 5),

                          if (huboFaltante)
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red)),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text('Faltante reportado: ${orden['detalles_faltante'] ?? 'se ajustaron los productos.'}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12))),
                                ],
                              ),
                            ),
                            
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 5),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0), borderRadius: BorderRadius.circular(10)),
                            child: Column(
                              children: productos.map<Widget>((prod) {
                                bool tieneDescuento = prod['descuento'] != null;
                                
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 40, height: 40,
                                        decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.circular(8)),
                                        clipBehavior: Clip.hardEdge,
                                        child: (prod['imagenBytes'] != null)
    ? Image.memory(
        prod['imagenBytes'], 
        fit: BoxFit.cover, 
        cacheWidth: 100, // Cuidamos la memoria RAM del cliente al hacer scroll
        errorBuilder: (c,e,s) => const Icon(Icons.image, color: Colors.white)
      )
    : const Icon(Icons.image, color: Colors.white),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(prod['nombre_producto'], style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontWeight: FontWeight.bold)),
                                            
                                            // 🚀 RENDERIZAMOS EL DESCUENTO PARA EL CLIENTE/TRABAJADOR
                                            if (tieneDescuento)
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 2.0, top: 2.0),
                                                child: Row(
                                                  children: [
                                                    Text("\$${prod['precio_original']} MXN", style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                                                    const SizedBox(width: 6),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                      decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(4)),
                                                      child: Text("-${prod['descuento']}%", style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            
                                            Text("\$${double.parse(prod['precio'].toString()).toStringAsFixed(2)} MXN POR UNIDAD", style: TextStyle(color: tieneDescuento ? Colors.greenAccent : (isDarkMode ? Colors.black54 : Colors.white70), fontSize: 10, fontWeight: tieneDescuento ? FontWeight.bold : FontWeight.normal)),
                                          ],
                                        ),
                                      ),
                                      Text("${prod['cantidad']} u.", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 12)),
                                      const SizedBox(width: 10),
                                      Text("Total: \$${((double.tryParse(prod['precio'].toString()) ?? 0) * (double.tryParse(prod['cantidad'].toString()) ?? 0)).toStringAsFixed(2)}", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          Align(alignment: Alignment.centerLeft, child: Text("Total del viaje: \$${double.parse(orden['total'].toString()).toStringAsFixed(2)}", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold))),
                          const SizedBox(height: 20),
                        ],
                      );
                    }).toList(),
                  ],
                ),
              ),
              Container(
                width: double.infinity, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC), borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
                child: Center(child: Text("TOTAL GENERAL: \$${granTotal.toStringAsFixed(2)} MXN", style: TextStyle(color: isDarkMode ? Colors.black : Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabButton(String titulo, int tabIndex, bool isDarkMode) {
    final bool isSelected = _currentTab == tabIndex;
    return GestureDetector(
      onTap: () { 
        if (_currentTab != tabIndex) {
          setState(() { _currentTab = tabIndex; }); 
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        decoration: BoxDecoration(
          color: isSelected ? (isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC)) : Colors.transparent,
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Text(
          titulo,
          style: TextStyle(
            color: isSelected ? (isDarkMode ? Colors.black : Colors.white) : (isDarkMode ? Colors.white70 : Colors.black87),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            decoration: isSelected ? TextDecoration.none : TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}