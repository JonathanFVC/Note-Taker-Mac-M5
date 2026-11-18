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
    /// Qué se graba: «pantalla» (completa), «ventana» (una app o pestaña) o «area» (un rectángulo). **No se guarda**: la app siempre
    /// abre en «pantalla» (lo predeterminado); ventana y área valen solo para la sesión en curso.
    @Published var modoCaptura: String = "pantalla" { didSet { alCambiarCaptura?() } }
    /// Pantalla a grabar (CGDirectDisplayID; 0 = la principal, aunque cambie).
    @Published var pantallaCaptura: Int { didSet { d.set(pantallaCaptura, forKey: "pantallaCaptura"); alCambiarCaptura?() } }
    /// Ventana elegida (CGWindowID; 0 = ninguna). No se guarda: las ventanas van y vienen.
    @Published var ventanaCaptura: Int = 0 { didSet { alCambiarCaptura?() } }
    /// Último área elegida, en puntos de su pantalla (origen arriba a la izquierda) y la pantalla donde se eligió.
    @Published var areaX: Double { didSet { d.set(areaX, forKey: "areaX") } }
    @Published var areaY: Double { didSet { d.set(areaY, forKey: "areaY") } }
    @Published var areaW: Double { didSet { d.set(areaW, forKey: "areaW") } }
    @Published var areaH: Double { didSet { d.set(areaH, forKey: "areaH") } }
    @Published var areaPantalla: Int { didSet { d.set(areaPantalla, forKey: "areaPantalla") } }
    /// Si la sección «Transcripción (Whisper)» del panel está desplegada (por omisión, plegada).
    @Published var transcripcionAbierta: Bool { didSet { d.set(transcripcionAbierta, forKey: "transcripcionAbierta") } }
    var alCambiarCaptura: (() -> Void)?

    init() {
        gananciaMicDB = d.object(forKey: "gananciaMicDB") as? Double ?? 6
        gananciaSisDB = d.object(forKey: "gananciaSisDB") as? Double ?? 0
        micID = d.string(forKey: "micID") ?? ""
        microfonoActivo = d.object(forKey: "microfonoActivo") as? Bool ?? true
        calidadVideo = d.object(forKey: "calidadVideo3") as? Int ?? 1
        transcribirAlTerminar = d.object(forKey: "transcribirAlTerminar") as? Bool ?? true
        idiomaWhisper = d.string(forKey: "idiomaWhisper") ?? "es"
        d.removeObject(forKey: "modoCaptura")  // llave de versiones anteriores, que sí lo recordaban
        transcripcionAbierta = d.object(forKey: "transcripcionAbierta") as? Bool ?? false
        pantallaCaptura = d.object(forKey: "pantallaCaptura") as? Int ?? 0
        areaX = d.object(forKey: "areaX") as? Double ?? 0
        areaY = d.object(forKey: "areaY") as? Double ?? 0
        areaW = d.object(forKey: "areaW") as? Double ?? 0
        areaH = d.object(forKey: "areaH") as? Double ?? 0
        areaPantalla = d.object(forKey: "areaPantalla") as? Int ?? 0
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
    /// nil = aún no hay videos; true/false = si el último video ya tiene su transcripción.
    @Published var ultimoTranscrito: Bool?
    /// Aviso chico («Video transcrito», «Ya está transcrito») que se quita solo a los pocos segundos.
    @Published var avisoTexto: String?
    /// Pantallas que se pueden grabar (se actualizan al abrir el panel) y nombre de la ventana elegida con el puntero.
    @Published var pantallas: [OpcionPantalla] = []
    /// Alto real del contenido del panel (lo mide la vista); el panel se limita al alto de la pantalla y se desplaza si no cabe.
    @Published var altoPanel: CGFloat = 640
    @Published var ventanaTexto = ""
    /// True mientras Whisper trabaja o hay videos en cola: desactiva el botón y activa la rueda de carga azul.
    @Published var transcribiendo = false
}

