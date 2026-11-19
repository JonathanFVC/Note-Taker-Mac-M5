// Selector de ventana con el puntero: una capa tenue sobre cada pantalla; al mover el ratón se resalta la ventana que queda debajo
// y un clic la elige (como al capturar una ventana con Cmd+Shift+4 y Espacio). Esc o clic derecho cancelan.
import AppKit

/// Ventana visible de otra app. `marco` en coordenadas de Quartz: puntos, origen arriba a la izquierda de la pantalla principal.
struct VentanaBajoPuntero {
    let id: Int
    let app: String
    let titulo: String
    let marco: CGRect
    let pid: Int32
    /// True si es una miniatura de la columna de Stage Manager (una ventana real dibujada en chiquito, que no se puede capturar bien:
    /// sale diminuta y negra). Para grabarla hay que traer su app al centro.
    let esMiniatura: Bool
    var etiqueta: String { titulo.isEmpty ? app : "\(app) — \(String(titulo.prefix(48)))" }
}

/// Ventanas normales visibles, de adelante hacia atrás. Solo de apps normales (no el sistema: WindowManager, Dock, Control Center…), sin las de
/// Note Taker y sin las muy chicas. Las miniaturas de la columna de Stage Manager SÍ cuentan: son ventanas reales (Finder, Slack…) dibujadas en
/// chiquito y cada una lleva encima una «Gesture Blocking Overlay» de WindowManager, que se descarta por no ser de una app normal.
func ventanasVisibles() -> [VentanaBajoPuntero] {
    guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    let propio = ProcessInfo.processInfo.processIdentifier
    func marco(_ w: [String: Any]) -> CGRect? { (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
    let capas = lista.filter { ($0[kCGWindowOwnerName as String] as? String) == "WindowManager" && ($0[kCGWindowName as String] as? String) == "Gesture Blocking Overlay" }.compactMap(marco)
    var res: [VentanaBajoPuntero] = []
    for w in lista {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != propio,
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
              let id = w[kCGWindowNumber as String] as? Int,
              ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
              let marco = marco(w), marco.width >= 80, marco.height >= 80 else { continue }
        res.append(VentanaBajoPuntero(id: id, app: (w[kCGWindowOwnerName as String] as? String) ?? "App",
                                      titulo: (w[kCGWindowName as String] as? String) ?? "", marco: marco, pid: pid, esMiniatura: capas.contains(marco)))
    }
    return res
}

/// Trae al centro la app de una miniatura de Stage Manager (como pulsarla) y espera la animación; así la ventana queda a tamaño real.
/// Devuelve true si hizo falta traerla. Con una ventana normal no hace nada.
@MainActor
func traerAlFrenteSiEsMiniatura(_ id: Int) async -> Bool {
    guard let v = ventanasVisibles().first(where: { $0.id == id }), v.esMiniatura,
          let app = NSRunningApplication(processIdentifier: v.pid), let url = app.bundleURL else { return false }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    try? await Task.sleep(nanoseconds: 1_400_000_000)
    logApp("ventana: miniatura de Stage Manager («\(v.etiqueta)») traída al centro")
    return true
}

/// La ventana más al frente bajo un punto (coordenadas de Quartz).
func ventanaBajo(_ punto: CGPoint) -> VentanaBajoPuntero? { ventanasVisibles().first(where: { $0.marco.contains(punto) }) }

final class VistaSelectorVentana: NSView {
    var pantalla: NSScreen?
    var resaltada: VentanaBajoPuntero?
    var alMover: (() -> Void)?
    var alClic: (() -> Void)?
    var alCancelar: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with e: NSEvent) { alMover?() }
    override func mouseDown(with e: NSEvent) { alClic?() }
    override func rightMouseDown(with e: NSEvent) { alCancelar?() }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { alCancelar?() } else { super.keyDown(with: e) } }

    /// De coordenadas de Quartz (arriba a la izquierda de la principal) a las de esta vista (abajo a la izquierda de su pantalla).
    private func aVista(_ q: CGRect) -> NSRect {
        let altoPrincipal = NSScreen.screens.first?.frame.height ?? bounds.height
        let origen = pantalla?.frame.origin ?? .zero
        return NSRect(x: q.minX - origen.x, y: (altoPrincipal - q.maxY) - origen.y, width: q.width, height: q.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        let capa = NSBezierPath(rect: bounds)
        var hueco: NSRect?
        if let v = resaltada {
            let r = aVista(v.marco).intersection(bounds)
            if !r.isNull && r.width > 1 && r.height > 1 { hueco = r; capa.append(NSBezierPath(rect: r)); capa.windingRule = .evenOdd }
        }
        capa.fill()
        if let h = hueco, let v = resaltada {
            Tema.seleccion.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: h).fill()
            Tema.seleccion.setStroke()
            let borde = NSBezierPath(rect: h.insetBy(dx: 1.5, dy: 1.5))
            borde.lineWidth = 3
            borde.stroke()
            rotular(v.etiqueta, centradoEn: NSPoint(x: h.midX, y: h.midY + 14), tam: 15)
            rotular(v.esMiniatura ? "Clic: se trae al centro y se graba" : "Clic para grabar esta ventana", centradoEn: NSPoint(x: h.midX, y: h.midY - 14), tam: 12)
        }
        rotular("Mueve el puntero sobre la ventana que quieras grabar y haz clic · Esc cancela", centradoEn: NSPoint(x: bounds.midX, y: bounds.maxY - 60), tam: 13)
    }

    private func rotular(_ texto: String, centradoEn c: NSPoint, tam: CGFloat) {
        let at: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tam, weight: .semibold), .foregroundColor: NSColor.white]
        let t = NSAttributedString(string: texto, attributes: at)
        let s = t.size()
        let caja = NSRect(x: c.x - s.width / 2 - 10, y: c.y - s.height / 2 - 4, width: s.width + 20, height: s.height + 8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: caja, xRadius: 7, yRadius: 7).fill()
        t.draw(at: NSPoint(x: caja.minX + 10, y: caja.minY + 4))
    }
}

