import Foundation

enum SpicyLyricsParserError: Error {
    case invalidData
    case missingLyrics
    case missingLines
    case missingWords
    case invalidSyllables
    case invalidTimestamp
    case noMatchingQuery
    case httpError(Int)
}

struct SpicyLyricsParser {
    
    /// 解析 SpicyLyrics 的 SLObjPack 数据，转换成 LyricsDto
    static func parseLyrics(from rawData: Data) throws -> LyricsDto {
        let json = try JSONSerialization.jsonObject(with: rawData)
        
        guard let dict = json as? [String: Any] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        guard let queries = dict["queries"] as? [[String: Any]] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        guard let matchedQuery = queries.first(where: { ($0["operationId"] as? String) == "0" }),
              let result = matchedQuery["result"] as? [String: Any] else {
            throw SpicyLyricsParserError.noMatchingQuery
        }
        
        let httpStatus = result["httpStatus"] as? Int ?? 0
        switch httpStatus {
        case 200:
            break
        case 404:
            throw LyricsError.noSuchSong
        case 401, 403:
            spotifyAccessToken = nil
            throw LyricsError.noSuchSong
        default:
            if httpStatus >= 400 {
                throw SpicyLyricsParserError.httpError(httpStatus)
            }
        }
        
        guard let data = result["data"] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        let unpacked = try SLObjPack.unpack(data)
        
        // 数据在根级别，没有 "lyrics" 包装
        guard let lyricsObj = unpacked.objectValue else {
            throw SpicyLyricsParserError.missingLyrics
        }
        
        let type = lyricsObj["Type"]?.stringValue ?? "Static"
        
        let dto: LyricsDto
        switch type {
        case "Syllable":
            dto = parseSyllableLyrics(lyricsObj)
        case "Line":
            dto = parseLineLyrics(lyricsObj)
        default:
            dto = parseStaticLyrics(lyricsObj)
        }
        
        // 繁体转简体（和 Musixmatch 一样）
        let convertedLines = dto.lines.map { line -> LyricsLineDto in
            let simplifiedWords = traditionalToSimplified(line.words)
            return LyricsLineDto(
                words: simplifiedWords,
                startTimeMs: line.startTimeMs,
                syllables: line.syllables
            )
        }
        
        return LyricsDto(
            lines: convertedLines,
            timeSynced: dto.timeSynced,
            isSyllableSynced: dto.isSyllableSynced,
            romanization: dto.romanization,
            translation: dto.translation
        )
    }
    
    // MARK: - Syllable 逐字歌词解析
    
    private static func parseSyllableLyrics(_ lyricsObj: [String: SLObjPackValue]) -> LyricsDto {
        guard let content = lyricsObj["Content"]?.arrayValue else {
            return emptyDto()
        }
        
        var lines: [LyricsLineDto] = []
        var hasTimeSynced = false
        var hasSyllableSynced = false
        
        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal",
                  let lead = entry["Lead"]?.objectValue else {
                continue
            }
            
            var lineText = ""
            var syllables: [SyllableDto] = []
            
            if let syllablesArray = lead["Syllables"]?.arrayValue {
                for syllable in syllablesArray {
                    guard let syllableObj = syllable.objectValue else { continue }
                    
                    if let text = syllableObj["Text"]?.stringValue {
                        let isPartOfWord = syllableObj["IsPartOfWord"]?.boolValue ?? false
                        if !lineText.isEmpty && !isPartOfWord {
                            lineText += " "
                        }
                        lineText += text
                    }
                    
                    if let startTime = syllableObj["StartTime"]?.doubleValue,
                       let numChars = syllableObj["Text"]?.stringValue?.count {
                        syllables.append(SyllableDto(
                            startTimeMs: Int64(startTime * 1000),
                            numChars: Int64(numChars)
                        ))
                        hasSyllableSynced = true
                    }
                }
            }
            
            if lineText.isEmpty {
                if let text = lead["Text"]?.stringValue {
                    lineText = text
                } else {
                    continue
                }
            }
            
            var startTimeMs: Int64? = nil
            if let startTime = lead["StartTime"]?.doubleValue {
                startTimeMs = Int64(startTime * 1000)
                hasTimeSynced = true
            }
            
            let lineDto = LyricsLineDto(
                words: lineText,
                startTimeMs: startTimeMs,
                syllables: syllables.isEmpty ? nil : syllables
            )
            lines.append(lineDto)
        }
        
