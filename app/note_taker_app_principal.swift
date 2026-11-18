// App de barra de menú «Note Taker»: iniciar/detener, niveles de voz y audio de la Mac, atajo ⌃⌥⌘N.
import SwiftUI
import AppKit
import AVFoundation
import Carbon
import ServiceManagement
import ScreenCaptureKit

func manejadorAtajo(_ siguiente: EventHandlerCallRef?, _ evento: EventRef?, _ datos: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in AppDelegate.compartido?.alternar() }
    return noErr
}

@main
@MainActor
struct NoteTakerApp {
    static func main() {
        let app = NSApplication.shared
        let delegado = AppDelegate()
        app.delegate = delegado
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static var compartido: AppDelegate?
    let ajustes = Ajustes()
    let estado = EstadoUI()
    var motor: Motor!
    var item: NSStatusItem!
    let popover = NSPopover()
    var reloj: Timer?
    var histMic: [Double] = []
    var calFin: Date?
    var calPico: Float = 0
    var popoverAbierto = false
    var teclaRef: EventHotKeyRef?
    var mantenerMonitorHasta = Date.distantPast
    var colaTranscripcion: [URL] = []
    /// Espejo de `estado.transcribiendo`: la vista lo usa para desactivar el botón y mostrar «Transcribiendo video…».
    var transcribiendo: Bool { get { estado.transcribiendo } set { estado.transcribiendo = newValue } }
    var videoEnCurso: URL?
    var tokenAviso = 0
    let aviso = AvisoFlotante()
    let selector = SelectorArea()
    let selectorVentana = SelectorVentana()
    var tokenMonitor = 0
    /// Medidores de voz y de audio de la Mac: vistas propias que se dibujan solas (no pasan por SwiftUI, que recalculaba todo el panel en cada lectura).
    let medidorMic = MedidorVista()
    let medidorSis = MedidorVista()
    /// Intervalo del reloj que mueve los medidores y el contador: nil = apagado (nada que mover).
    var relojIntervalo: TimeInterval?
    /// Indicador animado sobre el icono de la barra: rueda al guardar o transcribir, cuadrado rojo que late al grabar (Core Animation, sin CPU).
    var indicador: IndicadorCA?
    /// Mientras se graba, guarda o transcribe, macOS no debe poner la app en reposo (App Nap).
    var actividadSistema: NSObjectProtocol?
    lazy var imagenReposo: NSImage? = {
        let i = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Note Taker")
        i?.isTemplate = true
        return i
    }()
    /// Imagen vacía del tamaño del icono: conserva el ancho del botón mientras el indicador animado ocupa su lugar.
    lazy var imagenHueco: NSImage = NSImage(size: NSSize(width: 18, height: 18))
    /// Si macOS ocultó el botón al ponerle el tiempo (no cabía en la barra), esta grabación sigue solo con el icono.
    var sinTiempoEnBarra = false
    /// Segundos de la grabación en curso para la barra (el panel usa `estado.segundos`, que solo se actualiza con el panel abierto).
    var segundosBarra = 0
    var botonOcultoSeguidos = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.compartido = self
        motor = Motor(ajustes: ajustes)
        ajustes.alCambiar = { [weak self] in self?.motor.actualizarGanancias() }
        ajustes.alCambiarCaptura = { [weak self] in self?.reiniciarMonitorTrasCambio() }
        motor.alError = { [weak self] msg in self?.errorMotor(msg) }
        configurarItem()
        configurarPopover()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(manejarURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        registrarAtajo()
        refrescarPermisos(pedir: true)
        configurarLoginInicial()
        programarReloj()  // en reposo con el panel cerrado no corre ningún reloj
    }

    /// Un solo reloj, y solo cuando hace falta: rápido (0.07 s) con el panel abierto o midiendo la voz; lento (1 s) para el contador mientras
    /// se graba con el panel cerrado; apagado el resto del tiempo (antes corría 14 veces por segundo siempre y la app nunca descansaba).
    func programarReloj() {
        let intervalo: TimeInterval? = (popoverAbierto || calFin != nil) ? 0.07 : (estado.fase == .grabando ? 1.0 : nil)
        guard intervalo != relojIntervalo else { return }
        reloj?.invalidate(); reloj = nil
        relojIntervalo = intervalo
        guard let i = intervalo else { return }
        let t = Timer.scheduledTimer(withTimeInterval: i, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tic() }
        }
        t.tolerance = i * 0.15
        reloj = t
    }

