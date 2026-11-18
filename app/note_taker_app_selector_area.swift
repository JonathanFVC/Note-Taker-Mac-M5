// Selector de área, como el de Cmd+Shift+5: una capa tenue sobre cada pantalla donde se arrastra el rectángulo a grabar.
import AppKit

final class VentanaSelector: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class VistaSelector: NSView {
    var inicio: NSPoint?
    var actual: NSPoint?
    /// Rectángulo elegido en coordenadas de la vista (origen abajo a la izquierda), o nil si se cancela.
    var alTerminar: ((NSRect?) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    var rect: NSRect? {
        guard let a = inicio, let b = actual else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        let capa = NSBezierPath(rect: bounds)
        if let r = rect { capa.append(NSBezierPath(rect: r)); capa.windingRule = .evenOdd }
        capa.fill()
        if let r = rect {
            NSColor.white.setStroke()
            let borde = NSBezierPath(rect: r)
            borde.lineWidth = 1.5
            borde.stroke()
            rotular("\(Int(r.width)) × \(Int(r.height))", en: NSPoint(x: r.minX, y: max(4, r.minY - 24)))
        } else {
            rotular("Arrastra para elegir el área a grabar · Esc cancela", en: NSPoint(x: bounds.midX - 190, y: bounds.midY))
        }
    }

    private func rotular(_ texto: String, en punto: NSPoint) {
        let atributos: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let t = NSAttributedString(string: texto, attributes: atributos)
        let caja = NSRect(origin: punto, size: NSSize(width: t.size().width + 16, height: 22))
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: caja, xRadius: 6, yRadius: 6).fill()
        t.draw(at: NSPoint(x: caja.minX + 8, y: caja.minY + 3))
    }

    override func mouseDown(with e: NSEvent) { inicio = convert(e.locationInWindow, from: nil); actual = inicio; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { actual = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with e: NSEvent) { actual = convert(e.locationInWindow, from: nil); terminar() }
    override func rightMouseDown(with e: NSEvent) { alTerminar?(nil) }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { alTerminar?(nil) } else { super.keyDown(with: e) } }

    /// Un arrastre demasiado chico no cuenta: se vuelve a empezar.
    func terminar() {
        if let r = rect, r.width >= 16, r.height >= 16 { alTerminar?(r) } else { inicio = nil; actual = nil; needsDisplay = true }
    }

    /// Para pruebas: hace como si el usuario hubiera arrastrado de un punto a otro.
    func simular(desde a: NSPoint, hasta b: NSPoint) { inicio = a; actual = b; needsDisplay = true; terminar() }
}

@MainActor
final class SelectorArea {
    private var ventanas: [NSWindow] = []
    private var vistas: [(vista: VistaSelector, pantalla: NSScreen)] = []
    var enCurso = false

    /// Muestra la capa en todas las pantallas. `alElegir` recibe el área en puntos de su pantalla (origen arriba a la izquierda)
    /// y el id de esa pantalla; `alCancelar`, cuando se pulsa Esc o clic derecho.
    func iniciar(alElegir: @escaping (CGRect, Int) -> Void, alCancelar: @escaping () -> Void) {
        guard !enCurso else { return }
        enCurso = true
        for pantalla in NSScreen.screens {
            let w = VentanaSelector(contentRect: pantalla.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: pantalla)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = VistaSelector(frame: NSRect(origin: .zero, size: pantalla.frame.size))
            let id = Int((pantalla.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
            v.alTerminar = { [weak self] r in
                guard let self, self.enCurso else { return }
                self.cerrar()
                if let r {
                    let alto = pantalla.frame.height
                    alElegir(CGRect(x: r.minX, y: alto - r.maxY, width: r.width, height: r.height), id)
                } else { alCancelar() }
            }
            w.contentView = v
            ventanas.append(w)
            vistas.append((v, pantalla))
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in ventanas { w.makeKeyAndOrderFront(nil); if let v = w.contentView { w.makeFirstResponder(v) } }
    }

    func cerrar() {
        enCurso = false
        for w in ventanas { w.orderOut(nil) }
        ventanas = []
        vistas = []
    }

    /// Para pruebas: arrastre simulado en la pantalla principal (coordenadas en puntos, origen arriba a la izquierda).
    func simular(_ area: CGRect) {
        guard let par = vistas.first(where: { $0.pantalla == NSScreen.main }) ?? vistas.first else { return }
        let alto = par.pantalla.frame.height
        par.vista.simular(desde: NSPoint(x: area.minX, y: alto - area.minY), hasta: NSPoint(x: area.maxX, y: alto - area.maxY))
    }
}
