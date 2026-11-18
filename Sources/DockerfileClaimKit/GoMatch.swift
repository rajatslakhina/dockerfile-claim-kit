/// Go's `filepath.Match` for one path segment, which the classic builder uses for `COPY` sources: `*` is any run of
/// characters, `?` one character, `[a-z]` and `[^a-z]` a class, `\` escapes the next character. A malformed pattern
/// matches nothing.
enum GoMatch {
    static func matches(_ pattern: String, _ name: String) -> Bool {
        matches(Array(pattern), 0, Array(name), 0)
    }

    static func hasWildcard(_ text: String) -> Bool {
        text.contains { "*?[".contains($0) }
    }

    private static func matches(_ pattern: [Character], _ p: Int, _ name: [Character], _ n: Int) -> Bool {
        guard p < pattern.count else { return n == name.count }
        switch pattern[p] {
        case "*":
            return (n...name.count).contains { matches(pattern, p + 1, name, $0) }
        case "?":
            return n < name.count && matches(pattern, p + 1, name, n + 1)
        case "[":
            guard n < name.count, let (matched, end) = matchClass(pattern, p + 1, name[n]) else { return false }
            return matched && matches(pattern, end, name, n + 1)
        case "\\":
            guard p + 1 < pattern.count else { return false }
            return n < name.count && name[n] == pattern[p + 1] && matches(pattern, p + 2, name, n + 1)
        default:
            return n < name.count && name[n] == pattern[p] && matches(pattern, p + 1, name, n + 1)
        }
    }

    /// Whether `character` is in the class that starts at `start` (just after `[`), and where the class ends.
    private static func matchClass(_ pattern: [Character], _ start: Int, _ character: Character) -> (Bool, Int)? {
        var index = start
        let negated = index < pattern.count && pattern[index] == "^"
        if negated { index += 1 }
        var matched = false
        while index < pattern.count {
            if pattern[index] == "]" { return (matched != negated, index + 1) }
            guard let low = literal(pattern, &index) else { return nil }
            var high = low
            if index + 1 < pattern.count, pattern[index] == "-", pattern[index + 1] != "]" {
                index += 1
                guard let end = literal(pattern, &index) else { return nil }
                high = end
            }
            if low <= character && character <= high { matched = true }
        }
        return nil
    }

    private static func literal(_ pattern: [Character], _ index: inout Int) -> Character? {
        if pattern[index] == "\\" { index += 1 }
        guard index < pattern.count else { return nil }
        defer { index += 1 }
        return pattern[index]
    }
}
