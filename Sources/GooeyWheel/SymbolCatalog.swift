import Foundation

/// Every SF Symbol that ships with this Mac, for an icon picker grid.
enum SymbolCatalog {
    /// All symbol names usable on this Mac, grouped by Apple's subject categories in their order,
    /// restricted ones and per-language variants excluded. Loaded once, lazily; safe to call from a
    /// background thread.
    static var all: [String] { Index.current.names }

    /// Names matching the query by name fragments and search keywords, best matches first. Empty query returns `all`.
    static func search(_ query: String) -> [String] {
        Index.current.search(query)
    }

    /// Apple's categories (key, title, icon symbol) in their order, for optional filter chips.
    static var categories: [(key: String, title: String, symbol: String)] {
        Index.current.categories
    }

    /// Symbols in one category, in Apple's order. The `"all"` category returns every symbol.
    static func symbols(in categoryKey: String) -> [String] {
        Index.current.symbols(in: categoryKey)
    }
}

/// Immutable index. `static let` initializes it once, and that initialization is thread-safe.
private struct Index {
    struct Entry {
        var lowerNames: [String]
        var tokens: [String]
        var keywords: [String]
    }

    static let current = Index.load()

    let names: [String]
    /// Each name's place in Apple's alphabetical order. Search results keep that order within
    /// a rank, so a symbol's variants stay together.
    let alphabetical: [Int]
    let categories: [(key: String, title: String, symbol: String)]
    let members: [String: [String]]
    let entries: [Entry]

    func symbols(in categoryKey: String) -> [String] {
        if categoryKey == "all" { return names }
        return members[categoryKey] ?? []
    }