struct AltoPanelKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum Accion {
    case alternarGrabacion, calibrarVoz, mostrarFinder, abrirAjustesPantalla, abrirAjustesMic, salir
    case login(Bool), volumenEntrada(Double), elegirMic(String), reiniciar, modoMicrofono
    case abrirCarpetaNotas, copiarTranscripcion, transcribirUltimo, elegirArea, elegirVentana
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
        // Un solo bloque: todo el panel (incluida la transcripción y el pie) se desplaza junto, sin barra visible. Plegada la transcripción
        // cabe completo; al desplegarla crece hacia abajo, el panel llega al alto de la pantalla y baja solo hasta mostrar lo desplegado.
        let altoMaximo = max(400, (NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800) - 24)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                contenido
                    .background(GeometryReader { g in Color.clear.preference(key: AltoPanelKey.self, value: g.size.height) })
                    .id("panel")
                Color.clear.frame(height: 1).id("fin")
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 340, height: min(max(e.altoPanel, 200), altoMaximo))
            .onPreferenceChange(AltoPanelKey.self) { h in
                if h > 0, abs(h - e.altoPanel) > 0.5 { DispatchQueue.main.async { e.altoPanel = h } }
            }
            .onChange(of: a.transcripcionAbierta) { _, abierto in
                // Al desplegar, bajar hasta el final para que las opciones nuevas se vean; al plegar, volver arriba.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(abierto ? "fin" : "panel", anchor: abierto ? .bottom : .top) }
                }
            }
        }
    }

    var contenido: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            seccionCaptura
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
        .frame(width: 340, alignment: .leading)
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

    /// «Qué grabar»: pantalla completa (la que se elija), ventana (app o pestaña) o un área, como en Cmd+Shift+5.
    var seccionCaptura: some View {
        let principal = Int(CGMainDisplayID())
        return VStack(alignment: .leading, spacing: 6) {
            Text("Qué grabar").font(.subheadline).bold()
            Picker("", selection: $a.modoCaptura) {
                Text("Pantalla").tag("pantalla")
                Text("Ventana o app").tag("ventana")
                Text("Área").tag("area")
            }
            .pickerStyle(.segmented).labelsHidden()
            if a.modoCaptura == "ventana" {
                HStack(spacing: 8) {
                    Button("Elegir ventana…") { accion(.elegirVentana) }.controlSize(.small)
                    Text(a.ventanaCaptura != 0 ? e.ventanaTexto : "Aún sin ventana elegida")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("Haz clic en la ventana a grabar. Solo se graba esa ventana y el audio de su app (una pestaña = la ventana del navegador).")
                    .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if a.modoCaptura == "area" {
                HStack(spacing: 8) {
                    Button("Elegir área…") { accion(.elegirArea) }.controlSize(.small)
                    Text(a.areaW >= 16 ? "\(Int(a.areaW)) × \(Int(a.areaH)) pt · \(nombrePantalla(CGDirectDisplayID(a.areaPantalla == 0 ? principal : a.areaPantalla)))" : "Aún sin área elegida")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("Solo ese rectángulo de la pantalla y el audio de toda la Mac. Si no hay área, se pide al pulsar «Iniciar grabación».")
                    .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: Binding(get: { a.pantallaCaptura == 0 ? principal : a.pantallaCaptura },
                                              set: { a.pantallaCaptura = ($0 == principal) ? 0 : $0 })) {
                    ForEach(e.pantallas) { Text($0.nombre).tag($0.id) }
                }
                .pickerStyle(.menu).labelsHidden()
                Text("Toda la pantalla elegida y el audio de toda la Mac.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .disabled(e.fase != .inactivo)
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
            Text("Se graba aunque tengas audífonos, mute o el volumen bajo. El medidor se mueve mientras grabas.").font(.caption2).foregroundColor(.secondary)
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

    var transcribiendoAhora: Bool { e.transcribiendo }

    /// Transcripción plegable: cerrada solo se ve la fila con la flecha y el interruptor (más el progreso o el aviso, si los hay);
    /// con la flecha se despliegan idioma, botones y estado, para que el panel no crezca hacia abajo.
    var seccionTranscripcion: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: { a.transcripcionAbierta.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(.secondary)
                            .rotationEffect(.degrees(a.transcripcionAbierta ? 90 : 0)).frame(width: 10)
                        Text("Transcripción (Whisper)").font(.subheadline).bold()
                    }
                }
                .buttonStyle(.plain).help(a.transcripcionAbierta ? "Ocultar las opciones de transcripción" : "Mostrar las opciones de transcripción")
                Spacer()
                Text(a.transcribirAlTerminar ? "automática" : "manual").font(.caption2).foregroundColor(.secondary)
                Toggle("", isOn: $a.transcribirAlTerminar).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if a.transcripcionAbierta { detalleTranscripcion } else { resumenTranscripcion }
        }
    }

    /// Plegada: solo lo que el usuario no debe perderse (error, progreso y el aviso «Video transcrito»).
    @ViewBuilder var resumenTranscripcion: some View {
        if transcribiendoAhora {
            HStack(spacing: 6) {
                RuedaCarga()
                Text("Transcribiendo video…").font(.caption).bold().foregroundColor(.blue)
            }
        } else if case .error(let m) = e.transcripcion {
            Text(m).font(.caption).foregroundColor(.red).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        if let t = e.avisoTexto { CapsulaAviso(texto: t) }
    }

    /// Desplegada: idioma, estado del último video, botones, progreso y la guía.
    @ViewBuilder var detalleTranscripcion: some View {
        Picker("", selection: $a.idiomaWhisper) {
            ForEach(idiomasWhisper, id: \.codigo) { Text($0.nombre).tag($0.codigo) }
        }
        .pickerStyle(.menu).labelsHidden()
        estadoTranscripcion
        HStack {
            Button("Abrir carpeta") { accion(.abrirCarpetaNotas) }
            Button("Copiar transcripción") { accion(.copiarTranscripcion) }
        }.controlSize(.small)
        Button(action: { accion(.transcribirUltimo) }) {
            Text("Transcribir último video grabado").frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .disabled(e.ultimoArchivo == nil || e.fase != .inactivo || transcribiendoAhora)
        if transcribiendoAhora {
            HStack(spacing: 6) {
                RuedaCarga()
                Text("Transcribiendo video…").font(.caption).bold().foregroundColor(.blue)
                if case .enCurso(let n) = e.transcripcion {
                    Text(n).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        if let t = e.avisoTexto {
            CapsulaAviso(texto: t).frame(maxWidth: .infinity, alignment: .center)
        }
        Text("Guarda la última transcripción en «Note-Taker-Transcriptions» (dentro de Películas › Note-Taker): pégasela a tu IA y pídele un «Resumen ejecutivo».")
            .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var estadoTranscripcion: some View {
        if !transcribiendoAhora {
            if case .error(let m) = e.transcripcion {
                Text(m).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            avisoUltimoVideo
        }
    }

    @ViewBuilder var avisoUltimoVideo: some View {
        if let hecho = e.ultimoTranscrito {
            Text(hecho ? "Último video transcrito" : "Último video no transcrito")
                .font(.caption).bold().foregroundColor(hecho ? .green : .red)
            if let r = e.ultimoArchivo {
                Text(URL(fileURLWithPath: r).lastPathComponent).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } else {
            Text("Aún no hay videos grabados.").font(.caption).foregroundColor(.secondary)
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
                        Text("\(mmss(Int(u.duracion))) · \(String(format: "%.1f", u.megas)) MB · Audio de la Mac: \(texto(u.picoSis)) · Tu voz: pico \(texto(u.picoMic))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    ForEach(u.avisos, id: \.self) { Text("⚠️ \($0)").font(.caption2).foregroundColor(.orange) }
                    ForEach(u.notas, id: \.self) { Text("ℹ️ \($0)").font(.caption2).foregroundColor(.secondary) }
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

    func texto(_ p: Float) -> String { p <= 0.0001 ? "sin sonido" : String(format: "%.0f dB", dbDe(p)) }
}
