const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
const bcrypt = require('bcrypt');
const nodemailer = require('nodemailer');
const crypto = require('crypto');
require('dotenv').config();
const http = require('http'); 
const { Server } = require('socket.io');
const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const serviceAccount = require('./firebase-admin-key.json'); 

// Inicializamos directo, sin el if
initializeApp({
    credential: cert(serviceAccount)
});

const pool = new Pool({
    user: process.env.DB_USER,
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    password: process.env.DB_PASSWORD,
    port: process.env.DB_PORT,
});
const app = express();
app.set('trust proxy', 1);
app.use(cors());
app.use(express.json({ limit: '50mb' }));



const transporter = nodemailer.createTransport({
    service: 'gmail',
    auth: {
        user: process.env.EMAIL_USER,
        pass: process.env.EMAIL_PASS
    }
});
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: "*", // Permite que cualquier app se conecte
        methods: ["GET", "POST", "PUT", "DELETE"]
    }
});
io.on('connection', (socket) => {
    console.log(`🔌 Un dispositivo se conectó al radio: ${socket.id}`);
    
    socket.on('ubicacion_repartidor', (data) => {
        console.log(`📍 Ubicación recibida de ${data.id_repartidor}: Lat ${data.latitud}, Lng ${data.longitud}`);
        io.emit('ubicacion_repartidor', data);
    });

    socket.on('disconnect', () => {
        console.log(`❌ Dispositivo desconectado: ${socket.id}`);
    });
});
const rateLimit = require('express-rate-limit');

// Bloquea a quien haga más de 100 peticiones en 15 minutos
const limiter = rateLimit({
    windowMs: 15 * 60 * 1000, 
    max: 2000, 
    message: "Tranquilo viejo, muchas peticiones. Intenta en un rato."
});

// Se lo aplicas a todo el servidor
app.use(limiter);
// ==========================================
// SUBQUERIES REUTILIZABLES (Imágenes en productos)
// ==========================================
const subqueryProductosConImagen = `
    (SELECT array_to_json(array_agg(json_build_object(
        'nombre_producto', op.nombre_producto, 
        'detalle', op.detalle, 
        'cantidad', op.cantidad, 
        'precio', op.precio, 
        'precio_original', op.precio_original, 
        'descuento', op.descuento, 
        'imagen', m.imagen
    )))
    FROM ordenes_productos op LEFT JOIN mercancia m ON op.nombre_producto = m.nombre WHERE op.id_orden = o.id) AS productos
`;
const codigosVerificacion = {};
// FUNCIÓN PARA ENVIAR PUSH NOTIFICATIONS
const enviarPush = async (token, titulo, cuerpo, dataPayload = {}) => {
    if (!token) return;
    try {
        await getMessaging().send({
            token: token,
            notification: { title: titulo, body: cuerpo },
            data: dataPayload,
            android: { 
                priority: 'high',
                notification: { 
                    sound: 'default',
                    channelId: 'canal_molino_popup' //  ESTA ES LA LLAVE MÁGICA PARA EL POP-UP
                } 
            },
            apns: {
                payload: {
                    aps: { sound: 'default', badge: 1 }
                }
            }
        });
        console.log(`📱 Push enviado: ${titulo}`);
    } catch (error) {
        console.error("Error enviando Push:", error.message);
    }
};

//  RUTA PARA GUARDAR EL TOKEN DEL TELÉFONO
app.put('/perfil/fcm-token', async (req, res) => {
    const { id, rol, fcm_token } = req.body;
    let tabla = 'clientes';
    if (rol === 'admin') tabla = 'usuarios';
    else if (rol === 'repartidor') tabla = 'repartidores';
    else if (rol === 'trabajador') tabla = 'trabajadores';

    try {
        await pool.query(`UPDATE ${tabla} SET fcm_token = $1 WHERE id = $2`, [fcm_token, id]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error guardando token" }); }
});
// ==========================================
//        RUTAS DE CLIENTES Y LOGIN
// ==========================================

app.get('/clientes/pendientes', async (req, res) => {
    try {
        //  AÑADIMOS "imagen" A LA CONSULTA SQL
        const result = await pool.query(`SELECT id, nombre_propietario, empresa, local, correo, telefono, direccion, latitud, longitud, fecha_registro, imagen FROM clientes WHERE estado = 'Pendiente' ORDER BY fecha_registro DESC`);
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error en el servidor" }); }
});

app.put('/clientes/aprobar/:id', async (req, res) => {
    try {
        await pool.query("UPDATE clientes SET estado = 'Activo' WHERE id = $1", [req.params.id]);
        res.json({ success: true, message: "Cliente aprobado" });
    } catch (err) { res.status(500).json({ error: "Error al aprobar" }); }
});

app.delete('/clientes/rechazar/:id', async (req, res) => {
    try {
        const result = await pool.query("DELETE FROM clientes WHERE id = $1 RETURNING id", [req.params.id]);
        if (result.rowCount > 0) res.json({ success: true, message: "Cliente eliminado" });
        else res.status(404).json({ success: false, message: "No se encontró el cliente" });
    } catch (err) { res.status(500).json({ error: "Error al eliminar" }); }
});

// --- RUTA DE REGISTRO ---
app.post('/registro', async (req, res) => {
    try {
        //  AÑADIMOS "imagen" A LA LISTA DE RECEPCIÓN
        const { usuario, password, correo, telefono, nombre_propietario, empresa, local, direccion, latitud, longitud, imagen } = req.body;
        if (!usuario || !password) return res.status(400).json({ success: false, message: "Faltan datos obligatorios" });
        
        const hashedPassword = await bcrypt.hash(password, 10);
        
        //  AÑADIMOS "imagen" AL INSERT
        const result = await pool.query(
            `INSERT INTO clientes (usuario, password, nombre_propietario, empresa, local, correo, telefono, direccion, latitud, longitud, imagen) 
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id, usuario, estado`, 
            [usuario, hashedPassword, nombre_propietario, empresa, local, correo, telefono, direccion, latitud, longitud, imagen]
        );
        io.emit('actualizacion_clientes');
        io.emit('notify_nuevo_registro', { cliente: nombre_propietario, id_cliente: result.rows[0].id });
        const admins = await pool.query("SELECT fcm_token FROM usuarios WHERE fcm_token IS NOT NULL");
        admins.rows.forEach(admin => {
            enviarPush(admin.fcm_token, "¡Nuevo Registro!", `${nombre_propietario} ha solicitado unirse a la app.`);
        }); //  NUEVO AVISO
        res.json({ success: true, message: "Usuario registrado", user: result.rows[0] });
    } catch (err) { 
        if (err.code === '23505') return res.status(400).json({ success: false, message: "Este usuario ya existe." });
        res.status(500).json({ success: false, message: "Error interno" }); 
    }
});

// --- RUTA NUEVA: VALIDAR CÓDIGO DE CORREO ---
app.post('/validar-codigo', (req, res) => {
    const { correo, codigo } = req.body;
    
    // Revisamos si el código guardado en memoria coincide con el que manda la app
    if (codigosVerificacion[correo] && codigosVerificacion[correo] === codigo) {
        delete codigosVerificacion[correo]; // Lo borramos para que no se reuse
        return res.json({ success: true, message: "Código válido" });
    }
    
    res.json({ success: false, message: "Código incorrecto o expirado" });
});

app.post('/login', async (req, res) => {
    try {
        const { usuario, password } = req.body;
        let usuarioEncontrado = null; let rolAsignado = null; let tabla = null;

        let result = await pool.query('SELECT * FROM usuarios WHERE usuario = $1', [usuario]);
        if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; rolAsignado = usuarioEncontrado.rol || 'admin'; tabla = 'usuarios'; }
        else {
            result = await pool.query('SELECT * FROM clientes WHERE usuario = $1', [usuario]);
            if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; rolAsignado = 'cliente'; tabla = 'clientes'; }
            else {
                result = await pool.query('SELECT * FROM repartidores WHERE usuario = $1', [usuario]);
                if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; rolAsignado = 'repartidor'; tabla = 'repartidores'; }
                else {
                    result = await pool.query('SELECT * FROM trabajadores WHERE usuario = $1', [usuario]);
                    if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; rolAsignado = 'trabajador'; tabla = 'trabajadores'; }
                }
            }
        }

        if (usuarioEncontrado) {
            if (tabla === 'clientes' && usuarioEncontrado.estado === 'Pendiente') return res.status(401).json({ success: false, message: 'Tu cuenta está en revisión. Espera a que un administrador te apruebe.' });
            
            let passwordValida = false;
            if (usuarioEncontrado.password.startsWith('$2')) { passwordValida = await bcrypt.compare(password, usuarioEncontrado.password); } 
            else {
                if (password === usuarioEncontrado.password) {
                    passwordValida = true;
                    const nuevoHash = await bcrypt.hash(password, 10);
                    await pool.query(`UPDATE ${tabla} SET password = $1 WHERE usuario = $2`, [nuevoHash, usuario]);
                }
            }
            if (passwordValida) {
                delete usuarioEncontrado.password; usuarioEncontrado.rol = rolAsignado; res.json({ success: true, user: usuarioEncontrado });
            } else res.status(401).json({ success: false, message: "Contraseña incorrecta" });
        } else res.status(404).json({ success: false, message: "Usuario no existe" });
    } catch (err) { res.status(500).json({ success: false, message: "Error" }); }
});

// ==========================================
//        RUTAS DE PERFIL Y RECUPERACIÓN
// ==========================================
app.put('/perfil/cambiar-password', async (req, res) => {
    const { id, rol, oldPassword, newPassword } = req.body;
    let tabla = 'clientes';
    if (rol === 'admin') tabla = 'usuarios';
    else if (rol === 'repartidor') tabla = 'repartidores';
    else if (rol === 'trabajador') tabla = 'trabajadores';

    try {
        const result = await pool.query(`SELECT password FROM ${tabla} WHERE id = $1`, [id]);
        if (result.rows.length === 0) return res.status(404).json({ success: false, message: "Usuario no encontrado" });

        const hashActual = result.rows[0].password;
        let passwordValida = hashActual.startsWith('$2') ? await bcrypt.compare(oldPassword, hashActual) : (oldPassword === hashActual);

        if (!passwordValida) return res.status(401).json({ success: false, message: "La contraseña actual es incorrecta." });

        const nuevoHash = await bcrypt.hash(newPassword, 10);
        await pool.query(`UPDATE ${tabla} SET password = $1 WHERE id = $2`, [nuevoHash, id]);
        res.json({ success: true, message: "Contraseña actualizada exitosamente" });
    } catch (err) { res.status(500).json({ success: false, message: "Error en el servidor" }); }
});

app.post('/recuperar-password', async (req, res) => {
    const { correo } = req.body;
    if (!correo) return res.status(400).json({ success: false, message: "Correo es requerido" });

    try {
        let usuarioEncontrado = null; let tabla = null;
        let result = await pool.query('SELECT * FROM clientes WHERE correo = $1', [correo]);
        if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; tabla = 'clientes'; }
        if (!usuarioEncontrado) { result = await pool.query('SELECT * FROM usuarios WHERE correo = $1', [correo]); if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; tabla = 'usuarios'; } }
        if (!usuarioEncontrado) { result = await pool.query('SELECT * FROM repartidores WHERE correo = $1', [correo]); if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; tabla = 'repartidores'; } }
        if (!usuarioEncontrado) { result = await pool.query('SELECT * FROM trabajadores WHERE correo = $1', [correo]); if (result.rows.length > 0) { usuarioEncontrado = result.rows[0]; tabla = 'trabajadores'; } }

        if (!usuarioEncontrado) return res.status(404).json({ success: false, message: "El correo no está registrado." });

        const passwordTemporal = crypto.randomBytes(4).toString('hex'); 
        const hashedPassword = await bcrypt.hash(passwordTemporal, 10);
        await pool.query(`UPDATE ${tabla} SET password = $1 WHERE id = $2`, [hashedPassword, usuarioEncontrado.id]);

        const mailOptions = {
            from: '"Soporte de la App" <udisystemc5@gmail.com>',
            to: correo,
            subject: "Recuperación de contraseña",
            text: `Hola ${usuarioEncontrado.usuario || 'Usuario'},\n\nHas solicitado recuperar tu contraseña.\n\nTu nueva contraseña temporal es: ${passwordTemporal}\n\nPor favor, inicia sesión con esta contraseña y cámbiala por una nueva desde el apartado de tu perfil lo antes posible.\n\nSaludos.`
        };
        await transporter.sendMail(mailOptions);
        res.json({ success: true, message: "Se ha enviado una contraseña temporal a tu correo." });
    } catch (err) { res.status(500).json({ success: false, message: "Error al enviar el correo." }); }
});

