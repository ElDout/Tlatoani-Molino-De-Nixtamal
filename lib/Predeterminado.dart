import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; 
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';

// 🚀 FUNCIÓN TRADUCTORA PARA EVITAR EL ERROR DE JSONDECODE EN COMPUTE
List<dynamic> parsearListaJson(String jsonStr) {
  final parsed = jsonDecode(jsonStr);
  return parsed is List ? parsed : [];
}

// =========================================================================
// 🚀 TAB 2: LISTA DE PEDIDOS PREDETERMINADOS
// =========================================================================
class PredeterminadosTab extends StatefulWidget {
  final Map<String, dynamic> tortilleria; 

  const PredeterminadosTab({super.key, required this.tortilleria});

  @override
  State<PredeterminadosTab> createState() => _PredeterminadosTabState();
}

class _PredeterminadosTabState extends State<PredeterminadosTab> {
  bool _isLoading = true;
  List<dynamic> _ordenesActivas = [];
  
  // 🚀 HORARIOS EXTENDIDOS DE 8 AM A 6 PM
  final List<String> horarios = [
    '8:00 AM', '10:00 AM', '12:00 PM', 
    '2:00 PM', '4:00 PM',  '6:00 PM'
  ];

  @override
  void initState() {
    super.initState();
    _fetchOrdenesActivas();
  }

