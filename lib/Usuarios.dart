import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';

class UsuariosScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const UsuariosScreen({super.key, required this.onThemeChanged});
  
  @override
  State<UsuariosScreen> createState() => _UsuariosScreenState();
}

class _UsuariosScreenState extends State<UsuariosScreen> {
  // Pestañas disponibles
  final List<String> _tabs = ['Repartidores', 'Trabajadores', 'Clientes', 'Administradores'];
  String _tabActual = 'Repartidores';
  
  List<dynamic> _listaUsuarios = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _obtenerUsuarios();
  }

  // --- OBTENER DATOS DEL SERVIDOR ---
  Future<void> _obtenerUsuarios() async {
    setState(() => _isLoading = true);
    final String endpoint = _tabActual.toLowerCase();
    
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/panel/usuarios/$endpoint'));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _listaUsuarios = jsonDecode(response.body);
          });
        }
      } else {
        debugPrint('Error del servidor: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error obteniendo usuarios: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // --- ELIMINAR USUARIO ---
  Future<void> _eliminarUsuario(String id) async {
    final String endpoint = _tabActual.toLowerCase();
    try {
      final response = await http.delete(Uri.parse('${AppConfig.apiHost}/panel/usuarios/$endpoint/$id'));
      if (response.statusCode == 200) {
        _obtenerUsuarios();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Usuario eliminado 🗑️')));
      } else {
        final data = jsonDecode(response.body);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['error'] ?? 'Error al borrar'), backgroundColor: Colors.red));
      }
    } catch (e) {
      debugPrint('Error eliminando: $e');
    }
  }

  void _confirmarEliminacion(String id, String nombre) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('⚠️ Cuidado'),
          content: Text('Estás a punto de eliminar a "$nombre". Esta acción no se puede deshacer.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.of(context).pop();
                _eliminarUsuario(id);
              },
              child: const Text('Eliminar'),
            ),
          ],
        );
      },
    );
  }

  // --- DIÁLOGO PARA AÑADIR / EDITAR (LIMPIO) ---
  void _mostrarDialogoFormulario({Map<String, dynamic>? usuarioEdit}) {
    final bool esEditar = usuarioEdit != null;
    
    final TextEditingController nombreController = TextEditingController(text: esEditar ? usuarioEdit['nombre'] : '');
    final TextEditingController usuarioController = TextEditingController(text: esEditar ? usuarioEdit['usuario'] : '');
    final TextEditingController passwordController = TextEditingController(); // Siempre vacío por seguridad

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final isDarkMode = Theme.of(context).brightness == Brightness.dark;
            final colorFondo = isDarkMode ? const Color(0xFF212121) : const Color(0xFF0052CC);
            final colorTexto = Colors.white;

            Future<void> guardarDatos() async {
              if (nombreController.text.isEmpty || usuarioController.text.isEmpty || (!esEditar && passwordController.text.isEmpty)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Llena los campos obligatorios')));
                return;
              }
              
              final body = jsonEncode({
                'nombre': nombreController.text.trim(),
                'edad': 0, // Se envía 0 por defecto
                'usuario': usuarioController.text.trim(),
                'password': passwordController.text.trim(),
                'imagen': '', // Se envía vacío por defecto
              });

              final String endpoint = _tabActual.toLowerCase();

              try {
                http.Response response;
                if (esEditar) {
                  response = await http.put(Uri.parse('${AppConfig.apiHost}/panel/usuarios/$endpoint/${usuarioEdit['id']}'), headers: {'Content-Type': 'application/json'}, body: body);
                } else {
                  response = await http.post(Uri.parse('${AppConfig.apiHost}/panel/usuarios/$endpoint'), headers: {'Content-Type': 'application/json'}, body: body);
                }

                if (response.statusCode == 200) {
                  _obtenerUsuarios();
                  if (mounted) Navigator.pop(context);
                } else {
                  final errorData = jsonDecode(response.body);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorData['error'] ?? 'Error')));
                }
              } catch (e) {
                debugPrint('Error al guardar: $e');
              }
            }

            return Dialog(
              backgroundColor: colorFondo,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // FORMULARIO LIMPIO
                    Text('Nombre ${_tabActual.substring(0, _tabActual.length - 1)}', style: TextStyle(color: colorTexto, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(controller: nombreController, style: const TextStyle(color: Colors.black), decoration: _inputBlanco()),
                    
                    const SizedBox(height: 16),
                    Text('Usuario', style: TextStyle(color: colorTexto, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(controller: usuarioController, style: const TextStyle(color: Colors.black), decoration: _inputBlanco()),
                    
                    const SizedBox(height: 16),
                    Text('Contraseña', style: TextStyle(color: colorTexto, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(controller: passwordController, obscureText: true, style: const TextStyle(color: Colors.black), decoration: _inputBlanco(hint: esEditar ? 'Dejar vacío para no cambiar' : '')),
                    
                    const SizedBox(height: 32),
                    Center(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, minimumSize: const Size(120, 40)),
                        onPressed: guardarDatos,
                        child: Text(esEditar ? 'EDITAR' : 'Alta', style: const TextStyle(fontWeight: FontWeight.bold)),
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

  // --- DIÁLOGO PARA VER DETALLES DE USUARIO NORMAL ---
  void _mostrarDetallesUsuario(Map<String, dynamic> usuario) {
    final esCliente = _tabActual == 'Clientes';
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(usuario['nombre'] ?? 'Detalles del Usuario'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // FOTO
                Center(
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.hardEdge,
                    // ✅ CÓDIGO OPTIMIZADO
child: usuario['imagen'] != null && usuario['imagen'].toString().isNotEmpty
    ? Image.memory(
        base64Decode(usuario['imagen'].toString().replaceAll(RegExp(r'\s+'), '')), 
        fit: BoxFit.cover,
        cacheWidth: 200, // 🚀 Carga súper rápido al abrir el diálogo
      )
    : Icon(Icons.person, size: 60, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 24),

                // Si es cliente, muestra sus datos específicos
                if (esCliente) ...[
                  _buildDetalleRow('Nombre Propietario:', usuario['nombre']),
                  _buildDetalleRow('Empresa:', usuario['empresa']),
                  _buildDetalleRow('Local:', usuario['local']),
                  _buildDetalleRow('Correo:', usuario['correo']),
                  _buildDetalleRow('Teléfono:', usuario['telefono']),
                ] 
                // Si es cualquier otro tipo de usuario
                else ...[
                  _buildDetalleRow('Nombre:', usuario['nombre']),
                  _buildDetalleRow('Usuario:', usuario['usuario']),
                ]
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cerrar'),
            )
          ],
        );
      },
    );
  }

  // 🚀 FASE 3/4: DIÁLOGO ESPECIAL CON RESEÑAS PARA EL REPARTIDOR 🚀
  void _mostrarDetallesRepartidor(Map<String, dynamic> repartidor) {
    bool cargandoResenas = true;
    double promedio = 0.0;
    int totalViajes = 0;
    List<dynamic> comentarios = [];
    bool peticionHecha = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;
        final modalBg = isDarkMode ? const Color(0xFF222222) : Colors.white;

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateModal) {
            // Hacemos la petición al backend una sola vez
            if (!peticionHecha) {
              peticionHecha = true;
              http.get(Uri.parse('${AppConfig.apiHost}/repartidores/${repartidor['id']}/resenas')).then((res) {
                if (res.statusCode == 200) {
                  final data = jsonDecode(res.body);
                  if (data['success'] == true) {
                    setStateModal(() {
                      promedio = double.tryParse(data['promedio'].toString()) ?? 0.0;
                      totalViajes = int.tryParse(data['total_viajes'].toString()) ?? 0;
                      comentarios = data['comentarios'] ?? [];
                      cargandoResenas = false;
                    });
                  } else {
                    setStateModal(() => cargandoResenas = false);
                  }
                } else {
                  setStateModal(() => cargandoResenas = false);
                }
              }).catchError((e) {
                setStateModal(() => cargandoResenas = false);
              });
            }

            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: modalBg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: Column(
                children: [
                  // Tirita decorativa
                  Container(width: 50, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10))),
                  const SizedBox(height: 20),
                  
                  // Perfil Básico
                  Row(
                    children: [
                      Container(
                        width: 60, height: 60,
                        decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.circular(12)),
                        clipBehavior: Clip.hardEdge,
                        // ✅ CÓDIGO OPTIMIZADO
child: repartidor['imagen'] != null && repartidor['imagen'].toString().isNotEmpty
    ? Image.memory(
        base64Decode(repartidor['imagen'].toString().replaceAll(RegExp(r'\s+'), '')), 
        fit: BoxFit.cover,
        cacheWidth: 120, // 🚀 Evita lag al deslizar el panel hacia arriba
      )
    : const Icon(Icons.person, color: Colors.white, size: 40),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(repartidor['nombre'] ?? 'Repartidor', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
                            Text("Usuario: ${repartidor['usuario']}", style: const TextStyle(color: Colors.grey, fontSize: 14)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  if (cargandoResenas)
                    const Expanded(child: Center(child: CircularProgressIndicator()))
                  else ...[
                    // Promedio de Estrellas
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.withOpacity(0.5))
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 40),
                          const SizedBox(width: 8),
                          Text(promedio.toStringAsFixed(1), style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Calificación Global", style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
                              Text("Basado en $totalViajes viajes", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                            ],
                          )
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Align(alignment: Alignment.centerLeft, child: Text("Comentarios y Reseñas", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface))),
                    const SizedBox(height: 10),
                    
                    // Lista de Comentarios
                    Expanded(
                      child: comentarios.isEmpty
                          ? const Center(child: Text("Aún no tiene reseñas.", style: TextStyle(color: Colors.grey)))
                          : ListView.builder(
                              itemCount: comentarios.length,
                              itemBuilder: (context, index) {
                                final c = comentarios[index];
                                final int estrellas = int.tryParse(c['calificacion_repartidor'].toString()) ?? 0;
                                
                                return Card(
                                  elevation: 0,
                                  color: isDarkMode ? Colors.grey[800] : Colors.grey[100],
                                  margin: const EdgeInsets.only(bottom: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                c['nombre_quien_califica'] ?? 'Cliente', 
                                                style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface),
                                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Row(
                                              children: List.generate(5, (starIndex) => Icon(
                                                starIndex < estrellas ? Icons.star : Icons.star_border, 
                                                color: Colors.amber, 
                                                size: 16
                                              )),
                                            )
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          "\"${c['comentario_repartidor']}\"",
                                          style: TextStyle(fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurface),
                                        )
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ]
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- WIDGET REUTILIZABLE PARA MOSTRAR DETALLES ---
  Widget _buildDetalleRow(String titulo, String? valor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titulo,
            style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.7), fontSize: 12),
          ),
          Text(valor ?? 'N/A', style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  InputDecoration _inputBlanco({String hint = ''}) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Colors.white, // Los inputs del mockup son blancos incluso en modo oscuro
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final esCliente = _tabActual == 'Clientes'; // 🚨 Bandera para bloquear acciones a clientes

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
        title: Text('Usuarios', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
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
      body: Column(
        children: [
          // --- PESTAÑAS (TABS) ---
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: _tabs.map((tabName) {
                final isSelected = _tabActual == tabName;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _tabActual = tabName;
                    });
                    _obtenerUsuarios(); // Recargamos la lista al cambiar de pestaña
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 12.0),
                    padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
                    decoration: BoxDecoration(
                      color: isSelected 
                          ? (isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC)) 
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: Text(
                      tabName,
                      style: TextStyle(
                        color: isSelected 
                            ? (isDarkMode ? Colors.black : Colors.white) 
                            : (isDarkMode ? Colors.white70 : Colors.black87),
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        decoration: isSelected ? TextDecoration.none : TextDecoration.underline,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // --- BOTÓN AÑADIR (Se oculta si es cliente) ---
          if (!esCliente)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDarkMode ? const Color(0xFFE0E0E0) : const Color(0xFF0052CC),
                  foregroundColor: isDarkMode ? Colors.black : Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => _mostrarDialogoFormulario(),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text('Añadir $_tabActual', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold))),
                    const Icon(Icons.add),
                  ],
                ),
              ),
            ),
          
          const SizedBox(height: 16),
          
          // --- LISTA DE USUARIOS ---
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _listaUsuarios.isEmpty
                    ? Center(child: Text('No hay $_tabActual registrados'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        itemCount: _listaUsuarios.length,
                        itemBuilder: (context, index) {
                          final user = _listaUsuarios[index];
                          return GestureDetector(
                            onTap: () {
                              // 🚀 MAGIA AQUÍ: SI ES REPARTIDOR, ABRIMOS SU PANEL DE RESEÑAS
                              if (_tabActual == 'Repartidores') {
                                _mostrarDetallesRepartidor(user);
                              } else {
                                _mostrarDetallesUsuario(user);
                              }
                            },
                            child: Card(
                              color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF0052CC),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              margin: const EdgeInsets.only(bottom: 12),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Row(
                                  children: [
                                    // FOTO DE PERFIL
                                    Container(
                                      width: 50, height: 50,
                                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
                                      clipBehavior: Clip.hardEdge,
                                      // ✅ CÓDIGO OPTIMIZADO
child: user['imagen'] != null && user['imagen'].toString().isNotEmpty
    ? Image.memory(
        base64Decode(user['imagen'].toString().replaceAll(RegExp(r'\s+'), '')), 
        fit: BoxFit.cover,
        cacheWidth: 100, // 🚀 Protege la RAM al hacer scroll en la lista completa
      )
    : const Icon(Icons.person, color: Colors.white),
                                    ),
                                    const SizedBox(width: 16),
                                    
                                    // NOMBRE
                                    Expanded(
                                      child: Text(user['nombre'] ?? 'Sin nombre', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                                    ),
                                    
                                    // BOTONES DE ACCIÓN
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red),
                                          onPressed: () => _confirmarEliminacion(user['id'].toString(), user['nombre']),
                                        ),
                                      ],
                                    )
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}