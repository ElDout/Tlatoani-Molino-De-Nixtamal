import 'dart:convert';
import 'dart:typed_data'; // 🚀 Añadido para mantener la imagen en bytes
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:molino_app/config.dart';
import 'package:molino_app/Login.dart';

class PerfilScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  const PerfilScreen({super.key, required this.onThemeChanged});

  @override
  State<PerfilScreen> createState() => _PerfilScreenState();
}

class _PerfilScreenState extends State<PerfilScreen> {
  String nombre = "Cargando...";
  String correo = "Cargando...";
  String usuario = "Cargando...";
  String telefono = "Cargando...";
  
  // 🚀 VARIABLES OPTIMIZADAS PARA LA IMAGEN
  String? imagenBase64;
  Uint8List? _imagenBytesDecodificados; 
  
  int? userId;
  String rol = "";
  double _promedio = 0.0;
  int _totalViajes = 0;
  List<dynamic> _comentarios = [];
  bool _cargandoResenas = false;

  @override
  void initState() {
    super.initState();
    _cargarPerfil();
  }

  Future<void> _cargarPerfil() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 🚀 Decodificamos la imagen una sola vez en el inicio
    String? base64Str = prefs.getString('userImage');
    Uint8List? bytesLimpios;
    if (base64Str != null && base64Str.isNotEmpty) {
      try {
        bytesLimpios = base64Decode(base64Str.replaceAll(RegExp(r'\s+'), ''));
      } catch (e) {
        bytesLimpios = null;
      }
    }

    setState(() {
      userId = prefs.getInt('userId');
      rol = prefs.getString('userRole') ?? 'cliente';
      nombre = prefs.getString('userName') ?? 'Usuario';
      usuario = prefs.getString('userUser') ?? prefs.getString('userName') ?? 'Usuario';
      telefono = prefs.getString('userPhone') ?? 'Sin teléfono';
      
      String? correoGuardado = prefs.getString('userEmail');
      if (correoGuardado == null || correoGuardado.trim().isEmpty) {
        correo = "Agrega Correo";
      } else {
        correo = correoGuardado;
      }
      
      imagenBase64 = base64Str;
      _imagenBytesDecodificados = bytesLimpios; // 🔥 Lo guardamos para el UI
    });
    
