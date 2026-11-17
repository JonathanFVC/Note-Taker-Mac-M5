// App de barra de menú «Note Taker»: iniciar/detener, niveles de voz y audio de la Mac, atajo ⌃⌥⌘N.
import SwiftUI
import AppKit
import AVFoundation
import Carbon
import ServiceManagement

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
    var transcribiendo = false
    var tokenAviso = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.compartido = self
        motor = Motor(ajustes: ajustes)
        ajustes.alCambiar = { [weak self] in self?.motor.actualizarGanancias() }
        motor.alError = { [weak self] msg in self?.errorMotor(msg) }
        configurarItem()
        configurarPopover()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(manejarURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        registrarAtajo()
        refrescarPermisos(pedir: true)
        configurarLoginInicial()
        reloj = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tic() }
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

    func icono(grabando: Bool) -> NSImage? {
        let img = NSImage(systemSymbolName: grabando ? "record.circle.fill" : "waveform.circle", accessibilityDescription: "Note Taker")
        if grabando { return img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) }
        img?.isTemplate = true
        return img
    }

    func actualizarItem() {
        guard let b = item.button else { return }
        let g = estado.fase == .grabando
        b.image = icono(grabando: g)
        b.title = g ? " \(mmss(estado.segundos))" : (transcribiendo ? " …" : "")
    }

    @objc func clicItem(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { mostrarMenuContextual(); return }
        if popover.isShown { popover.performClose(nil) } else { mostrarPopover() }
    }

    func mostrarMenuContextual() {
        let m = NSMenu()
        let a = NSMenuItem(title: estado.fase == .grabando ? "Detener y guardar" : "Iniciar grabación", action: #selector(menuAlternar), keyEquivalent: "")
        a.target = self; m.addItem(a)
        let s = NSMenuItem(title: "Salir", action: #selector(menuSalir), keyEquivalent: "")
        s.target = self; m.addItem(s)
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func menuAlternar() { alternar() }
    @objc func menuSalir() { salir() }

    func configurarPopover() {
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: VistaPrincipal(e: estado, a: ajustes, accion: { [weak self] a in self?.ejecutar(a) }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    /// Último video grabado: el .mov más reciente de ~/Movies (también cuenta lo grabado con el comando o antes de reiniciar la app).
    func buscarUltimoVideo() {
        let dir = URL(fileURLWithPath: carpetaVideos)
        let claves: [URLResourceKey] = [.contentModificationDateKey]
        let archivos = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: claves)) ?? []
        let grabaciones = archivos.filter { $0.lastPathComponent.hasPrefix("nota_") && $0.pathExtension == "mov" }
        let ultimo = grabaciones.max { a, b in
            let fa = (try? a.resourceValues(forKeys: Set(claves)).contentModificationDate) ?? .distantPast
            let fb = (try? b.resourceValues(forKeys: Set(claves)).contentModificationDate) ?? .distantPast
            return fa < fb
        }
        estado.ultimoArchivo = ultimo?.path
        actualizarUltimoTranscrito()
    }

    /// Aviso chico bajo el botón; se quita solo (si se vuelve a pulsar, el plazo se reinicia).
    func mostrarAvisoYaTranscrito() {
        tokenAviso += 1
        let mio = tokenAviso
        estado.avisoYaTranscrito = true
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if tokenAviso == mio { estado.avisoYaTranscrito = false }
        }
    }

    /// ¿El último video ya tiene su transcripción en la carpeta de transcripciones?
    func actualizarUltimoTranscrito() {
        guard let r = estado.ultimoArchivo, !r.isEmpty else { estado.ultimoTranscrito = nil; return }
        let base = URL(fileURLWithPath: r).deletingPathExtension().lastPathComponent
        estado.ultimoTranscrito = FileManager.default.fileExists(atPath: carpetaNotas + "/" + base + ".txt")
    }

    func mostrarPopover() {
        guard let b = item.button else { return }
        buscarUltimoVideo()
        refrescarPermisos(pedir: false)
        refrescarMicrofonos()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverWillShow(_ notification: Notification) {
        popoverAbierto = true
        Task {
            if CGPreflightScreenCaptureAccess() {
                if let err = await motor.iniciarMonitor() { estado.mensaje = err } else if estado.fase == .inactivo { estado.mensaje = nil }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverAbierto = false
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
            buscarUltimoVideo()
            if estado.ultimoTranscrito == true {
                mostrarAvisoYaTranscrito()
            } else if let r = estado.ultimoArchivo, !r.isEmpty {
                iniciarTranscripcion(URL(fileURLWithPath: r))
            } else {
                estado.mensaje = "Aún no hay videos grabados."
            }
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
        if !CGPreflightScreenCaptureAccess() {
            estado.permisoPantalla = false
            estado.mensaje = "Primero da el permiso de Grabación de pantalla y audio del sistema."
            _ = CGRequestScreenCaptureAccess()
            return
        }
        if let err = await motor.iniciarGrabacion() { estado.mensaje = err; return }
        estado.fase = .grabando
        estado.segundos = 0
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
        if ajustes.transcribirAlTerminar, let ruta = r?.ruta, !ruta.isEmpty, FileManager.default.fileExists(atPath: ruta) {
            iniciarTranscripcion(URL(fileURLWithPath: ruta))
        }
        if popoverAbierto { _ = await motor.iniciarMonitor() }
    }

    /// Whisper de uno en uno: si llega otra grabación mientras transcribe, espera su turno.
    func iniciarTranscripcion(_ url: URL) {
        colaTranscripcion.append(url)
        if !transcribiendo { procesarCola() }
    }

    func procesarCola() {
        guard !colaTranscripcion.isEmpty else { transcribiendo = false; actualizarItem(); return }
        transcribiendo = true
        let url = colaTranscripcion.removeFirst()
        estado.transcripcion = .enCurso(url.lastPathComponent)
        actualizarItem()
        Task {
            let r = await transcribirVideo(url, idioma: ajustes.idiomaWhisper)
            estado.transcripcion = r.ok ? .lista(r.texto) : .error(r.texto)
            actualizarUltimoTranscrito()
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
        if motor.modo == .grabando { Task { await detener() } }
    }

    // MARK: Medidores y calibración

    func tic() {
        if motor.modo == .inactivo && !popoverAbierto { return }
        let n = motor.leerNiveles()
        let decae = 5.0
        let micDB = dbDe(n.mic)
        estado.nivelSis = max(dbDe(n.sis), estado.nivelSis - decae)
        estado.nivelMic = max(micDB, estado.nivelMic - decae)
        estado.micVivo = n.micVivo
        estado.modoMic = nombreModoMic(AVCaptureDevice.activeMicrophoneMode)
        estado.aislamientoConocido = n.micVivo
        estado.aislamientoActivo = AVCaptureDevice.activeMicrophoneMode == .voiceIsolation
        histMic.append(micDB)
        if histMic.count > 30 { histMic.removeFirst() }
        estado.consejoVoz = consejo(histMic.max() ?? -90, vivo: n.micVivo)
        if motor.modo == .grabando {
            let s = Int(Date().timeIntervalSince(motor.inicioGrabacion))
            if s != estado.segundos { estado.segundos = s; actualizarItem() }
        }
        if let fin = calFin {
            calPico = max(calPico, n.micCrudo)
            let r = max(0, Int(ceil(fin.timeIntervalSinceNow)))
            if r != estado.calibrandoRestante { estado.calibrandoRestante = r }
            if Date() >= fin { terminarCalibracion() }
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
    }

    func terminarCalibracion() {
        calFin = nil
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

    @objc func manejarURL(_ ev: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = ev.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URL(string: s) else { return }
        let db = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "db" })?.value.flatMap(Double.init)
        let n = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "n" })?.value.flatMap(Int.init)
        switch u.host {
        case "iniciar": if motor.modo != .grabando { alternar() }
        case "detener": if motor.modo == .grabando { alternar() }
        case "alternar": alternar()
        case "mostrar": mostrarPopover()
        case "ocultar": popover.performClose(nil)
        case "calibrar": calibrar()
        case "modo": ejecutar(.modoMicrofono)
        case "transcribir": if let n = n { ajustes.transcribirAlTerminar = (n != 0) }
        case "transcribir-ultimo": ejecutar(.transcribirUltimo)
        case "calidad": if let n = n { ajustes.calidadVideo = max(0, min(presetsVideo.count - 1, n)) }
        case "mic": if let db = db { ajustes.gananciaMicDB = max(0, min(36, db)) }
        case "sistema": if let db = db { ajustes.gananciaSisDB = max(-18, min(12, db)) }
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
