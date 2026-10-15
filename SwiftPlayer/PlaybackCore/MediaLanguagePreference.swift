import Foundation

nonisolated func preferredLanguageIndex(in languages: [String?], preferred: [String]) -> Int? {
    for tag in preferred {
        let normalized = tag.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = languages.firstIndex(where: { $0?.replacingOccurrences(of: "_", with: "-").lowercased() == normalized }) { return exact }
        let requested = Locale(identifier: tag).language
        guard let code = requested.languageCode, code.identifier != "und" else { continue }
        let matches = languages.indices.filter { index in
            guard let language = languages[index] else { return false }
            return Locale(identifier: language).language.languageCode == code
        }
        if let script = requested.script,
           let match = matches.first(where: { Locale(identifier: languages[$0]!).language.script == script }) { return match }
        if let match = matches.first { return match }
    }
    return nil
}