 Future<void> _fetchOrdenesActivas() async {
    setState(() => _isLoading = true);
    try {
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/tortilleria/${widget.tortilleria['id']}'));
      if (res.statusCode == 200) {
        final List<dynamic> todas = await compute(parsearListaJson, res.body);
        
        // 🚀 MAGIA: Filtramos para agarrar el pedido más reciente de cada horario
        // sin importar si ya fue entregado o cobrado hoy.
        Map<String, dynamic> ordenesUnicas = {};
        for (var o in todas) {
          String viaje = o['viaje_programado'] ?? '';
          if (viaje.startsWith('Viaje ')) {
            // Como vienen ordenadas por fecha desde la BD, la primera es la más actual
            if (!ordenesUnicas.containsKey(viaje)) {
              if (o['estado'] != 'Cancelada') {
                ordenesUnicas[viaje] = o;
              }
            }
          }
        }
        
        _ordenesActivas = ordenesUnicas.values.toList();
      }
    } catch (e) {
      debugPrint("Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _fetchOrdenesActivas,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: horarios.length,
        itemBuilder: (context, index) {
          final String horarioViaje = 'Viaje ${horarios[index]}';
          
          final int indexOrden = _ordenesActivas.indexWhere((o) => o['viaje_programado'] == horarioViaje);
          final ordenExistente = indexOrden != -1 ? _ordenesActivas[indexOrden] : null;
          final bool estaConfigurado = ordenExistente != null;
          
          final String estadoSolicitud = ordenExistente?['estado_solicitud'] ?? '';
          final bool haySolicitud = estadoSolicitud == 'Pendiente';

          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              leading: Icon(
                haySolicitud ? Icons.warning_amber_rounded : (estaConfigurado ? Icons.lock : Icons.access_time_filled), 
                color: haySolicitud ? Colors.orange : (estaConfigurado ? Colors.green : Colors.blueAccent), 
                size: 30
              ),
              title: Text(horarioViaje, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: haySolicitud 
                  ? const Text("⚠️ Solicitud de Edición", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold))
                  : (estaConfigurado ? const Text("✅ Configurado", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)) : null),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () async {
                if (haySolicitud) {
                  await Navigator.push(context, MaterialPageRoute(builder: (context) => RevisarSolicitudScreen(orden: ordenExistente!)));
                } else if (estaConfigurado) {
                  // 🚀 BLOQUEO: Ya es permanente, no se puede volver a agregar
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Este viaje ya está configurado y es permanente. Solo el administrador puede eliminarlo o modificarlo.', style: TextStyle(fontWeight: FontWeight.bold)),
                      backgroundColor: Colors.blueAccent,
                    )
                  );
                } else {
                  await Navigator.push(context, MaterialPageRoute(builder: (context) => ConfigurarPredeterminadoScreen(
                      horario: horarios[index],
                      tortilleria: widget.tortilleria,
                      ordenAEditar: ordenExistente, 
                    ),
                  ));
                }
                _fetchOrdenesActivas(); 
              },
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// 🚀 PANTALLA: CONFIGURAR PEDIDO PREDETERMINADO
// =========================================================================
class ConfigurarPredeterminadoScreen extends StatefulWidget {
  final String horario;
  final Map<String, dynamic> tortilleria;
  final Map<String, dynamic>? ordenAEditar; 

  const ConfigurarPredeterminadoScreen({super.key, required this.horario, required this.tortilleria, this.ordenAEditar});

  @override
  State<ConfigurarPredeterminadoScreen> createState() => _ConfigurarPredeterminadoScreenState();
}

class _ConfigurarPredeterminadoScreenState extends State<ConfigurarPredeterminadoScreen> {
  bool _isLoading = false;
  bool _isEditingMode = false; 

  List<Map<String, dynamic>> _carrito = [];
  List<dynamic> _mercanciaDB = [];
  List<dynamic> _masasDB = []; // 🚀 AQUÍ GUARDAMOS LAS MASAS

  @override
  void initState() {
    super.initState();
    _isEditingMode = widget.ordenAEditar == null;
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() => _isLoading = true);
    try {
      // 🚀 CARGAS INDEPENDIENTES PARA MAYOR VELOCIDAD
      try {
        final resMerc = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia'));
        if (resMerc.statusCode == 200 && mounted) {
          setState(() => _mercanciaDB = jsonDecode(resMerc.body));
        }
      } catch(e) {}
      
      try {
        final resMasas = await http.get(Uri.parse('${AppConfig.apiHost}/masas')); 
        if (resMasas.statusCode == 200 && mounted) {
          setState(() => _masasDB = jsonDecode(resMasas.body));
        }
      } catch(e) {}

      if (widget.ordenAEditar != null) {
        List<dynamic> prodsDB = widget.ordenAEditar!['productos'] is String ? jsonDecode(widget.ordenAEditar!['productos']) : List.from(widget.ordenAEditar!['productos'] ?? []);
        setState(() {
          _carrito = prodsDB.map((p) => {
            'nombre': p['nombre_producto'] ?? p['nombre'],
            'detalle': p['detalle'] ?? '\$${p['precio']} MXN POR UNIDAD',
            'cantidad': int.tryParse(p['cantidad'].toString()) ?? 1,
            'precio': double.tryParse(p['precio'].toString()) ?? 0.0,
          }).toList();
        });
      }

    } catch (e) {
      debugPrint("Error cargando catálogos: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  double _calcularTotal() {
    double total = 0;
    for (var prod in _carrito) { 
      double precio = double.tryParse(prod['precio'].toString()) ?? 0.0;
      int cantidad = int.tryParse(prod['cantidad'].toString()) ?? 0;
      total += (cantidad * precio); 
    }
    return total;
  }

  // 🚀 AHORA RECIBE UN BOOLEANO PARA SABER QUÉ CATÁLOGO ABRIR
  // 🚀 FILTRA DUPLICADOS
  void _abrirCatalogo(bool esMasa) {
    if (!_isEditingMode) return; 
    
    final catalogoCompleto = esMasa ? _masasDB : _mercanciaDB;
    
    // 🚀 MAGIA: Filtramos para que sólo salgan los que NO están en el carrito
    final catalogoActivo = catalogoCompleto.where((item) {
      return !_carrito.any((c) => c['nombre'] == item['nombre']);
    }).toList();

    final titulo = esMasa ? 'Selecciona una Masa' : 'Selecciona un Producto';

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return Column(
          children: [
            Padding(padding: const EdgeInsets.all(16.0), child: Text(titulo, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface))),
            Expanded(
              child: catalogoActivo.isEmpty
                  ? const Center(child: Text('Todos los productos ya están en el carrito', style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: catalogoActivo.length,
                      itemBuilder: (context, i) {
                        final item = catalogoActivo[i];
                        return ListTile(
                          leading: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: esMasa ? Colors.orangeAccent : Colors.blueAccent, borderRadius: BorderRadius.circular(8)),
                            clipBehavior: Clip.hardEdge,
                            child: item['imagen'] != null && item['imagen'].toString().isNotEmpty
                                ? Image.memory(
                                    base64Decode(item['imagen'].toString().replaceAll(RegExp(r'\s+'), '')), 
                                    fit: BoxFit.cover, 
                                    cacheWidth: 80,
                                    errorBuilder: (c, e, s) => const Icon(Icons.image, color: Colors.white)
                                  )
                                : const Icon(Icons.image, color: Colors.white),
                          ),
                          title: Text(item['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('\$${item['precio']} MXN por ${item['unidad']}'),
                          onTap: () { Navigator.pop(context); _pedirCantidad(item); },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  void _pedirCantidad(Map<String, dynamic> productoInfo, {int? indexEditar}) {
    if (!_isEditingMode) return; 
    final TextEditingController qtyController = TextEditingController(text: indexEditar != null ? _carrito[indexEditar]['cantidad'].toString() : '1');
    showDialog(
      context: context,
      builder: (context) {
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDarkMode ? const Color(0xFF2A2A2A) : Colors.white,
          title: Text(indexEditar != null ? 'Editar cantidad' : '¿Cuántas unidades?'),
          content: TextField(controller: qtyController, keyboardType: TextInputType.number, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white),
              onPressed: () {
                int qty = int.tryParse(qtyController.text) ?? 1;
                if (qty > 0) {
                  setState(() {
                    if (indexEditar != null) {
                      _carrito[indexEditar]['cantidad'] = qty;
                    } else {
                      _carrito.add({
                        'nombre': productoInfo['nombre'],
                        'detalle': '\$${productoInfo['precio']} MXN POR ${(productoInfo['unidad'] ?? 'UNIDAD').toString().toUpperCase()}',
                        'cantidad': qty,
                        'precio': double.tryParse(productoInfo['precio'].toString()) ?? 0.0,
                      });
                    }
                  });
                }
                Navigator.pop(context);
              },
              child: const Text('Confirmar'),
            )
          ],
        );
      }
    );
  }

  Future<void> _guardarPredeterminado() async {
    if (_carrito.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Añade al menos un producto al carrito.")));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final productosLimpios = _carrito.map((p) => {
        'nombre': p['nombre'],
        'detalle': p['detalle'],
        'cantidad': p['cantidad'],
        'precio': p['precio']
      }).toList();

      if (widget.ordenAEditar == null) {
        final payload = {
          'id_tortilleria': widget.tortilleria['id'],
          'id_repartidor': null, 
          'id_trabajador': widget.tortilleria['id_trabajador'], 
          'viaje_programado': 'Viaje ${widget.horario}',
          'total': _calcularTotal(),
          'productos': productosLimpios,
        };
        await http.post(Uri.parse('${AppConfig.apiHost}/ordenes/predeterminadas'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      } else {
        final payloadProductos = {
          'id_trabajador': widget.tortilleria['id_trabajador'], 
          'viaje_programado': 'Viaje ${widget.horario}',
          'fuera_de_tiempo': false,
          'total': _calcularTotal(),
          'cambio_efectivo': 0,
          'productos': productosLimpios,
        };
        await http.put(Uri.parse('${AppConfig.apiHost}/ordenes/actualizar/${widget.ordenAEditar!['id']}'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payloadProductos));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Viaje configurado con éxito", style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
      Navigator.pop(context);
      
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al procesar el viaje")));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 🚀 AHORA BUSCA LA IMAGEN EN LOS DOS CATÁLOGOS
  Widget _construirImagenDesdeCatalogo(String nombreProducto, bool isDarkMode) {
    Map<String, dynamic>? item;
    try {
      item = _mercanciaDB.firstWhere((m) => m['nombre'] == nombreProducto);
    } catch(e) {
      try {
        item = _masasDB.firstWhere((m) => m['nombre'] == nombreProducto);
      } catch(e) {
        item = null;
      }
    }
    
    if (item != null && item['imagen'] != null && item['imagen'].toString().isNotEmpty) {
      try {
        String cleanStr = item['imagen'].toString().replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
        return Image.memory(
          base64Decode(cleanStr), 
          fit: BoxFit.cover, 
          cacheWidth: 100, // 🚀 FIX: Protege la RAM al mostrar el carrito
          errorBuilder: (_,__,___) => Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white)
        );
      } catch(e) {
        return Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white);
      }
    }
    return Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white);
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final colorGrisFondo = isDarkMode ? const Color(0xFF383838) : Colors.white;
    final colorGrisInferior = isDarkMode ? const Color(0xFF424242) : Colors.white;
    final colorAzulMockup = const Color(0xFF003399);
    
    return Scaffold(
      backgroundColor: colorGrisFondo,
      appBar: AppBar(
        title: Text("Viaje ${widget.horario}", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0, 
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
      ),
      body: SafeArea(
        child: _isLoading 
          ? const Center(child: CircularProgressIndicator())
          : Column(
          children: [
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("📍 Local: ${widget.tortilleria['nombre']}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                          const SizedBox(height: 4),
                          Text("👤 Recibe: ${widget.tortilleria['nombre_trabajador'] ?? 'Sin asignar'}", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    
                    Text("Productos a Entregar", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    
                    if (_isEditingMode)
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => _abrirCatalogo(false),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 45, height: 45,
                                      decoration: BoxDecoration(color: isDarkMode ? Colors.grey[400] : colorAzulMockup, borderRadius: BorderRadius.circular(8)),
                                      child: Icon(Icons.add, color: isDarkMode ? Colors.black : Colors.white),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text('Agregar Producto', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold))),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: InkWell(
                              onTap: () => _abrirCatalogo(true), // 🚀 AQUÍ ABRIMOS LA MASA
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 45, height: 45,
                                      decoration: BoxDecoration(color: Colors.orangeAccent, borderRadius: BorderRadius.circular(8)),
                                      child: const Icon(Icons.add, color: Colors.white),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text('Agregar Masa', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold))),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    
                    if (_isEditingMode) const SizedBox(height: 16),
              
                    Expanded(
                      child: _carrito.isEmpty 
                          ? Center(child: Text("No has añadido productos", style: TextStyle(color: Colors.grey[500])))
                          : ListView.builder(
                              itemCount: _carrito.length,
                              itemBuilder: (context, index) {
                                final p = _carrito[index];
                                bool esMasa = p['detalle'].toString().toLowerCase().contains('kilo') || p['detalle'].toString().toLowerCase().contains('gramo');

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12.0),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 50, height: 50, 
                                        decoration: BoxDecoration(color: esMasa ? Colors.orangeAccent : (isDarkMode ? Colors.grey[400] : colorAzulMockup), borderRadius: BorderRadius.circular(8)),
                                        clipBehavior: Clip.hardEdge,
                                        child: _construirImagenDesdeCatalogo(p['nombre'], isDarkMode),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(p['nombre'], style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
                                            Text(p['detalle'], style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                      Row(
                                        children: [
                                          if (_isEditingMode)
                                            IconButton(icon: const Icon(Icons.edit, color: Colors.orange, size: 20), onPressed: () => _pedirCantidad(p, indexEditar: index)),
                                          if (_isEditingMode)
                                            IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 20), onPressed: () => setState(() => _carrito.removeAt(index))),
                                          Text('${p['cantidad']} ${esMasa ? "Kl." : "U."}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
                                        ],
                                      )
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

            Expanded(
              flex: 2, 
              child: Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: colorGrisInferior, 
                  border: Border(top: BorderSide(color: isDarkMode ? Colors.white24 : Colors.black12, width: 2))
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: Text('TOTAL: \$${_calcularTotal().toStringAsFixed(2)} MXN', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 16))),
                      const SizedBox(height: 24),
                
                      if (!_isEditingMode)
                        ElevatedButton(
                          onPressed: () => setState(() => _isEditingMode = true),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                          child: const Text("EDITAR VIAJE", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        )
                      else
                        ElevatedButton(
                          onPressed: _guardarPredeterminado,
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                          child: Text(widget.ordenAEditar == null ? "GUARDAR VIAJE" : "ACTUALIZAR VIAJE", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        )
                    ],
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// 🚀 PANTALLA: ADMIN REVISA LA SOLICITUD DE EDICIÓN DEL TRABAJADOR
// =========================================================================
class RevisarSolicitudScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  const RevisarSolicitudScreen({super.key, required this.orden});

  @override
  State<RevisarSolicitudScreen> createState() => _RevisarSolicitudScreenState();
}

class _RevisarSolicitudScreenState extends State<RevisarSolicitudScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _solicitud;
  List<dynamic> _productosNuevos = [];

  @override
  void initState() {
    super.initState();
    _cargarSolicitud();
  }

  Future<void> _cargarSolicitud() async {
    try {
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/admin/solicitudes/${widget.orden['id_solicitud']}'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _solicitud = data;
          // 🚀 FIX: Aseguramos que parsee bien la lista aunque venga anidada
          dynamic rawProds = data['productos_nuevos'];
          if (rawProds is String) {
            _productosNuevos = jsonDecode(rawProds);
          } else if (rawProds is List) {
            _productosNuevos = List.from(rawProds);
          } else {
            _productosNuevos = [];
          }
          _isLoading = false;
        });
      } else {
         if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _responderSolicitud(String accion) async {
    setState(() => _isLoading = true);
    try {
      final endpoint = accion == 'Aprobar' ? 'aprobar' : 'rechazar';
      await http.put(Uri.parse('${AppConfig.apiHost}/admin/solicitudes/$endpoint/${_solicitud!['id']}'));
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Solicitud $accion"), backgroundColor: accion == 'Aprobar' ? Colors.green : Colors.red));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text("Revisar Edición", style: TextStyle(fontWeight: FontWeight.bold)), centerTitle: true, backgroundColor: Colors.transparent, elevation: 0),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.orange)),
                  child: Column(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 40),
                      const SizedBox(height: 8),
                      Text("El responsable de ${widget.orden['cliente']} solicita un cambio para el ${widget.orden['viaje_programado']}", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text("Nuevos Productos Solicitados:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.builder(
                    itemCount: _productosNuevos.length,
                    itemBuilder: (context, index) {
                      final p = _productosNuevos[index];
                      return Card(
                        color: isDarkMode ? Colors.grey[800] : Colors.white,
                        child: ListTile(
                          leading: const CircleAvatar(backgroundColor: Colors.blueAccent, child: Icon(Icons.inventory, color: Colors.white, size: 20)),
                          title: Text(p['nombre'] ?? p['nombre_producto'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          trailing: Text("${p['cantidad']} u.", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(thickness: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Total Antiguo:", style: TextStyle(color: Colors.grey)),
                    Text("\$${widget.orden['total']} MXN", style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("NUEVO TOTAL:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    Text("\$${_solicitud!['total_nuevo']} MXN", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.green)),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: ElevatedButton(onPressed: () => _responderSolicitud('Rechazar'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)), child: const Text("RECHAZAR"))),
                    const SizedBox(width: 16),
                    Expanded(child: ElevatedButton(onPressed: () => _responderSolicitud('Aprobar'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)), child: const Text("APROBAR"))),
                  ],
                )
              ],
            ),
          ),
    );
  }
}