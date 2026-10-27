import Foundation

struct CuriusFeedItem: Identifiable {
    var id: String { url }
    let url: String
    var title: String
    var metadata: String
    let day: String
    var saved: Bool
}

struct CuriusFeedPage {
    let items: [CuriusFeedItem]
    let next: Int?
}

/// Papery's existing feed endpoint returns escaped, well-formed HTML fragments.
/// Parse only its known fields; never execute or render remote HTML.
final class CuriusFeedParser: NSObject, XMLParserDelegate {
    private var items: [CuriusFeedItem] = []
    private var current: CuriusFeedItem?
    private var day = ""
    private var field = ""
    private var text = ""

    static func parse(_ html: String) throws -> [CuriusFeedItem] {
        let delegate = CuriusFeedParser()
        let parser = XMLParser(data: Data(("<feed>" + html + "</feed>").utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.coderReadCorrupt)
        }
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributesDict: [String: String]) {
        let classes = (attributesDict["class"] ?? "").split(separator: " ")
        if elementName == "li", classes.contains("feed-day") {
            field = "day"; text = ""
        } else if elementName == "li", classes.contains("feed-item"),
                  let url = attributesDict["data-url"],
                  let scheme = URL(string: url)?.scheme, ["https", "http"].contains(scheme) {
            current = CuriusFeedItem(url: url, title: "", metadata: "", day: day, saved: false)
        } else if elementName == "a", current != nil {
            field = "title"; text = ""
        } else if elementName == "span", classes.contains("fmeta"), current != nil {
            field = "metadata"; text = ""
        } else if elementName == "button", classes.contains("saved") {
            current?.saved = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !field.isEmpty { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "a", field == "title" { current?.title = text; field = "" }
        if elementName == "span", field == "metadata" { current?.metadata = text; field = "" }
        if elementName == "li" {
            if field == "day" { day = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let item = current { items.append(item) }
            current = nil; field = ""; text = ""
        }
    }
}
