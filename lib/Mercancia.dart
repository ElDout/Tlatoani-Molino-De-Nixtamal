import 'dart:convert';
import 'dart:typed_data'; // 🚀 Añadido para manejar la imagen en bytes
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:molino_app/config.dart'; 

class MercanciaScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const MercanciaScreen({super.key, required this.onThemeChanged});
  
  @override
  State<MercanciaScreen> createState() => _MercanciaScreenState();
}

class _MercanciaScreenState extends State<MercanciaScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  List<dynamic> _productos = [];
  List<dynamic> _masas = [];
  List<dynamic> _faltantes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 🚀 AHORA SON 3 PESTAÑAS: Productos, Masas, Faltantes
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      if (_tabController.index == 0) {
        _obtenerProductos();
      } else if (_tabController.index == 1) {
        _obtenerMasas();
      } else {
        _obtenerFaltantes();
      }
    });
    _obtenerProductos();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // 🚀 OPTIMIZACIÓN CLAVE: Decodifica las imágenes del catálogo 1 sola vez
  List<dynamic> _optimizarCatalogo(List<dynamic> itemsCrudos) {
    return itemsCrudos.map((item) {
      if (item['imagen'] != null && item['imagen'].toString().isNotEmpty) {
        try {
          item['imagenBytes'] = base64Decode(item['imagen'].toString().replaceAll(RegExp(r'\s+'), ''));
        } catch (e) {
          item['imagenBytes'] = null;
        }
      }
      return item;
    }).toList();
  }

  // =====================================
  // LOGICA PESTAÑA 1: PRODUCTOS
  // =====================================
  Future<void> _obtenerProductos() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia'));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            // 🚀 Pasamos los datos por nuestra función limpiadora
            _productos = _optimizarCatalogo(jsonDecode(response.body));
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error obteniendo productos: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _eliminarItem(String id, bool esMasa) async {
    try {
      String endpoint = esMasa ? 'masas' : 'mercancia';
      await http.delete(Uri.parse('${AppConfig.apiHost}/$endpoint/$id'));
      esMasa ? _obtenerMasas() : _obtenerProductos();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Artículo eliminado 🗑️')));
    } catch (e) {
      debugPrint('Error eliminando: $e');
    }
  }

  void _confirmarEliminacion(String id, String nombre, bool esMasa) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('⚠️ Cuidado'),
          content: Text('Estás a punto de borrar "$nombre". ¿Estás seguro?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.of(context).pop();
                _eliminarItem(id, esMasa);
              },
              child: const Text('Borrar'),
            ),
          ],
        );
      },
    );
  }

  // =====================================
  // LOGICA PESTAÑA 2: MASAS
  // =====================================
  Future<void> _obtenerMasas() async {
    setState(() => _isLoading = true);
    try {
      // ⚠️ NOTA: Asegúrate de crear el endpoint GET /masas en tu server.js
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/masas'));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
             // 🚀 Pasamos los datos por nuestra función limpiadora
            _masas = _optimizarCatalogo(jsonDecode(response.body));
            _isLoading = false;
          });
        }
      } else {
         if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Error obteniendo masas: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }


  // =====================================
  // FORMULARIO UNIVERSAL (Para Productos y Masas)
  // =====================================
  void _mostrarDialogoFormulario({Map<String, dynamic>? itemGuardado, required bool esMasa}) {
    final bool esEditar = itemGuardado != null;
    
    final TextEditingController nombreController = TextEditingController(text: esEditar ? itemGuardado['nombre'] : '');
    final TextEditingController precioController = TextEditingController(text: esEditar ? itemGuardado['precio'].toString() : '');
    final TextEditingController unidadController = TextEditingController(text: esEditar ? itemGuardado['unidad'] : (esMasa ? 'Kilo' : ''));
    
    String? base64Imagen = esEditar ? itemGuardado['imagen'] : null;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final isDarkMode = Theme.of(context).brightness == Brightness.dark;
            final colorFondo = isDarkMode ? const Color(0xFF2A2A2A) : const Color(0xFF0052CC);
            final colorEtiqueta = Colors.white; 
            final colorInput = isDarkMode ? Colors.white : Colors.black; 

            Future<void> tomarFoto() async {
              final ImagePicker picker = ImagePicker();
              final XFile? foto = await picker.pickImage(source: ImageSource.camera, imageQuality: 50);
              if (foto != null) {
                final bytes = await foto.readAsBytes();
                setStateDialog(() {
                  base64Imagen = base64Encode(bytes);
                });
              }
            }

            Future<void> guardarDatos() async {
              if (nombreController.text.isEmpty || precioController.text.isEmpty || unidadController.text.isEmpty) {
                return;
              }
              
              final body = jsonEncode({
                'nombre': nombreController.text.trim(),
                'precio': double.tryParse(precioController.text.trim()) ?? 0.0,
                'unidad': unidadController.text.trim(),
                'imagen': base64Imagen ?? '',
              });

              try {
                String endpoint = esMasa ? 'masas' : 'mercancia';
                if (esEditar) {
                  await http.put(Uri.parse('${AppConfig.apiHost}/$endpoint/${itemGuardado['id']}'), headers: {'Content-Type': 'application/json'}, body: body);
                } else {
                  await http.post(Uri.parse('${AppConfig.apiHost}/$endpoint'), headers: {'Content-Type': 'application/json'}, body: body);
                }
                
                esMasa ? _obtenerMasas() : _obtenerProductos();
                if (!mounted) return;
                Navigator.pop(context);
              } catch (e) {
                debugPrint('Error al guardar: $e');
              }
            }

            return Dialog(
              backgroundColor: colorFondo,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(esMasa ? (esEditar ? 'Editar Masa' : 'Nueva Masa') : (esEditar ? 'Editar Producto' : 'Nuevo Producto'), 
                         style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: tomarFoto,
                      child: Container(
                        height: 150,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: isDarkMode ? const Color(0xFF505050) : const Color(0xFF4C8CFF),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white54),
                        ),
                        child: base64Imagen != null && base64Imagen!.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                // 🚀 FIX: cacheHeight para evitar lag en el formulario
                                child: Image.memory(
                                  base64Decode(base64Imagen!), 
                                  fit: BoxFit.cover,
                                  cacheHeight: 300, 
                                ),
                              )
                            : const Icon(Icons.camera_alt, size: 80, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(esEditar ? 'Tocar para volver a tomar' : 'Tocar para tomar foto', style: TextStyle(color: colorEtiqueta, fontSize: 12)),
                    const SizedBox(height: 24),
                    
                    Align(alignment: Alignment.centerLeft, child: Text('Nombre:', style: TextStyle(color: colorEtiqueta, fontWeight: FontWeight.bold))),
                    const SizedBox(height: 8),
                    TextField(controller: nombreController, style: TextStyle(color: colorInput), decoration: _inputDeco(isDarkMode)),
                    
                    const SizedBox(height: 16),
                    Align(alignment: Alignment.centerLeft, child: Text('Precio:', style: TextStyle(color: colorEtiqueta, fontWeight: FontWeight.bold))),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: TextField(
                          controller: precioController, 
                          // 🚀 FIX: TextInputType.numberWithOptions(decimal: true) permite teclado con punto decimal
                          keyboardType: const TextInputType.numberWithOptions(decimal: true), 
                          style: TextStyle(color: colorInput), 
                          decoration: _inputDeco(isDarkMode)
                        )),
                        const SizedBox(width: 8),
                        Text('MXN', style: TextStyle(color: colorEtiqueta, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    
                    const SizedBox(height: 16),
                    Align(alignment: Alignment.centerLeft, child: Text('Por:', style: TextStyle(color: colorEtiqueta, fontWeight: FontWeight.bold))),
                    const SizedBox(height: 8),
                    TextField(
                      controller: unidadController, 
                      style: TextStyle(color: colorInput), 
                      decoration: _inputDeco(isDarkMode).copyWith(hintText: esMasa ? 'Ej. Kilo' : 'Ej. Pieza, Costal'),
                    ),
                    
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 150,
                      height: 45,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white),
                        onPressed: guardarDatos,
                        child: Text(esEditar ? 'Editar' : 'Agregar', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    )
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  InputDecoration _inputDeco(bool isDarkMode) {
    return InputDecoration(
      filled: true,
      fillColor: isDarkMode ? const Color(0xFF505050) : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
  }

  // =====================================
  // LOGICA PESTAÑA 3: FALTANTES
  // =====================================
  Future<void> _obtenerFaltantes() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia-faltante'));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _faltantes = jsonDecode(response.body);
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _marcarDisponible(int id) async {
    setState(() => _isLoading = true);
    try {
      await http.put(Uri.parse('${AppConfig.apiHost}/mercancia-faltante/disponible/$id'));
      _obtenerFaltantes();
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // =====================================
  // CONSTRUCCIÓN DE LA UI (TABS)
  // =====================================
  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
        title: Column(
          children: [
            Text(
              'Inventario',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
            ),
            const Text('Control de Stock', style: TextStyle(fontSize: 14, color: Colors.grey)),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: isDarkMode ? Colors.black : Colors.white,
          unselectedLabelColor: isDarkMode ? Colors.white70 : Colors.black87,
          indicator: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isDarkMode ? Colors.grey[300] : const Color(0xFF1565C0),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          tabs: const [
            Tab(text: "Masas"),
            Tab(text: "Productos"),
            Tab(text: "Faltantes"),
          ],
        ),
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
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildPestanaLista(_masas, isDarkMode, true), // Tab Masas
                _buildPestanaLista(_productos, isDarkMode, false), // Tab Productos
                _buildPestanaFaltantes(isDarkMode), // Tab Faltantes
              ],
            ),
      
      floatingActionButton: _tabController.index == 0 || _tabController.index == 1 ? FloatingActionButton.extended(
        onPressed: () => _mostrarDialogoFormulario(esMasa: _tabController.index == 0),
        backgroundColor: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF001529),
        foregroundColor: isDarkMode ? Colors.black : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
        label: Text(_tabController.index == 0 ? 'Agregar Masa +' : 'Agregar Producto +', style: const TextStyle(fontWeight: FontWeight.bold)),
      ) : null,
    );
  }

  // Widget reutilizable para pintar la lista de Masas o Productos
  Widget _buildPestanaLista(List<dynamic> lista, bool isDarkMode, bool esMasa) {
    if (lista.isEmpty) {
      return Center(child: Text(esMasa ? 'No hay masas registradas' : 'No hay productos registrados'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: lista.length,
      itemBuilder: (context, index) {
        final item = lista[index];
        return Card(
          color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF0052CC),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(color: isDarkMode ? const Color(0xFF757575) : const Color(0xFF0040A0), borderRadius: BorderRadius.circular(8)),
                  clipBehavior: Clip.hardEdge,
                  // 🚀 FIX: Usamos los bytes decodificados con cacheWidth para salvar RAM
                  child: item['imagenBytes'] != null
                      ? Image.memory(
                          item['imagenBytes'], 
                          fit: BoxFit.cover,
                          cacheWidth: 120, // Protege la RAM al hacer scroll
                        )
                      : const Icon(Icons.image_not_supported, color: Colors.white54),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item['nombre'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text('${item['precio']} MXN Por ${item['unidad']}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                Row(
                  children: [
                    IconButton(icon: const Icon(Icons.edit, color: Colors.orange), onPressed: () => _mostrarDialogoFormulario(itemGuardado: item, esMasa: esMasa)),
                    IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _confirmarEliminacion(item['id'].toString(), item['nombre'], esMasa)),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPestanaFaltantes(bool isDarkMode) {
    if (_faltantes.isEmpty) {
      return const Center(child: Text('No hay reportes de mercancía faltante.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: _faltantes.length,
      itemBuilder: (context, index) {
        final f = _faltantes[index];
        bool esAgotado = f['estado'] == 'Agotado';
        
        DateTime fecha = DateTime.parse(f['fecha_registro']).toLocal();
        String fechaFormat = "${fecha.day}/${fecha.month}/${fecha.year}";

        return Card(
          color: isDarkMode ? const Color(0xFF424242) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: esAgotado ? Colors.redAccent : Colors.greenAccent, width: 2)
          ),
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("📍 ${f['afectado'] ?? 'Desconocido'}", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Theme.of(context).colorScheme.onSurface)),
                    Text(fechaFormat, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Text("Se le quedó a deber: ${f['cantidad_faltante']}x ${f['nombre_producto']}", style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 14)),
                const SizedBox(height: 12),
                
                if (esAgotado)
                  SizedBox(
                    width: double.infinity,
                    height: 45,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, padding: EdgeInsets.zero),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('MARCAR COMO DISPONIBLE', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () => _marcarDisponible(f['id']),
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(color: Colors.green.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
                    child: const Center(child: Text("✅ Autorizado para pedirse", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
                  )
              ],
            ),
          ),
        );
      },
    );
  }
}