        let romanization = extractRomanization(from: lyricsObj)
        
        return LyricsDto(
            lines: lines,
            timeSynced: hasTimeSynced,
            isSyllableSynced: hasSyllableSynced,
            romanization: romanization,
            translation: extractTranslation(from: lyricsObj)
        )
    }
    
    // MARK: - Line 逐行歌词解析
    
    private static func parseLineLyrics(_ lyricsObj: [String: SLObjPackValue]) -> LyricsDto {
        guard let content = lyricsObj["Content"]?.arrayValue else {
            return emptyDto()
        }
        
        var lines: [LyricsLineDto] = []
        var hasTimeSynced = false
        
        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            
            let text = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue ?? ""
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            
            var startTimeMs: Int64? = nil
            if let startTime = startTime {
                startTimeMs = Int64(startTime * 1000)
                hasTimeSynced = true
            }
            
            lines.append(LyricsLineDto(
                words: text,
                startTimeMs: startTimeMs,
                syllables: nil
            ))
        }
        
        let romanization = extractRomanization(from: lyricsObj)
        
        return LyricsDto(
            lines: lines,
            timeSynced: hasTimeSynced,
            isSyllableSynced: false,
            romanization: romanization,
            translation: extractTranslation(from: lyricsObj)
        )
    }
    
    // MARK: - Static 静态歌词解析
    
    private static func parseStaticLyrics(_ lyricsObj: [String: SLObjPackValue]) -> LyricsDto {
        let rawLines = lyricsObj["Lines"]?.arrayValue ?? []
        
        let lines = rawLines.compactMap { entry -> LyricsLineDto? in
            guard let text = entry["Text"]?.stringValue else { return nil }
            return LyricsLineDto(
                words: text,
                startTimeMs: nil,
                syllables: nil
            )
        }
        
        let romanization = extractRomanization(from: lyricsObj)
        
        return LyricsDto(
            lines: lines,
            timeSynced: false,
            isSyllableSynced: false,
            romanization: romanization,
            translation: extractTranslation(from: lyricsObj)
        )
    }
    
    // MARK: - Helper: 提取罗马化状态
    
    private static func extractRomanization(from lyricsObj: [String: SLObjPackValue]) -> LyricsRomanizationStatus {
        if let romanization = lyricsObj["Romanization"]?.stringValue {
            switch romanization.lowercased() {
            case "romanized":
                return .romanized
            case "canberomanized":
                return .canBeRomanized
            default:
                return .original
            }
        }
        
        if let hasRomanized = lyricsObj["HasTransliterations"]?.boolValue, hasRomanized {
            return .romanized
        }
        
        return .original
    }
    
    // MARK: - Helper: 提取翻译
    
    private static func extractTranslation(from lyricsObj: [String: SLObjPackValue]) -> LyricsTranslationDto? {
        guard let translationObj = lyricsObj["Translation"]?.objectValue ?? lyricsObj["translation"]?.objectValue else {
            return nil
        }
        
        guard let languageCode = translationObj["Language"]?.stringValue ?? translationObj["language"]?.stringValue,
              let lines = translationObj["Lines"]?.arrayValue ?? translationObj["lines"]?.arrayValue else {
            return nil
        }
        
        let translatedLines = lines.compactMap { $0.stringValue }
        
        return LyricsTranslationDto(
            languageCode: languageCode,
            lines: translatedLines
        )
    }
    
    // MARK: - Helper: 空 DTO
    
    private static func emptyDto() -> LyricsDto {
        LyricsDto(
            lines: [],
            timeSynced: false,
            isSyllableSynced: false,
            romanization: .original,
            translation: nil
        )
    }
}
