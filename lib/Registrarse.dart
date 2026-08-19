import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart'; // 📸 LIBRERÍA DE LA CÁMARA
import 'package:molino_app/config.dart';
import 'dart:typed_data';

const String kGoogleApiKey = "AIzaSyArmA4eDBu5Qy_PedPFtq0u3y1CEdPKAR0";

class RegistrarseScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  const RegistrarseScreen({super.key, required this.onThemeChanged});

  @override
  State<RegistrarseScreen> createState() => _RegistrarseScreenState();
}

class _RegistrarseScreenState extends State<RegistrarseScreen> {
  final PageController _pageController = PageController();
  
  bool _isPasswordVisible = false;
  bool _isLoading = false;
  
  // Controladores
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _telefonoController = TextEditingController();
  final TextEditingController _correoController = TextEditingController();
  final TextEditingController _usuarioController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _empresaController = TextEditingController();
  final TextEditingController _localController = TextEditingController();
  final TextEditingController _direccionController = TextEditingController();
  
  final List<TextEditingController> _codigoControllers = List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _codigoFocus = List.generate(4, (_) => FocusNode());

  // Mapa
  GoogleMapController? _mapController;
  LatLng _posicionActual = const LatLng(19.432608, -99.133209); 
  Set<Marker> _marcadores = {};

  Timer? _debounce;
  String? _sessionToken;
  List<Map<String, dynamic>> _sugerencias = [];
  bool _cargandoSugerencias = false;
  final FocusNode _direccionFocusNode = FocusNode();

