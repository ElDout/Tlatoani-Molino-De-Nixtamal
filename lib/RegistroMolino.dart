import 'dart:async';
import 'dart:convert';
import 'dart:typed_data'; // 🚀 Añadido para la imagen en bytes
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:molino_app/config.dart';
import 'package:molino_app/Login.dart';

class RegistroMolinoScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final Map<String, dynamic> userData; 

  const RegistroMolinoScreen({
    super.key, 
    required this.onThemeChanged,
    required this.userData,
  });

  @override
  State<RegistroMolinoScreen> createState() => _RegistroMolinoScreenState();
}

class _RegistroMolinoScreenState extends State<RegistroMolinoScreen> {
  final PageController _pageController = PageController();
  bool _isLoading = false;
  bool _isPasswordVisible = false;

  // Controladores
  final TextEditingController _correoController = TextEditingController();
  final TextEditingController _telefonoController = TextEditingController(); 
  final TextEditingController _usuarioController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  
  // PIN Controllers
  final List<TextEditingController> _codigoControllers = List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _codigoFocus = List.generate(4, (_) => FocusNode());

  // Temporizador para reenvío de código
  int _segundosRestantes = 0;
  Timer? _timer;

  // Cámara
  String? _imagenBase64;
  Uint8List? _imagenBytesDecodificados; // 🚀 OPTIMIZACIÓN: Evita tirones al escribir
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    // Pre-llenamos datos si es que el admin los dejó
    if (widget.userData['usuario'] != null) {
      _usuarioController.text = widget.userData['usuario'].toString();
    }
    if (widget.userData['telefono'] != null && widget.userData['telefono'] != 'Sin número') {
      _telefonoController.text = widget.userData['telefono'].toString().replaceAll('+52 ', '');
    }
    
