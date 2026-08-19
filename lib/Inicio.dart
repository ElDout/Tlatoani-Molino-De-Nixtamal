import 'package:flutter/material.dart';
import 'package:molino_app/Login.dart';
import 'package:molino_app/Registrarse.dart';

class InicioScreen extends StatelessWidget {
  final Function(ThemeMode) onThemeChanged;
  
  const InicioScreen({super.key, required this.onThemeChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorAzul = const Color(0xFF0052CC);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 🖼️ PLACEHOLDER DEL FONDO (Aquí pondrás la foto del nixtamal después)
          Container(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            // child: Image.asset('assets/fondo_nixtamal.jpg', fit: BoxFit.cover),
          ),
          
          // 📦 CONTENIDO PRINCIPAL
          SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.1),
                  
                  // LOGO
                  Center(
                    child: Image.asset(
                      'assets/fulllogo_transparent_nobuffer.png',
                      height: 180,
                      cacheHeight: 400, // 🚀 MAGIA PURA: Evita que la RAM explote al abrir la app
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 50),
                  
                  // CLIENTE
                  Text('¿ Eres nuestro cliente ?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorAzul,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => RegistrarseScreen(onThemeChanged: onThemeChanged)));
                    },
                    child: const Text('¡REGISTRATE AQUI!', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  
                  const SizedBox(height: 40),
                  
                  // TRABAJADOR
                  Text('¿ Trabajas con nosotros ?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorAzul,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => LoginScreen(onThemeChanged: onThemeChanged)));
                    },
                    child: const Text('¡INICIA SESION AQUI!', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  
                  const SizedBox(height: 60),
                  
                  // LOGIN ALTERNATIVO
                  Text('Si ya tienes cuenta', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
                  TextButton(
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => LoginScreen(onThemeChanged: onThemeChanged)));
                    },
                    child: Text(
                      'INICIAR SESION',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: colorAzul, decoration: TextDecoration.underline, decorationColor: colorAzul, decorationThickness: 2),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}