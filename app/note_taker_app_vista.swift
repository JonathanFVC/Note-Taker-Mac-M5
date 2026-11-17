// Ajustes, estado y ventana (SwiftUI) de la app Note Taker.
import SwiftUI
import Foundation

final class Ajustes: ObservableObject {
    private let d = UserDefaults.standard
    var alCambiar: (() -> Void)?

    /// Refuerzo de mi voz en la grabación (dB).
    @Published var gananciaMicDB: Double { didSet { d.set(gananciaMicDB, forKey: "gananciaMicDB"); alCambiar?() } }
    /// Volumen del audio de la Mac en la grabación (dB).
    @Published var gananciaSisDB: Double { didSet { d.set(gananciaSisDB, forKey: "gananciaSisDB"); alCambiar?() } }
    /// "" = micrófono integrado de la Mac.
    @Published var micID: String { didSet { d.set(micID, forKey: "micID") } }
    @Published var microfonoActivo: Bool { didSet { d.set(microfonoActivo, forKey: "microfonoActivo") } }
    /// 0 Ultra ahorro (128), 1 Baja (960, por defecto), 2 Media (1280), 3 Alta (1920). Solo afecta el video.
    @Published var calidadVideo: Int { didSet { d.set(calidadVideo, forKey: "calidadVideo3") } }
    /// Transcribir con Whisper al terminar cada grabación.
    @Published var transcribirAlTerminar: Bool { didSet { d.set(transcribirAlTerminar, forKey: "transcribirAlTerminar") } }
    /// Idioma de la transcripción: es, en o auto (detectarlo).
    @Published var idiomaWhisper: String { didSet { d.set(idiomaWhisper, forKey: "idiomaWhisper") } }

    init() {
        gananciaMicDB = d.object(forKey: "gananciaMicDB") as? Double ?? 6
        gananciaSisDB = d.object(forKey: "gananciaSisDB") as? Double ?? 0
        micID = d.string(forKey: "micID") ?? ""
        microfonoActivo = d.object(forKey: "microfonoActivo") as? Bool ?? true
        calidadVideo = d.object(forKey: "calidadVideo3") as? Int ?? 1
        transcribirAlTerminar = d.object(forKey: "transcribirAlTerminar") as? Bool ?? true
        idiomaWhisper = d.string(forKey: "idiomaWhisper") ?? "es"
    }
}

enum Fase { case inactivo, grabando, cerrando }

final class EstadoUI: ObservableObject {
    @Published var fase: Fase = .inactivo
    @Published var segundos = 0
    @Published var nivelSis: Double = -90
    @Published var nivelMic: Double = -90
    @Published var consejoVoz = "Habla para ver tu nivel"
    @Published var micVivo = false
    @Published var calibrando = false
    @Published var calibrandoRestante = 0
    @Published var ultima: ResultadoGrabacion?
    @Published var ultimoArchivo: String?
    @Published var mensaje: String?
    @Published var permisoPantalla = true
    @Published var permisoMic = true
    @Published var volEntradaPct: Double = 50
    @Published var hayVolEntrada = false
    @Published var loginActivo = false
    @Published var microfonos: [(id: String, nombre: String)] = []
    @Published var nombreMicUsado = ""
    @Published var modoMic = "Estándar"
    @Published var aislamientoActivo = false
    @Published var aislamientoConocido = false
    @Published var transcripcion: EstadoTranscripcion = .ninguna
}

enum Accion {
    case alternarGrabacion, calibrarVoz, mostrarFinder, abrirAjustesPantalla, abrirAjustesMic, salir
    case login(Bool), volumenEntrada(Double), elegirMic(String), reiniciar, modoMicrofono
    case abrirCarpetaNotas, copiarTranscripcion
}

struct Medidor: View {
    var db: Double
    var body: some View {
        GeometryReader { g in
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.25))
                Rectangle().fill(Color.green.opacity(0.20))
                    .frame(width: g.size.width * 15 / 60).offset(x: g.size.width * 42 / 60)
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: max(2, g.size.width * frac))
            }
        }
        .frame(height: 10)
    }
    var color: Color {
        if db > -3 { return .red }
        if db > -18 { return .green }
        if db > -36 { return .yellow }
        return .gray
    }
}