    // Listeners para reconstruir la UI en el último paso
    _correoController.addListener(() => setState(() {}));
    _telefonoController.addListener(() => setState(() {}));
    _usuarioController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pageController.dispose();
    _correoController.dispose();
    _telefonoController.dispose();
    _usuarioController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _timer?.cancel();
    for (var c in _codigoControllers) { c.dispose(); }
    for (var f in _codigoFocus) { f.dispose(); }
    super.dispose();
  }

  void _nextPage() {
    FocusScope.of(context).unfocus();
    _pageController.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
  }

  void _iniciarTemporizador() {
    setState(() => _segundosRestantes = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_segundosRestantes > 0) {
        setState(() => _segundosRestantes--);
      } else {
        timer.cancel();
      }
    });
  }

  // --- PASO 1: ENVIAR CORREO ---
  Future<void> _enviarCodigoCorreo({bool isResend = false}) async {
    final correo = _correoController.text.trim();
    if (!correo.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingresa un correo válido')));
      return;
    }
    
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiHost}/perfil/enviar-codigo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'correo': correo}),
      );
      
      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        _iniciarTemporizador();
        if (isResend) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Código reenviado a tu correo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        } else {
          _nextPage(); 
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error al enviar')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // --- PASO 2: VALIDAR PIN ---
  Future<void> _validarCodigo() async {
    final codigo = _codigoControllers.map((c) => c.text).join();
    if (codigo.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingresa los 4 dígitos completos')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiHost}/validar-codigo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'correo': _correoController.text.trim(),
          'codigo': codigo
        }),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        _timer?.cancel();
        _nextPage(); 
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ Código incorrecto o caducado', style: TextStyle(fontWeight: FontWeight.bold))));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // --- PASO 4: TOMAR FOTO ---
  Future<void> _tomarFotografia() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera, imageQuality: 50);
      if (photo != null) {
        final bytes = await photo.readAsBytes();
        setState(() { 
          _imagenBase64 = base64Encode(bytes); 
          _imagenBytesDecodificados = bytes; // 🚀 Lo guardamos listo para usar
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al acceder a la cámara.')));
    }
  }

  // --- PASO 5: ACTUALIZAR PERFIL EN BD ---
  Future<void> _completarRegistro() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.put(
        Uri.parse('${AppConfig.apiHost}/perfil/completar-empleado'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id': widget.userData['id'],
          'rol': widget.userData['rol'],
          'correo': _correoController.text.trim(),
          'telefono': "+52 ${_telefonoController.text.trim()}", 
          'usuario': _usuarioController.text.trim(),
          'password': _passwordController.text.trim(),
          'imagen': _imagenBase64, 
        }),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Perfil completado con éxito. Por favor inicia sesión.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        
        if (!mounted) return;
        Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => LoginScreen(onThemeChanged: widget.onThemeChanged)), (route) => false);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error', style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión', style: TextStyle(color: Colors.white)), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onSurface),
          onPressed: () {
            if (_pageController.page != null && _pageController.page! > 0) {
              _pageController.previousPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
            } else {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => LoginScreen(onThemeChanged: widget.onThemeChanged)));
            }
          },
        ),
      ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(), 
        children: [
          _buildPaso1(), 
          _buildPaso2(), 
          _buildPaso3(), 
          _buildPaso4(), 
          _buildPaso5(), 
        ],
      ),
    );
  }

  // 1. CORREO
  Widget _buildPaso1() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Ingresa tu correo', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 30),
          const Align(alignment: Alignment.centerLeft, child: Text('Correo', style: TextStyle(fontSize: 14))),
          const SizedBox(height: 8),
          TextField(
            controller: _correoController, 
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 30),
          _isLoading 
            ? const CircularProgressIndicator()
            : ElevatedButton(
                onPressed: () => _enviarCodigoCorreo(isResend: false),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
                child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
          const SizedBox(height: 80), 
        ],
      ),
    );
  }

  // 2. CÓDIGO 4 DÍGITOS (Mismo diseño de borde gris que Registrarse.dart)
  Widget _buildPaso2() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('INTRODUCE EL CODIGO DE 4\nDIGITOS ENVIADO A', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(_correoController.text.toUpperCase(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0052CC))),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(4, (index) => Container(
              width: 50, height: 60,
              decoration: BoxDecoration(border: Border.all(color: Colors.grey, width: 2), borderRadius: BorderRadius.circular(8)),
              child: Center(
                child: TextField(
                  controller: _codigoControllers[index],
                  focusNode: _codigoFocus[index],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  maxLength: 1,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(counterText: "", border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none),
                  onChanged: (val) {
                    if (val.isNotEmpty && index < 3) FocusScope.of(context).requestFocus(_codigoFocus[index+1]);
                    if (val.isEmpty && index > 0) FocusScope.of(context).requestFocus(_codigoFocus[index-1]);
                  },
                ),
              ),
            )),
          ),
          const SizedBox(height: 30),
          _isLoading
            ? const CircularProgressIndicator()
            : ElevatedButton(
                onPressed: _validarCodigo,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
                child: const Text('VALIDAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: _segundosRestantes == 0 ? () => _enviarCodigoCorreo(isResend: true) : null,
            child: Text(
              _segundosRestantes > 0 ? 'Reenviar despues de $_segundosRestantes segundos' : 'Reenviar código', 
              style: TextStyle(decoration: TextDecoration.underline, color: _segundosRestantes > 0 ? Colors.grey : const Color(0xFF0052CC), fontSize: 13)
            ),
          ),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  // 3. TELÉFONO, USUARIO Y CONTRASEÑA
  Widget _buildPaso3() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 40.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 60),
          const Text('Crea un Usuario y Contraseña', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900), textAlign: TextAlign.center),
          const SizedBox(height: 40),
          
          const Text('Numero de telefono', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            controller: _telefonoController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              prefixText: '+52 ', 
              prefixStyle: TextStyle(fontWeight: FontWeight.bold)
            ),
          ),
          const SizedBox(height: 20),

          const Text('Usuario', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _usuarioController),
          const Text('Con este usuario iniciaras sesión', style: TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.right),
          const SizedBox(height: 20),
          
          const Text('Contraseña', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordController, 
            obscureText: !_isPasswordVisible,
            decoration: InputDecoration(
              suffixIcon: IconButton(icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible)),
            ),
          ),
          const SizedBox(height: 20),
          
          const Text('Confirma Contraseña', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmPasswordController, 
            obscureText: !_isPasswordVisible,
            decoration: InputDecoration(
              suffixIcon: IconButton(icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible)),
            ),
          ),
          
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: () {
              if (_telefonoController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingresa un número de teléfono')));
                return;
              }
              if (_usuarioController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingresa un nombre de usuario')));
                return;
              }
              if (_passwordController.text.isEmpty || _passwordController.text != _confirmPasswordController.text) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Las contraseñas no coinciden o están vacías')));
                return;
              }
              _nextPage();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
            child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 4. FOTOGRAFÍA
  Widget _buildPaso4() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('TOMA UNA FOTOGRAFIA\nDE TU ROSTRO', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 50),
          GestureDetector(
            onTap: _tomarFotografia,
            child: Container(
              width: 200, height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF003399),
                shape: BoxShape.circle,
                // 🚀 FIX: Usamos el ResizeImage para que la app no explote
                image: _imagenBytesDecodificados != null 
                    ? DecorationImage(
                        image: ResizeImage(MemoryImage(_imagenBytesDecodificados!), width: 250), 
                        fit: BoxFit.cover
                      ) 
                    : null,
              ),
              child: _imagenBytesDecodificados == null ? const Icon(Icons.camera_alt, color: Colors.white, size: 60) : null,
            ),
          ),
          const SizedBox(height: 50),
          ElevatedButton(
            onPressed: () {
              if (_imagenBase64 == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor, tómate una foto.')));
                return;
              }
              _nextPage();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
            child: const Text('ACEPTAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // 5. RESUMEN FINAL
  Widget _buildPaso5() {
    final String nombre = widget.userData['nombre'] ?? widget.userData['nombres'] ?? 'Usuario';
    final String rol = widget.userData['rol'] ?? 'Empleado';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('FELICIDADES YA ESTAS A UN\nPASO MAS...', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 30),
          CircleAvatar(
            radius: 80, 
            backgroundColor: const Color(0xFF003399),
            // 🚀 FIX: Usamos el ResizeImage también aquí
            backgroundImage: _imagenBytesDecodificados != null 
                ? ResizeImage(MemoryImage(_imagenBytesDecodificados!), width: 250) 
                : null,
            child: _imagenBytesDecodificados == null ? const Icon(Icons.person, size: 50, color: Colors.white) : null,
          ),
          const SizedBox(height: 30),
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nombre: $nombre', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text('Numero de telefono: +52 ${_telefonoController.text}', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text('Correo: ${_correoController.text}', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text('Usuario: ${_usuarioController.text}', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text('Rol: ${rol[0].toUpperCase()}${rol.substring(1)}', style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 50),
          _isLoading
              ? const CircularProgressIndicator()
              : ElevatedButton(
                  onPressed: _completarRegistro,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
                  child: const Text('Registrarse', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
        ],
      ),
    );
  }
}