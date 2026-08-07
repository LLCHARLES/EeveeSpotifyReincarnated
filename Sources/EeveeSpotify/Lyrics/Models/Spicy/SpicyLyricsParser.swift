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
    /// 适配上游 API 格式：queries[0].result.data
    static func parseLyrics(from rawData: Data) throws -> LyricsDto {
        // 1. 解码 JSON
        let json = try JSONSerialization.jsonObject(with: rawData)
        
        guard let dict = json as? [String: Any] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        // 2. 提取 queries 数组
        guard let queries = dict["queries"] as? [[String: Any]] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        // 3. 查找 operationId == "0" 的查询结果
        guard let matchedQuery = queries.first(where: { ($0["operationId"] as? String) == "0" }),
              let result = matchedQuery["result"] as? [String: Any] else {
            throw SpicyLyricsParserError.noMatchingQuery
        }
        
        // 4. 检查 HTTP 状态码
        let httpStatus = result["httpStatus"] as? Int ?? 0
        switch httpStatus {
        case 200:
            break // 成功，继续
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
        
        // 5. 提取 data 字段（ObjPack 格式）
        guard let data = result["data"] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        // 6. 用 SLObjPack 解包
        let unpacked = try SLObjPack.unpack(data)
        
        // 7. 提取 lyrics 对象
        guard let lyricsObj = unpacked["lyrics"]?.objectValue else {
            throw SpicyLyricsParserError.missingLyrics
        }
        
        // 8. 提取 type 字段，判断歌词类型
        let type = lyricsObj["Type"]?.stringValue ?? "Static"
        
        // 9. 根据类型解析
        let dto: LyricsDto
        switch type {
        case "Syllable":
            dto = parseSyllableLyrics(lyricsObj)
        case "Line":
            dto = parseLineLyrics(lyricsObj)
        default:
            dto = parseStaticLyrics(lyricsObj)
        }
    
    // ✅ 加日志：打印解析结果
        print("[SpicyLyrics] ✅ 解析完成：\(dto.lines.count) 行，isSyllableSynced=\(dto.isSyllableSynced)")
        for (index, line) in dto.lines.enumerated() {
            print("[SpicyLyrics]   第\(index+1)行: words=\(line.words), syllables=\(line.syllables?.count ?? 0)")
        }
    
        return dto
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
            
            // 提取歌词文本（从 Syllables 拼接）
            var lineText = ""
            var syllables: [SyllableDto] = []
            
            if let syllablesArray = lead["Syllables"]?.arrayValue {
                for syllable in syllablesArray {
                    guard let syllableObj = syllable.objectValue else { continue }
                    
                    // 提取文本
                    if let text = syllableObj["Text"]?.stringValue {
                        let isPartOfWord = syllableObj["IsPartOfWord"]?.boolValue ?? false
                        if !lineText.isEmpty && !isPartOfWord {
                            lineText += " "
                        }
                        lineText += text
                    }
                    
                    // 提取音节时间
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
            
            // 如果没有 syllables，尝试直接从 Lead 提取
            if lineText.isEmpty {
                if let text = lead["Text"]?.stringValue {
                    lineText = text
                } else {
                    continue
                }
            }
            
            // 提取开始时间
            var startTimeMs: Int64? = nil
            if let startTime = lead["StartTime"]?.doubleValue {
                startTimeMs = Int64(startTime * 1000)
                hasTimeSynced = true
            }
            
            // 提取罗马化
            if lead["TransliteratedText"]?.stringValue != nil {
                // 有罗马化标记
            }
            
            let lineDto = LyricsLineDto(
                words: lineText,
                startTimeMs: startTimeMs,
                syllables: syllables.isEmpty ? nil : syllables
            )
            lines.append(lineDto)
        }
        
        // 判断罗马化状态
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