// ==========================================
//        RUTAS DE MERCANCÍA
// ==========================================
app.get('/mercancia', async (req, res) => {
    try { const result = await pool.query("SELECT * FROM mercancia ORDER BY id DESC"); res.json(result.rows); } 
    catch (err) { res.status(500).json({ error: "Error en el servidor" }); }
});

app.post('/mercancia', async (req, res) => {
    try {
        const { nombre, precio, unidad, imagen } = req.body;
        const result = await pool.query(`INSERT INTO mercancia (nombre, precio, unidad, imagen) VALUES ($1, $2, $3, $4) RETURNING *`, [nombre, precio, unidad, imagen]);
        res.json({ success: true, producto: result.rows[0] });
    } catch (err) { res.status(500).json({ error: "Error al guardar" }); }
});

app.put('/mercancia/:id', async (req, res) => {
    try {
        const { nombre, precio, unidad, imagen } = req.body;
        const result = await pool.query(`UPDATE mercancia SET nombre = $1, precio = $2, unidad = $3, imagen = $4 WHERE id = $5 RETURNING *`, [nombre, precio, unidad, imagen, req.params.id]);
        res.json({ success: true, producto: result.rows[0] });
    } catch (err) { res.status(500).json({ error: "Error al editar" }); }
});

app.delete('/mercancia/:id', async (req, res) => {
    try { await pool.query("DELETE FROM mercancia WHERE id = $1", [req.params.id]); res.json({ success: true }); } 
    catch (err) { res.status(500).json({ error: "Error" }); }
});
// ==========================================
//        RUTAS DE MASAS
// ==========================================
app.get('/masas', async (req, res) => {
    try { 
        const result = await pool.query("SELECT * FROM masas ORDER BY id DESC"); 
        res.json(result.rows); 
    } catch (err) { 
        res.status(500).json({ error: "Error en el servidor al obtener masas" }); 
    }
});

app.post('/masas', async (req, res) => {
    try {
        const { nombre, precio, unidad, imagen } = req.body;
        const result = await pool.query(`INSERT INTO masas (nombre, precio, unidad, imagen) VALUES ($1, $2, $3, $4) RETURNING *`, [nombre, precio, unidad, imagen]);
        res.json({ success: true, producto: result.rows[0] });
    } catch (err) { 
        res.status(500).json({ error: "Error al guardar la masa" }); 
    }
});

app.put('/masas/:id', async (req, res) => {
    try {
        const { nombre, precio, unidad, imagen } = req.body;
        const result = await pool.query(`UPDATE masas SET nombre = $1, precio = $2, unidad = $3, imagen = $4 WHERE id = $5 RETURNING *`, [nombre, precio, unidad, imagen, req.params.id]);
        res.json({ success: true, producto: result.rows[0] });
    } catch (err) { 
        res.status(500).json({ error: "Error al editar la masa" }); 
    }
});

app.delete('/masas/:id', async (req, res) => {
    try { 
        await pool.query("DELETE FROM masas WHERE id = $1", [req.params.id]); 
        res.json({ success: true }); 
    } catch (err) { 
        res.status(500).json({ error: "Error al eliminar la masa" }); 
    }
});
// ==========================================
//        RUTAS DE TORTILLERÍAS
// ==========================================
app.get('/tortillerias', async (req, res) => {
    try { 
        //  AHORA TRAEMOS AL ENCARGADO ACTUAL DE LA TORTILLERÍA
        const result = await pool.query(`
            SELECT t.*, tr.nombre AS nombre_trabajador, tr.id AS id_trabajador
            FROM tortillerias t
            LEFT JOIN trabajadores tr ON t.id_trabajador_actual = tr.id
            ORDER BY t.id DESC
        `); 
        res.json(result.rows); 
    } catch (err) { res.status(500).json({ error: "Error en el servidor" }); }
});
app.put('/tortillerias/turno/:id', async (req, res) => {
    try {
        //  GUARDA EL TRABAJADOR Y LA HORA EXACTA
        await pool.query('UPDATE tortillerias SET id_trabajador_actual = $1, fecha_asignacion = CURRENT_TIMESTAMP WHERE id = $2', [req.body.id_trabajador, req.params.id]);
        res.json({ success: true });
    } catch(e) { res.status(500).json({ error: "Error" }); }
});
app.post('/tortillerias', async (req, res) => {
    try {
        const { nombre, latitud, longitud } = req.body;
        const result = await pool.query(
            `INSERT INTO tortillerias (nombre, latitud, longitud) VALUES ($1, $2, $3) RETURNING *`, 
            [nombre, latitud, longitud]
        );
        res.json({ success: true, tortilleria: result.rows[0] });
    } catch (err) { res.status(500).json({ error: "Error al guardar" }); }
});

app.delete('/tortillerias/:id', async (req, res) => {
    try { 
        await pool.query("DELETE FROM tortillerias WHERE id = $1", [req.params.id]); 
        res.json({ success: true }); 
    } catch (err) { res.status(500).json({ error: "Error" }); }
});
// ==========================================
//        PANEL GENERAL DE USUARIOS
// ==========================================
const obtenerTabla = (tipo) => {
    if (tipo === 'repartidores') return 'repartidores';
    if (tipo === 'trabajadores') return 'trabajadores';
    if (tipo === 'administradores') return 'usuarios'; 
    if (tipo === 'clientes') return 'clientes';
    return null;
};