    /// Mientras hay trabajo (grabar, guardar, transcribir) se avisa a macOS para que no limite la app; al terminar se suelta.
    func gestionarActividad(_ activa: Bool) {
        if activa, actividadSistema == nil {
            actividadSistema = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Note Taker: grabando, guardando o transcribiendo")
        } else if !activa, let a = actividadSistema {
            ProcessInfo.processInfo.endActivity(a)
            actividadSistema = nil
        }
    }

    // MARK: Barra de menú

    func configurarItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = icono(grabando: false)
            b.imagePosition = .imageLeft
            b.target = self
            b.action = #selector(clicItem(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func icono(grabando: Bool) -> NSImage? { grabando ? imagenHueco : imagenReposo }  // al grabar, el cuadrado rojo lo pone el indicador animado

    func actualizarItem() {
        guard let b = item.button else { return }
        let g = estado.fase == .grabando
        let ocupado = estado.fase == .cerrando || transcribiendo
        let tip = g ? "Grabando \(mmss(segundosBarra)) · clic para detener y guardar" : (ocupado ? "Guardando o transcribiendo…" : "Note Taker")
        if b.toolTip != tip { b.toolTip = tip }
        if g || !ocupado {
            // Grabando: cuadrado rojo que late (un clic detiene y guarda) y el contador. Inactivo: la onda de siempre. Con el indicador de grabación
            // de macOS y el notch no cabe mucho más: si macOS oculta el botón se queda solo el cuadrado (el tiempo va en el texto emergente).
            let img = icono(grabando: g)
            if b.image !== img { b.image = img }  // solo si cambió: reasignarla cada segundo hacía redibujar la barra
            if g { ponerIndicador(.grabando) } else { quitarIndicador() }
            if g && !sinTiempoEnBarra { b.attributedTitle = tiempoEnBarra(segundosBarra); vigilarBoton() }
            else if b.attributedTitle.length > 0 { b.attributedTitle = NSAttributedString(string: "") }
        } else {
            // Guardando o transcribiendo (y sin grabar): rueda de carga con el color del tema, animada por Core Animation.
            if b.attributedTitle.length > 0 { b.attributedTitle = NSAttributedString(string: "") }
            if b.image !== imagenHueco { b.image = imagenHueco }
            ponerIndicador(.rueda)
        }
        colocarIndicador()
        gestionarActividad(g || ocupado)
        programarReloj()
    }

    func ponerIndicador(_ tipo: IndicadorCA.Tipo) {
        if indicador?.tipo == tipo { return }
        quitarIndicador()
        guard let b = item.button else { return }
        let i = IndicadorCA(tipo: tipo, lado: 18)
        b.addSubview(i)
        indicador = i
    }

    func quitarIndicador() {
        indicador?.removeFromSuperview()
        indicador = nil
    }

    /// El indicador va justo donde macOS dibuja la imagen del botón (a la izquierda; el contador queda a su derecha), centrado en vertical.
    func colocarIndicador() {
        guard let i = indicador, let b = item.button else { return }
        let r = (b.cell as? NSButtonCell)?.imageRect(forBounds: b.bounds) ?? NSRect(x: 4, y: 2, width: 18, height: 18)
        let origen = NSPoint(x: (r.midX - i.lado / 2).rounded(), y: ((b.bounds.height - i.lado) / 2).rounded())
        if i.frame.origin != origen { i.setFrameOrigin(origen) }
    }