struct VistaPrincipal: View {
    @ObservedObject var e: EstadoUI
    @ObservedObject var a: Ajustes
    let accion: (Accion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(e.fase == .grabando ? Color.red : Color.gray).frame(width: 10, height: 10)
                Text(titulo).font(.headline)
                Spacer()
                if e.fase == .grabando { Text(mmss(e.segundos)).monospacedDigit().font(.headline) }
            }
            Button(action: { accion(.alternarGrabacion) }) {
                Text(e.fase == .grabando ? "Detener y guardar" : (e.fase == .cerrando ? "Guardando…" : "Iniciar grabación"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .tint(e.fase == .grabando ? .red : .accentColor)
            .disabled(e.fase == .cerrando)

            if !e.permisoPantalla {
                avisoPermiso("Falta el permiso de Grabación de pantalla y audio del sistema. Actívalo para «Note Taker» en Ajustes y luego pulsa «Reiniciar app».", boton: "Abrir ajustes", destino: .abrirAjustesPantalla)
            }
            if !e.permisoMic {
                avisoPermiso("Falta el permiso de Micrófono. Actívalo para «Note Taker» en Ajustes y luego pulsa «Reiniciar app».", boton: "Abrir ajustes", destino: .abrirAjustesMic)
            }
            if let m = e.mensaje { Text(m).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }

            Divider()
            seccionVoz
            Divider()
            seccionSistema
            Divider()
            seccionVideo
            Divider()
            seccionTranscripcion
            Divider()
            pie
        }
        .padding(16)
        .frame(width: 340)
    }

    var titulo: String {
        switch e.fase {
        case .grabando: return "Grabando"
        case .cerrando: return "Guardando…"
        case .inactivo: return "Listo para grabar"
        }
    }

    func avisoPermiso(_ texto: String, boton: String, destino: Accion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(texto).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(boton) { accion(destino) }.controlSize(.small)
                Button("Reiniciar app") { accion(.reiniciar) }.controlSize(.small)
            }
        }
    }

    var seccionVoz: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mi voz").font(.subheadline).bold()
                Spacer()
                Toggle("", isOn: $a.microfonoActivo).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(e.fase != .inactivo)
            }
            if a.microfonoActivo {
                Picker("", selection: Binding(get: { a.micID }, set: { accion(.elegirMic($0)) })) {
                    Text("Micrófono integrado de la Mac").tag("")
                    ForEach(e.microfonos, id: \.id) { m in Text(m.nombre).tag(m.id) }
                }
                .labelsHidden().disabled(e.fase != .inactivo)
                HStack {
                    Text("Nivel de mi voz").font(.caption)
                    Spacer()
                    Text(String(format: "%+.0f dB", a.gananciaMicDB)).font(.caption).monospacedDigit()
                }
                Slider(value: $a.gananciaMicDB, in: 0...36, step: 1)
                Medidor(db: e.nivelMic)
                HStack {
                    Text(e.calibrando ? "Habla normal… \(e.calibrandoRestante) s" : e.consejoVoz)
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button(e.calibrando ? "Midiendo…" : "Ajustar mi voz solo") { accion(.calibrarVoz) }
                        .controlSize(.small).disabled(e.calibrando)
                }
                HStack(spacing: 6) {
                    Text("Aislamiento de voz").font(.caption)
                    Text(!e.aislamientoConocido ? "…" : (e.aislamientoActivo ? "Activado" : "Desactivado"))
                        .font(.caption).bold()
                        .foregroundColor(!e.aislamientoConocido ? .secondary : (e.aislamientoActivo ? .green : .red))
                    Spacer()
                    Button(e.aislamientoActivo ? "Desactivar" : "Activar") { accion(.modoMicrofono) }.controlSize(.small)
                }
                if e.hayVolEntrada {
                    DisclosureGroup("Sensibilidad del micrófono de la Mac") {
                        HStack {
                            Slider(value: Binding(get: { e.volEntradaPct }, set: { accion(.volumenEntrada($0)) }), in: 0...100, step: 1)
                            Text(String(format: "%.0f %%", e.volEntradaPct)).font(.caption).monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                    }.font(.caption)
                }
            }
        }
    }

    var seccionSistema: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio de la Mac (junta, videos, música)").font(.subheadline).bold()
            HStack {
                Text("Volumen en la grabación").font(.caption)
                Spacer()
                Text(String(format: "%+.0f dB", a.gananciaSisDB)).font(.caption).monospacedDigit()
            }
            Slider(value: $a.gananciaSisDB, in: -18...12, step: 1)
            Medidor(db: e.nivelSis)
            Text("Se graba aunque tengas audífonos, mute o el volumen bajo.").font(.caption2).foregroundColor(.secondary)
        }
    }

    var seccionVideo: some View {
        let pre = presetsVideo[max(0, min(presetsVideo.count - 1, a.calidadVideo))]
        let mb = pre.mbPorHora
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Video").font(.subheadline).bold()
                Spacer()
                Text("≈ \(mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB") por hora, como máximo").font(.caption).foregroundColor(.secondary)
            }
            Picker("", selection: $a.calidadVideo) {
                ForEach(0..<presetsVideo.count, id: \.self) { i in Text("\(presetsVideo[i].nombre) · \(Int(presetsVideo[i].ancho)) px" + (presetsVideo[i].nota.isEmpty ? "" : " · \(presetsVideo[i].nota)")).tag(i) }
            }
            .pickerStyle(.menu).labelsHidden().disabled(e.fase != .inactivo)
            Text("Solo cambia la calidad del video; el audio sigue en alta calidad en todos los niveles").font(.caption2).foregroundColor(.secondary)
        }
    }

    var seccionTranscripcion: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transcripción (Whisper)").font(.subheadline).bold()
                Spacer()
                Toggle("", isOn: $a.transcribirAlTerminar).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if a.transcribirAlTerminar {
                Picker("", selection: $a.idiomaWhisper) {
                    ForEach(idiomasWhisper, id: \.codigo) { Text($0.nombre).tag($0.codigo) }
                }
                .pickerStyle(.menu).labelsHidden()
                estadoTranscripcion
                HStack {
                    Button("Abrir carpeta") { accion(.abrirCarpetaNotas) }
                    Button("Copiar transcripción") { accion(.copiarTranscripcion) }
                }.controlSize(.small)
                Text("Deja en el escritorio la carpeta «Note-Taker» con la última transcripción: pégasela a tu IA y pídele un «Resumen ejecutivo».")
                    .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder var estadoTranscripcion: some View {
        switch e.transcripcion {
        case .ninguna:
            Text("Se transcribe sola al terminar cada grabación.").font(.caption).foregroundColor(.secondary)
        case .enCurso(let n):
            Text("Transcribiendo \(n)…").font(.caption).foregroundColor(.orange).lineLimit(1).truncationMode(.middle)
        case .lista(let r):
            Text("Lista: \(URL(fileURLWithPath: r).lastPathComponent)").font(.caption).foregroundColor(.green).lineLimit(1).truncationMode(.middle)
        case .error(let m):
            Text(m).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    var pie: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let u = e.ultima {
                    if u.ruta.isEmpty {
                        Text("Última grabación: no se guardó").font(.caption).bold()
                    } else {
                        Text("Última: \(URL(fileURLWithPath: u.ruta).lastPathComponent)").font(.caption).bold().lineLimit(1).truncationMode(.middle)
                        Text("\(mmss(Int(u.duracion))) · \(String(format: "%.1f", u.megas)) MB · Mac \(texto(u.picoSis)) · voz \(texto(u.picoMic))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    ForEach(u.avisos, id: \.self) { Text("⚠️ \($0)").font(.caption2).foregroundColor(.orange) }
                } else if let ruta = e.ultimoArchivo {
                    Text("Última: \(URL(fileURLWithPath: ruta).lastPathComponent)").font(.caption).bold().lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Aún no hay grabaciones en Películas").font(.caption).foregroundColor(.secondary)
                }
                Button("Ir al último video grabado") { accion(.mostrarFinder) }.controlSize(.small).disabled(e.ultimoArchivo == nil)
            }
            HStack {
                Toggle("Abrir al iniciar sesión", isOn: Binding(get: { e.loginActivo }, set: { accion(.login($0)) })).font(.caption)
                Spacer()
                Button("Salir") { accion(.salir) }.controlSize(.small)
            }
            Text("Atajo: ⌃⌥⌘N inicia o detiene la grabación.").font(.caption2).foregroundColor(.secondary)
        }
    }

    func texto(_ p: Float) -> String { p <= 0.0001 ? "silencio" : String(format: "%.0f dB", dbDe(p)) }
}