app.get('/panel/usuarios/:tipo', async (req, res) => {
    const tabla = obtenerTabla(req.params.tipo);
    if (!tabla) return res.status(400).json({ error: "Tipo inválido" });
    try {
        const query = tabla === 'clientes' 
            ? `SELECT id, nombre_propietario AS nombre, empresa, local, correo, telefono, usuario, imagen FROM clientes WHERE LOWER(estado) = 'activo' ORDER BY id DESC`
            : `SELECT id, nombre, edad, usuario, imagen FROM ${tabla} ORDER BY id DESC`;
        const queryAdmins = `SELECT id, nombres AS nombre, edad, usuario, imagen FROM usuarios ORDER BY id DESC`;
        const result = await pool.query(tabla === 'usuarios' ? queryAdmins : query);
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.post('/panel/usuarios/:tipo', async (req, res) => {
    const tabla = obtenerTabla(req.params.tipo);
    if (!tabla || tabla === 'clientes') return res.status(403).json({ error: "No permitido" });
    try {
        const { nombre, edad, usuario, password, imagen } = req.body;
        const hashedPass = await bcrypt.hash(password, 10);
        const query = tabla === 'usuarios'
            ? `INSERT INTO usuarios (nombres, edad, usuario, password, imagen, rol) VALUES ($1, $2, $3, $4, $5, 'admin')`
            : `INSERT INTO ${tabla} (nombre, edad, usuario, password, imagen) VALUES ($1, $2, $3, $4, $5)`;
        await pool.query(query, [nombre, edad, usuario, hashedPass, imagen]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error al crear" }); }
});

app.put('/panel/usuarios/:tipo/:id', async (req, res) => {
    const tabla = obtenerTabla(req.params.tipo);
    if (!tabla || tabla === 'clientes') return res.status(403).json({ error: "No permitido" });
    try {
        const { nombre, edad, usuario, password, imagen } = req.body;
        if (password && password.trim() !== '') {
            const hashedPass = await bcrypt.hash(password, 10);
            await pool.query(`UPDATE ${tabla} SET ${tabla==='usuarios'?'nombres':'nombre'}=$1, edad=$2, usuario=$3, password=$4, imagen=$5 WHERE id=$6`, [nombre, edad, usuario, hashedPass, imagen, req.params.id]);
        } else {
            await pool.query(`UPDATE ${tabla} SET ${tabla==='usuarios'?'nombres':'nombre'}=$1, edad=$2, usuario=$3, imagen=$4 WHERE id=$5`, [nombre, edad, usuario, imagen, req.params.id]);
        }
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error al editar" }); }
});

app.delete('/panel/usuarios/:tipo/:id', async (req, res) => {
    const tabla = obtenerTabla(req.params.tipo);
    try {
        if (tabla === 'usuarios' && req.params.id == 1) return res.status(403).json({ error: "No puedes borrar al admin" });
        await pool.query(`DELETE FROM ${tabla} WHERE id = $1`, [req.params.id]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});
// ==========================================
//        RUTAS DE ÓRDENES (PEDIDOS)
// ==========================================
// Guardar el descuento y actualizar total sin cobrar
app.put('/ordenes/guardar-descuentos/:id', async (req, res) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const { total, productos } = req.body;
        
        await client.query(`UPDATE ordenes SET total = $1 WHERE id = $2`, [total, req.params.id]);
        await client.query(`DELETE FROM ordenes_productos WHERE id_orden = $1`, [req.params.id]);
        
        for (let prod of productos) {
            await client.query(
                `INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio, precio_original, descuento) 
                 VALUES ($1, $2, $3, $4, $5, $6, $7)`, 
                [req.params.id, prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio, prod.precio_original || null, prod.descuento || null]
            );
        }
        
        await client.query('COMMIT');
        io.emit('actualizacion_ordenes');
        res.json({ success: true });
    } catch (e) {
        await client.query('ROLLBACK');
        res.status(500).json({ error: e.message });
    } finally {
        client.release();
    }
});
// 1. Crear nueva orden (Combinado con custom locations y trabajadores)
app.post('/ordenes', async (req, res) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const { id_cliente, id_trabajador, viaje_programado, fuera_de_tiempo, ultima_entrega, total, cambio_efectivo, productos, direccion_custom, lat_custom, lng_custom } = req.body;
        const codigo_entrega = Math.floor(1000 + Math.random() * 9000).toString();

        const insertOrden = `
            INSERT INTO ordenes (id_cliente, id_trabajador, estado, viaje_programado, fuera_de_tiempo, ultima_entrega, total, cambio_efectivo, codigo_entrega, direccion_custom, lat_custom, lng_custom)
            VALUES ($1, $2, 'Buscando Repartidor', $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id, codigo_entrega
        `;
        const resultOrden = await client.query(insertOrden, [id_cliente || null, id_trabajador || null, viaje_programado, fuera_de_tiempo, ultima_entrega || false, total, cambio_efectivo || 0, codigo_entrega, direccion_custom || null, lat_custom || null, lng_custom || null]);
        const id_orden = resultOrden.rows[0].id;

        for (let prod of productos) {
            await client.query(`INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)`, [id_orden, prod.nombre || prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio]);
        }
        await client.query('COMMIT');
        
        // Buscamos el nombre de quien pidió para la notificación
        let nombreC = "Alguien";
        if (id_cliente) { const r = await pool.query("SELECT nombre_propietario FROM clientes WHERE id=$1", [id_cliente]); if(r.rows.length>0) nombreC = r.rows[0].nombre_propietario; }
        else if (id_trabajador) { const r = await pool.query("SELECT nombre FROM trabajadores WHERE id=$1", [id_trabajador]); if(r.rows.length>0) nombreC = r.rows[0].nombre; }
        
        io.emit('actualizacion_ordenes');
        io.emit('notify_nuevo_pedido', { cliente: nombreC, id_orden: id_orden }); //  NUEVO AVISO
        //  NOTIFICACIÓN ADMIN 1
        const admins = await pool.query("SELECT fcm_token FROM usuarios WHERE fcm_token IS NOT NULL");
        admins.rows.forEach(a => enviarPush(a.fcm_token, "Nuevo Pedido 📦", `Ha llegado un nuevo pedido de ${nombreC}`, { tipo: 'admin_nuevo', id_orden: id_orden.toString() }));

        //  NOTIFICACIÓN REPARTIDOR 2
        const reps = await client.query("SELECT fcm_token FROM repartidores WHERE fcm_token IS NOT NULL");
        reps.rows.forEach(r => enviarPush(r.fcm_token, "Nuevo Pedido Disponible", `Nuevo Pedido para ${nombreC}`, { tipo: 'rep_nuevo', id_orden: id_orden.toString() }));
        
        res.json({ success: true, id_orden, codigo_entrega, orden: {id: id_orden, estado: 'Buscando Repartidor', viaje_programado, total} });
    } catch (err) { await client.query('ROLLBACK'); res.status(500).json({ error: "Error al crear la orden" }); } finally { client.release(); }
});

// 2. Actualizar Orden
app.put('/ordenes/actualizar/:id', async (req, res) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        //  AÑADIMOS id_trabajador PARA QUE SE ACTUALICE SI CAMBIA DE TURNO
        const { viaje_programado, fuera_de_tiempo, total, cambio_efectivo, productos, direccion_custom, lat_custom, lng_custom, id_trabajador } = req.body;
        
        // El COALESCE hace magia: Si id_trabajador es null, deja al que ya estaba.
        await client.query(
            `UPDATE ordenes SET viaje_programado=$1, fuera_de_tiempo=$2, total=$3, cambio_efectivo=$4, direccion_custom=$5, lat_custom=$6, lng_custom=$7, id_trabajador=COALESCE($8, id_trabajador), estado='Buscando Repartidor', id_repartidor=NULL WHERE id=$9`,
            [viaje_programado, fuera_de_tiempo, total, cambio_efectivo, direccion_custom || null, lat_custom || null, lng_custom || null, id_trabajador || null, req.params.id]
        );
        
        await client.query(`DELETE FROM ordenes_productos WHERE id_orden=$1`, [req.params.id]);
        for (let prod of productos) {
            await client.query(`INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)`, [req.params.id, prod.nombre || prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio]);
        }
        await client.query('COMMIT');
        
        io.emit('actualizacion_ordenes');

        // 🚀 SOCKET Y PUSH PARA CUANDO ACTUALIZAS EL VIAJE
        io.emit('notify_nuevo_pedido', { cliente: 'Local (Actualizado)', id_orden: req.params.id });

        const reps = await client.query("SELECT fcm_token FROM repartidores WHERE fcm_token IS NOT NULL");
        reps.rows.forEach(r => enviarPush(r.fcm_token, "Viaje Liberado 🛵", `Un pedido programado fue actualizado y está disponible en la lista pública.`, { tipo: 'rep_nuevo', id_orden: req.params.id.toString() }));

        res.json({ success: true });
    } catch(e) { await client.query('ROLLBACK'); res.status(500).json({error: e.message}); } finally { client.release(); }
});
// 3. Pendientes Repartidor (Combina soporte de trabajadores, custom location y filtro de 80 min)
app.get('/ordenes/pendientes', async (req, res) => {
    try {
        const query = `
            SELECT o.*, 
            COALESCE(c.nombre_propietario, t.nombre, tor.nombre) AS cliente, 
            c.local,
            COALESCE(c.telefono, t.telefono) AS telefono, 
            COALESCE(o.direccion_custom, c.direccion, 'Tortillería ' || tor.nombre) AS direccion, 
            COALESCE(o.lat_custom, CAST(c.latitud AS VARCHAR), CAST(t.latitud AS VARCHAR), CAST(tor.latitud AS VARCHAR)) AS latitud, 
            COALESCE(o.lng_custom, CAST(c.longitud AS VARCHAR), CAST(t.longitud AS VARCHAR), CAST(tor.longitud AS VARCHAR)) AS longitud, 
            COALESCE(c.imagen, t.imagen) AS foto_cliente,
            ${subqueryProductosConImagen} 
            FROM ordenes o 
            LEFT JOIN clientes c ON o.id_cliente = c.id 
            LEFT JOIN trabajadores t ON o.id_trabajador = t.id 
            LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id
            WHERE o.estado = 'Buscando Repartidor' ORDER BY o.fecha_registro ASC
        `;
        const result = await pool.query(query);

        //  MODO PRUEBA: Mandamos TODAS las órdenes sin importar la hora ni los 80 minutos
        res.json(result.rows);
    } catch (err) { 
        res.status(500).json({ error: "Error al obtener pendientes" }); 
    }
});

// 4. Obtener Orden por ID (Tiempo real)
// 4. Obtener Orden por ID (Tiempo real)
app.get('/ordenes/:id', async (req, res) => {
    try {
        // 🚀 AQUÍ ESTÁ EL ARREGLO DE IZTACALCO (Jala el GPS de clientes, trabajadores y tortillerías)
        const query = `
            SELECT o.*, 
            COALESCE(c.nombre_propietario, t.nombre, tor.nombre) AS cliente, 
            COALESCE(c.telefono, t.telefono) AS telefono, 
            COALESCE(o.direccion_custom, c.direccion, 'Tortillería ' || tor.nombre) AS direccion, 
            COALESCE(o.lat_custom, CAST(c.latitud AS VARCHAR), CAST(t.latitud AS VARCHAR), CAST(tor.latitud AS VARCHAR)) AS latitud, 
            COALESCE(o.lng_custom, CAST(c.longitud AS VARCHAR), CAST(t.longitud AS VARCHAR), CAST(tor.longitud AS VARCHAR)) AS longitud, 
            r.nombre AS nombre_repartidor, r.telefono AS tel_repartidor, r.imagen AS foto_repartidor, 
            ${subqueryProductosConImagen} 
            FROM ordenes o 
            LEFT JOIN clientes c ON o.id_cliente = c.id 
            LEFT JOIN trabajadores t ON o.id_trabajador = t.id 
            LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id
            LEFT JOIN repartidores r ON o.id_repartidor = r.id 
            WHERE o.id = $1
        `;
        const result = await pool.query(query, [req.params.id]);
        if (result.rows.length > 0) res.json({ success: true, orden: result.rows[0] }); else res.json({ success: false });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});


// 5. Aceptar Orden y Flujo del Repartidor
app.put('/ordenes/aceptar/:id', async (req, res) => {
    try {
        const result = await pool.query(
            `UPDATE ordenes SET id_repartidor = $1, estado = 'Pendiente' WHERE id = $2 AND estado = 'Buscando Repartidor' RETURNING id`, 
            [req.body.id_repartidor, req.params.id]
        );
        if (result.rows.length > 0) {
            const repInfo = await pool.query("SELECT nombre FROM repartidores WHERE id=$1", [req.body.id_repartidor]);
            const uInfo = await pool.query("SELECT o.id_cliente, o.id_trabajador FROM ordenes o WHERE o.id=$1", [req.params.id]);
            const nombreRep = repInfo.rows[0]?.nombre || 'Un repartidor';

            //  NOTIFICACIÓN CLIENTE 1
            if(uInfo.rows[0]?.id_cliente) {
                const tk = await pool.query("SELECT fcm_token FROM clientes WHERE id=$1", [uInfo.rows[0].id_cliente]);
                if(tk.rows.length>0) enviarPush(tk.rows[0].fcm_token, "Pedido Aceptado ✅", `${nombreRep} ha aceptado tu pedido`, { tipo: 'cli_aceptado', id_orden: req.params.id.toString() });
            } else if (uInfo.rows[0]?.id_trabajador) {
                const tk = await pool.query("SELECT fcm_token FROM trabajadores WHERE id=$1", [uInfo.rows[0].id_trabajador]);
                if(tk.rows.length>0) enviarPush(tk.rows[0].fcm_token, "Pedido Aceptado ✅", `${nombreRep} ha aceptado tu pedido`, { tipo: 'cli_aceptado', id_orden: req.params.id.toString() });
            }

            res.json({ success: true, message: "Orden aceptada" });
            io.emit('actualizacion_ordenes');
        } else {
            res.json({ success: false, message: "Alguien más ya tomó este pedido" });
        }
    } catch (err) { res.status(500).json({ error: "Error" }); }
});
// 5.5 Aceptar MÚLTIPLES Órdenes a la vez
app.put('/ordenes/aceptar-multiples', async (req, res) => {
    try {
        const { id_repartidor, ids_ordenes } = req.body;
        
        if (!ids_ordenes || ids_ordenes.length === 0) {
            return res.json({ success: false, message: "No se seleccionaron pedidos" });
        }

        // Usamos ANY($2::int[]) para actualizar todas las órdenes en una sola consulta
        const result = await pool.query(
            `UPDATE ordenes SET id_repartidor = $1, estado = 'Pendiente' WHERE id = ANY($2::int[]) AND estado = 'Buscando Repartidor' RETURNING id`, 
            [id_repartidor, ids_ordenes]
        );

        if (result.rows.length > 0) {
            res.json({ success: true, message: "Órdenes aceptadas" });
            io.emit('actualizacion_ordenes');
        } else {
            res.json({ success: false, message: "Alguien más tomó estos pedidos o ya no están disponibles" });
        }
    } catch (err) { 
        console.error(err);
        res.status(500).json({ error: "Error interno" }); 
    }
});
// 5.6 Reportar Mercancía Faltante, editar cantidades y mandarlo al Limbo
app.put('/ordenes/modificar-productos/:id', async (req, res) => {
    console.log(" Recibiendo modificaciones de orden", req.params.id);
    console.log("🔍 Productos faltantes enviados:", JSON.stringify(req.body.productos_faltantes, null, 2));
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const { productos, total, detalles_faltante, productos_faltantes } = req.body; 
        
        await client.query(`UPDATE ordenes SET total = $1, hubo_faltante = TRUE, detalles_faltante = $2 WHERE id = $3`, [total, detalles_faltante || 'Faltan productos', req.params.id]);
        await client.query(`DELETE FROM ordenes_productos WHERE id_orden = $1`, [req.params.id]);
        
        for (let prod of productos) {
            if (prod.cantidad > 0) {
                await client.query(
                    `INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)`, 
                    [req.params.id, prod.nombre_producto || prod.nombre, prod.detalle, prod.cantidad, prod.precio]
                );
            }
        }

        // METEMOS LA MERCANCÍA AL LIMBO
        if (productos_faltantes && productos_faltantes.length > 0) {
            const ordInfoLimbo = await client.query("SELECT id_cliente, id_trabajador, id_tortilleria FROM ordenes WHERE id = $1", [req.params.id]);
            if (ordInfoLimbo.rows.length > 0) {
                const { id_cliente, id_trabajador, id_tortilleria } = ordInfoLimbo.rows[0];
                for (let faltante of productos_faltantes) {
                    await client.query(
                        `INSERT INTO mercancia_faltante (id_orden, id_cliente, id_trabajador, id_tortilleria, nombre_producto, cantidad_faltante, estado) 
                         VALUES ($1, $2, $3, $4, $5, $6, 'Agotado')`,
                        [req.params.id, id_cliente || null, id_trabajador || null, id_tortilleria || null, faltante.nombre_producto, faltante.cantidad_faltante]
                    );
                }
            }
        }
        
        await client.query('COMMIT');

        // 👇 LA MAGIA LIMPIA DE NODE.JS 👇
        const infoCompleta = await client.query(`
            SELECT o.id_cliente, o.id_trabajador, r.nombre as rep 
            FROM ordenes o 
            LEFT JOIN repartidores r ON o.id_repartidor = r.id 
            WHERE o.id = $1
        `, [req.params.id]);

        if (infoCompleta.rows.length > 0) {
            const { id_cliente, id_trabajador, rep } = infoCompleta.rows[0];
            const repName = rep || "Un repartidor";

            io.emit('actualizacion_ordenes');
            io.emit('notify_mercancia_modificada', { 
                id_orden: req.params.id, 
                nuevo_total: total, 
                id_cliente: id_cliente,
                id_trabajador: id_trabajador
            });

            // NOTIFICACIÓN ADMIN
            const admins = await client.query("SELECT fcm_token FROM usuarios WHERE fcm_token IS NOT NULL AND fcm_token != ''");
            for (let a of admins.rows) {
                enviarPush(a.fcm_token, "Faltantes Reportados ⚠️", `${repName} marcó que hay faltantes`, { tipo: 'admin_faltante', id_orden: req.params.id.toString() });
            }

            // NOTIFICACIÓN CLIENTE / TRABAJADOR
            if (id_cliente) {
                const cliInfo = await client.query("SELECT fcm_token FROM clientes WHERE id = $1 AND fcm_token IS NOT NULL", [id_cliente]);
                if (cliInfo.rows.length > 0) {
                    enviarPush(cliInfo.rows[0].fcm_token, "Pedido Modificado ⚠️", `Tu pedido tuvo mercancia faltante: ${detalles_faltante || 'Ver detalles'}`, { tipo: 'cli_faltante', id_orden: req.params.id.toString() });
                }
            } else if (id_trabajador) {
                const trabInfo = await client.query("SELECT fcm_token FROM trabajadores WHERE id = $1 AND fcm_token IS NOT NULL", [id_trabajador]);
                if (trabInfo.rows.length > 0) {
                    enviarPush(trabInfo.rows[0].fcm_token, "Pedido Modificado ⚠️", `Tu pedido tuvo mercancia faltante: ${detalles_faltante || 'Ver detalles'}`, { tipo: 'cli_faltante', id_orden: req.params.id.toString() });
                }
            }
        }

        res.json({ success: true });
    } catch(e) { 
        await client.query('ROLLBACK'); 
        console.error("❌ ERROR EN SERVIDOR AL GUARDAR FALTANTE:", e);
        res.status(500).json({error: e.message}); 
    } finally { 
        client.release(); 
    }
});

app.get('/ordenes/activa/repartidor/:id', async (req, res) => {
    try {
const query = `
    SELECT o.*, 
    COALESCE(c.nombre_propietario, t.nombre, tor.nombre) AS cliente, 
    COALESCE(c.telefono, t.telefono) AS telefono, 
    COALESCE(c.local, tor.nombre) AS local,
    COALESCE(o.direccion_custom, c.direccion, 'Tortillería ' || tor.nombre) AS direccion,
    COALESCE(o.lat_custom, CAST(c.latitud AS VARCHAR), CAST(t.latitud AS VARCHAR), CAST(tor.latitud AS VARCHAR)) AS latitud, 
    COALESCE(o.lng_custom, CAST(c.longitud AS VARCHAR), CAST(t.longitud AS VARCHAR), CAST(tor.longitud AS VARCHAR)) AS longitud, 
    COALESCE(c.imagen, t.imagen) AS foto_cliente, 
    r.nombre AS nombre_repartidor_origen, r.telefono AS tel_repartidor_origen,
    rd.nombre AS nombre_repartidor_destino, rd.telefono AS tel_repartidor_destino,
    ${subqueryProductosConImagen} 
    FROM ordenes o 
    LEFT JOIN clientes c ON o.id_cliente = c.id 
    LEFT JOIN trabajadores t ON o.id_trabajador = t.id 
    LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id 
    LEFT JOIN repartidores r ON o.id_repartidor = r.id
    LEFT JOIN repartidores rd ON o.id_repartidor_destino = rd.id
    WHERE (o.id_repartidor = $1 OR o.id_repartidor_destino = $1) 
    AND o.estado IN ('Asignado', 'Pendiente', 'En Camino') 
    ORDER BY o.id ASC
`;        const result = await pool.query(query, [req.params.id]);
        
        if (result.rows.length > 0) {
            res.json({ success: true, ordenes: result.rows }); 
        } else {
            res.json({ success: false });
        }
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.put('/ordenes/estado/:id', async (req, res) => {
    try { 
        await pool.query(`UPDATE ordenes SET estado = $1 WHERE id = $2`, [req.body.estado, req.params.id]); 
        
        if (req.body.estado === 'En Camino') {
            const ord = await pool.query("SELECT o.id_cliente, o.id_trabajador, r.nombre as rep, COALESCE(c.nombre_propietario, t.nombre) as cliente_nombre FROM ordenes o LEFT JOIN repartidores r ON o.id_repartidor = r.id LEFT JOIN clientes c ON o.id_cliente = c.id LEFT JOIN trabajadores t ON o.id_trabajador = t.id WHERE o.id=$1", [req.params.id]);
            
            const nombreRep = ord.rows[0]?.rep || "Un repartidor";
            const nombreCli = ord.rows[0]?.cliente_nombre || "un cliente";

            //  NOTIFICACIÓN ADMIN 2
            const admins = await pool.query("SELECT fcm_token FROM usuarios WHERE fcm_token IS NOT NULL");
            admins.rows.forEach(a => enviarPush(a.fcm_token, "Pedido Recogido 🛵", `${nombreRep} recogio el pedido de ${nombreCli}`, { tipo: 'admin_recogido', id_orden: req.params.id.toString() }));

            io.emit('notify_pedido_recogido', { id_orden: req.params.id, nombre_repartidor: nombreRep, id_cliente: ord.rows[0]?.id_cliente, id_trabajador: ord.rows[0]?.id_trabajador });
        }
        
        io.emit('actualizacion_ordenes'); 
        res.json({ success: true });
    } 
    catch (err) { res.status(500).json({ error: "Error" }); }
});

app.post('/ordenes/completar/:id', async (req, res) => {
    try {
        const check = await pool.query(`SELECT id FROM ordenes WHERE id = $1 AND codigo_entrega = $2`, [req.params.id, req.body.codigo]);
        if (check.rows.length > 0) {
            await pool.query(`UPDATE ordenes SET estado = 'Completada', codigo_entrega = NULL, fecha_entrega = CURRENT_TIMESTAMP WHERE id = $1`, [req.params.id]);
            
            const ordInfo = await pool.query("SELECT o.id_cliente, o.id_trabajador, r.nombre as rep, COALESCE(c.nombre_propietario, t.nombre) as cliente_nombre FROM ordenes o LEFT JOIN repartidores r ON o.id_repartidor = r.id LEFT JOIN clientes c ON o.id_cliente = c.id LEFT JOIN trabajadores t ON o.id_trabajador = t.id WHERE o.id=$1", [req.params.id]);
            
            //  NOTIFICACIÓN ADMIN 4
            const admins = await pool.query("SELECT fcm_token FROM usuarios WHERE fcm_token IS NOT NULL");
            admins.rows.forEach(a => enviarPush(a.fcm_token, "Pedido Completado ✅", `${ordInfo.rows[0]?.rep} ha completado el pedido de ${ordInfo.rows[0]?.cliente_nombre}`, { tipo: 'admin_completado', id_orden: req.params.id.toString() }));

            io.emit('actualizacion_ordenes');
            res.json({ success: true });
        } else res.json({ success: false, message: "Código incorrecto" });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 6. Consultas para Clientes y Trabajadores (Pendientes, Completadas, Hoy, Ticket)
app.get('/ordenes/pendientes/cliente/:id', async (req, res) => {
    try {
        // 🚀 AHORA SÍ JALAMOS LA DIRECCIÓN, LATITUD Y LONGITUD DEL CLIENTE
        const query = `
            SELECT o.*, 
            r.nombre AS nombre_repartidor, 
            r.telefono AS tel_repartidor, 
            r.imagen AS foto_repartidor, 
            COALESCE(o.direccion_custom, c.direccion) AS direccion, 
            COALESCE(o.lat_custom, CAST(c.latitud AS VARCHAR)) AS latitud, 
            COALESCE(o.lng_custom, CAST(c.longitud AS VARCHAR)) AS longitud, 
            ${subqueryProductosConImagen} 
            FROM ordenes o 
            LEFT JOIN clientes c ON o.id_cliente = c.id 
            LEFT JOIN repartidores r ON o.id_repartidor = r.id 
            WHERE o.id_cliente = $1 AND o.estado != 'Completada' AND o.estado != 'Cancelada' 
            ORDER BY o.fecha_registro ASC
        `;
        const result = await pool.query(query, [req.params.id]); 
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/pendientes/trabajador/:id', async (req, res) => {
    try {
        const query = `SELECT o.*, r.nombre AS nombre_repartidor, r.telefono AS tel_repartidor, r.imagen AS foto_repartidor, ${subqueryProductosConImagen} FROM ordenes o LEFT JOIN repartidores r ON o.id_repartidor = r.id WHERE o.id_trabajador = $1 AND o.estado != 'Completada' AND o.estado != 'Cancelada' ORDER BY o.fecha_registro ASC`;
        const result = await pool.query(query, [req.params.id]); res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/completadas/cliente/:id', async (req, res) => {
    try {
        const query = `SELECT o.*, ${subqueryProductosConImagen} FROM ordenes o WHERE o.id_cliente = $1 AND o.estado IN ('Completada', 'Cobrado') ORDER BY o.fecha_registro DESC`;
        const result = await pool.query(query, [req.params.id]); res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/completadas/trabajador/:id', async (req, res) => {
    try {
        const query = `SELECT o.*, ${subqueryProductosConImagen} FROM ordenes o WHERE o.id_trabajador = $1 AND o.estado IN ('Completada', 'Cobrado') ORDER BY o.fecha_registro DESC`;
        const result = await pool.query(query, [req.params.id]); res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/completadas/repartidor/:id', async (req, res) => {
    try {
        // FIX: Se cambió id_trabajador por id_repartidor y se añadieron joins para mostrar la tarjeta completa.
        const query = `
            SELECT o.*, 
                   COALESCE(c.nombre_propietario, t.nombre, tor.nombre) AS cliente,
                   c.local,
                   r.nombre AS nombre_repartidor,
                   ${subqueryProductosConImagen} 
            FROM ordenes o 
            LEFT JOIN repartidores r ON o.id_repartidor = r.id
            LEFT JOIN clientes c ON o.id_cliente = c.id 
            LEFT JOIN trabajadores t ON o.id_trabajador = t.id 
            LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id
            WHERE o.id_repartidor = $1 AND o.estado IN ('Completada', 'Cobrado') ORDER BY o.fecha_registro DESC`;
        const result = await pool.query(query, [req.params.id]); res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/hoy/cliente/:id', async (req, res) => {
    try {
        const query = `SELECT viaje_programado, ultima_entrega, estado FROM ordenes WHERE id_cliente = $1 AND estado != 'Cancelada' AND viaje_programado NOT LIKE 'Prog:%' AND DATE(fecha_registro AT TIME ZONE 'America/Mexico_City') = DATE(CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')`;
        const result = await pool.query(query, [req.params.id]); res.json({ success: true, ordenes: result.rows });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/hoy/trabajador/:id', async (req, res) => {
    try {
        const query = `SELECT viaje_programado FROM ordenes WHERE id_trabajador = $1 AND estado != 'Cancelada' AND viaje_programado NOT LIKE 'Prog:%' AND DATE(fecha_registro AT TIME ZONE 'America/Mexico_City') = DATE(CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')`;
        const result = await pool.query(query, [req.params.id]); res.json({ success: true, ordenes: result.rows });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

app.get('/ordenes/ticket_diario/cliente/:id', async (req, res) => {
    try {
        const query = `SELECT o.*, ${subqueryProductosConImagen} FROM ordenes o WHERE o.id_cliente = $1 AND o.viaje_programado NOT LIKE 'Prog:%' AND DATE(o.fecha_registro AT TIME ZONE 'America/Mexico_City') = DATE(CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City') ORDER BY o.fecha_registro ASC`;
        const result = await pool.query(query, [req.params.id]); res.json({ success: true, ticket: result.rows });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});
app.put('/ordenes/llegada/:id', async (req, res) => {
    try {
        const ord = await pool.query("SELECT o.id_cliente, o.id_trabajador, r.nombre as rep FROM ordenes o LEFT JOIN repartidores r ON o.id_repartidor = r.id WHERE o.id=$1", [req.params.id]);
        
        //  NOTIFICACIÓN CLIENTE 2
        if(ord.rows[0]?.id_cliente) {
            const tk = await pool.query("SELECT fcm_token FROM clientes WHERE id=$1", [ord.rows[0].id_cliente]);
            if(tk.rows.length>0) enviarPush(tk.rows[0].fcm_token, "¡Ya llegué! 📍", `${ord.rows[0].rep} ya llego recibe tu pedido`, { tipo: 'cli_llegado', id_orden: req.params.id.toString() });
        } else if (ord.rows[0]?.id_trabajador) {
            const tk = await pool.query("SELECT fcm_token FROM trabajadores WHERE id=$1", [ord.rows[0].id_trabajador]);
            if(tk.rows.length>0) enviarPush(tk.rows[0].fcm_token, "¡Ya llegué! 📍", `${ord.rows[0].rep} ya llego recibe tu pedido`, { tipo: 'cli_llegado', id_orden: req.params.id.toString() });
        }
        res.json({success:true});
    } catch(e) { res.status(500).json({error: "Error"}); }
});
// ==========================================
//   RUTAS: TORTILLERÍAS Y PREDETERMINADOS
// ==========================================

// Crear pedido predeterminado (Va directo a un repartidor)
app.post('/ordenes/predeterminadas', async (req, res) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        //  AÑADIMOS EL id_trabajador AL BODY Y AL INSERT
        const { id_tortilleria, id_repartidor, id_trabajador, viaje_programado, total, productos } = req.body;
        const codigo_entrega = Math.floor(1000 + Math.random() * 9000).toString();

        const insertOrden = `
            INSERT INTO ordenes (id_tortilleria, id_repartidor, id_trabajador, estado, viaje_programado, total, codigo_entrega)
            VALUES ($1, $2, $3, 'Buscando Repartidor', $4, $5, $6) RETURNING id
        `;
        const resultOrden = await client.query(insertOrden, [id_tortilleria, id_repartidor, id_trabajador, viaje_programado, total, codigo_entrega]);
        const id_orden = resultOrden.rows[0].id;

        for (let prod of productos) {
            await client.query(`INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)`, [id_orden, prod.nombre || prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio]);
        }
        await client.query('COMMIT');
        
        io.emit('actualizacion_ordenes');
        
        const tortInfo = await client.query("SELECT nombre FROM tortillerias WHERE id=$1", [id_tortilleria]);
        const nombreTortilleria = tortInfo.rows[0] ? tortInfo.rows[0].nombre : 'Tortillería';

        // 🚀 AQUÍ ESTÁ EL SOCKET QUE DESCUBRISTE EN TUS SUEÑOS
        io.emit('notify_nuevo_pedido', { cliente: nombreTortilleria, id_orden: id_orden });

        // Avisar a TODOS los repartidores porque el pedido ahora es público
        const reps = await client.query("SELECT fcm_token FROM repartidores WHERE fcm_token IS NOT NULL");
        reps.rows.forEach(r => enviarPush(r.fcm_token, "Nuevo Viaje Programado 🛵", `Hay un nuevo viaje de ${nombreTortilleria} para las ${viaje_programado}`, { tipo: 'rep_nuevo', id_orden: id_orden.toString() }));

        res.json({ success: true, id_orden });
    } catch (err) { 
        await client.query('ROLLBACK'); 
        res.status(500).json({ error: "Error al crear la orden" }); 
    } finally { client.release(); }
});

// Traer los tickets de una Tortillería
app.get('/ordenes/tortilleria/:id', async (req, res) => {
    try {
        const query = `
            SELECT o.*, r.nombre AS nombre_repartidor, t.nombre AS cliente, tr.nombre AS responsable, 
            (SELECT estado FROM solicitudes_edicion s WHERE s.id_orden = o.id ORDER BY id DESC LIMIT 1) as estado_solicitud,
            (SELECT id FROM solicitudes_edicion s WHERE s.id_orden = o.id ORDER BY id DESC LIMIT 1) as id_solicitud,
            ${subqueryProductosConImagen} 
            FROM ordenes o 
            LEFT JOIN repartidores r ON o.id_repartidor = r.id 
            LEFT JOIN tortillerias t ON o.id_tortilleria = t.id
            LEFT JOIN trabajadores tr ON o.id_trabajador = tr.id
            WHERE o.id_tortilleria = $1 ORDER BY o.fecha_registro DESC
        `;
        const result = await pool.query(query, [req.params.id]);
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// Cambiar estado a "Cobrado"
app.put('/ordenes/cobrar/:id', async (req, res) => {
    try {
        await pool.query(`UPDATE ordenes SET estado = 'Cobrado' WHERE id = $1`, [req.params.id]);
        io.emit('actualizacion_ordenes');
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// ==========================================
//    RUTAS: COMPARTIR PEDIDOS (REPARTIDORES)
// ==========================================

// 1. Ver qué repartidores están ocupados y qué llevan
app.get('/ordenes/en-proceso/repartidores', async (req, res) => {
    try {
        const query = `
            SELECT r.id AS id_repartidor, r.nombre AS nombre_repartidor, r.telefono, r.imagen AS foto_repartidor,
                   o.id AS id_orden, COALESCE(c.nombre_propietario, tr.nombre, tor.nombre) AS cliente, o.direccion_custom AS direccion, o.total, o.viaje_programado, o.estado, ${subqueryProductosConImagen}
            COALESCE(c.local, tor.nombre) AS local,
                   o.direccion_custom AS direccion, o.total, o.viaje_programado, o.estado, ${subqueryProductosConImagen}
                   FROM ordenes o
            JOIN repartidores r ON o.id_repartidor = r.id
            LEFT JOIN clientes c ON o.id_cliente = c.id
            LEFT JOIN trabajadores tr ON o.id_trabajador = tr.id
            LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id
            WHERE o.estado IN ('Asignado', 'Pendiente', 'En Camino')
            ORDER BY r.id, o.fecha_registro ASC
        `;
        const result = await pool.query(query);
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 2. Solicitante (B) pide órdenes al ocupado (A)
app.post('/ordenes/solicitar-compartir', async (req, res) => {
    const { id_repartidor_origen, id_repartidor_destino, nombre_destino, ordenes, cliente_nombre, productos } = req.body;

    const repOrigen = await pool.query("SELECT fcm_token FROM repartidores WHERE id=$1", [id_repartidor_origen]);
    if(repOrigen.rows.length > 0 && repOrigen.rows[0].fcm_token) {
        const notificationText = `${nombre_destino} solicita compartir ${ordenes.length} pedido(s) de tu ruta.`;
        enviarPush(
            repOrigen.rows[0].fcm_token, 
            "Solicitud de Transferencia 🤝", 
            notificationText, 
            { 
                tipo: 'rep_solicita_compartir', 
                data: JSON.stringify(req.body) // Enviamos todo el cuerpo para que el cliente reconstruya la petición
            }
        );
    }

    io.emit('peticion_compartir', { id_repartidor_origen, id_repartidor_destino, nombre_destino, ordenes, cliente_nombre, productos });
    res.json({success: true});
});

// 3. Ocupado (A) acepta, se genera código (SI ESTÁ EN CAMINO) o se asigna directo (SI NO LO HA RECOGIDO)
app.post('/ordenes/aceptar-compartir', async (req, res) => {
    try {
        const { id_repartidor_origen, id_repartidor_destino, ids_ordenes } = req.body;
        
        // 🚀 NUEVO: Consultamos el estado actual del pedido para saber qué flujo tomar
        const checkEstado = await pool.query('SELECT estado FROM ordenes WHERE id = $1', [ids_ordenes[0]]);
        const estadoActual = checkEstado.rows[0]?.estado;
        
        let requiereCodigo = false;
        let codigo = null;

        if (estadoActual === 'En Camino') {
            // CASO B: Ya lo tiene en la mano -> Requiere PIN
            requiereCodigo = true;
            codigo = Math.floor(1000 + Math.random() * 9000).toString();
            await pool.query(`UPDATE ordenes SET codigo_transferencia = $1, id_repartidor_destino = $2 WHERE id = ANY($3::int[])`, [codigo, id_repartidor_destino, ids_ordenes]);
        } else {
            // CASO A: Aún no lo recoge ('Buscando Repartidor', 'Asignado', 'Pendiente') -> Transferencia Inmediata
            await pool.query(`UPDATE ordenes SET id_repartidor = $1, codigo_transferencia = NULL, id_repartidor_destino = NULL WHERE id = ANY($2::int[])`, [id_repartidor_destino, ids_ordenes]);
        }

        const repDestino = await pool.query("SELECT fcm_token FROM repartidores WHERE id=$1", [id_repartidor_destino]);
        const repOrigen = await pool.query("SELECT nombre FROM repartidores WHERE id=$1", [id_repartidor_origen]);

        if(repDestino.rows.length > 0 && repDestino.rows[0].fcm_token) {
            const ordInfo = await pool.query("SELECT COALESCE(c.nombre_propietario, t.nombre, tor.nombre) as cliente FROM ordenes o LEFT JOIN clientes c ON o.id_cliente = c.id LEFT JOIN trabajadores t ON o.id_trabajador = t.id LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id WHERE o.id = $1", [ids_ordenes[0]]);
            const clienteNombre = ordInfo.rows[0]?.cliente || 'un pedido';

            if (requiereCodigo) {
                // Notificación para cuando necesita dictar el PIN (Caso B)
                enviarPush(
                    repDestino.rows[0].fcm_token, 
                    "Transferencia Aceptada ✅", 
                    `${repOrigen.rows[0]?.nombre} aceptó compartir el pedido de ${clienteNombre}.`, 
                    { 
                        tipo: 'rep_acepto_compartir', 
                        id_orden: ids_ordenes[0].toString(),
                        codigo_transferencia: codigo
                    }
                );
            } else {
                 // Notificación para cuando se transfiere directo (Caso A)
                 enviarPush(
                    repDestino.rows[0].fcm_token, 
                    "¡Pedido transferido! 🛵", 
                    `El pedido de ${clienteNombre} ahora es tuyo.`, 
                    { 
                        tipo: 'rep_nuevo', // Usamos rep_nuevo para que solo recargue la pantalla
                        id_orden: ids_ordenes[0].toString(),
                    }
                );
            }
        }

        io.emit('compartir_aceptado', { 
            id_repartidor_origen, id_repartidor_destino, ids_ordenes,
            codigo_transferencia: codigo,
            requiere_codigo: requiereCodigo // 👈 Le avisamos a Flutter qué pasó
        });
        io.emit('actualizacion_ordenes');
        io.emit('compartir_rechazado', { id_repartidor_destino, ids_ordenes });
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 4. Ocupado (A) mete el código que le dictó (B) y se transfiere la orden
app.post('/ordenes/confirmar-transferencia', async (req, res) => {
    try {
        const { ids_ordenes, id_repartidor_destino, codigo } = req.body;
        
        const check = await pool.query(`SELECT id, id_trabajador, id_cliente FROM ordenes WHERE id = ANY($1::int[]) AND codigo_transferencia = $2`, [ids_ordenes, codigo]);
        
        if (check.rows.length > 0) {
            // Transferencia exitosa: Limpiamos los rastros y asignamos al nuevo dueño
            await pool.query(`UPDATE ordenes SET id_repartidor = $1, codigo_transferencia = NULL, id_repartidor_destino = NULL WHERE id = ANY($2::int[])`, [id_repartidor_destino, ids_ordenes]);
            
            const repResult = await pool.query(`SELECT nombre FROM repartidores WHERE id = $1`, [id_repartidor_destino]);
            const nombreNuevoRepartidor = repResult.rows[0]?.nombre || 'Un nuevo repartidor';

            // Avisamos a los clientes/trabajadores que hubo cambio de conductor
            check.rows.forEach(o => {
                io.emit('notify_cambio_repartidor', { id_orden: o.id, id_cliente: o.id_cliente, id_trabajador: o.id_trabajador, nombre_repartidor: nombreNuevoRepartidor });
            });

            io.emit('actualizacion_ordenes');
            res.json({ success: true });
        } else {
            res.json({ success: false, message: "Código incorrecto" });
        }
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 3.5 Ocupado (A) RECHAZA la solicitud de transferencia de (B)
app.post('/ordenes/rechazar-compartir', async (req, res) => {
    try {
        const { id_repartidor_destino, ids_ordenes } = req.body;
        
        // 🚀 AQUÍ ESTÁ LA MAGIA QUE DESTRABA EL BOTÓN
        io.emit('compartir_rechazado', { id_repartidor_destino, ids_ordenes });

        // Buscamos el token del wey que pidió el viaje para mandarle una notificación
        const repDestino = await pool.query("SELECT fcm_token FROM repartidores WHERE id=$1", [id_repartidor_destino]);
        
        if (repDestino.rows.length > 0 && repDestino.rows[0].fcm_token) {
             enviarPush(
                repDestino.rows[0].fcm_token, 
                "Solicitud Rechazada ❌", 
                "El compañero no pudo aceptar la transferencia del pedido.", 
                { tipo: 'rep_rechazo_compartir' }
            );
        }

        res.json({ success: true });
    } catch (err) { 
        console.error(err);
        res.status(500).json({ error: "Error al rechazar" }); 
    }
});

// ==========================================
// RUTAS DE ADMINISTRADOR
// ==========================================

// 1. Dashboard Master (ACTUALIZADO FASE 3: Radar de Faltantes)
app.get('/admin/ordenes/dashboard', async (req, res) => {
    try {
        const query = `
            SELECT o.*, 
            COALESCE(c.nombre_propietario, t.nombre, tor.nombre) AS cliente, 
            COALESCE(c.local, tor.nombre) AS local,
            COALESCE(c.telefono, t.telefono) AS telefono, 
            COALESCE(o.direccion_custom, c.direccion, 'Tortillería ' || tor.nombre) AS direccion,
            COALESCE(o.lat_custom, CAST(c.latitud AS VARCHAR), CAST(tor.latitud AS VARCHAR)) AS latitud, 
            COALESCE(o.lng_custom, CAST(c.longitud AS VARCHAR), CAST(tor.longitud AS VARCHAR)) AS longitud, 
            r.nombre AS nombre_repartidor,
            COALESCE(c.imagen, t.imagen) AS foto_cliente, 
            r.imagen AS foto_repartidor, 
            ${subqueryProductosConImagen}
            FROM ordenes o 
            LEFT JOIN clientes c ON o.id_cliente = c.id 
            LEFT JOIN trabajadores t ON o.id_trabajador = t.id 
            LEFT JOIN tortillerias tor ON o.id_tortilleria = tor.id
            LEFT JOIN repartidores r ON o.id_repartidor = r.id
            WHERE o.estado != 'Cancelada'
            ORDER BY o.fecha_registro DESC
        `;
        const result = await pool.query(query);

        const recibidos = [];
        const asignados = [];
        const pendientes = [];
        const completados = [];
        const rescates = []; // 👈 FASE 3: Nuevo arreglo para el Radar
        const idsToDelete = []; 

        const formatter = new Intl.DateTimeFormat('en-US', {
            timeZone: 'America/Mexico_City',
            year: 'numeric', month: 'numeric', day: 'numeric',
            hour: 'numeric', minute: 'numeric', second: 'numeric',
            hour12: false
        });
        const parts = formatter.formatToParts(new Date());
        const mx = {};
        parts.forEach(({ type, value }) => { mx[type] = parseInt(value); });
        if (mx.hour === 24) mx.hour = 0;
        
        const mxNow = new Date(mx.year, mx.month - 1, mx.day, mx.hour, mx.minute, mx.second);

        result.rows.forEach(orden => {
            let orderDate = new Date(mx.year, mx.month - 1, mx.day, mx.hour, mx.minute, mx.second);
            const viajeStr = orden.viaje_programado;

            if (viajeStr && viajeStr.startsWith('Prog:')) {
                try {
                    const parts = viajeStr.split(' '); 
                    const datePart = parts[1];
                    const [day, month, year] = datePart.split('/');
                    orderDate.setFullYear(parseInt(year), parseInt(month) - 1, parseInt(day));
                } catch (e) { console.error(e); }
            } else {
                orderDate = new Date(new Date(orden.fecha_registro).toLocaleString("en-US", {timeZone: "America/Mexico_City"}));
            }

            let orderMidnight = new Date(orderDate);
            orderMidnight.setHours(0, 0, 0, 0);

            let cutoffTime = new Date(orderDate);
            
            if (viajeStr && viajeStr.startsWith('Viaje ') && orderDate.getHours() >= 19) {
                cutoffTime.setDate(cutoffTime.getDate() + 1);
            }
            cutoffTime.setHours(23, 59, 0, 0);

            //if (mxNow < orderMidnight) return; 

            //  EVITAMOS QUE BORRE LOS COBRADOS A LA MEDIANOCHE
            if (mxNow > cutoffTime && orden.estado !== 'Completada' && orden.estado !== 'Cobrado' && !(viajeStr && viajeStr.startsWith('Viaje '))) {
                idsToDelete.push(orden.id);
                return; 
            }

            //  DISTRIBUCIÓN: Metemos Completadas y Cobradas en la misma pestaña
            if (orden.estado === 'Completada' || orden.estado === 'Cobrado') {
                completados.push(orden);
            } else if (viajeStr === 'Entrega de pedido pendiente' || viajeStr === 'Prog: Rescate (Mañana)') {
                rescates.push(orden); 
            } else if (orden.estado === 'Buscando Repartidor') {
                recibidos.push(orden);
            } else if (orden.estado === 'Asignado') {
                asignados.push(orden);
            } else if (orden.estado === 'Pendiente' || orden.estado === 'En Camino') {
                pendientes.push(orden);
            }
        });

        if (idsToDelete.length > 0) {
            const idsStr = idsToDelete.join(',');
            pool.query(`DELETE FROM ordenes_productos WHERE id_orden IN (${idsStr})`)
                .then(() => pool.query(`DELETE FROM ordenes WHERE id IN (${idsStr})`));
        }

        res.json({ success: true, data: { recibidos, asignados, pendientes, completados, rescates } });
    } catch (error) { res.status(500).json({ success: false, error: 'Error del servidor' }); }
});

app.get('/admin/mercancia-faltante', async (req, res) => {
    try {
        const query = `
            SELECT
                COALESCE(o.id, mf.id_orden) AS id,
                mf.id_orden,
                mf.id_cliente,
                mf.id_trabajador,
                mf.id_tortilleria,
                COALESCE(c.nombre_propietario, t.nombre, tor.nombre, 'Desconocido') AS cliente,
                COALESCE(c.local, tor.nombre) AS local,
                COALESCE(c.telefono, t.telefono) AS telefono,
                COALESCE(o.direccion_custom, c.direccion, 'Tortillería ' || tor.nombre) AS direccion,
                COALESCE(o.lat_custom, CAST(c.latitud AS VARCHAR), CAST(tor.latitud AS VARCHAR)) AS latitud,
                COALESCE(o.lng_custom, CAST(c.longitud AS VARCHAR), CAST(tor.longitud AS VARCHAR)) AS longitud,
                COALESCE(c.imagen, t.imagen) AS foto_cliente,
                r.nombre AS nombre_repartidor,
                r.imagen AS foto_repartidor,
                COALESCE(o.viaje_programado, 'Entrega de pedido pendiente') AS viaje_programado,
                COALESCE(o.estado, 'Buscando Repartidor') AS estado,
                o.total,
                o.codigo_entrega,
                o.fecha_registro,
                json_agg(json_build_object(
                    'id', mf.id,
                    'nombre_producto', mf.nombre_producto,
                    'cantidad_faltante', mf.cantidad_faltante,
                    'estado', mf.estado
                ) ORDER BY mf.id) AS productos
            FROM mercancia_faltante mf
            LEFT JOIN ordenes o ON mf.id_orden = o.id
            LEFT JOIN clientes c ON mf.id_cliente = c.id
            LEFT JOIN trabajadores t ON mf.id_trabajador = t.id
            LEFT JOIN tortillerias tor ON mf.id_tortilleria = tor.id
            LEFT JOIN repartidores r ON o.id_repartidor = r.id
            GROUP BY
                o.id, mf.id_orden, mf.id_cliente, mf.id_trabajador, mf.id_tortilleria,
                c.nombre_propietario, t.nombre, tor.nombre, c.local, c.telefono, t.telefono,
                o.direccion_custom, c.direccion, o.lat_custom, c.latitud, tor.latitud,
                o.lng_custom, c.longitud, tor.longitud, c.imagen, t.imagen,
                r.nombre, r.imagen, o.viaje_programado, o.estado,
                o.total, o.codigo_entrega, o.fecha_registro
            ORDER BY o.fecha_registro DESC
        `;
        const result = await pool.query(query);
        res.json({ success: true, data: result.rows });
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: 'Error al obtener mercancia faltante para admin' });
    }
});

// 2. Obtener lista de repartidores (Corregido para buscar en la tabla 'repartidores')
app.get('/admin/repartidores', async (req, res) => {
    try {
        const result = await pool.query(`SELECT id, nombre, telefono FROM repartidores`);
        res.json(result.rows);
    } catch (error) { 
        res.status(500).json({ error: 'Error al obtener repartidores' }); 
    }
});

// 3. Asignar o Reasignar Orden (Ajustado para recibir /asignar/:id como manda Flutter)
app.put('/admin/ordenes/asignar/:id', async (req, res) => {
    const { id } = req.params;
    const { id_repartidor } = req.body;

    if (!id_repartidor) {
        return res.status(400).json({ error: 'Falta el ID del repartidor' });
    }

    try {
        // Obligamos a que el estado sea 'Asignado' para que el radar del repartidor lo detecte
        const result = await pool.query(
            `UPDATE ordenes SET id_repartidor = $1, estado = 'Asignado' WHERE id = $2 RETURNING id`,
            [id_repartidor, id]
        );

        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Orden no encontrada' });
        }
        const rep = await pool.query("SELECT nombre FROM repartidores WHERE id=$1", [id_repartidor]);
        const ord = await pool.query("SELECT id_cliente, id_trabajador FROM ordenes WHERE id=$1", [id]);
        
        io.emit('actualizacion_ordenes');
        io.emit('notify_pedido_asignado', { 
            id_orden: id, 
            id_repartidor: id_repartidor, 
            nombre_repartidor: rep.rows[0]?.nombre || "Un repartidor",
            id_cliente: ord.rows[0]?.id_cliente,
            id_trabajador: ord.rows[0]?.id_trabajador
        });
        const repInfo = await pool.query("SELECT fcm_token FROM repartidores WHERE id=$1", [id_repartidor]);
        if (repInfo.rows.length > 0 && repInfo.rows[0].fcm_token) {
            enviarPush(repInfo.rows[0].fcm_token, "Pedido Asignado", "Tienes un nuevo pedido asignado. ¡A rodar!");
        }
        res.json({ message: 'Orden asignada con éxito, el repartidor ya fue notificado' });
    } catch (error) { 
        console.error("Error asignando:", error);
        res.status(500).json({ error: 'Error interno al asignar' }); 
    }
});

// 4. Eliminar Orden (Ajustado para recibir /:id directo como manda Flutter)
app.delete('/admin/ordenes/:id', async (req, res) => {
    try {
        await pool.query('DELETE FROM ordenes_productos WHERE id_orden = $1', [req.params.id]);
        await pool.query('DELETE FROM ordenes WHERE id = $1', [req.params.id]);
        io.emit('actualizacion_ordenes');
        res.json({ message: 'Orden eliminada de raíz' });
    } catch (error) { 
        res.status(500).json({ error: 'Error al eliminar' }); 
    }
});
// Ruta para actualizar la foto de perfil
app.put('/perfil/actualizar-imagen', async (req, res) => {
    const { id, rol, imagen } = req.body;
    let tabla = 'clientes'; // Por defecto
    
    if (rol === 'admin') tabla = 'usuarios';
    else if (rol === 'repartidor') tabla = 'repartidores';
    else if (rol === 'trabajador') tabla = 'trabajadores';

    try {
        await pool.query(`UPDATE ${tabla} SET imagen = $1 WHERE id = $2`, [imagen, id]);
        res.json({ success: true, message: "Imagen actualizada correctamente" });
    } catch (err) {
        console.error("Error al actualizar imagen:", err);
        res.status(500).json({ success: false, message: "Error en el servidor" });
    }
});
// Variable global para guardar los códigos en memoria
 // Ej: { "correo@ejemplo.com": "1234" }

// Enviar código de verificación
// Enviar código de verificación
app.post('/perfil/enviar-codigo', async (req, res) => {
    const { correo } = req.body;
    if (!correo) return res.status(400).json({ success: false, message: "Correo requerido" });
    
    const codigo = Math.floor(1000 + Math.random() * 9000).toString();
    codigosVerificacion[correo] = codigo; // Se guarda vinculado al correo

    //  CODIGO DEBUG
    console.log(`\n===========================================`);
    console.log(`🔑 CÓDIGO GENERADO PARA: ${correo}`);
    console.log(`🔑 PIN: ${codigo}`);
    console.log(`===========================================\n`);

    const mailOptions = {
        from: '"Soporte de Seguridad Tlatoani" <udisystemc5@gmail.com>',
        to: correo,
        subject: "Código de Verificación",
        text: `Tu código de seguridad es: ${codigo}\n\nIngrésalo en la aplicación para autorizar tu registro.`
    };

    try {
        await transporter.sendMail(mailOptions);
        res.json({ success: true, message: "Código enviado al correo" });
    } catch (err) {
        console.error("Error enviando correo (Gmail berrinchudo):", err.message);
        //  AUNQUE FALLE EL CORREO, LE DECIMOS A FLUTTER QUE SÍ SE ENVIÓ PARA QUE USES EL PIN DE LA CONSOLA
        res.json({ success: true, message: "Simulado en consola" });
    }
});

// Actualizar un campo general del perfil
app.put('/perfil/actualizar-campo', async (req, res) => {
    const { id, rol, campo, valor, codigo, correoConfirmacion } = req.body;
    
    let tabla = 'clientes';
    if (rol === 'admin') tabla = 'usuarios';
    else if (rol === 'repartidor') tabla = 'repartidores';
    else if (rol === 'trabajador') tabla = 'trabajadores';

    //  Validación estricta para usuario y correo
    if (campo === 'correo' || campo === 'usuario') {
        if (!codigosVerificacion[correoConfirmacion] || codigosVerificacion[correoConfirmacion] !== codigo) {
            return res.json({ success: false, message: "El código es incorrecto o ya caducó." });
        }
    }

    // Mapeo dinámico de nombres de columnas en la BD
    let columna = campo;
    if (campo === 'nombre') {
        if (tabla === 'clientes') columna = 'nombre_propietario';
        else if (tabla === 'usuarios') columna = 'nombres';
        else columna = 'nombre';
    }

    try {
        // Bloqueo de duplicados en la base de datos
        if (campo === 'correo' || campo === 'usuario') {
            const check = await pool.query(`SELECT id FROM ${tabla} WHERE ${columna} = $1 AND id != $2`, [valor, id]);
            if (check.rows.length > 0) return res.json({ success: false, message: `Ese ${campo} ya está ocupado por otra persona.` });
        }

        await pool.query(`UPDATE ${tabla} SET ${columna} = $1 WHERE id = $2`, [valor, id]);
        
        // Exterminamos el código de la memoria para que no se re-use
        if (campo === 'correo' || campo === 'usuario') {
            delete codigosVerificacion[correoConfirmacion];
        }

        res.json({ success: true, message: "Actualizado correctamente" });
    } catch(err) {
        res.status(500).json({ success: false, message: "Error al actualizar la base de datos" });
    }
});

// Reseteo maestro de contraseña con PIN
app.post('/perfil/reset-password-codigo', async (req, res) => {
    const { correo, codigo, nuevaPassword } = req.body;
    
    if (!codigosVerificacion[correo] || codigosVerificacion[correo] !== codigo) {
        return res.json({ success: false, message: "Código incorrecto." });
    }
    
    try {
        let tabla = null, id = null;
        const tablas = ['clientes', 'usuarios', 'repartidores', 'trabajadores'];
        
        for(let t of tablas) {
            let r = await pool.query(`SELECT id FROM ${t} WHERE correo = $1`, [correo]);
            if (r.rows.length > 0) { tabla = t; id = r.rows[0].id; break; }
        }
        
        if (!tabla) return res.json({ success: false, message: "No encontramos tu cuenta." });

        const nuevoHash = await bcrypt.hash(nuevaPassword, 10);
        await pool.query(`UPDATE ${tabla} SET password = $1 WHERE id = $2`, [nuevoHash, id]);
        
        delete codigosVerificacion[correo];
        res.json({ success: true, message: "Contraseña actualizada exitosamente" });
    } catch(err) {
        res.status(500).json({ success: false, message: "Error en el servidor" });
    }
});
// Completar perfil de empleados (Repartidores/Trabajadores)
app.put('/perfil/completar-empleado', async (req, res) => {
    //  Agregamos 'telefono' aquí
    const { id, rol, correo, telefono, usuario, password, imagen } = req.body;
    
    let tabla = '';
    if (rol === 'admin') tabla = 'usuarios';
    else if (rol === 'repartidor') tabla = 'repartidores';
    else if (rol === 'trabajador') tabla = 'trabajadores';

    if (!tabla) return res.status(400).json({ success: false, message: "Rol inválido" });

    try {
        const hashedPass = await bcrypt.hash(password, 10);
        //  Agregamos telefono = $2 en el UPDATE
        await pool.query(
            `UPDATE ${tabla} SET correo = $1, telefono = $2, usuario = $3, password = $4, imagen = $5 WHERE id = $6`,
            [correo, telefono, usuario, hashedPass, imagen, id]
        );
        res.json({ success: true, message: "Perfil completado exitosamente" });
    } catch (err) {
        if (err.code === '23505') return res.status(400).json({ success: false, message: "El usuario o correo ya está en uso." });
        res.status(500).json({ success: false, message: "Error al actualizar perfil" });
    }
});
// ==========================================
// RUTAS: SOLICITUDES DE EDICIÓN (TRABAJADORES)
// ==========================================

// 1. Traer predeterminados del local para el trabajador (SOLO LOS DE HOY)
app.get('/ordenes/predeterminadas/local/:id_tortilleria', async (req, res) => {
    try {
        const query = `
            SELECT o.*, 
            r.nombre AS nombre_repartidor, r.telefono AS tel_repartidor, r.imagen AS foto_repartidor,
            (SELECT estado FROM solicitudes_edicion s WHERE s.id_orden = o.id ORDER BY id DESC LIMIT 1) as estado_solicitud,
            ${subqueryProductosConImagen}
            FROM ordenes o
            LEFT JOIN repartidores r ON o.id_repartidor = r.id
            WHERE o.id_tortilleria = $1 
            AND o.viaje_programado LIKE 'Viaje %' 
            AND o.estado NOT IN ('Cobrado', 'Cancelada')
            /*  ESTA ES LA MAGIA QUE EVITA DUPLICADOS: SOLO TRAE LOS DE HOY  */
            AND DATE(o.fecha_registro AT TIME ZONE 'America/Mexico_City') = DATE(CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')
            ORDER BY o.viaje_programado ASC
        `;
        const result = await pool.query(query, [req.params.id_tortilleria]);
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 2. El trabajador envía la solicitud de edición
app.post('/solicitudes-edicion', async (req, res) => {
    try {
        const { id_orden, id_trabajador, productos_nuevos, total_nuevo } = req.body;
        await pool.query(`INSERT INTO solicitudes_edicion (id_orden, id_trabajador, productos_nuevos, total_nuevo, estado) VALUES ($1, $2, $3, $4, 'Pendiente')`, [id_orden, id_trabajador, JSON.stringify(productos_nuevos), total_nuevo]);
        
        const info = await pool.query("SELECT o.viaje_programado, t.nombre as tortilleria, tr.nombre as trabajador FROM ordenes o LEFT JOIN tortillerias t ON o.id_tortilleria = t.id LEFT JOIN trabajadores tr ON o.id_trabajador = tr.id WHERE o.id = $1", [id_orden]);
        
        //  NOTIFICACIÓN ADMIN 5
        const admins = await pool.query("SELECT fcm_token FROM usuarios WHERE fcm_token IS NOT NULL");
        admins.rows.forEach(a => enviarPush(a.fcm_token, "Edición 📝", `${info.rows[0]?.trabajador} de la tortilleria ${info.rows[0]?.tortilleria} Solicita editar su pedido predeterminado ${info.rows[0]?.viaje_programado}`, { tipo: 'admin_solicitud_edicion', id_orden: id_orden.toString() }));

        io.emit('actualizacion_ordenes'); 
        res.json({ success: true });
    } catch (error) { res.status(500).json({ error: "Error" }); }
});

// 3. [PARA EL ADMIN MÁS ADELANTE] Aprobar la solicitud
app.put('/admin/solicitudes/aprobar/:id_solicitud', async (req, res) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const reqData = await client.query('SELECT * FROM solicitudes_edicion WHERE id = $1', [req.params.id_solicitud]);
        const solicitud = reqData.rows[0];
        const prods = typeof solicitud.productos_nuevos === 'string' ? JSON.parse(solicitud.productos_nuevos) : solicitud.productos_nuevos;
        
        await client.query('UPDATE ordenes SET total = $1 WHERE id = $2', [solicitud.total_nuevo, solicitud.id_orden]);
        await client.query('DELETE FROM ordenes_productos WHERE id_orden = $1', [solicitud.id_orden]);
        for (let prod of prods) await client.query(`INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)`, [solicitud.id_orden, prod.nombre || prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio]);
        await client.query('UPDATE solicitudes_edicion SET estado = $1 WHERE id = $2', ['Aprobada', req.params.id_solicitud]);
        await client.query('COMMIT');
        
        //  NOTIFICACIÓN TRABAJADOR 4
        const trab = await pool.query("SELECT fcm_token FROM trabajadores WHERE id=$1", [solicitud.id_trabajador]);
        if(trab.rows.length>0) enviarPush(trab.rows[0].fcm_token, "Autorizado ✅", "El Administrador autorizo la edicion del pedido predeterminado", { tipo: 'cli_edicion', id_orden: solicitud.id_orden.toString() });

        io.emit('actualizacion_ordenes');
        res.json({ success: true });
    } catch(e) { await client.query('ROLLBACK'); res.status(500).json({ error: e.message }); } finally { client.release(); }
});

// 4. [PARA EL ADMIN MÁS ADELANTE] Rechazar la solicitud
app.put('/admin/solicitudes/rechazar/:id_solicitud', async (req, res) => {
    try {
        const reqData = await pool.query('UPDATE solicitudes_edicion SET estado = $1 WHERE id = $2 RETURNING id_trabajador', ['Rechazada', req.params.id_solicitud]);
        
        //  NOTIFICACIÓN TRABAJADOR 5
        const trab = await pool.query("SELECT fcm_token FROM trabajadores WHERE id=$1", [reqData.rows[0].id_trabajador]);
        if(trab.rows.length>0) enviarPush(trab.rows[0].fcm_token, "Rechazado ❌", "El Administrador rechazo la edicion del pedido predeterminado", { tipo: 'cli_edicion_rechazo' });
        
        io.emit('actualizacion_ordenes');
        res.json({ success: true });
    } catch(e) { res.status(500).json({ error: "Error" }); }
});
const cron = require('node-cron');

// Se ejecuta todos los días a las 12:00 AM (00:00) hora de CDMX
cron.schedule('0 0 * * *', async () => {
    console.log("🔄 Ejecutando reinicio de viajes predeterminados (12:00 AM)...");
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        // (Si el trabajador pidió edición y el admin aprobó, se usará la versión nueva automáticamente)
        // 1. Obtener la versión más reciente de cada viaje predeterminado
        const queryPlantillas = `
            SELECT DISTINCT ON (id_tortilleria, viaje_programado) *
            FROM ordenes
            WHERE id_tortilleria IS NOT NULL 
            AND viaje_programado LIKE 'Viaje %'
            AND hubo_faltante = FALSE 
            ORDER BY id_tortilleria, viaje_programado, fecha_registro DESC
        `;
        const plantillas = await client.query(queryPlantillas);

        // 2. Clonarlas como nuevas órdenes "Pendientes" para hoy
        for (let orden of plantillas.rows) {
            const codigo_entrega = Math.floor(1000 + Math.random() * 9000).toString();
            
            const insertOrden = `
                INSERT INTO ordenes (id_tortilleria, id_repartidor, id_trabajador, estado, viaje_programado, total, codigo_entrega)
                VALUES ($1, $2, $3, 'Buscando Repartidor', $4, $5, $6) RETURNING id
            `;
            const nuevaOrden = await client.query(insertOrden, [
                orden.id_tortilleria, 
                null, 
                orden.id_trabajador, // Se le asignará al trabajador que inicie sesión hoy
                orden.viaje_programado, 
                orden.total, 
                codigo_entrega
            ]);
            
            const id_nueva_orden = nuevaOrden.rows[0].id;

            // 3. Clonar sus productos
            const productos = await client.query('SELECT * FROM ordenes_productos WHERE id_orden = $1', [orden.id]);
            for (let prod of productos.rows) {
                await client.query(
                    'INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)', 
                    [id_nueva_orden, prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio]
                );
            }
        }
        
        await client.query('COMMIT');
        console.log(`✅ ${plantillas.rows.length} viajes predeterminados creados para hoy.`);
        io.emit('actualizacion_ordenes'); // Avisa a las apps de los repartidores
        io.emit('notify_nuevo_pedido', { cliente: 'Múltiples Locales', id_orden: 0 }); // 🚀 SOCKET PARA EL AUTOMÁTICO
    } catch (err) {
        await client.query('ROLLBACK');
        console.error("❌ Error al clonar predeterminadas:", err);
    } finally {
        client.release();
    }
}, {
    timezone: "America/Mexico_City"
});
// ==========================================
//        RUTAS DE MERCANCÍA FALTANTE (LIMBO)
// ==========================================
// 1. Obtener toda la mercancía en el Limbo (Agotada o Disponible)
app.get('/mercancia-faltante', async (req, res) => {
    try {
        const query = `
            SELECT mf.*, 
            COALESCE(c.nombre_propietario, t.nombre, tor.nombre, 'Desconocido') AS afectado,
            COALESCE(o.viaje_programado, 'Inmediato') AS viaje_programado,
            o.fecha_registro as fecha_orden
            FROM mercancia_faltante mf
            LEFT JOIN clientes c ON mf.id_cliente = c.id
            LEFT JOIN trabajadores t ON mf.id_trabajador = t.id
            LEFT JOIN tortillerias tor ON mf.id_tortilleria = tor.id
            LEFT JOIN ordenes o ON mf.id_orden = o.id
            ORDER BY mf.fecha_registro DESC
        `;
        const result = await pool.query(query);
        res.json(result.rows);
    } catch (err) { res.status(500).json({ error: "Error en el servidor" }); }
});

// 2. Marcar Faltante como "Disponible" y avisar
app.put('/mercancia-faltante/disponible/:id', async (req, res) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        
        await client.query(`UPDATE mercancia_faltante SET estado = 'Disponible' WHERE id = $1`, [req.params.id]);
        
        const info = await client.query("SELECT * FROM mercancia_faltante WHERE id = $1", [req.params.id]);
        
        if (info.rows.length > 0) {
            const f = info.rows[0];
            io.emit('notify_faltante_disponible', { 
                id_cliente: f.id_cliente, 
                id_trabajador: f.id_trabajador,
                id_tortilleria: f.id_tortilleria,
                nombre_producto: f.nombre_producto 
            });

            // Si es un cliente o un trabajador con token, le mandamos PUSH
            let token = null;
            if (f.id_cliente) {
                const u = await client.query("SELECT fcm_token FROM clientes WHERE id = $1", [f.id_cliente]);
                token = u.rows[0]?.fcm_token;
            } else if (f.id_trabajador) {
                const u = await client.query("SELECT fcm_token FROM trabajadores WHERE id = $1", [f.id_trabajador]);
                token = u.rows[0]?.fcm_token;
            }
            if (token) enviarPush(token, "¡Mercancía Disponible!", `Ya hay stock de ${f.nombre_producto}. ¡Pide tu reposición ahora!`);
        }

        await client.query('COMMIT');
        res.json({ success: true });
    } catch (err) { 
        await client.query('ROLLBACK');
        res.status(500).json({ error: "Error" }); 
    } finally {
        client.release();
    }
});
// 3. FASE 1: Obtener faltantes agrupados por viaje para Trabajador (MUESTRA TODOS)
app.get('/mercancia-faltante/local/:id', async (req, res) => {
    try {
        // Quitamos el filtro estricto y buscamos por id_tortilleria O id_trabajador (si el trabajador es el dueño del turno)
        const query = `
            SELECT mf.*, o.viaje_programado, o.fecha_registro as fecha_orden
            FROM mercancia_faltante mf
            LEFT JOIN ordenes o ON mf.id_orden = o.id
            WHERE mf.id_tortilleria = $1 OR mf.id_trabajador = (SELECT id_trabajador_actual FROM tortillerias WHERE id = $1)
            ORDER BY mf.id_orden DESC, mf.fecha_registro ASC
        `;
        const result = await pool.query(query, [req.params.id]);
        
        const agrupados = {};
        for(let row of result.rows) {
            if(!agrupados[row.id_orden]) {
                agrupados[row.id_orden] = {
                    id_orden: row.id_orden,
                    viaje_programado: row.viaje_programado,
                    fecha_orden: row.fecha_orden,
                    todos_disponibles: true, 
                    faltantes: []
                };
            }
            if (row.estado === 'Agotado') {
                agrupados[row.id_orden].todos_disponibles = false; 
            }
            agrupados[row.id_orden].faltantes.push(row);
        }
        res.json(Object.values(agrupados));
    } catch (err) { res.status(500).json({ error: "Error en el servidor" }); }
});
// 3.5 FASE 1: Obtener faltantes agrupados por viaje para Cliente (MUESTRA TODOS)
app.get('/mercancia-faltante/cliente/:id', async (req, res) => {
    try {
        const query = `
            SELECT mf.*, COALESCE(o.viaje_programado, 'Inmediato') as viaje_programado, o.fecha_registro as fecha_orden
            FROM mercancia_faltante mf
            LEFT JOIN ordenes o ON mf.id_orden = o.id
            WHERE mf.id_cliente = $1
            ORDER BY mf.id_orden DESC, mf.fecha_registro ASC
        `;
        const result = await pool.query(query, [req.params.id]);
        
        const agrupados = {};
        for(let row of result.rows) {
            if(!agrupados[row.id_orden]) {
                agrupados[row.id_orden] = {
                    id_orden: row.id_orden,
                    viaje_programado: row.viaje_programado,
                    fecha_orden: row.fecha_orden,
                    todos_disponibles: true,
                    faltantes: []
                };
            }
            if (row.estado === 'Agotado') {
                agrupados[row.id_orden].todos_disponibles = false;
            }
            agrupados[row.id_orden].faltantes.push(row);
        }
        res.json(Object.values(agrupados));
    } catch (err) { res.status(500).json({ error: "Error en el servidor" }); }
});
// RUTA DE DEBUG: ESTA TRAE TODO SIN FILTRAR POR ID
app.get('/mercancia-faltante/debug-all', async (req, res) => {
    try {
        const query = `
            SELECT mf.*, o.viaje_programado, o.fecha_registro as fecha_orden
            FROM mercancia_faltante mf
            LEFT JOIN ordenes o ON mf.id_orden = o.id
            ORDER BY mf.id DESC LIMIT 10
        `;
        const result = await pool.query(query);
        console.log("🔍 DEBUG: Datos encontrados en tabla:", result.rows);
        res.json(result.rows);
    } catch (err) { 
        console.error("❌ ERROR DEBUG:", err);
        res.status(500).json({ error: "Error" }); 
    }
});

// 4. Eliminar un viaje faltante completo (si deciden descartar la tarjeta)
app.delete('/mercancia-faltante/viaje/:id_orden', async (req, res) => {
    try {
        await pool.query('DELETE FROM mercancia_faltante WHERE id_orden = $1', [req.params.id_orden]);
        res.json({ success: true });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 5. FASE 1: Crear la orden final de Rescate con REGLA DE TIEMPO
app.post('/ordenes/rescate', async (req, res) => {
    const client = await pool.connect();
    try {
        //  REGLA ESTRICTA DE TIEMPO (Bloqueado de 5:20 PM a 5:59 AM)
        const mxDate = new Date(new Date().toLocaleString("en-US", {timeZone: "America/Mexico_City"}));
        const mxHour = mxDate.getHours();
        const mxMinute = mxDate.getMinutes();

        const isBlocked = mxHour < 6 || (mxHour === 23 && mxMinute >= 20) || mxHour > 23;
        
        if (isBlocked) {
            return res.json({ 
                success: false, 
                message: "El horario para pedir rescates es de 6:00 AM a 5:20 PM." 
            });
        }

        await client.query('BEGIN');
        const { id_cliente, id_tortilleria, id_trabajador, total, productos, ids_faltantes } = req.body;
        const codigo_entrega = Math.floor(1000 + Math.random() * 9000).toString();

        // Titulo que pediste para los repartidores
        const viaje_programado = "Entrega de pedido pendiente"; 

        const insertOrden = `
            INSERT INTO ordenes (id_cliente, id_tortilleria, id_trabajador, estado, viaje_programado, total, codigo_entrega)
            VALUES ($1, $2, $3, 'Buscando Repartidor', $4, $5, $6) RETURNING id
        `;
        const resultOrden = await client.query(insertOrden, [id_cliente || null, id_tortilleria || null, id_trabajador || null, viaje_programado, total, codigo_entrega]);
        const id_orden = resultOrden.rows[0].id;

        for (let prod of productos) {
            await client.query('INSERT INTO ordenes_productos (id_orden, nombre_producto, detalle, cantidad, precio) VALUES ($1, $2, $3, $4, $5)', 
            [id_orden, prod.nombre || prod.nombre_producto, prod.detalle, prod.cantidad, prod.precio]);
        }

        // Borra los faltantes del limbo para que no los vuelvan a pedir
        if (ids_faltantes && ids_faltantes.length > 0) {
            await client.query('DELETE FROM mercancia_faltante WHERE id = ANY($1::int[])', [ids_faltantes]);
        }

        await client.query('COMMIT');
        io.emit('actualizacion_ordenes');
        
        let nombreC = "Alguien";
        if (id_cliente) { const r = await pool.query("SELECT nombre_propietario FROM clientes WHERE id=$1", [id_cliente]); if(r.rows.length>0) nombreC = r.rows[0].nombre_propietario; }
        else if (id_trabajador) { const r = await pool.query("SELECT nombre FROM trabajadores WHERE id=$1", [id_trabajador]); if(r.rows.length>0) nombreC = r.rows[0].nombre; }
        
        //  NOTIFICACIÓN REPARTIDOR 6
        const reps = await pool.query("SELECT fcm_token FROM repartidores WHERE fcm_token IS NOT NULL");
        reps.rows.forEach(r => enviarPush(r.fcm_token, "Rescate 📦", `${nombreC} solicita entrega de pedido faltante`, { tipo: 'rep_rescate', id_orden: id_orden.toString() }));
        
        io.emit('actualizacion_ordenes');
        io.emit('notify_nuevo_pedido', { cliente: nombreC, id_orden: id_orden });

        res.json({ success: true, id_orden });
    } catch (err) { 
        await client.query('ROLLBACK'); 
        res.status(500).json({ error: "Error al crear rescate" }); 
    } finally { 
        client.release(); 
    }
});
// ==========================================
//        RUTAS DE RESEÑAS (FASE 1)
// ==========================================

// 1. Guardar la reseña obligatoria
app.put('/ordenes/resena/:id', async (req, res) => {
    try {
        const { calificacion_pedido, calificacion_repartidor, comentario_repartidor } = req.body;
        await pool.query(`UPDATE ordenes SET calificacion_pedido = $1, calificacion_repartidor = $2, comentario_repartidor = $3 WHERE id = $4`, [calificacion_pedido, calificacion_repartidor, comentario_repartidor, req.params.id]);
        
        //  NOTIFICACIÓN REPARTIDOR 5
        const ord = await pool.query("SELECT id_repartidor, COALESCE(c.nombre_propietario, t.nombre) as cliente FROM ordenes o LEFT JOIN clientes c ON o.id_cliente = c.id LEFT JOIN trabajadores t ON o.id_trabajador = t.id WHERE o.id = $1", [req.params.id]);
        if (ord.rows.length > 0 && ord.rows[0].id_repartidor) {
            const rep = await pool.query("SELECT fcm_token FROM repartidores WHERE id=$1", [ord.rows[0].id_repartidor]);
            if(rep.rows.length>0) enviarPush(rep.rows[0].fcm_token, "Nueva Reseña ⭐", `${ord.rows[0].cliente} te ha reseñado`, { tipo: 'rep_resena', id_orden: req.params.id.toString() });
        }

        io.emit('actualizacion_ordenes');
        res.json({ success: true, message: 'Reseña guardada' });
    } catch (err) { res.status(500).json({ error: "Error" }); }
});

// 2. Verificar si el usuario tiene reseñas pendientes (El Purgatorio)
app.get('/ordenes/pendientes-resena/:rol/:id_usuario', async (req, res) => {
    try {
        const { rol, id_usuario } = req.params;
        let columna = rol === 'cliente' ? 'id_cliente' : 'id_trabajador';
        
        // Buscamos si hay alguna orden "Completada" que NO tenga calificacion
        const query = `
            SELECT o.*, r.nombre AS nombre_repartidor, r.imagen AS foto_repartidor 
            FROM ordenes o 
            LEFT JOIN repartidores r ON o.id_repartidor = r.id
            WHERE o.${columna} = $1 
              AND o.estado = 'Completada' 
              AND o.calificacion_pedido IS NULL
            ORDER BY o.fecha_entrega ASC
            LIMIT 1
        `;
        const result = await pool.query(query, [id_usuario]);
        
        if (result.rows.length > 0) {
            // Sí debe una reseña, lo mandamos al purgatorio
            res.json({ success: true, requiere_resena: true, orden: result.rows[0] });
        } else {
            // Está limpio, lo dejamos pasar
            res.json({ success: true, requiere_resena: false });
        }
    } catch (err) {
        res.status(500).json({ error: "Error al verificar reseñas" });
    }
});

// 3. Obtener el promedio y comentarios para el perfil del Repartidor
app.get('/repartidores/:id/resenas', async (req, res) => {
    try {
        // Sacamos el promedio de estrellas
        const resultPromedio = await pool.query(`
            SELECT ROUND(AVG(calificacion_repartidor), 1) as promedio, COUNT(*) as total_viajes
            FROM ordenes 
            WHERE id_repartidor = $1 AND calificacion_repartidor IS NOT NULL
        `, [req.params.id]);

        // Sacamos la lista de comentarios de texto
        const resultComentarios = await pool.query(`
            SELECT comentario_repartidor, calificacion_repartidor, fecha_entrega,
                   COALESCE(c.nombre_propietario, t.nombre) AS nombre_quien_califica
            FROM ordenes o
            LEFT JOIN clientes c ON o.id_cliente = c.id
            LEFT JOIN trabajadores t ON o.id_trabajador = t.id
            WHERE o.id_repartidor = $1 
              AND o.comentario_repartidor IS NOT NULL 
              AND TRIM(o.comentario_repartidor) != ''
            ORDER BY o.fecha_entrega DESC
        `, [req.params.id]);

        res.json({ 
            success: true, 
            promedio: resultPromedio.rows[0].promedio || 0,
            total_viajes: resultPromedio.rows[0].total_viajes || 0,
            comentarios: resultComentarios.rows 
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: "Error al obtener reseñas" });
    }
});
const PORT = process.env.PORT || 80;
server.listen(PORT, () => { 
    console.log(` Tlatoani Molino De Nixtamal corriendo con Sockets en el puerto ${PORT}`); 
    console.log('En caso de fallar el servidor en un futuro comunicarse con los desarrolladores atte: Mateo y Andres')
    console.log(` URL: http://localhost:${PORT}`);
    
});