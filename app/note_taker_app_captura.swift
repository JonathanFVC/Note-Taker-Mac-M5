// Qué se graba: una pantalla completa (la que se elija), una ventana (app o pestaña) o un área de la pantalla, como en Cmd+Shift+5.
import Foundation
import AppKit
import ScreenCaptureKit

enum ModoCaptura: String { case pantalla, ventana, area }

/// Pantalla elegible. `id` = CGDirectDisplayID.
struct OpcionPantalla: Identifiable { let id: Int; let nombre: String }

/// Lo que ScreenCaptureKit va a capturar: filtro, tamaño en píxeles del contenido y, si es un área, su rectángulo en puntos.
struct ObjetivoCaptura {
    let filtro: SCContentFilter
    let pixelesAncho: Int
    let pixelesAlto: Int
    let area: CGRect?
    let descripcion: String
}

/// Nombre legible de una pantalla: «Pantalla integrada (principal)».
func nombrePantalla(_ id: CGDirectDisplayID) -> String {
    let n = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id })?.localizedName ?? "Pantalla \(id)"
    return id == CGMainDisplayID() ? "\(n) (principal)" : n
}

/// Pantallas conectadas, la principal primero.
func listarPantallas(_ c: SCShareableContent) -> [OpcionPantalla] {
    c.displays
        .sorted { ($0.displayID == CGMainDisplayID() ? 0 : 1, $0.displayID) < ($1.displayID == CGMainDisplayID() ? 0 : 1, $1.displayID) }
        .map { OpcionPantalla(id: Int($0.displayID), nombre: "\(nombrePantalla($0.displayID)) · \($0.width)×\($0.height)") }
}

extension Motor {
    /// Arma el filtro de captura según lo elegido en el panel (pantalla, ventana o área). Un objetivo inválido es un error.
    @MainActor
    func resolverObjetivo(_ c: SCShareableContent) throws -> ObjetivoCaptura {
        func fallo(_ m: String) -> NSError { NSError(domain: "grabar", code: 2, userInfo: [NSLocalizedDescriptionKey: m]) }
        guard let principal = c.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? c.displays.first else {
            throw fallo("No se encontró ninguna pantalla")
        }
        func pantalla(_ id: Int) -> SCDisplay { c.displays.first(where: { Int($0.displayID) == id }) ?? principal }
        func pixeles(_ p: SCDisplay) -> (ancho: Int, alto: Int) {
            let m = CGDisplayCopyDisplayMode(p.displayID)
            return (m?.pixelWidth ?? p.width * 2, m?.pixelHeight ?? p.height * 2)
        }
        func completa(_ p: SCDisplay, _ texto: String) -> ObjetivoCaptura {
            let px = pixeles(p)
            return ObjetivoCaptura(filtro: SCContentFilter(display: p, excludingApplications: [], exceptingWindows: []),
                                   pixelesAncho: px.ancho, pixelesAlto: px.alto, area: nil, descripcion: texto)
        }
        switch ModoCaptura(rawValue: ajustes.modoCaptura) ?? .pantalla {
            case .pantalla:
                let p = pantalla(ajustes.pantallaCaptura)
                return completa(p, "pantalla completa: \(nombrePantalla(p.displayID))")
            case .ventana:
                guard let v = c.windows.first(where: { Int($0.windowID) == ajustes.ventanaCaptura && $0.isOnScreen }) else {
                    throw fallo("La ventana elegida ya no está visible. Elige otra en «Qué grabar».")
                }
                let f = SCContentFilter(desktopIndependentWindow: v)
                let esc = max(1, Double(f.pointPixelScale))
                let r = f.contentRect
                return ObjetivoCaptura(filtro: f, pixelesAncho: max(2, Int(r.width * esc)), pixelesAlto: max(2, Int(r.height * esc)),
                                       area: nil, descripcion: "ventana: \(v.owningApplication?.applicationName ?? "") \(v.title ?? "")")
            case .area:
                let p = pantalla(ajustes.areaPantalla)
                let limite = CGRect(x: 0, y: 0, width: p.width, height: p.height)
                let r = CGRect(x: ajustes.areaX, y: ajustes.areaY, width: ajustes.areaW, height: ajustes.areaH).intersection(limite)
                guard !r.isNull, r.width >= 16, r.height >= 16 else {
                    throw fallo("Elige el área que quieres grabar en «Qué grabar» (Elegir área…).")
                }
                let px = pixeles(p)
                let esc = Double(px.ancho) / Double(max(1, p.width))
                return ObjetivoCaptura(filtro: SCContentFilter(display: p, excludingApplications: [], exceptingWindows: []),
                                       pixelesAncho: max(2, Int(r.width * esc)), pixelesAlto: max(2, Int(r.height * esc)), area: r,
                                       descripcion: "área \(Int(r.width))×\(Int(r.height)) pt en \(nombrePantalla(p.displayID))")
        }
    }
}
