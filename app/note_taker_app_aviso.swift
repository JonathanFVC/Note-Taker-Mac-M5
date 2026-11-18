// Avisos y animación de carga: rueda azul (panel e icono de la barra), cápsula «Video transcrito» y aviso flotante bajo el icono.
import SwiftUI
import AppKit

/// Rueda de carga azul para el panel: gira sola mientras está en pantalla (TimelineView: el `swiftc` de consola no tiene la macro @State).
struct RuedaCarga: View {
    var tamano: CGFloat = 14
    var body: some View {
        TimelineView(.animation) { contexto in
            let vuelta = contexto.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: max(2, tamano / 6), lineCap: .round))
                .frame(width: tamano, height: tamano)
                .rotationEffect(.degrees(vuelta * 360))
        }
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

/// Imagen de la rueda de carga azul para el icono de la barra de menú (un cuadro de la animación).
func imagenRuedaCarga(angulo: CGFloat) -> NSImage {
    let lado: CGFloat = 18
    let img = NSImage(size: NSSize(width: lado, height: lado), flipped: false) { rect in
        let centro = NSPoint(x: rect.midX, y: rect.midY)
        let radio = rect.width / 2 - 3
        let pista = NSBezierPath()
        pista.appendArc(withCenter: centro, radius: radio, startAngle: 0, endAngle: 360)
        pista.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.25).setStroke()
        pista.stroke()
        let arco = NSBezierPath()
        arco.appendArc(withCenter: centro, radius: radio, startAngle: angulo, endAngle: angulo + 260)
        arco.lineWidth = 2.2
        arco.lineCapStyle = .round
        NSColor.systemBlue.setStroke()
        arco.stroke()
        return true
    }
    img.isTemplate = false
    return img
}

/// Botón de stop para el icono de la barra mientras se graba: cuadrado rojo de esquinas redondeadas (el símbolo clásico de «detener»).
func imagenBotonStop() -> NSImage {
    let lado: CGFloat = 18
    let img = NSImage(size: NSSize(width: lado, height: lado), flipped: false) { rect in
        let cuadrado = rect.insetBy(dx: 2.5, dy: 2.5)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: cuadrado, xRadius: 3, yRadius: 3).fill()
        return true
    }
    img.isTemplate = false
    return img
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