  // 📸 VARIABLES DE LA CÁMARA
  String? _imagenBase64;
  Uint8List? _imagenBytesDecodificados;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _direccionController.addListener(_onDireccionChanged);
    _direccionFocusNode.addListener(() {
      if (!_direccionFocusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) setState(() { _sugerencias = []; });
        });
      }
    });

    // 🔒 Esto asegura que cualquier cambio en los textos se guarde en tiempo real
    _nombreController.addListener(() => setState(() {}));
    _telefonoController.addListener(() => setState(() {}));
    _correoController.addListener(() => setState(() {}));
    _usuarioController.addListener(() => setState(() {}));
    _empresaController.addListener(() => setState(() {}));
    _localController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pageController.dispose();
    _direccionController.removeListener(_onDireccionChanged);
    _nombreController.dispose();
    _telefonoController.dispose();
    _correoController.dispose();
    _usuarioController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _empresaController.dispose();
    _localController.dispose();
    _direccionController.dispose();
    _mapController?.dispose();
    _debounce?.cancel();
    _direccionFocusNode.dispose();
    for (var c in _codigoControllers) { c.dispose(); }
    for (var f in _codigoFocus) { f.dispose(); }
    super.dispose();
  }

  // --- 🚀 NAVEGACIÓN Y ACTUALIZACIÓN DE DATOS ---
  void _nextPage() {
    FocusScope.of(context).unfocus(); 
    _pageController.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
  }

  void _prevPage() {
    FocusScope.of(context).unfocus();
    _pageController.previousPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
  }

  // --- 📸 TOMAR FOTOGRAFÍA O GALERÍA (La solución definitiva) ---
  Future<void> _seleccionarImagen(ImageSource source) async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: source, 
        imageQuality: 50, 
      );
      
      if (photo != null) {
        final bytes = await photo.readAsBytes();
        setState(() {
          _imagenBase64 = base64Encode(bytes);
          _imagenBytesDecodificados = bytes;
        });
      }
    } catch (e) {
      debugPrint("Error al obtener foto: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al acceder a la cámara o galería.')));
      }
    }
  }

  void _mostrarOpcionesImagen() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFF0052CC)),
              title: const Text('Tomar Foto', style: TextStyle(fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(context);
                _seleccionarImagen(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Color(0xFF0052CC)),
              title: const Text('Elegir de Galería', style: TextStyle(fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(context);
                _seleccionarImagen(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- 📧 ENVIAR CORREO CON CÓDIGO (Corregido para Reenvíos) ---
  Future<void> _enviarCodigoCorreo({bool isResend = false}) async {
    final correo = _correoController.text.trim();
    if (!correo.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingresa un correo válido')));
      return;
    }
    
    setState(() => _isLoading = true);
    try {
      final url = Uri.parse('${AppConfig.apiHost}/perfil/enviar-codigo');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'correo': correo}),
      );
      
      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        if (isResend) {
          // 🚨 Si es reenvío, SOLO mostramos el mensaje, NO cambiamos de página
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Código reenviado a tu correo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        } else {
          // Si es el primer envío, avanzamos a la pantalla del PIN
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

  // --- 🔐 VALIDAR CÓDIGO DE 4 DÍGITOS ---
  Future<void> _validarCodigo() async {
    final codigo = _codigoControllers.map((c) => c.text).join();
    if (codigo.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingresa los 4 dígitos completos')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final url = Uri.parse('${AppConfig.apiHost}/validar-codigo');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'correo': _correoController.text.trim(),
          'codigo': codigo
        }),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        _nextPage(); // Si es correcto, pasamos a crear Usuario/Pass
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ Código incorrecto o caducado', style: TextStyle(fontWeight: FontWeight.bold))));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // --- 📝 REGISTRO FINAL ---
  Future<void> _enviarRegistro() async {
    setState(() => _isLoading = true);
    try {
      final url = Uri.parse('${AppConfig.apiHost}/registro');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'nombre_propietario': _nombreController.text.trim(),
          'empresa': _empresaController.text.trim(),
          'local': _localController.text.trim(),
          'correo': _correoController.text.trim(),
          'telefono': "+52 ${_telefonoController.text.trim()}",
          'direccion': _direccionController.text.trim(),
          'latitud': _posicionActual.latitude,
          'longitud': _posicionActual.longitude,
          'usuario': _usuarioController.text.trim(),
          'password': _passwordController.text.trim(),
          'imagen': _imagenBase64, 
        }),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Registro exitoso. Espera tu aprobación.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        Navigator.pop(context); 
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error', style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión', style: TextStyle(color: Colors.white)), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- LÓGICA DEL MAPA ---
  Future<void> _obtenerUbicacionActual() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    LatLng latLng = LatLng(position.latitude, position.longitude);
    _actualizarMapa(latLng);
    _obtenerDireccionDesdeGoogle(latLng);
  }

  Future<void> _obtenerDireccionDesdeGoogle(LatLng latLng) async {
    try {
      final url = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'latlng': '${latLng.latitude},${latLng.longitude}', 'language': 'es', 'key': kGoogleApiKey,
      });
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          setState(() { _direccionController.text = data['results'][0]['formatted_address']; });
        }
      }
    } catch (e) {}
  }

  void _onDireccionChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      final query = _direccionController.text;
      if (query.length > 2 && _direccionFocusNode.hasFocus) {
        if(_sessionToken == null) setState(() { _sessionToken = DateTime.now().millisecondsSinceEpoch.toString(); });
        _buscarSugerencias(query);
      } else if (query.isEmpty) {
        setState(() { _sugerencias = []; _sessionToken = null; });
      }
    });
  }

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
        if (data['status'] == 'OK') {
          if (mounted) setState(() { _sugerencias = (data['predictions'] as List).map((p) => {'texto': p['description'], 'place_id': p['place_id']}).toList(); });
        } else {
          if (mounted) setState(() { _sugerencias = []; });
        }
      }
    } catch (e) {
      if (mounted) setState(() { _sugerencias = []; }); 
    } finally {
      if (mounted) setState(() { _cargandoSugerencias = false; }); 
    }
  }

  Future<void> _seleccionarLugar(String placeId, String descripcion) async {
    _direccionFocusNode.unfocus();
    setState(() { _direccionController.text = descripcion; _sugerencias = []; });
    try {
      final url = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
        'place_id': placeId, 'fields': 'geometry', 'key': kGoogleApiKey, 'sessiontoken': _sessionToken!,
      });
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK') {
          final location = data['result']['geometry']['location'];
          _actualizarMapa(LatLng(location['lat'], location['lng']));
        }
      }
    } catch (e) {} finally { setState(() { _sessionToken = null; }); }
  }

  void _actualizarMapa(LatLng latLng) {
    setState(() {
      _posicionActual = latLng;
      _marcadores = {Marker(markerId: const MarkerId("ubicacion_elegida"), position: latLng)};
    });
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(latLng, 16));
  }

  // --- UI WIDGETS ---
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
              _prevPage();
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(), // 🚫 Bloquea el scroll manual
        children: [
          _buildPaso1(), // Nombre, Foto y Teléfono
          _buildPaso2(), // Mini preview 1
          _buildPaso3(), // Correo
          _buildPaso4(), // Código 4 dígitos
          _buildPaso5(), // Usuario y Contraseña
          _buildPaso6(), // Empresa, Local, Mapa
          _buildPaso7(), // Preview Final y Registrarse
        ],
      ),
    );
  }

  // 1. FOTO, NOMBRE Y TELÉFONO
  Widget _buildPaso1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: _mostrarOpcionesImagen, // 📸 Muestra el menú de Cámara/Galería
            child: CircleAvatar(
              radius: 80,
              backgroundColor: const Color(0xFF003399),
              backgroundImage: _imagenBytesDecodificados != null 
    ? ResizeImage(MemoryImage(_imagenBytesDecodificados!), width: 250) // 🚀 Cero lag al teclear
    : null,
              child: _imagenBase64 == null 
                  ? const Icon(Icons.camera_alt, color: Colors.white, size: 50) 
                  : null, 
            ),
          ),
          const SizedBox(height: 10),
          const Text('Toca para añadir foto', style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 30),
          const Align(alignment: Alignment.centerLeft, child: Text('Nombre:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          const SizedBox(height: 8),
          TextField(
            controller: _nombreController,
          ),
          const SizedBox(height: 20),
          
          AnimatedSize(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOut,
            child: _nombreController.text.trim().isNotEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Numero de telefono', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _telefonoController,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(prefixText: '+52 ', prefixStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          InkWell(
                            onTap: () {
                              if (_telefonoController.text.trim().isNotEmpty) _nextPage();
                            },
                            child: const CircleAvatar(
                              backgroundColor: Color(0xFF0052CC),
                              radius: 25,
                              child: Icon(Icons.verified, color: Colors.white, size: 30),
                            ),
                          )
                        ],
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // 2. MINI PREVIEW 1
  Widget _buildPaso2() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 70, 
            backgroundColor: const Color(0xFF003399),
            backgroundImage: _imagenBytesDecodificados != null 
              ? ResizeImage(MemoryImage(_imagenBytesDecodificados!), width: 250)
              : null,
            child: _imagenBase64 == null ? const Icon(Icons.person, size: 50, color: Colors.white) : null,
          ),
          const SizedBox(height: 30),
          Text('Nombre: ${_nombreController.text}', style: const TextStyle(fontSize: 16)),
          Text('Numero de telefono: +52 ${_telefonoController.text}', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 30),
          const Text('Muy bien. Asi va\nquedando tu perfil.', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _nextPage,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
            child: const Text('TERMINAR REGISTRO', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 20),
          const Text('Vamos con los\ntoques finales', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _prevPage,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
            child: const Text('Editar informacion'),
          ),
        ],
      ),
    );
  }

  // 3. CORREO
  Widget _buildPaso3() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Ingresa tu correo', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          const Align(alignment: Alignment.centerLeft, child: Text('Correo', style: TextStyle(fontSize: 14))),
          const SizedBox(height: 8),
          TextField(controller: _correoController, keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 30),
          _isLoading 
            ? const CircularProgressIndicator()
            : ElevatedButton(
                onPressed: () => _enviarCodigoCorreo(isResend: false), // 📧 Primer Envío
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
                child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
        ],
      ),
    );
  }

  // 4. CÓDIGO 4 DÍGITOS
  Widget _buildPaso4() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('INTRODUCE EL CODIGO DE 4\nDIGITOS ENVIADO A', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(_correoController.text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0052CC))),
          const SizedBox(height: 30),
          Row(
  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  children: List.generate(4, (index) => Container(
    width: 50, height: 60,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.white, // Fondo limpio para que contraste
      border: Border.all(color: const Color(0xFF0052CC), width: 2), 
      borderRadius: BorderRadius.circular(8)
    ),
    child: TextField(
      controller: _codigoControllers[index],
      focusNode: _codigoFocus[index],
      textAlign: TextAlign.center,
      textAlignVertical: TextAlignVertical.center, // 🔥 Centrado perfecto
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black), // Color de número asegurado
      maxLength: 1,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        counterText: "", 
        border: InputBorder.none, // 🔥 Quita la raya molesta
        enabledBorder: InputBorder.none, 
        focusedBorder: InputBorder.none,
        isDense: true, // 🔥 Compacta el widget
        contentPadding: EdgeInsets.zero, // 🔥 Hace que el número sea visible
      ),
      onChanged: (val) {
        if (val.isNotEmpty) {
          if (index < 3) {
            FocusScope.of(context).requestFocus(_codigoFocus[index+1]);
          } else {
            _codigoFocus[index].unfocus();
          }
        } else {
          if (index > 0) {
            FocusScope.of(context).requestFocus(_codigoFocus[index-1]);
          }
        }
      },
    ),
  )),
),
          const SizedBox(height: 30),
          _isLoading
            ? const CircularProgressIndicator()
            : ElevatedButton(
                onPressed: _validarCodigo, // 🔐 Verifica con el servidor
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
                child: const Text('VALIDAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () => _enviarCodigoCorreo(isResend: true), // 🔁 Reenvío Seguro
            child: const Text('Reenviar código', style: TextStyle(decoration: TextDecoration.underline, color: Colors.grey)),
          )
        ],
      ),
    );
  }

  // 5. USUARIO Y CONTRASEÑA
  Widget _buildPaso5() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 50),
          const Text('Crea un Usuario y Contraseña', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 30),
          const Text('Usuario', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _usuarioController),
          const Text('Con este usuario iniciaras sesión', style: TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.right),
          const SizedBox(height: 20),
          const Text('Contraseña', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordController, obscureText: !_isPasswordVisible,
            decoration: InputDecoration(suffixIcon: IconButton(icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible))),
          ),
          const SizedBox(height: 20),
          const Text('Confirma Contraseña', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmPasswordController, obscureText: !_isPasswordVisible,
            decoration: InputDecoration(suffixIcon: IconButton(icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible))),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: () {
              if (_passwordController.text != _confirmPasswordController.text) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Las contraseñas no coinciden')));
              } else if (_usuarioController.text.isNotEmpty) {
                _nextPage();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
            child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 6. DATOS DE EMPRESA Y UBICACIÓN
  Widget _buildPaso6() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Nos gustaria saber mas', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 30),
          const Text('Empresa', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _empresaController),
          const SizedBox(height: 16),
          const Text('Nombre del Local', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(controller: _localController),
          const SizedBox(height: 20),
          
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Ubicación', style: TextStyle(fontSize: 14)),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _obtenerUbicacionActual,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(children: [
                          Icon(Icons.location_on, color: Color(0xFF0052CC), size: 30),
                          SizedBox(width: 8),
                          Text('Dirección', style: TextStyle(fontSize: 14)),
                        ]),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _direccionController,
                          focusNode: _direccionFocusNode,
                          style: const TextStyle(fontSize: 12),
                          onSubmitted: (value) { setState(() { _sugerencias = []; }); _direccionFocusNode.unfocus(); },
                        ),
                        if (_cargandoSugerencias || _sugerencias.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(top: 4.0),
                            constraints: const BoxConstraints(maxHeight: 160),
                            decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(8)),
                            child: _cargandoSugerencias
                                ? const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()))
                                : Material( 
                                    color: Colors.transparent,
                                    child: ListView.builder(
                                      padding: EdgeInsets.zero, shrinkWrap: true, itemCount: _sugerencias.length,
                                      itemBuilder: (context, index) {
                                        return ListTile(
                                          title: Text(_sugerencias[index]['texto'], maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                          onTap: () => _seleccionarLugar(_sugerencias[index]['place_id'], _sugerencias[index]['texto']),
                                        );
                                      },
                                    ),
                                  ),
                          ),
                      ],
                    )
                  ],
                ),
              ),
              const SizedBox(width: 16), 
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Mapa', style: TextStyle(fontSize: 14)),
                    const SizedBox(height: 8),
                    Container(
                      height: 100, 
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF0052CC), width: 2), borderRadius: BorderRadius.circular(8.0)),
                      clipBehavior: Clip.hardEdge, 
                      child: AbsorbPointer(
                        child: GoogleMap(
                          initialCameraPosition: CameraPosition(target: _posicionActual, zoom: 15),
                          markers: _marcadores, mapType: MapType.normal, zoomControlsEnabled: false, myLocationButtonEnabled: false,
                          onMapCreated: (GoogleMapController controller) { _mapController = controller; },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 50),
          ElevatedButton(
            onPressed: _nextPage,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
            child: const Text('CONTINUAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 7. PREVIEW FINAL Y ENVIAR
  Widget _buildPaso7() {
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
                Text('Nombre: ${_nombreController.text}', style: const TextStyle(fontSize: 14)),
                Text('Numero de telefono: +52 ${_telefonoController.text}', style: const TextStyle(fontSize: 14)),
                Text('Correo: ${_correoController.text}', style: const TextStyle(fontSize: 14)),
                Text('Usuario: ${_usuarioController.text}', style: const TextStyle(fontSize: 14)),
                Text('Empresa: ${_empresaController.text}', style: const TextStyle(fontSize: 14)),
                Text('Nombre del Local: ${_localController.text}', style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 10),
                const Text('Ubicación:', style: TextStyle(fontSize: 14)),
                Text(_direccionController.text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 10),
                const Text('Mapa', style: TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                Container(
                  height: 100, width: 120,
                  decoration: BoxDecoration(border: Border.all(color: const Color(0xFF0052CC), width: 2), borderRadius: BorderRadius.circular(8.0)),
                  clipBehavior: Clip.hardEdge, 
                  child: AbsorbPointer(
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(target: _posicionActual, zoom: 14),
                      markers: _marcadores, mapType: MapType.normal, zoomControlsEnabled: false,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          _isLoading
              ? const CircularProgressIndicator()
              : ElevatedButton(
                  onPressed: _enviarRegistro,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
                  child: const Text('ENVIAR SOLICITUD', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
          const SizedBox(height: 10),
          const Text('Te llegara un correo o\nnotificacion cuando tu\nregistro sea autorizado*', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}