    // 🚀 FASE 4: SI ES REPARTIDOR, JALAMOS SUS RESEÑAS
    if (rol == 'repartidor') {
      _cargarResenas();
    }
  }

  // 🚀 FASE 4: FUNCIÓN QUE CONSULTA EL PROMEDIO AL BACKEND
  Future<void> _cargarResenas() async {
    setState(() => _cargandoResenas = true);
    try {
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/repartidores/$userId/resenas'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true && mounted) {
          setState(() {
            _promedio = double.tryParse(data['promedio'].toString()) ?? 0.0;
            // 👇 ESTA ES LA MAGIA QUE ARREGLA EL CERO 👇
            _totalViajes = int.tryParse(data['total_viajes'].toString()) ?? 0;
            _comentarios = data['comentarios'] ?? [];
          });
        }
      }
    } catch (e) {
      debugPrint("Error cargando reseñas: $e");
    } finally {
      if (mounted) setState(() => _cargandoResenas = false);
    }
  }
  
  // --- ACTUALIZACIONES DIRECTAS (Nombre y Teléfono) ---
  void _mostrarDialogoDirecto(String titulo, String campoClave, String valorActual) {
    TextEditingController controller = TextEditingController(text: valorActual);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Editar $titulo'),
        content: TextField(
          controller: controller,
          keyboardType: campoClave == 'telefono' ? TextInputType.phone : TextInputType.text,
          decoration: InputDecoration(hintText: 'Nuevo $titulo'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _guardarCambioEnBD(campoClave, controller.text);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  Future<void> _guardarCambioEnBD(String campo, String valor, {String? codigo, String? correoConfirmacion}) async {
    try {
      final response = await http.put(
        Uri.parse('${AppConfig.apiHost}/perfil/actualizar-campo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id': userId, 'rol': rol, 'campo': campo, 'valor': valor, 
          'codigo': codigo, 'correoConfirmacion': correoConfirmacion
        }),
      );
      final data = jsonDecode(response.body);
      if (data['success']) {
        final prefs = await SharedPreferences.getInstance();
        if (campo == 'nombre') { prefs.setString('userName', valor); setState(() => nombre = valor); }
        if (campo == 'telefono') { prefs.setString('userPhone', valor); setState(() => telefono = valor); }
        if (campo == 'correo') { prefs.setString('userEmail', valor); setState(() => correo = valor); }
        if (campo == 'usuario') { prefs.setString('userUser', valor); setState(() => usuario = valor); }
        
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$campo actualizado con éxito')));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'])));
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  // --- FLUJO PARA CORREO Y USUARIO (Con PIN) ---
  Future<void> _enviarCodigoA(String emailDestino) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiHost}/perfil/enviar-codigo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'correo': emailDestino}),
      );
      final data = jsonDecode(response.body);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'])));
    } catch (e) { debugPrint("Error al pedir código: $e"); }
  }

  void _iniciarCambioCorreo() {
    TextEditingController emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cambiar Correo'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(hintText: 'Ingresa tu nuevo correo'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              String nuevoCorreo = emailController.text.trim();
              if (nuevoCorreo.isEmpty) return;
              Navigator.pop(context);
              await _enviarCodigoA(nuevoCorreo);
              _pedirCodigoValidacion(campo: 'correo', correoDestino: nuevoCorreo, valorNuevo: nuevoCorreo);
            },
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }

  void _iniciarCambioUsuario() async {
    if (correo == "Agrega Correo") {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registra un correo primero para poder validar tu identidad.')));
      return;
    }
    await _enviarCodigoA(correo);
    _pedirCodigoValidacion(campo: 'usuario', correoDestino: correo);
  }

  void _pedirCodigoValidacion({required String campo, required String correoDestino, String? valorNuevo}) {
    TextEditingController codeController = TextEditingController();
    TextEditingController valueController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verificación de Seguridad'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Ingresa el código de 4 dígitos enviado a:\n$correoDestino', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            TextField(controller: codeController, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'PIN de seguridad')),
            if (campo == 'usuario') ...[
              const SizedBox(height: 15),
              TextField(controller: valueController, decoration: const InputDecoration(hintText: 'Nuevo nombre de usuario')),
            ],
            if (campo == 'password_forgot') ...[
              const SizedBox(height: 15),
              TextField(controller: valueController, obscureText: true, decoration: const InputDecoration(hintText: 'Nueva Contraseña')),
            ]
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              if (campo == 'password_forgot') {
                await _resetPasswordConCodigo(correoDestino, codeController.text.trim(), valueController.text.trim());
              } else {
                String valorFinal = campo == 'correo' ? valorNuevo! : valueController.text.trim();
                await _guardarCambioEnBD(campo, valorFinal, codigo: codeController.text.trim(), correoConfirmacion: correoDestino);
              }
            },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }

  // --- CONTRASEÑAS ---
  void _mostrarDialogoPassword() {
    TextEditingController oldPassController = TextEditingController();
    TextEditingController newPassController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cambiar Contraseña'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: oldPassController, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña Actual')),
            const SizedBox(height: 10),
            TextField(controller: newPassController, obscureText: true, decoration: const InputDecoration(labelText: 'Nueva Contraseña')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              if (correo == "Agrega Correo") {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Necesitas registrar un correo para recuperar tu contraseña.')));
                return;
              }
              _enviarCodigoA(correo);
              _pedirCodigoValidacion(campo: 'password_forgot', correoDestino: correo);
            },
            child: const Text('Olvidé mi contraseña', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _cambiarPasswordClasico(oldPassController.text, newPassController.text);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  Future<void> _cambiarPasswordClasico(String oldPass, String newPass) async {
    try {
      final response = await http.put(
        Uri.parse('${AppConfig.apiHost}/perfil/cambiar-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id': userId, 'rol': rol, 'oldPassword': oldPass, 'newPassword': newPass}),
      );
      final data = jsonDecode(response.body);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'])));
    } catch (e) { debugPrint("Error: $e"); }
  }

  Future<void> _resetPasswordConCodigo(String email, String codigo, String nuevaPass) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiHost}/perfil/reset-password-codigo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'correo': email, 'codigo': codigo, 'nuevaPassword': nuevaPass}),
      );
      final data = jsonDecode(response.body);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'])));
    } catch (e) { debugPrint("Error: $e"); }
  }

  // --- CÁMARA Y CERRAR SESIÓN (Ya estaban listas) ---
  Future<void> _tomarFoto() async {
    final XFile? photo = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 50);
    if (photo != null) {
      final base64Image = base64Encode(await photo.readAsBytes());
      
      // 🚀 FIX: Decodificamos y guardamos la variable optimizada al instante
      setState(() {
        imagenBase64 = base64Image;
        _imagenBytesDecodificados = base64Decode(base64Image);
      });
      
      await http.put(
        Uri.parse('${AppConfig.apiHost}/perfil/actualizar-imagen'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id': userId, 'rol': rol, 'imagen': base64Image}),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('userImage', base64Image);
    }
  }

  Future<void> _cerrarSesion() async {
    final prefs = await SharedPreferences.getInstance(); await prefs.clear(); 
    if (mounted) Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => LoginScreen(onThemeChanged: widget.onThemeChanged)), (route) => false);
  }

  Widget _buildPerfilItem(String titulo, String valor, VoidCallback onEdit, {bool resaltaVacio = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 24.0),
      child: Row(
        children: [
          Text('$titulo: ', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          Expanded(child: Text(valor, style: TextStyle(fontSize: 16, color: resaltaVacio ? Colors.redAccent : null, fontStyle: resaltaVacio ? FontStyle.italic : FontStyle.normal))),
          IconButton(icon: const Icon(Icons.edit, size: 20, color: Colors.grey), onPressed: onEdit),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        leading: IconButton(icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onSurface), onPressed: () => Navigator.pop(context)),
      ),
      body: SafeArea(
        child: SingleChildScrollView( 
          child: Column(
            children: [
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _tomarFoto,
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Container(
                      width: 120, height: 120,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0052CC), 
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                      clipBehavior: Clip.hardEdge,
                      // 🚀 FIX: Usamos la imagen decodificada con un cacheWidth
                      child: _imagenBytesDecodificados != null
                          ? Image.memory(
                              _imagenBytesDecodificados!, 
                              fit: BoxFit.cover,
                              cacheWidth: 200, // Cuidamos la memoria
                            )
                          : const Icon(Icons.person, size: 80, color: Colors.white),
                    ),
                    Container(padding: const EdgeInsets.all(6), decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle), child: const Icon(Icons.camera_alt, color: Colors.white, size: 20))
                  ],
                ),
              ),
              const SizedBox(height: 30),
              _buildPerfilItem('Nombre', nombre, () => _mostrarDialogoDirecto('Nombre', 'nombre', nombre)), 
              _buildPerfilItem('Teléfono', telefono, () => _mostrarDialogoDirecto('Teléfono', 'telefono', telefono == 'Sin teléfono' ? '' : telefono)),
              _buildPerfilItem('Correo', correo, _iniciarCambioCorreo, resaltaVacio: correo == "Agrega Correo"),
              _buildPerfilItem('Usuario', usuario, _iniciarCambioUsuario),
              _buildPerfilItem('Contraseña', '********', _mostrarDialogoPassword),
              // 🚀 FASE 4: EL MURO DEL REPARTIDOR
              if (rol == 'repartidor') ...[
                const SizedBox(height: 20),
                const Divider(thickness: 1),
                const SizedBox(height: 10),
                const Text('Mi Desempeño', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                if (_cargandoResenas)
                  const CircularProgressIndicator()
                else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.star, color: Colors.amber, size: 45),
                      const SizedBox(width: 8),
                      Text(_promedio.toStringAsFixed(1), style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Text('($_totalViajes viajes)', style: const TextStyle(color: Colors.grey, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (_comentarios.isNotEmpty) ...[
                    const Align(
                      alignment: Alignment.centerLeft, 
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24.0),
                        child: Text('Comentarios Recientes:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      )
                    ),
                    const SizedBox(height: 10),
                    Container(
                      height: 220, 
                      margin: const EdgeInsets.symmetric(horizontal: 20.0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.withOpacity(0.3))
                      ),
                      child: ListView.builder(
                        itemCount: _comentarios.length,
                        itemBuilder: (context, index) {
                          final c = _comentarios[index];
                          return ListTile(
                            leading: const Icon(Icons.format_quote, color: Colors.blueAccent),
                            title: Text('"${c['comentario_repartidor']}"', style: const TextStyle(fontStyle: FontStyle.italic)),
                            subtitle: Text('- ${c['nombre_quien_califica'] ?? 'Alguien'} (⭐ ${c['calificacion_repartidor']})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          );
                        },
                      ),
                    ),
                  ] else 
                    const Text('Aún no tienes comentarios escritos.', style: TextStyle(color: Colors.grey)),
                ],
                const SizedBox(height: 10),
                const Divider(thickness: 1),
                const SizedBox(height: 10),
              ],
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Modo Oscuro', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Switch(value: Theme.of(context).brightness == Brightness.dark, onChanged: (v) => widget.onThemeChanged(v ? ThemeMode.dark : ThemeMode.light)),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: _cerrarSesion,
                    icon: const Icon(Icons.logout),
                    label: const Text('Cerrar sesión', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }
}