    func search(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return names }
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty { return names }
        if terms.count == 1 { return ranked(terms[0]) }
        return ranked(terms)
    }

    /// Exact name, then name prefix, then a dot-separated token prefix, then a keyword.
    private func rank(_ term: String, _ entry: Entry) -> Int? {
        for name in entry.lowerNames where name == term { return 0 }
        for name in entry.lowerNames where name.hasPrefix(term) { return 1 }
        for token in entry.tokens where token.hasPrefix(term) { return 2 }
        for word in entry.keywords where word.hasPrefix(term) { return 3 }
        return nil
    }

    private func ranked(_ term: String) -> [String] {
        var buckets = [[Int]](repeating: [], count: 4)
        for (offset, entry) in entries.enumerated() {
            guard let rank = rank(term, entry) else { continue }
            buckets[rank].append(offset)
        }
        return buckets.flatMap { bucket in
            bucket.sorted { alphabetical[$0] < alphabetical[$1] }.map { names[$0] }
        }
    }

    /// Every term must match. Lower summed rank wins; Apple's order breaks ties.
    private func ranked(_ terms: [String]) -> [String] {
        var matches: [(rank: Int, index: Int)] = []
        for (offset, entry) in entries.enumerated() {
            var total = 0
            var hit = true
            for term in terms {
                guard let rank = rank(term, entry) else {
                    hit = false
                    break
                }
                total += rank
            }
            if hit { matches.append((total, offset)) }
        }
        matches.sort { $0.rank == $1.rank ? alphabetical[$0.index] < alphabetical[$1.index] : $0.rank < $1.rank }
        return matches.map { names[$0.index] }
    }

    private static func load() -> Index {
        let root = URL(
            fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources",
            isDirectory: true
        )
        func plist(_ name: String) -> Any? {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        }

        guard let ordered = plist("symbol_order.plist") as? [String] else {
            return Index(names: [], alphabetical: [], categories: [], members: [:], entries: [])
        }

        let restrictionMap = plist("symbol_restrictions.strings") as? [String: String] ?? [:]
        let restrictions = Set(restrictionMap.keys)
        let availability = plist("name_availability.plist") as? [String: Any]
        let symbolYears = availability?["symbols"] as? [String: String] ?? [:]
        let releases = availability?["year_to_release"] as? [String: [String: String]] ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = (os.majorVersion, os.minorVersion)
        let haveReleases = !releases.isEmpty

        func version(_ string: String) -> (Int, Int)? {
            let parts = string.split(separator: ".")
            guard let major = Int(parts.first ?? "") else { return nil }
            let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return (major, minor)
        }

        /// A year that maps to a newer macOS is dropped. An unmapped year is dropped when the
        /// release table loaded; symbols with no year, or a missing table, stay.
        func available(_ name: String) -> Bool {
            guard haveReleases, let year = symbolYears[name] else { return true }
            guard let mac = releases[year]?["macOS"], let required = version(mac) else { return false }
            if required.0 != current.0 { return required.0 < current.0 }
            return required.1 <= current.1
        }

        var names: [String] = []
        names.reserveCapacity(ordered.count)
        var seen = Set<String>()
        seen.reserveCapacity(ordered.count)
        for name in ordered where !name.isEmpty && seen.insert(name).inserted {
            if restrictions.contains(name) || !available(name) { continue }
            names.append(name)
        }

        // A variant drawn for one language or for right-to-left text is left out: the system
        // swaps it in for that language by itself. One with no plain symbol to stand for it stays.
        let variantSuffixes = localizedSuffixes(in: ordered)
        let known = Set(ordered)
        names.removeAll { name in
            guard let dot = name.lastIndex(of: "."),
                  variantSuffixes.contains(String(name[name.index(after: dot)...])) else { return false }
            return known.contains(String(name[..<dot]))
        }

        var categories: [(key: String, title: String, symbol: String)] = []
        if let rows = plist("categories.plist") as? [[String: Any]] {
            for row in rows {
                guard let key = row["key"] as? String, let icon = row["icon"] as? String,
                      !key.isEmpty, !icon.isEmpty else { continue }
                categories.append((key, Self.title(for: key), icon))
            }
        }
        let categoryMap = plist("symbol_categories.plist") as? [String: [String]] ?? [:]

        // The system's own order is alphabetical, which opens on a page of digits. Subjects
        // first instead: each symbol goes with the earliest subject category it is in, and
        // keeps its alphabetical place within it. Symbols in no subject category come last.
        let subjects = categories.map(\.key).filter { !metaCategories.contains($0) }
        let subjectRank = Dictionary(uniqueKeysWithValues: subjects.enumerated().map { ($1, $0) })
        let bySubject = names.enumerated().map { offset, name in
            (rank: categoryMap[name]?.compactMap { subjectRank[$0] }.min() ?? Int.max, offset: offset, name: name)
        }.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
        names = bySubject.map(\.name)
        let alphabetical = bySubject.map(\.offset)
        let included = Set(names)

        let aliasMap = plist("name_aliases.strings") as? [String: String] ?? [:]
        func resolve(_ name: String) -> String {
            var current = name
            var walked = Set<String>()
            while let next = aliasMap[current], walked.insert(current).inserted {
                current = next
            }
            return current
        }

        var aliasesOf: [String: [String]] = [:]
        for alias in aliasMap.keys {
            let target = resolve(alias)
            if target != alias && included.contains(target) {
                aliasesOf[target, default: []].append(alias)
            }
        }

        var keywordsOf: [String: [String]] = [:]
        if let table = plist("symbol_search.plist") as? [String: [String]] {
            for (key, words) in table {
                let target = resolve(key)
                guard included.contains(target) else { continue }
                var list = keywordsOf[target] ?? []
                var known = Set(list)
                for word in words {
                    let lower = word.lowercased()
                    guard !lower.isEmpty else { continue }
                    var pieces = [lower]
                    if lower.contains(" ") {
                        pieces.append(contentsOf: lower.split(separator: " ").map(String.init))
                    }
                    for piece in pieces where known.insert(piece).inserted {
                        list.append(piece)
                    }
                }
                keywordsOf[target] = list
            }
        }

        var entries: [Entry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            var lowerNames: [String] = []
            var tokens: [String] = []
            var tokenSeen = Set<String>()
            func absorb(_ raw: String) {
                let lower = raw.lowercased()
                if !lowerNames.contains(lower) { lowerNames.append(lower) }
                for part in lower.split(separator: ".") {
                    let token = String(part)
                    if tokenSeen.insert(token).inserted { tokens.append(token) }
                }
            }
            absorb(name)
            for alias in aliasesOf[name] ?? [] { absorb(alias) }
            entries.append(Entry(
                lowerNames: lowerNames,
                tokens: tokens,
                keywords: keywordsOf[name] ?? []
            ))
        }

        var sets: [String: Set<String>] = [:]
        for (symbol, keys) in categoryMap where included.contains(symbol) {
            for key in keys {
                sets[key, default: []].insert(symbol)
            }
        }
        var members: [String: [String]] = [:]
        members.reserveCapacity(sets.count)
        for (key, set) in sets {
            members[key] = names.filter { set.contains($0) }
        }

        return Index(names: names, alphabetical: alphabetical, categories: categories, members: members, entries: entries)
    }

    /// Categories that say how a symbol draws or when it was added, not what it shows. They
    /// don't take part in ordering the full list.
    private static let metaCategories: Set<String> = ["all", "whatsnew", "draw", "variable", "multicolor"]

    /// The last parts of names that mark a variant for one language ("ar", "hi") or for
    /// right-to-left text ("rtl"), found in the names themselves: a part that is a language
    /// code and is only ever the last part of a name. The second test keeps English words that
    /// happen to be language codes, such as "fan", "min", and "car".
    private static func localizedSuffixes(in names: [String]) -> Set<String> {
        var last = Set<String>()
        var elsewhere = Set<String>()
        for name in names {
            let parts = name.split(separator: ".")
            for (i, part) in parts.enumerated() {
                if i == parts.count - 1, parts.count > 1 { last.insert(String(part)) } else { elsewhere.insert(String(part)) }
            }
        }
        let codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier)).union(["rtl"])
        return last.intersection(codes).subtracting(elsewhere)
    }

    /// Apple's SF Symbols category names. Keys the system adds later get a capitalized fallback.
    private static func title(for key: String) -> String {
        let known: [String: String] = [
            "all": "All",
            "whatsnew": "What's New",
            "draw": "Draw",
            "variable": "Variable",
            "multicolor": "Multicolor",
            "communication": "Communication",
            "weather": "Weather",
            "maps": "Maps",
            "objectsandtools": "Objects & Tools",
            "devices": "Devices",
            "cameraandphotos": "Camera & Photos",
            "gaming": "Gaming",
            "connectivity": "Connectivity",
            "transportation": "Transportation",
            "automotive": "Automotive",
            "accessibility": "Accessibility",
            "privacyandsecurity": "Privacy & Security",
            "human": "Human",
            "home": "Home",
            "fitness": "Fitness",
            "nature": "Nature",
            "editing": "Editing",
            "textformatting": "Text Formatting",
            "media": "Media",
            "keyboard": "Keyboard",
            "commerce": "Commerce",
            "time": "Time",
            "health": "Health",
            "shapes": "Shapes",
            "arrows": "Arrows",
            "indices": "Indices",
            "math": "Math",
        ]
        if let title = known[key] { return title }
        guard let first = key.first else { return key }
        return first.uppercased() + key.dropFirst()
    }
}