@MainActor
final class SelectorVentana {
    private var ventanas: [NSWindow] = []
    private var vistas: [VistaSelectorVentana] = []
    private var resaltada: VentanaBajoPuntero?
    private var alElegir: ((VentanaBajoPuntero) -> Void)?
    private var alCancelar: (() -> Void)?
    var enCurso = false

    /// Muestra la capa en todas las pantallas. `alElegir` recibe la ventana elegida; `alCancelar`, cuando se pulsa Esc o clic derecho.
    func iniciar(alElegir: @escaping (VentanaBajoPuntero) -> Void, alCancelar: @escaping () -> Void) {
        guard !enCurso else { return }
        enCurso = true
        self.alElegir = alElegir
        self.alCancelar = alCancelar
        for pantalla in NSScreen.screens {
            let w = crearVentanaSelector(cubriendo: pantalla)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = VistaSelectorVentana(frame: NSRect(origin: .zero, size: pantalla.frame.size))
            v.pantalla = pantalla
            v.alMover = { [weak self] in self?.mover() }
            v.alClic = { [weak self] in self?.clic() }
            v.alCancelar = { [weak self] in self?.cancelar() }
            w.contentView = v
            ventanas.append(w)
            vistas.append(v)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in ventanas { w.makeKeyAndOrderFront(nil); if let v = w.contentView { w.makeFirstResponder(v) } }
        mover()  // resalta ya la ventana que quede bajo el puntero
    }

    private func puntoQuartz() -> CGPoint {
        let l = NSEvent.mouseLocation
        return CGPoint(x: l.x, y: (NSScreen.screens.first?.frame.height ?? 0) - l.y)
    }

    /// Solo se redibujan las capas (de pantalla completa) cuando la ventana resaltada cambia de verdad, no en cada movimiento del puntero.
    private func resaltar(_ v: VentanaBajoPuntero?) {
        if v?.id == resaltada?.id && v?.marco == resaltada?.marco { return }
        resaltada = v
        for vista in vistas { vista.resaltada = v; vista.needsDisplay = true }
    }

    /// Lista de ventanas guardada 0.2 s: el puntero genera decenas de eventos por segundo y cada consulta al sistema cuesta varios ms.
    private var listaCache: (fecha: Date, ventanas: [VentanaBajoPuntero])?
    private func ventanaBajoPunto(_ punto: CGPoint) -> VentanaBajoPuntero? {
        if listaCache == nil || Date().timeIntervalSince(listaCache!.fecha) > 0.2 { listaCache = (Date(), ventanasVisibles()) }
        return listaCache!.ventanas.first(where: { $0.marco.contains(punto) })
    }

    private func mover() { resaltar(ventanaBajoPunto(puntoQuartz())) }

    private func clic() {
        guard let v = resaltada else { return }  // clic sobre el escritorio: no hay ventana que elegir
        cerrar()
        alElegir?(v)
    }

    private func cancelar() { cerrar(); alCancelar?() }

    func cerrar() {
        enCurso = false
        for w in ventanas { w.orderOut(nil) }
        ventanas = []
        vistas = []
        listaCache = nil
        resaltada = nil
    }

    /// Para pruebas: pone el puntero en un punto de Quartz (puntos, arriba a la izquierda) y, si `clic`, elige la ventana de abajo.
    func simular(punto: CGPoint, clic: Bool) {
        guard enCurso else { return }
        resaltar(ventanaBajo(punto))
        if clic { self.clic() }
    }
}
