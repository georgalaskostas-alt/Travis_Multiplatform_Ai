import Foundation

/// Safe, deterministic presentation substrate for TRAVIS V6.
/// Models may propose this schema, but rendering is local and code-free: no JavaScript,
/// remote resources, generated Swift, shell execution, or arbitrary HTML is required.
struct ArtifactManifestV6: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case report
        case dashboard
        case chart
        case table
    }

    struct Metric: Codable, Hashable {
        var label: String
        var value: String
        var note: String?
    }

    struct Bar: Codable, Hashable {
        var label: String
        var value: Double
        var displayValue: String?
    }

    struct Section: Codable, Hashable {
        enum SectionKind: String, Codable, CaseIterable, Hashable {
            case text
            case metrics
            case table
            case barChart
        }

        var kind: SectionKind
        var title: String
        var text: String?
        var metrics: [Metric]?
        var headers: [String]?
        var rows: [[String]]?
        var bars: [Bar]?
    }

    var version: Int = 1
    var kind: Kind
    var title: String
    var subtitle: String?
    var sections: [Section]
    var footer: String?
}

enum DeclarativeArtifactEngineV6 {
    enum RenderFormat: String, Codable, CaseIterable {
        case markdown = "md"
        case html
        case svg
    }

    enum ArtifactError: LocalizedError {
        case invalidManifest(String)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .invalidManifest(let reason): return "Invalid artifact manifest: \(reason)"
            case .unsupportedFormat: return "Unsupported artifact render format"
            }
        }
    }

    static func validate(_ manifest: ArtifactManifestV6) throws {
        guard manifest.version == 1 else { throw ArtifactError.invalidManifest("unsupported version") }
        guard clean(manifest.title).count >= 2, manifest.title.count <= 180 else { throw ArtifactError.invalidManifest("title length") }
        guard manifest.sections.count >= 1, manifest.sections.count <= 24 else { throw ArtifactError.invalidManifest("section count") }
        guard manifest.subtitle?.count ?? 0 <= 500, manifest.footer?.count ?? 0 <= 1_000 else { throw ArtifactError.invalidManifest("metadata length") }

        var totalCells = 0
        for section in manifest.sections {
            guard clean(section.title).count >= 1, section.title.count <= 180 else { throw ArtifactError.invalidManifest("section title") }
            switch section.kind {
            case .text:
                guard let text = section.text, !clean(text).isEmpty, text.count <= 12_000 else { throw ArtifactError.invalidManifest("text section") }
            case .metrics:
                guard let metrics = section.metrics, !metrics.isEmpty, metrics.count <= 24 else { throw ArtifactError.invalidManifest("metrics section") }
                for metric in metrics {
                    guard metric.label.count <= 120, metric.value.count <= 240, metric.note?.count ?? 0 <= 500 else { throw ArtifactError.invalidManifest("metric length") }
                }
            case .table:
                guard let headers = section.headers, !headers.isEmpty, headers.count <= 16,
                      let rows = section.rows, !rows.isEmpty, rows.count <= 200 else { throw ArtifactError.invalidManifest("table shape") }
                guard rows.allSatisfy({ $0.count == headers.count }) else { throw ArtifactError.invalidManifest("table column mismatch") }
                totalCells += headers.count * rows.count
                guard totalCells <= 2_000 else { throw ArtifactError.invalidManifest("table size") }
                guard headers.allSatisfy({ $0.count <= 160 }), rows.flatMap({ $0 }).allSatisfy({ $0.count <= 1_500 }) else { throw ArtifactError.invalidManifest("table cell length") }
            case .barChart:
                guard let bars = section.bars, !bars.isEmpty, bars.count <= 40 else { throw ArtifactError.invalidManifest("bar chart size") }
                guard bars.allSatisfy({ $0.value.isFinite && $0.label.count <= 120 && ($0.displayValue?.count ?? 0) <= 120 }) else { throw ArtifactError.invalidManifest("bar chart value") }
            }
        }
    }

    static func render(_ manifest: ArtifactManifestV6, as format: RenderFormat) throws -> String {
        try validate(manifest)
        switch format {
        case .markdown: return renderMarkdown(manifest)
        case .html: return renderHTML(manifest)
        case .svg: return try renderSVG(manifest)
        }
    }

    static func suggestedFilename(for manifest: ArtifactManifestV6, format: RenderFormat) -> String {
        let base = manifest.title
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(8)
            .joined(separator: "-")
        return "\(base.isEmpty ? "travis-artifact" : base).\(format.rawValue)"
    }

    private static func renderMarkdown(_ manifest: ArtifactManifestV6) -> String {
        var out = "# \(manifest.title)\n"
        if let subtitle = manifest.subtitle, !subtitle.isEmpty { out += "\n\(subtitle)\n" }
        for section in manifest.sections {
            out += "\n## \(section.title)\n"
            switch section.kind {
            case .text:
                out += "\n\(section.text ?? "")\n"
            case .metrics:
                for metric in section.metrics ?? [] {
                    out += "\n- **\(metric.label):** \(metric.value)"
                    if let note = metric.note, !note.isEmpty { out += " — \(note)" }
                }
                out += "\n"
            case .table:
                let headers = section.headers ?? []
                let rows = section.rows ?? []
                out += "\n| \(headers.map(escapeMarkdownCell).joined(separator: " | ")) |\n"
                out += "| \(headers.map { _ in "---" }.joined(separator: " | ")) |\n"
                for row in rows { out += "| \(row.map(escapeMarkdownCell).joined(separator: " | ")) |\n" }
            case .barChart:
                let bars = section.bars ?? []
                let maxValue = max(bars.map { abs($0.value) }.max() ?? 1, 0.000_001)
                for bar in bars {
                    let units = min(32, max(0, Int((abs(bar.value) / maxValue * 32).rounded())))
                    let visual = String(repeating: "█", count: units)
                    out += "\n- \(bar.label): `\(visual)` \(bar.displayValue ?? Self.number(bar.value))"
                }
                out += "\n"
            }
        }
        if let footer = manifest.footer, !footer.isEmpty { out += "\n---\n\(footer)\n" }
        return out
    }

    private static func renderHTML(_ manifest: ArtifactManifestV6) -> String {
        var body = "<header><h1>\(escapeHTML(manifest.title))</h1>"
        if let subtitle = manifest.subtitle, !subtitle.isEmpty { body += "<p class=\"subtitle\">\(escapeHTML(subtitle))</p>" }
        body += "</header>"
        for section in manifest.sections {
            body += "<section><h2>\(escapeHTML(section.title))</h2>"
            switch section.kind {
            case .text:
                body += "<p>\(escapeHTML(section.text ?? "").replacingOccurrences(of: "\n", with: "<br>"))</p>"
            case .metrics:
                body += "<div class=\"metrics\">"
                for metric in section.metrics ?? [] {
                    body += "<article class=\"metric\"><span>\(escapeHTML(metric.label))</span><strong>\(escapeHTML(metric.value))</strong>"
                    if let note = metric.note, !note.isEmpty { body += "<small>\(escapeHTML(note))</small>" }
                    body += "</article>"
                }
                body += "</div>"
            case .table:
                body += "<div class=\"table-wrap\"><table><thead><tr>"
                for h in section.headers ?? [] { body += "<th>\(escapeHTML(h))</th>" }
                body += "</tr></thead><tbody>"
                for row in section.rows ?? [] {
                    body += "<tr>"
                    for cell in row { body += "<td>\(escapeHTML(cell))</td>" }
                    body += "</tr>"
                }
                body += "</tbody></table></div>"
            case .barChart:
                let bars = section.bars ?? []
                let maxValue = max(bars.map { abs($0.value) }.max() ?? 1, 0.000_001)
                body += "<div class=\"bars\">"
                for bar in bars {
                    let pct = min(100, max(0, abs(bar.value) / maxValue * 100))
                    body += "<div class=\"bar-row\"><span>\(escapeHTML(bar.label))</span><div class=\"track\"><div class=\"fill\" style=\"width:\(String(format: "%.2f", pct))%\"></div></div><strong>\(escapeHTML(bar.displayValue ?? number(bar.value)))</strong></div>"
                }
                body += "</div>"
            }
            body += "</section>"
        }
        if let footer = manifest.footer, !footer.isEmpty { body += "<footer>\(escapeHTML(footer))</footer>" }

        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escapeHTML(manifest.title))</title>
        <style>
        :root{color-scheme:dark;background:#07111f;color:#eaf7ff;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}body{margin:0;padding:32px;max-width:1200px;margin-inline:auto}header,section,footer{background:#0b1829;border:1px solid #163750;border-radius:18px;padding:24px;margin:0 0 18px}h1,h2{margin-top:0}.subtitle,small,footer{color:#9db4c7}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.metric{background:#0f2135;border-radius:14px;padding:16px}.metric span,.metric small{display:block}.metric strong{display:block;font-size:1.6rem;margin:8px 0}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse}th,td{padding:10px 12px;border-bottom:1px solid #17344b;text-align:left}.bar-row{display:grid;grid-template-columns:minmax(100px,180px) 1fr minmax(70px,auto);gap:12px;align-items:center;margin:10px 0}.track{height:12px;border-radius:999px;background:#10283d;overflow:hidden}.fill{height:100%;background:#27d8ff;border-radius:999px}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func renderSVG(_ manifest: ArtifactManifestV6) throws -> String {
        let chartSections = manifest.sections.filter { $0.kind == .barChart }
        guard !chartSections.isEmpty else { throw ArtifactError.invalidManifest("SVG requires at least one barChart section") }
        let bars = chartSections.flatMap { $0.bars ?? [] }.prefix(24)
        let width = 1200.0
        let rowHeight = 42.0
        let top = 150.0
        let height = top + Double(bars.count) * rowHeight + 80
        let maxValue = max(bars.map { abs($0.value) }.max() ?? 1, 0.000_001)
        var rows = ""
        for (index, bar) in bars.enumerated() {
            let y = top + Double(index) * rowHeight
            let barWidth = min(720, abs(bar.value) / maxValue * 720)
            rows += "<text x=\"40\" y=\"\(y + 18)\" class=\"label\">\(escapeXML(bar.label))</text>"
            rows += "<rect x=\"300\" y=\"\(y)\" width=\"720\" height=\"24\" rx=\"12\" class=\"track\"/>"
            rows += "<rect x=\"300\" y=\"\(y)\" width=\"\(String(format: "%.2f", barWidth))\" height=\"24\" rx=\"12\" class=\"fill\"/>"
            rows += "<text x=\"1040\" y=\"\(y + 18)\" class=\"value\">\(escapeXML(bar.displayValue ?? number(bar.value)))</text>"
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width))" height="\(Int(height))" viewBox="0 0 \(Int(width)) \(Int(height))">
        <style>.bg{fill:#07111f}.panel{fill:#0b1829;stroke:#163750}.title{fill:#eaf7ff;font:700 34px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.sub{fill:#9db4c7;font:18px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.label,.value{fill:#d9efff;font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.track{fill:#10283d}.fill{fill:#27d8ff}</style>
        <rect width="100%" height="100%" class="bg"/><rect x="20" y="20" width="1160" height="\(Int(height-40))" rx="24" class="panel"/>
        <text x="40" y="70" class="title">\(escapeXML(manifest.title))</text>
        <text x="40" y="105" class="sub">\(escapeXML(manifest.subtitle ?? chartSections.first?.title ?? "TRAVIS visual artifact"))</text>
        \(rows)</svg>
        """
    }

    private static func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func number(_ value: Double) -> String { String(format: "%.4g", value) }
    private static func escapeMarkdownCell(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    private static func escapeXML(_ value: String) -> String { escapeHTML(value) }
}
