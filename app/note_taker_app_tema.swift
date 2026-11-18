// Tema visual: colores de acento y logo opcional. Este es el tema por omisión (colores del sistema y sin logo);
// una versión con otra marca sustituye este archivo y agrega `logo.png` junto a la app (ver README.md).
import SwiftUI
import AppKit

enum Tema {
    /// Color de los controles (interruptores, deslizadores y botón principal). nil = el acento de macOS.
    static let acento: Color? = nil
    /// Rueda de carga y letrero «Transcribiendo video…».
    static let carga: NSColor = .systemBlue
    /// Resaltado de los selectores de ventana y de área.
    static let seleccion: NSColor = .systemBlue
    /// Color del puntito junto a «Listo para grabar» cuando no se graba (el texto no cambia). nil = gris.
    static let listo: Color? = .blue
    /// Logo opcional que se muestra arriba del panel (`logo.png` en los recursos de la app); sin archivo, no se muestra.
    static let logo: NSImage? = Bundle.main.url(forResource: "logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
}
