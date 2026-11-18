// Avisos y animación de carga: rueda azul (panel e icono de la barra), cápsula «Video transcrito» y aviso flotante bajo el icono.
import SwiftUI
import AppKit

/// Indicador animado del icono de la barra y del panel, dibujado y animado por Core Animation: el sistema mueve las capas por su cuenta y la app
/// no gasta CPU mientras gira o parpadea (medido: 0.0 % de la app). Colores: rueda = `Tema.carga` (azul, o el naranja de marca); grabando = rojo.
final class IndicadorCA: NSView {
    enum Tipo { case rueda, grabando }
    let tipo: Tipo
    let lado: CGFloat
    private let pista = CAShapeLayer()
    private let figura = CAShapeLayer()

    init(tipo: Tipo, lado: CGFloat) {
        self.tipo = tipo
        self.lado = lado
        super.init(frame: NSRect(x: 0, y: 0, width: lado, height: lado))
        wantsLayer = true
        let caja = CGRect(x: 0, y: 0, width: lado, height: lado)
        for l in [pista, figura] { l.bounds = caja; l.position = CGPoint(x: lado / 2, y: lado / 2); layer?.addSublayer(l) }
        switch tipo {
        case .rueda:
            let ancho = max(2, lado / 7)
            let anillo = CGPath(ellipseIn: caja.insetBy(dx: ancho, dy: ancho), transform: nil)
            for l in [pista, figura] { l.path = anillo; l.fillColor = nil; l.lineWidth = ancho; l.lineCap = .round }
            pista.strokeColor = Tema.carga.withAlphaComponent(0.25).cgColor
            figura.strokeColor = Tema.carga.cgColor
            figura.strokeEnd = 0.72
        case .grabando:
            figura.path = CGPath(roundedRect: caja.insetBy(dx: lado * 0.14, dy: lado * 0.14), cornerWidth: 3, cornerHeight: 3, transform: nil)
            figura.fillColor = NSColor.systemRed.cgColor
        }
    }
    required init?(coder: NSCoder) { fatalError("no se usa") }

    override var intrinsicContentSize: NSSize { NSSize(width: lado, height: lado) }

    /// Las animaciones viven mientras la vista está en una ventana (y se reinician si vuelve a ella).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        figura.removeAllAnimations()
        guard window != nil else { return }
        switch tipo {
        case .rueda:  // vuelta completa cada 0.9 s, en el sentido de las manecillas del reloj
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi
            a.duration = 0.9; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            figura.add(a, forKey: "giro")
        case .grabando:  // late suave: 1.0 ⇄ 0.45 de opacidad
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0; a.toValue = 0.45
            a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            figura.add(a, forKey: "late")
        }
    }
}

/// Puente de SwiftUI para el indicador de Core Animation.
struct RuedaCargaCA: NSViewRepresentable {
    var lado: CGFloat
    func makeNSView(context: Context) -> IndicadorCA { IndicadorCA(tipo: .rueda, lado: lado) }
    func updateNSView(_ v: IndicadorCA, context: Context) {}
}

/// Rueda de carga del panel («Transcribiendo video…»): la misma de la barra, con el color del tema y de tamaño FIJO (una vista de AppKit se
/// estira por omisión y empujaba el texto de la fila).
struct RuedaCarga: View {
    var tamano: CGFloat = 14
    var body: some View {
        RuedaCargaCA(lado: tamano + 2).frame(width: tamano + 2, height: tamano + 2).fixedSize()
    }
}

/// Cápsula verde dentro del panel («Video transcrito», «Ya está transcrito»).
struct CapsulaAviso: View {
    var texto: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            Text(texto).bold()
        }
        .font(.caption).foregroundColor(.green)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.green.opacity(0.18)).cornerRadius(6)
    }
}

/// Contenido del aviso flotante (cuando el panel está cerrado).
struct AvisoFlotanteVista: View {
    var texto: String
    var advertencia = false
    var body: some View {
        let color: Color = advertencia ? .orange : .green
        HStack(spacing: 8) {
            Image(systemName: advertencia ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundColor(color).font(.title3)
            Text(texto).font(.callout).bold()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .padding(6)
        .fixedSize()  // el texto nunca se corta: la ventana toma su tamaño ideal
    }
}

/// Aviso chico que aparece bajo el icono de la barra de menú y se quita solo (para cuando el panel está cerrado).
@MainActor
final class AvisoFlotante {
    private var ventana: NSPanel?
    private var token = 0

    func mostrar(_ texto: String, advertencia: Bool = false, bajo boton: NSStatusBarButton?) {
        ventana?.orderOut(nil)
        token += 1
        let mio = token
        let host = NSHostingView(rootView: AvisoFlotanteVista(texto: texto, advertencia: advertencia))
        host.layoutSubtreeIfNeeded()
        let tam = host.fittingSize
        host.frame = NSRect(origin: .zero, size: tam)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        var origen = NSPoint(x: 100, y: 100)
        if let b = boton, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            let pantalla = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let x = min(max(r.midX - tam.width / 2, pantalla.minX + 8), pantalla.maxX - tam.width - 8)
            origen = NSPoint(x: x, y: r.minY - tam.height - 4)
        }
        p.setFrameOrigin(origen)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.animator().alphaValue = 1
        ventana = p
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard token == mio, let v = ventana else { return }
            v.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 400_000_000)
            if token == mio { v.orderOut(nil); ventana = nil }
        }
    }
}