    /// Tiempo compacto (m:ss) con dígitos de ancho fijo, para que el botón no cambie de ancho cada segundo.
    func tiempoEnBarra(_ s: Int) -> NSAttributedString {
        let texto = s >= 3600 ? String(format: " %d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: " %d:%02d", s / 60, s % 60)
        return NSAttributedString(string: texto, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    /// Si macOS oculta el botón porque con el tiempo no cabe en la barra (su ventana deja de estar «visible»), tras dos segundos seguidos
    /// se queda solo el icono; el tiempo sigue en el texto emergente. En la siguiente grabación se vuelve a intentar con el tiempo.
    func vigilarBoton() {
        guard let w = item.button?.window else { return }
        if w.occlusionState.contains(.visible) { botonOcultoSeguidos = 0; return }
        botonOcultoSeguidos += 1
        if botonOcultoSeguidos >= 2 {
            botonOcultoSeguidos = 0
            sinTiempoEnBarra = true
            item.button?.attributedTitle = NSAttributedString(string: "")
            logApp("barra: macOS ocultó el botón con el tiempo (no cabe en la barra); queda solo el icono")
        }
    }

    @objc func clicItem(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { mostrarMenuContextual(); return }
        // Todo minimizado: mientras se graba, un clic en el icono (botón de stop) detiene y guarda, y la cadena sigue sola
        // (rueda azul, transcripción y aviso «Video transcrito»). El panel completo solo se abre para iniciar o con clic derecho.
        if motor.modo == .grabando { popover.performClose(nil); alternar(); return }
        if motor.modo == .cerrando { return }
        if popover.isShown { popover.performClose(nil) } else { mostrarPopover() }
    }

    func mostrarMenuContextual() {
        let m = NSMenu()
        let a = NSMenuItem(title: estado.fase == .grabando ? "Detener y guardar" : "Iniciar grabación", action: #selector(menuAlternar), keyEquivalent: "")
        a.target = self; m.addItem(a)
        let p = NSMenuItem(title: "Mostrar panel", action: #selector(menuPanel), keyEquivalent: "")
        p.target = self; m.addItem(p)
        let s = NSMenuItem(title: "Salir", action: #selector(menuSalir), keyEquivalent: "")
        s.target = self; m.addItem(s)
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func menuAlternar() { alternar() }
    @objc func menuSalir() { salir() }
    @objc func menuPanel() { if !popover.isShown { mostrarPopover() } }

    func configurarPopover() {
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: VistaPrincipal(e: estado, a: ajustes, medidorMic: medidorMic, medidorSis: medidorSis,
                                                                accion: { [weak self] a in self?.ejecutar(a) }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Calienta el panel y la lista de micrófonos al arrancar: la primera vez cuestan ≈0.4 s y no deben caer en el primer clic del usuario.
        host.view.frame = NSRect(x: 0, y: 0, width: 340, height: 640)
        host.view.layoutSubtreeIfNeeded()
        Task.detached(priority: .utility) { _ = microfonosDisponibles() }
    }

    /// Último video grabado: el .mov más reciente de ~/Movies (también cuenta lo grabado con el comando o antes de reiniciar la app).
    func buscarUltimoVideo() {
        let dir = URL(fileURLWithPath: carpetaVideos)
        let claves: [URLResourceKey] = [.contentModificationDateKey]
        let archivos = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: claves)) ?? []
        // Una sola pasada: la fecha de cada archivo se lee una vez (antes se leía en cada comparación).
        var ultimo: (url: URL, fecha: Date)?
        for a in archivos where a.lastPathComponent.hasPrefix("nota_") && a.pathExtension == "mov" {
            let f = (try? a.resourceValues(forKeys: Set(claves)).contentModificationDate) ?? .distantPast
            if ultimo == nil || f > ultimo!.fecha { ultimo = (a, f) }
        }
        let ruta = ultimo?.url.path
        if estado.ultimoArchivo != ruta { estado.ultimoArchivo = ruta }
        actualizarUltimoTranscrito()
    }

    /// Aviso chico bajo el botón; se quita solo (si se vuelve a pulsar, el plazo se reinicia).
    /// Advertencia flotante bajo el icono de la barra (solo si el panel está cerrado; abierto, el panel ya muestra el mensaje).
    func mostrarAdvertencia(_ texto: String) {
        if !popover.isShown { aviso.mostrar(texto, advertencia: true, bajo: item.button) }
    }

    /// Aviso chico que se quita solo: dentro del panel si está abierto; si no, flotante bajo el icono de la barra.
    func mostrarAviso(_ texto: String) {
        tokenAviso += 1
        let mio = tokenAviso
        estado.avisoTexto = texto
        if !popover.isShown { aviso.mostrar(texto, bajo: item.button) }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if tokenAviso == mio { estado.avisoTexto = nil }
        }
    }

    /// ¿El último video ya tiene su transcripción en la carpeta de transcripciones?
    func actualizarUltimoTranscrito() {
        guard let r = estado.ultimoArchivo, !r.isEmpty else { if estado.ultimoTranscrito != nil { estado.ultimoTranscrito = nil }; return }
        let base = URL(fileURLWithPath: r).deletingPathExtension().lastPathComponent
        let hecho = FileManager.default.fileExists(atPath: carpetaNotas + "/" + base + ".txt")
        if estado.ultimoTranscrito != hecho { estado.ultimoTranscrito = hecho }
    }

    func mostrarPopover() {
        guard let b = item.button else { return }
        let t0 = DispatchTime.now()
        // Alto máximo del panel según las pantallas (antes se calculaba dentro de la vista en cada redibujado).
        estado.altoMaximoPanel = max(400, (NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800) - 24)
        buscarUltimoVideo()
        refrescarPermisos(pedir: false)
        refrescarMicrofonos()
        refrescarObjetivos()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()  // el panel toma el foco: sus controles se ven activos (con el color del tema)
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        if ms >= 50 { logApp("panel: abrir tardó \(ms) ms en el hilo principal") }
    }

    func popoverWillShow(_ notification: Notification) {
        popoverAbierto = true
        medidorMic.nivel = -90; medidorSis.nivel = -90; histMic.removeAll()  // el medidor arranca limpio, sin el valor de la vez anterior
        if estado.segundos != segundosBarra { estado.segundos = segundosBarra }  // el panel muestra el tiempo desde que se abre
        programarReloj()
        Task {
            if CGPreflightScreenCaptureAccess() {
                if let err = await motor.iniciarMonitor() { estado.mensaje = err } else if estado.fase == .inactivo { estado.mensaje = nil }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverAbierto = false
        programarReloj()
        Task {
            // Si se abrió el selector de modos de macOS, el micrófono debe seguir activo unos segundos.
            let espera = mantenerMonitorHasta.timeIntervalSinceNow
            if espera > 0 { try? await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000)) }
            if !popoverAbierto { await motor.detenerMonitor() }
        }
    }

    // MARK: Permisos y datos

    func refrescarPermisos(pedir: Bool) {
        var pantalla = CGPreflightScreenCaptureAccess()
        if !pantalla && pedir { pantalla = CGRequestScreenCaptureAccess() }
        estado.permisoPantalla = pantalla
        let st = AVCaptureDevice.authorizationStatus(for: .audio)
        if st == .notDetermined && pedir {
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { self.estado.permisoMic = ok } }
        }
        estado.permisoMic = (st == .authorized) || (st == .notDetermined)
    }

    func refrescarMicrofonos() {
        estado.microfonos = microfonosDisponibles().filter { !$0.nombre.contains("BlackHole") }
        let d = motor.dispositivoMic()
        estado.nombreMicUsado = d?.localizedName ?? ""
        if let uid = d?.uniqueID, let v = volumenEntrada(uid: uid) { estado.volEntradaPct = v; estado.hayVolEntrada = true } else { estado.hayVolEntrada = false }
    }

    // MARK: Acciones

    func ejecutar(_ a: Accion) {
        switch a {
        case .alternarGrabacion: alternar()
        case .calibrarVoz: calibrar()
        case .transcribirUltimo:
            // Ya hay una transcripción en curso: se ignora el clic (aunque el botón se pulse varias veces, corre una sola).
            guard !transcribiendo else { return }
            buscarUltimoVideo()
            if estado.ultimoTranscrito == true {
                mostrarAviso("Ya está transcrito")
            } else if let r = estado.ultimoArchivo, !r.isEmpty {
                iniciarTranscripcion(URL(fileURLWithPath: r))
            } else {
                estado.mensaje = "Aún no hay videos grabados."
            }
        case .elegirArea: elegirArea(iniciarDespues: false)
        case .elegirVentana: elegirVentana(iniciarDespues: false)
        case .abrirCarpetaNotas:
            try? FileManager.default.createDirectory(atPath: carpetaNotas, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: carpetaNotas))
        case .copiarTranscripcion:
            let ultima = carpetaNotas + "/ULTIMA_TRANSCRIPCION.txt"
            if let texto = try? String(contentsOfFile: ultima, encoding: .utf8), !texto.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(texto, forType: .string)
                estado.mensaje = "Transcripción copiada (\(texto.count) caracteres): pégala en tu IA."
            } else {
                estado.mensaje = "Aún no hay una transcripción para copiar."
            }
        case .mostrarFinder:
            buscarUltimoVideo()
            if let r = estado.ultimoArchivo, !r.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r)]) }
        case .abrirAjustesPantalla:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .abrirAjustesMic:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .modoMicrofono:
            mantenerMonitorHasta = Date().addingTimeInterval(40)
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            Task { // el menú de macOS debe quedar al frente: se cierra este panel
                try? await Task.sleep(nanoseconds: 300_000_000)
                popover.performClose(nil)
            }
        case .salir: salir()
        case .reiniciar:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
            try? p.run()
            NSApp.terminate(nil)
        case .login(let on): cambiarLogin(on)
        case .volumenEntrada(let v):
            estado.volEntradaPct = v
            if let uid = motor.dispositivoMic()?.uniqueID { ponerVolumenEntrada(uid: uid, porcentaje: v) }
        case .elegirMic(let id):
            ajustes.micID = id
            refrescarMicrofonos()
            Task { await motor.reiniciarMonitor() }
        }
    }

    func alternar() {
        switch motor.modo {
        case .grabando: Task { await detener() }
        case .cerrando: break
        default: Task { await iniciar() }
        }
    }

    func iniciar() async {
        estado.mensaje = nil
        // «Qué grabar»: en modo Área o Ventana sin elegir, se abre el selector (arrastrar o pasar el puntero) y se graba al elegir.
        if ajustes.modoCaptura == ModoCaptura.area.rawValue && ajustes.areaW < 16 { elegirArea(iniciarDespues: true); return }
        if ajustes.modoCaptura == ModoCaptura.ventana.rawValue && ajustes.ventanaCaptura == 0 { elegirVentana(iniciarDespues: true); return }
        if ajustes.modoCaptura == ModoCaptura.ventana.rawValue { _ = await traerAlFrenteSiEsMiniatura(ajustes.ventanaCaptura) }  // por si volvió a la columna
        if !CGPreflightScreenCaptureAccess() {
            estado.permisoPantalla = false
            estado.mensaje = "Primero da el permiso de Grabación de pantalla y audio del sistema."
            _ = CGRequestScreenCaptureAccess()
            return
        }
        if let err = await motor.iniciarGrabacion() { estado.mensaje = err; return }
        estado.fase = .grabando
        segundosBarra = 0; estado.segundos = 0
        sinTiempoEnBarra = false; botonOcultoSeguidos = 0  // cada grabación vuelve a intentar mostrar el tiempo
        actualizarItem()
        popover.performClose(nil) // ya grabando: el panel se cierra solo (si no, se queda fijo hasta volver a pulsar)
    }

    func detener() async {
        estado.fase = .cerrando
        actualizarItem()
        let r = await motor.detenerGrabacion()
        estado.ultima = r
        buscarUltimoVideo()
        estado.fase = .inactivo
        actualizarItem()
        if let ruta = r?.ruta, !ruta.isEmpty, FileManager.default.fileExists(atPath: ruta) {
            if ajustes.transcribirAlTerminar { iniciarTranscripcion(URL(fileURLWithPath: ruta)) }  // el aviso llega al terminar de transcribir
            else { mostrarAviso("Video guardado") }
        } else {
            mostrarAdvertencia("No se guardó la grabación")
        }
        if popoverAbierto { _ = await motor.iniciarMonitor() }
    }

    /// Whisper de uno en uno: si llega otra grabación mientras transcribe, espera su turno.
    func iniciarTranscripcion(_ url: URL) {
        // Un solo comando de transcripción por video: si ya se transcribe o espera turno, se ignora (evita cargar el modelo varias veces).
        guard url != videoEnCurso, !colaTranscripcion.contains(url) else { return }
        colaTranscripcion.append(url)
        if !transcribiendo { procesarCola() }
    }

    func procesarCola() {
        guard !colaTranscripcion.isEmpty else { transcribiendo = false; videoEnCurso = nil; actualizarItem(); return }
        transcribiendo = true
        let url = colaTranscripcion.removeFirst()
        videoEnCurso = url
        estado.transcripcion = .enCurso(url.lastPathComponent)
        actualizarItem()
        Task {
            let r = await transcribirVideo(url, idioma: ajustes.idiomaWhisper)
            estado.transcripcion = r.ok ? .lista(r.texto) : .error(r.texto)
            actualizarUltimoTranscrito()
            if r.ok { mostrarAviso("Video transcrito") }
            procesarCola()
        }
    }

    func salir() {
        Task {
            if motor.modo == .grabando { await detener() }
            NSApp.terminate(nil)
        }
    }

    func errorMotor(_ msg: String) {
        estado.mensaje = msg
        mostrarAdvertencia(String(msg.prefix(80)))
        if motor.modo == .grabando { Task { await detener() } }
    }

    // MARK: Medidores y calibración

    /// Lo que mueve el reloj (ver `programarReloj`). Los medidores se dibujan directo; al estado de SwiftUI solo se escribe lo que CAMBIÓ,
    /// porque cada escritura recalcula el panel completo (con el panel abierto eso consumía ≈100 % de un núcleo).
    func tic() {
        if motor.modo == .inactivo && !popoverAbierto { return }
        if popoverAbierto || calFin != nil {
            let n = motor.leerNiveles()
            let decae = 2.0  // dB por lectura: la barra sube al instante y baja suave (antes 5 dB: parpadeaba entre palabras)
            let micDB = dbDe(n.mic)
            medidorSis.nivel = max(dbDe(n.sis), medidorSis.nivel - decae)
            medidorMic.nivel = max(micDB, medidorMic.nivel - decae)
            if estado.micVivo != n.micVivo { estado.micVivo = n.micVivo }
            let modo = AVCaptureDevice.activeMicrophoneMode
            let nombreModo = nombreModoMic(modo)
            if estado.modoMic != nombreModo { estado.modoMic = nombreModo }
            if estado.aislamientoConocido != n.micVivo { estado.aislamientoConocido = n.micVivo }
            let aislado = modo == .voiceIsolation
            if estado.aislamientoActivo != aislado { estado.aislamientoActivo = aislado }
            histMic.append(micDB)
            if histMic.count > 30 { histMic.removeFirst() }
            let c = consejo(histMic.max() ?? -90, vivo: n.micVivo)
            if estado.consejoVoz != c { estado.consejoVoz = c }
            if let fin = calFin {
                calPico = max(calPico, n.micCrudo)
                let r = max(0, Int(ceil(fin.timeIntervalSinceNow)))
                if r != estado.calibrandoRestante { estado.calibrandoRestante = r }
                if Date() >= fin { terminarCalibracion() }
            }
        }
        if motor.modo == .grabando {
            let s = Int(Date().timeIntervalSince(motor.inicioGrabacion))
            // El contador de la barra no pasa por SwiftUI: con el panel cerrado, escribir `estado.segundos` cada segundo hacía recalcular el panel
            // (≈2 % de CPU en toda la grabación). Solo se publica si el panel está abierto.
            if s != segundosBarra { segundosBarra = s; if popoverAbierto { estado.segundos = s }; actualizarItem() }
        }
    }

    func consejo(_ pico: Double, vivo: Bool) -> String {
        if !ajustes.microfonoActivo { return "Micrófono apagado" }
        if !vivo { return "No llega audio del micrófono" }
        if pico < -50 { return "Habla para ver tu nivel" }
        if pico < -30 { return "Muy bajo: sube el nivel de mi voz" }
        if pico < -18 { return "Bajo: sube un poco" }
        if pico <= -3 { return "Bien ✓" }
        return "Muy alto: bájalo"
    }

    func calibrar() {
        guard motor.modo == .monitor || motor.modo == .grabando else {
            estado.mensaje = "Abre el panel con el permiso de pantalla activo para medir tu voz."
            return
        }
        calPico = 0
        calFin = Date().addingTimeInterval(5)
        estado.calibrando = true
        estado.calibrandoRestante = 5
        estado.mensaje = nil
        programarReloj()
    }

    func terminarCalibracion() {
        calFin = nil
        programarReloj()
        estado.calibrando = false
        let crudoDB = dbDe(calPico)
        if crudoDB < -58 {
            estado.mensaje = "No te oí. Habla más cerca del micrófono y vuelve a intentar."
            return
        }
        let g = max(0, min(36, (-9.0 - crudoDB).rounded()))
        ajustes.gananciaMicDB = g
        estado.mensaje = String(format: "Listo: tu voz llegó a %.0f dB; el nivel quedó en %+.0f dB.", crudoDB, g)
    }

    // MARK: URL (notetaker://iniciar | detener | alternar | mostrar | ocultar | calibrar | mic?db=N | sistema?db=N)

    // MARK: Qué grabar (pantalla, ventana o área)

    /// Vuelve a leer las pantallas que se pueden grabar y comprueba que la ventana elegida siga visible; `alTerminar` se llama al terminar.
    func refrescarObjetivos(alTerminar: (() -> Void)? = nil) {
        guard CGPreflightScreenCaptureAccess() else { alTerminar?(); return }
        Task {
            if let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
                estado.pantallas = listarPantallas(c)
                if ajustes.ventanaCaptura != 0, !c.windows.contains(where: { Int($0.windowID) == ajustes.ventanaCaptura && $0.isOnScreen }) {
                    ajustes.ventanaCaptura = 0; estado.ventanaTexto = ""  // la ventana elegida se cerró o ya no está a la vista
                }
                if ajustes.pantallaCaptura != 0, !estado.pantallas.contains(where: { $0.id == ajustes.pantallaCaptura }) { ajustes.pantallaCaptura = 0 }
            }
            alTerminar?()
        }
    }

    /// Cierra el panel y muestra el selector de área sobre las pantallas. Al elegir: guarda el área y, si se venía a grabar, empieza.
    func elegirArea(iniciarDespues: Bool) {
        popover.performClose(nil)
        selector.iniciar(alElegir: { [weak self] rect, pantallaID in
            guard let self else { return }
            self.ajustes.areaX = rect.minX; self.ajustes.areaY = rect.minY
            self.ajustes.areaW = rect.width; self.ajustes.areaH = rect.height
            self.ajustes.areaPantalla = pantallaID == Int(CGMainDisplayID()) ? 0 : pantallaID
            self.ajustes.modoCaptura = ModoCaptura.area.rawValue
            if iniciarDespues {
                Task { try? await Task.sleep(nanoseconds: 350_000_000); await self.iniciar() }  // la capa tenue ya no debe salir en el video
            } else { self.mostrarPopover() }
        }, alCancelar: { [weak self] in if !iniciarDespues { self?.mostrarPopover() } })
    }

    /// Cierra el panel y muestra la capa del selector: al pasar el puntero se resalta la ventana de abajo y un clic la elige.
    func elegirVentana(iniciarDespues: Bool) {
        popover.performClose(nil)
        selectorVentana.iniciar(alElegir: { [weak self] v in
            guard let self else { return }
            self.ajustes.ventanaCaptura = v.id
            self.estado.ventanaTexto = v.etiqueta
            self.ajustes.modoCaptura = ModoCaptura.ventana.rawValue
            Task {
                _ = await traerAlFrenteSiEsMiniatura(v.id)  // una miniatura de Stage Manager no se puede grabar tal cual: se trae al centro
                if iniciarDespues {
                    try? await Task.sleep(nanoseconds: 350_000_000)  // la capa tenue ya no debe salir en el video
                    await self.iniciar()
                } else { self.mostrarPopover() }
            }
        }, alCancelar: { [weak self] in if !iniciarDespues { self?.mostrarPopover() } })
    }

    /// El monitor de niveles usa el mismo objetivo que la grabación: si se cambia, se reinicia (con una pausa por si cambian varios ajustes).
    func reiniciarMonitorTrasCambio() {
        tokenMonitor += 1
        let mio = tokenMonitor
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard tokenMonitor == mio else { return }
            await motor.reiniciarMonitor()
        }
    }

    @objc func manejarURL(_ ev: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = ev.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URL(string: s) else { return }
        let db = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "db" })?.value.flatMap(Double.init)
        let n = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "n" })?.value.flatMap(Int.init)
        var q: [String: String] = [:]
        for i in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        func num(_ k: String) -> Double? { q[k].flatMap(Double.init) }
        switch u.host {
        case "iniciar": if motor.modo != .grabando { alternar() }
        case "detener": if motor.modo == .grabando { alternar() }
        case "alternar": alternar()
        case "icono": clicItem(nil)  // como pulsar el icono de la barra: grabando = detener; si no, abre o cierra el panel
        case "mostrar": mostrarPopover()
        case "ocultar": popover.performClose(nil)
        case "calibrar": calibrar()
        case "modo": ejecutar(.modoMicrofono)
        case "transcribir": if let n = n { ajustes.transcribirAlTerminar = (n != 0) }
        case "transcribir-ultimo": ejecutar(.transcribirUltimo)
        case "calidad": if let n = n { ajustes.calidadVideo = max(0, min(presetsVideo.count - 1, n)) }
        case "mic": if let db = db { ajustes.gananciaMicDB = max(0, min(36, db)) }
        case "sistema": if let db = db { ajustes.gananciaSisDB = max(-18, min(12, db)) }
        // «Qué grabar» (para Atajos y pruebas): captura?modo=pantalla|ventana|area · pantalla?n=1.. (0 = principal) · ventana?app=texto
        // · ventana-elegir · ventana-prueba?x=&y=[&clic=1]
        // · area?x=&y=&w=&h= (puntos, origen arriba a la izquierda) · area-elegir · area-prueba?x=&y=&w=&h= (arrastre simulado) · actualizar
        case "captura": if let m = q["modo"], ModoCaptura(rawValue: m) != nil { ajustes.modoCaptura = m }
        case "pantalla":
            refrescarObjetivos { [self] in
                guard let n = n else { return }
                if n <= 0 { ajustes.pantallaCaptura = 0 }
                else if n <= estado.pantallas.count { let id = estado.pantallas[n - 1].id; ajustes.pantallaCaptura = id == Int(CGMainDisplayID()) ? 0 : id }
                ajustes.modoCaptura = ModoCaptura.pantalla.rawValue
            }
        case "ventana":
            if let t = q["app"]?.lowercased(), let v = ventanasVisibles().first(where: { $0.app.lowercased().contains(t) || $0.titulo.lowercased().contains(t) }) {
                ajustes.ventanaCaptura = v.id; estado.ventanaTexto = v.etiqueta; ajustes.modoCaptura = ModoCaptura.ventana.rawValue
            }
        case "ventana-elegir": elegirVentana(iniciarDespues: false)
        case "ventana-prueba":  // pasa el puntero (y, con clic=1, pulsa) en un punto de la pantalla: x, y en puntos, origen arriba a la izquierda
            if let x = num("x"), let y = num("y") {
                if !selectorVentana.enCurso { elegirVentana(iniciarDespues: false) }
                let clic = (q["clic"] ?? "0") != "0"
                Task { try? await Task.sleep(nanoseconds: 700_000_000); selectorVentana.simular(punto: CGPoint(x: x, y: y), clic: clic) }
            }
        case "area":
            if let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") {
                ajustes.areaX = x; ajustes.areaY = y; ajustes.areaW = w; ajustes.areaH = h; ajustes.areaPantalla = 0
                ajustes.modoCaptura = ModoCaptura.area.rawValue
            }
        case "area-elegir": elegirArea(iniciarDespues: false)
        case "area-prueba":
            if let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") {
                if !selector.enCurso { elegirArea(iniciarDespues: false) }
                Task { try? await Task.sleep(nanoseconds: 800_000_000); selector.simular(CGRect(x: x, y: y, width: w, height: h)) }
            }
        case "actualizar": refrescarObjetivos()
        case "panel-transcripcion": if let n = n { ajustes.transcripcionAbierta = (n != 0) }  // despliega (1) o pliega (0) la sección de transcripción
        default: break
        }
    }

    // MARK: Atajo global ⌃⌥⌘N

    func registrarAtajo() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), manejadorAtajo, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x47524142), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &teclaRef)
    }

    // MARK: Abrir al iniciar sesión

    func configurarLoginInicial() {
        estado.loginActivo = SMAppService.mainApp.status == .enabled
    }

    func cambiarLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            estado.mensaje = "No se pudo cambiar el inicio automático: \(error.localizedDescription)"
        }
        estado.loginActivo = SMAppService.mainApp.status == .enabled
    }
}
