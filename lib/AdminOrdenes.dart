import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:molino_app/config.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/NotificacionesHelper.dart';
import 'dart:typed_data'; // Necesario para usar Uint8List

const String kGoogleApiKey = "AIzaSyCY5cOcVAzNpNfR_uSoOpC245m6fAtqdoU";

class OrdenesAdmin extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final int? abrirPedidoId;

  const OrdenesAdmin({super.key, required this.onThemeChanged, this.abrirPedidoId});
  @override
  _OrdenesAdminState createState() => _OrdenesAdminState();
}

class _OrdenesAdminState extends State<OrdenesAdmin> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  IO.Socket? _socket; 
  
  List<dynamic> recibidos = [];
  List<dynamic> asignados = [];
  List<dynamic> pendientes = [];
  List<dynamic> completados = [];
  List<dynamic> rescates = []; 
  List<dynamic> repartidores = [];
  bool isLoading = true;
  bool _yaSeAbrioAuto = false; 
  BitmapDescriptor? _iconoMoto;
  // 🚀 AQUÍ ATRAPAMOS EL GPS EN VIVO DE LOS REPARTIDORES
  Map<int, LatLng> _ubicacionesRepartidores = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this); 
    fetchDashboardData(showLoading: true);
    fetchRepartidores();
    _cargarIconoMoto();
    
    
    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true,
    });

    _socket!.on('actualizacion_ordenes', (_) {
      if (mounted) fetchDashboardData(showLoading: false);
    });

    _socket!.on('notify_nuevo_pedido', (data) {
      if (mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: 'Nuevo Pedido 📦',
          cuerpo: 'El usuario ${data['cliente']} acaba de hacer un pedido.',
          payload: {'tipo': 'admin_pedido', 'id_orden': data['id_orden']}
        );
      }
    });

    // 🚀 ESCUCHAMOS LA UBICACIÓN DEL REPARTIDOR Y LA GUARDAMOS POR ID DE ORDEN
    _socket!.on('ubicacion_repartidor', (data) {
      if (mounted && data['id_orden'] != null && data['lat'] != null) {
        setState(() {
          _ubicacionesRepartidores[data['id_orden']] = LatLng(data['lat'], data['lng']);
        });
      }
    });
  }

  @override
  void dispose() { 
    _socket?.disconnect(); 
    _tabController.dispose();
    super.dispose();
  }
  
  Future<void> _cargarIconoMoto() async {
    _iconoMoto = await BitmapDescriptor.fromAssetImage(
      const ImageConfiguration(size: Size(48, 48)),
      'assets/moto_icon.png', 
    );
    if (mounted) setState(() {});
  }

  Future<void> fetchDashboardData({bool showLoading = false}) async {
    if (showLoading) setState(() => isLoading = true);
    try {
      final responseDashboard = await http.get(Uri.parse('${AppConfig.apiHost}/admin/ordenes/dashboard'));
      final responseFaltantes = await http.get(Uri.parse('${AppConfig.apiHost}/admin/mercancia-faltante'));

      if (responseDashboard.statusCode == 200 && responseFaltantes.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(responseDashboard.body);
        final Map<String, dynamic> responseFaltantesData = json.decode(responseFaltantes.body);

        if (responseData['success'] == true && responseFaltantesData['success'] == true) {
          final data = responseData['data'];
          final faltantesData = responseFaltantesData['data'];
          if (mounted) {
            setState(() {
              recibidos = _optimizarOrdenes(data['recibidos'] ?? []);
              asignados = _optimizarOrdenes(data['asignados'] ?? []);
              pendientes = _optimizarOrdenes(data['pendientes'] ?? []);
              rescates = [
                ..._optimizarOrdenes(data['rescates'] ?? []),
                ..._optimizarOrdenes(faltantesData ?? [])
              ];
              completados = _optimizarOrdenes(data['completados'] ?? []);
              isLoading = false;
            });
            _intentarAbrirPedidoAutomatico();
          }
        } else {
          if (showLoading && mounted) setState(() => isLoading = false);
        }
      } else {
        if (showLoading && mounted) setState(() => isLoading = false);
      }
    } catch (e) {
      if (showLoading && mounted) setState(() => isLoading = false);
    }
  }

  void _intentarAbrirPedidoAutomatico() {
    if (widget.abrirPedidoId == null || _yaSeAbrioAuto) return;
    final int idBuscado = widget.abrirPedidoId!;
    dynamic ordenEncontrada;
    String? tabBuscado;

    try { ordenEncontrada = recibidos.firstWhere((o) => o['id'] == idBuscado); tabBuscado = 'Recibidos'; } catch (e) {
      try { ordenEncontrada = asignados.firstWhere((o) => o['id'] == idBuscado); tabBuscado = 'Asignados'; } catch (e) {
        try { ordenEncontrada = pendientes.firstWhere((o) => o['id'] == idBuscado); tabBuscado = 'Pendientes'; } catch (e) {
          try { ordenEncontrada = rescates.firstWhere((o) => o['id'] == idBuscado); tabBuscado = 'Faltantes'; } catch (e) {
            try { ordenEncontrada = completados.firstWhere((o) => o['id'] == idBuscado); tabBuscado = 'Completadas'; } catch (e) {}
          }
        }
      }
    }

    if (ordenEncontrada != null) {
      _yaSeAbrioAuto = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (tabBuscado == 'Completadas') {
          _mostrarDetallesCompletada(ordenEncontrada);
        } else {
          _abrirModalInteractivo(ordenEncontrada, tabBuscado!);
        }
      });
    }
  }

  Future<void> fetchRepartidores() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/admin/repartidores'));
      if (response.statusCode == 200 && mounted) {
        setState(() { repartidores = json.decode(response.body); });
      }
    } catch (e) { }
  }

  Future<void> eliminarPedido(int id) async {
    try {
      final response = await http.delete(Uri.parse('${AppConfig.apiHost}/admin/ordenes/$id'));
      if (response.statusCode == 200) {
        Navigator.pop(context); 
        fetchDashboardData(); 
      }
    } catch (e) { }
  }

  Future<void> asignarPedido(int idOrden, int idRepartidor) async {
    try {
      final response = await http.put(
        Uri.parse('${AppConfig.apiHost}/admin/ordenes/asignar/$idOrden'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"id_repartidor": idRepartidor}),
      );
      if (response.statusCode == 200) {
        Navigator.pop(context); // Cierra el modal inferior
        fetchDashboardData(); 
      }
    } catch (e) { }
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

  void _mostrarDialogoAsignacion(int idOrden, {int? repartidorActualId}) {
    List<dynamic> repartidoresDisponibles = repartidorActualId != null
        ? repartidores.where((r) => r['id'] != repartidorActualId).toList()
        : repartidores;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Seleccionar Repartidor", style: TextStyle(color: Colors.black)),
          backgroundColor: Colors.white,
          content: SizedBox(
            width: double.maxFinite,
            child: repartidoresDisponibles.isEmpty 
              ? const Text("No hay más repartidores disponibles.", style: TextStyle(color: Colors.black))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: repartidoresDisponibles.length,
                  itemBuilder: (context, index) {
                    final rep = repartidoresDisponibles[index];
                    return ListTile(
                      leading: const CircleAvatar(backgroundColor: Colors.blueAccent, child: Icon(Icons.person, color: Colors.white)),
                      title: Text(rep['nombre'], style: const TextStyle(color: Colors.black)),
                      onTap: () => asignarPedido(idOrden, rep['id']),
                    );
                  },
                ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancelar", style: TextStyle(color: Colors.red)))],
        );
      },
    );
  }

  // 🚀 ABRE EL NUEVO MODAL INTERACTIVO AL ESTILO "REPARTIDORES"
  void _abrirModalInteractivo(dynamic orden, String tabType) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AdminDetalleModal(
        orden: orden,
        tabType: tabType,
        ubicacionRepartidor: _ubicacionesRepartidores[orden['id']],
        socket: _socket, // 🚀 AHORA EL MODAL ESCUCHA AL SOCKET DIRECTAMENTE
        iconoMoto: _iconoMoto, // 🚀 LE PASAMOS LA MOTO
        onAsignar: (idRepActual) => _mostrarDialogoAsignacion(orden['id'], repartidorActualId: idRepActual),
        onEliminar: () => eliminarPedido(orden['id']),
      ),
    );
  }

  // 🚀 COMPLETADAS (Diseño idéntico a Clientes y con Descuentos)
  void _mostrarDetallesCompletada(dynamic orden) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    Color modalBg = isDarkMode ? const Color(0xFF222222) : const Color(0xFF0D47A1);

    DateTime fechaParsed = DateTime.parse(orden['fecha_registro']).toLocal();
    String minutos = fechaParsed.minute.toString().padLeft(2, '0');
    String horaStr = fechaParsed.hour > 12 
        ? "${fechaParsed.hour - 12}:$minutos PM" 
        : (fechaParsed.hour == 0 ? "12:$minutos AM" : "${fechaParsed.hour}:$minutos AM");
    String fechaStr = "${fechaParsed.day.toString().padLeft(2, '0')}/${fechaParsed.month.toString().padLeft(2, '0')}/${fechaParsed.year}";

    // ✅ CÓDIGO OPTIMIZADO
    List<dynamic> productos = orden['productos'] ?? [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.90,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: modalBg, borderRadius: const BorderRadius.vertical(top: Radius.circular(25))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 50, height: 5, decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 20),
              const Text("Resumen de Entrega Completada", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white30, height: 20),
              
              Row(
                children: [
                  const Icon(Icons.person, color: Colors.white70, size: 22), const SizedBox(width: 12),
                  const Text("Cliente:", style: TextStyle(color: Colors.white70, fontSize: 14)), const SizedBox(width: 10),
                  Expanded(child: Text(orden['cliente'] ?? "Desconocido", style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.delivery_dining, color: Colors.white70, size: 22), const SizedBox(width: 12),
                  const Text("Entregado por:", style: TextStyle(color: Colors.white70, fontSize: 14)), const SizedBox(width: 10),
                  Expanded(child: Text(orden['nombre_repartidor'] ?? "Desconocido", style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
                ],
              ),
              
              const Divider(color: Colors.white30, height: 20),
              
              // 🚀 PRODUCTOS CON DESCUENTOS EN COMPLETADAS
              Expanded(
                child: ListView(
                  children: [
                    const Text("Productos Entregados:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDarkMode ? const Color(0xFF1E1E1E) : Colors.white24,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: productos.map<Widget>((prod) {
                          bool tieneDescuento = prod['descuento'] != null;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12.0),
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
        cacheWidth: 100, // Ayuda muchísimo a la RAM al hacer scroll
        errorBuilder: (c,e,s) => const Icon(Icons.image, color: Colors.white)
      )
    : const Icon(Icons.image, color: Colors.white),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(prod['nombre_producto'] ?? 'Producto', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                                      Text("\$${(double.tryParse(prod['precio']?.toString() ?? '0') ?? 0.0).toStringAsFixed(2)} MXN POR UNIDAD", style: TextStyle(color: tieneDescuento ? Colors.greenAccent : Colors.white70, fontSize: 10, fontWeight: tieneDescuento ? FontWeight.bold : FontWeight.normal)),
                                    ],
                                  ),
                                ),
                                Text("${prod['cantidad']} u.", style: const TextStyle(color: Colors.white, fontSize: 12)),
                                const SizedBox(width: 10),
                                Text("Total: \$${((double.tryParse(prod['precio'].toString()) ?? 0) * (double.tryParse(prod['cantidad'].toString()) ?? 0)).toStringAsFixed(2)}", style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(color: Colors.white30, height: 20),
              Text("Total Pagado: \$${(double.tryParse(orden['total']?.toString() ?? '0') ?? 0.0).toStringAsFixed(2)} MXN", style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 18)),
              
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white24, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), minimumSize: const Size(0, 50)),
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cerrar", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              )
            ],
          ),
        );
      },
    );
  }

  // 🚀 EL DISEÑO DE TARJETA IDÉNTICO A CLIENTES / TRABAJADORES
  Widget _buildTarjetaPedido(dynamic orden, String tabType, bool isDarkMode) {
    final String? viaje = orden['viaje_programado'];
    final String estado = orden['estado'] ?? 'Pendiente';
    final bool esFuturo = viaje?.startsWith('Prog:') ?? false;
    final bool huboFaltante = orden['hubo_faltante'] == true;

    final Color colorBorde = huboFaltante ? Colors.redAccent : (esFuturo ? Colors.grey : Colors.orangeAccent);
    final String tituloViaje = esFuturo ? 'Programado: ${viaje?.replaceAll('Prog: ', '')}' : 'Entrega: $viaje';

    // 🚀 Lógica para el nombre del Repartidor o "En Espera"
    bool buscando = estado == 'Buscando Repartidor';
    String nombreRepartidor = buscando ? 'En Espera' : (orden['nombre_repartidor'] ?? 'No asignado');
    bool tieneRepartidor = !buscando && orden['nombre_repartidor'] != null;

    List<dynamic> prods = orden['productos'] ?? [];
    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    
    for(var p in prods) {
      // 🚀 BLINDAJE: Estandarizamos el nombre y la cantidad para evitar los nulls
      String nombreStr = p['nombre_producto']?.toString() ?? p['nombre']?.toString() ?? 'Producto';
      String detalleStr = p['detalle']?.toString().toLowerCase() ?? '';
      
      dynamic rawQty = p['cantidad'] ?? p['cantidad_faltante'] ?? 0;
      double qty = double.tryParse(rawQty.toString()) ?? 0.0;
      p['cantidad_final'] = qty == qty.toInt() ? qty.toInt().toString() : qty.toString();

      // Si no hay detalle, buscamos la palabra "masa" en el nombre (ej. Masa hija)
      bool esMasa = detalleStr.contains('kilo') || detalleStr.contains('gramo') || nombreStr.toLowerCase().contains('masa');
      
      if (esMasa) masas.add(p);
      else mercancia.add(p);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: InkWell( 
        onTap: () {
          if (tabType == 'Completadas') {
            _mostrarDetallesCompletada(orden);
          } else {
            _abrirModalInteractivo(orden, tabType);
          }
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
                              Icon(tieneRepartidor ? Icons.motorcycle : Icons.hourglass_empty, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                              const SizedBox(width: 4),
                              Expanded(child: Text(
                                'Repartidor: $nombreRepartidor', 
                                style: TextStyle(color: tieneRepartidor ? (isDarkMode ? Colors.cyanAccent : Colors.blue[800]) : Colors.grey, fontWeight: FontWeight.bold, fontSize: 14)
                              )),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // 🚀 AQUÍ AÑADIMOS EL LOCAL DEBAJO DEL REPARTIDOR
                          Row(
                            children: [
                              Icon(Icons.store, color: isDarkMode ? Colors.green[300] : Colors.green[700], size: 16),
                              const SizedBox(width: 4),
                              Expanded(child: Text(
                                'Local: ${orden['local'] ?? 'No especificado'}', 
                                style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13)
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
                        Expanded(child: Text('Faltante reportado. El pedido fue modificado.', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                  ),

                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (masas.isNotEmpty)
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: masas.map((m) => Text("${m['nombre_producto'] ?? m['nombre'] ?? 'Masa'}: ${m['cantidad_final']} Kl.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList(),
                        ),
                      ),
                    if (masas.isNotEmpty && mercancia.isNotEmpty)
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 8.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                    if (mercancia.isNotEmpty)
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: mercancia.map((m) => Text("${m['nombre_producto'] ?? m['nombre'] ?? 'Producto'}: ${m['cantidad_final']} U.", style: const TextStyle(fontSize: 12, color: Colors.grey))).toList(),
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
                    Text('\$${(double.tryParse(orden['total']?.toString() ?? '0') ?? 0.0).toStringAsFixed(2)} MXN', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<dynamic> ordenes, Color semaforoColor, String tabType) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    if (ordenes.isEmpty) {
      return RefreshIndicator(
        onRefresh: fetchDashboardData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(height: MediaQuery.of(context).size.height * 0.5, alignment: Alignment.center, child: Text("No hay órdenes", style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.grey))),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: fetchDashboardData,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: ordenes.length,
        itemBuilder: (context, index) {
          final orden = ordenes[index];
          return _buildTarjetaPedido(orden, tabType, isDarkMode);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    Color indicatorColor = isDarkMode ? Colors.grey[300]! : const Color(0xFF1565C0);
    Color labelColor = isDarkMode ? Colors.black : Colors.white;
    Color unselectedLabelColor = isDarkMode ? Colors.white70 : Colors.black87;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Theme.of(context).colorScheme.onSurface,
        title: const Text("Monitor de Órdenes", style: TextStyle(fontWeight: FontWeight.bold)), centerTitle: true,
        actions: [
          PopupMenuButton(
            icon: Icon(Icons.more_vert, color: Theme.of(context).colorScheme.onSurface),
            itemBuilder: (context) => <PopupMenuEntry<dynamic>>[
              PopupMenuItem(
                enabled: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Modo Oscuro'),
                    Switch(
                      value: isDarkMode,
                      onChanged: (value) {
                        widget.onThemeChanged(value ? ThemeMode.dark : ThemeMode.light);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
            ],
          )
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true, labelColor: labelColor, unselectedLabelColor: unselectedLabelColor,
          indicator: BoxDecoration(borderRadius: BorderRadius.circular(10), color: indicatorColor),
          indicatorSize: TabBarIndicatorSize.tab, indicatorPadding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          tabs: const [Tab(text: "Recibidos"), Tab(text: "Asignados"), Tab(text: "Pendientes"), Tab(text: "Faltantes"), Tab(text: "Completadas")],
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildList(recibidos, Colors.red, 'Recibidos'),
                _buildList(asignados, Colors.orange, 'Asignados'),
                _buildList(pendientes, Colors.yellow, 'Pendientes'),
                _buildList(rescates, Colors.purpleAccent, 'Faltantes'), 
                _buildList(completados, Colors.green, 'Completadas'),
              ],
            ),
    );
  }
}
// =========================================================
// 🚀 NUEVO MODAL INTERACTIVO CON MAPA, ETA Y PRODUCTOS PARA ADMIN
// =========================================================
class AdminDetalleModal extends StatefulWidget {
  final Map<String, dynamic> orden;
  final String tabType;
  final LatLng? ubicacionRepartidor; // GPS inicial
  final IO.Socket? socket; // 🚀 PARA RECIBIR EL GPS EN TIEMPO REAL
  final BitmapDescriptor? iconoMoto; // 🚀 ICONO DE MOTO
  final Function(int?) onAsignar;
  final VoidCallback onEliminar;

  const AdminDetalleModal({
    super.key, 
    required this.orden, 
    required this.tabType, 
    this.ubicacionRepartidor, 
    this.socket, 
    this.iconoMoto, 
    required this.onAsignar, 
    required this.onEliminar
  });

  @override
  State<AdminDetalleModal> createState() => _AdminDetalleModalState();
}

class _AdminDetalleModalState extends State<AdminDetalleModal> {
  GoogleMapController? _mapController;
  Set<Marker> _marcadores = {};
  Set<Polyline> _rutas = {};
  String? _etaEstimado;
  bool _trazandoRuta = false;

  DateTime? _ultimaVezRuta; // 🚀 PARA MEDIR EL TIEMPO
  LatLng? _posicionRepartidorActual; // 🚀 PARA RASTREARLO EN VIVO

  @override
  void initState() {
    super.initState();
    _posicionRepartidorActual = widget.ubicacionRepartidor;
    _prepararMapa();

    // 🚀 ESCUCHAR AL REPARTIDOR EN TIEMPO REAL MIENTRAS EL MODAL ESTÁ ABIERTO
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
        _marcadores.removeWhere((m) => m.markerId.value == 'repartidor');
        _marcadores.add(Marker(
          markerId: const MarkerId('repartidor'),
          position: nuevaPos,
          icon: widget.iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: InfoWindow(title: widget.orden['nombre_repartidor'] ?? 'Repartidor'),
        ));
      });

      // 🚀 Recalcular ruta en Google Maps cada 15 segundos
      if (_ultimaVezRuta == null || DateTime.now().difference(_ultimaVezRuta!).inSeconds >= 15) {
          final double latDestino = double.tryParse(widget.orden['latitud']?.toString() ?? '19.4') ?? 19.4;
          final double lngDestino = double.tryParse(widget.orden['longitud']?.toString() ?? '-99.1') ?? -99.1;
        _trazarRutaA(nuevaPos, LatLng(latDestino, lngDestino));
        _ultimaVezRuta = DateTime.now();
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
    final double latDestino = double.tryParse(widget.orden['latitud']?.toString() ?? '19.4') ?? 19.4;
    final double lngDestino = double.tryParse(widget.orden['longitud']?.toString() ?? '-99.1') ?? -99.1;
    final LatLng destino = LatLng(latDestino, lngDestino);

    _marcadores.add(Marker(
      markerId: const MarkerId('destino'),
      position: destino,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: InfoWindow(title: widget.orden['cliente'], snippet: widget.orden['local']),
    ));

    if (_posicionRepartidorActual != null && (widget.tabType == 'Asignados' || widget.tabType == 'Pendientes' || (widget.tabType == 'Faltantes' && widget.orden['estado'] != 'Buscando Repartidor'))) {
      _marcadores.add(Marker(
        markerId: const MarkerId('repartidor'),
        position: _posicionRepartidorActual!,
        icon: widget.iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: InfoWindow(title: widget.orden['nombre_repartidor'] ?? 'Repartidor'),
      ));
      _trazarRutaA(_posicionRepartidorActual!, destino);
      _ultimaVezRuta = DateTime.now(); 
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
            _etaEstimado = "$minutos min";
            _rutas = {Polyline(polylineId: const PolylineId('ruta_repartidor'), color: Colors.blueAccent, width: 5, points: puntosRuta)};
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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final orden = widget.orden;

    String tituloViaje = orden['viaje_programado']?.toString() ?? 'Viaje';
    final bool esFuturo = tituloViaje.startsWith('Prog:');
    tituloViaje = esFuturo ? 'Programado: ${tituloViaje.replaceAll('Prog: ', '')}' : 'Entrega: $tituloViaje';

    List<dynamic> productos = orden['productos'] ?? [];
    
    final double latDestino = double.tryParse(orden['latitud']?.toString() ?? '19.4') ?? 19.4;
    final double lngDestino = double.tryParse(orden['longitud']?.toString() ?? '-99.1') ?? -99.1;

    return Container(
      height: MediaQuery.of(context).size.height * 0.90, 
      decoration: BoxDecoration(
        color: isDarkMode ? Colors.grey[900] : Colors.white, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20))
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10)))),
          ),
          
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(tituloViaje, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange[700])),
                const SizedBox(height: 12),
                
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.person, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20), const SizedBox(width: 8),
                    Expanded(child: Text('Para: ${orden['cliente'] ?? 'Sin nombre'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.store, color: isDarkMode ? Colors.green[300] : Colors.green[700], size: 20), const SizedBox(width: 8),
                    Expanded(child: Text('Local: ${orden['local'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 15))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 20), const SizedBox(width: 8),
                    Expanded(child: Text('Ubicación: ${orden['direccion'] ?? 'No especificada'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 15))),
                  ],
                ),
                
                const SizedBox(height: 16),
                
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDarkMode ? const Color(0xFF1E1E1E) : Colors.grey[200],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: productos.map<Widget>((prod) {
                      bool tieneDescuento = prod['descuento'] != null;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
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
                                    cacheWidth: 100, 
                                    errorBuilder: (c,e,s) => const Icon(Icons.image, color: Colors.white),
                                  )
                                : const Icon(Icons.image, color: Colors.white),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(prod['nombre_producto'] ?? prod['nombre'] ?? 'Producto', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
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
                                  if (prod['precio'] != null)
                                    Text("\$${(double.tryParse(prod['precio']?.toString() ?? '0') ?? 0.0).toStringAsFixed(2)} MXN POR UNIDAD", style: TextStyle(color: tieneDescuento ? Colors.green : (isDarkMode ? Colors.white70 : Colors.black54), fontSize: 10, fontWeight: tieneDescuento ? FontWeight.bold : FontWeight.normal)),
                                ],
                              ),
                            ),
                            Text("${(double.tryParse(prod['cantidad']?.toString() ?? prod['cantidad_faltante']?.toString() ?? '0') ?? 0).toInt()} u.", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontSize: 13, fontWeight: FontWeight.bold)),
                            const SizedBox(width: 10),
                            if (prod['precio'] != null)
                              Text("Total: \$${((double.tryParse(prod['precio']?.toString() ?? '0') ?? 0.0) * (double.tryParse(prod['cantidad']?.toString() ?? '0') ?? 0.0)).toStringAsFixed(2)}", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),                          
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
                
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text("TOTAL: \$${(double.tryParse(orden['total']?.toString() ?? '0') ?? 0.0).toStringAsFixed(2)} MXN", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                const SizedBox(height: 16),

                Container(
                  height: 250, 
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.blueAccent, width: 2)
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: Stack(
                    children: [
                      GoogleMap(
                        initialCameraPosition: CameraPosition(
                           target: _posicionRepartidorActual ?? LatLng(latDestino, lngDestino), 
                           zoom: 16
                        ),
                        markers: _marcadores,
                        polylines: _rutas,
                        myLocationEnabled: false,
                        zoomControlsEnabled: false,
                        onMapCreated: (controller) => _mapController = controller,
                      ),
                      if (_etaEstimado != null)
                        Positioned(
                          top: 10, right: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                            child: Row(
                              children: [
                                const Icon(Icons.timer, color: Colors.blueAccent, size: 18),
                                const SizedBox(width: 6),
                                Text("Llega en $_etaEstimado", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
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
                        )
                    ],
                  ),
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.grey[850] : Colors.grey[100],
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))]
            ),
            child: Row(
              children: [
                if (widget.tabType == 'Recibidos' || (widget.tabType == 'Faltantes' && orden['estado'] == 'Buscando Repartidor')) ...[
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () { Navigator.pop(context); widget.onAsignar(null); },
                      child: const Text("Asignar", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () { Navigator.pop(context); widget.onEliminar(); },
                      child: const Text("Eliminar", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ] else if (widget.tabType == 'Asignados' || (widget.tabType == 'Faltantes' && orden['estado'] == 'Asignado')) ...[
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () { Navigator.pop(context); widget.onAsignar(orden['id_repartidor']); },
                      child: const Text("Asignar a alguien más", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () { Navigator.pop(context); widget.onEliminar(); },
                      child: const Text("Eliminar", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ] else if (widget.tabType == 'Pendientes' || (widget.tabType == 'Faltantes' && (orden['estado'] == 'Pendiente' || orden['estado'] == 'En Camino'))) ...[
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () { Navigator.pop(context); widget.onAsignar(orden['id_repartidor']); },
                      child: const Text("Reasignar", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ],
            ),
          )
        ],
      ),
    );
  }
}