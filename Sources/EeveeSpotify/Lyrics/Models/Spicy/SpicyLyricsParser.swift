import Foundation

enum SpicyLyricsParserError: Error {
    case invalidData
    case missingLyrics
    case missingLines
    case missingWords
    case invalidSyllables
    case invalidTimestamp
}

struct SpicyLyricsParser {
    
    /// 解析 SpicyLyrics 的 SLObjPack 数据，转换成 LyricsDto
    static func parseLyrics(from rawData: Data) throws -> LyricsDto {
        // 1. 解码 JSON
        let json = try JSONSerialization.jsonObject(with: rawData)
        
        // 2. 提取 data 字段
        guard let dict = json as? [String: Any],
              let data = dict["data"] else {
            throw SpicyLyricsParserError.invalidData
        }
        
        // 3. 用 SLObjPack 解包
        let unpacked = try SLObjPack.unpack(data)
        
        // 4. 提取 lyrics 对象
        guard let lyricsObj = unpacked["lyrics"]?.objectValue else {
            throw SpicyLyricsParserError.missingLyrics
        }
        
        // 5. 提取 lines 数组
        guard let linesArray = lyricsObj["lines"]?.arrayValue else {
            throw SpicyLyricsParserError.missingLines
        }
        
        // 6. 解析每一行
        var lines: [LyricsLineDto] = []
        var hasTimeSynced = false
        var hasSyllableSynced = false
        
        for lineValue in linesArray {
            guard let lineObj = lineValue.objectValue else {
                continue
            }
            
            // 提取文本
            guard let words = lineObj["words"]?.stringValue else {
                continue
            }
            
            // 提取开始时间（毫秒）
            var startTimeMs: Int64? = nil
            if let startTime = lineObj["startTimeMs"]?.doubleValue {
                startTimeMs = Int64(startTime)
                if startTimeMs != nil {
                    hasTimeSynced = true
                }
            }
            
            // 提取音节（逐字歌词）
            var syllables: [SyllableDto]? = nil
            if let syllablesArray = lineObj["syllables"]?.arrayValue,
               !syllablesArray.isEmpty {
                syllables = parseSyllables(syllablesArray)
                if syllables?.isEmpty == false {
                    hasSyllableSynced = true
                }
            }
            
            // 如果没找到 syllables，尝试从其他字段提取
            if syllables == nil || syllables?.isEmpty == true {
                if let startTimes = lineObj["syllableStartTimeMs"]?.arrayValue,
                   let numChars = lineObj["syllableNumChars"]?.arrayValue,
                   startTimes.count == numChars.count {
                    syllables = parseSyllablesFromArrays(startTimes: startTimes, numChars: numChars)
                    if syllables?.isEmpty == false {
                        hasSyllableSynced = true
                    }
                }
            }
            
            let lineDto = LyricsLineDto(
                words: words,
                startTimeMs: startTimeMs,
                syllables: syllables
            )
            lines.append(lineDto)
        }
        
        // 7. 提取罗马化状态
        let romanization = extractRomanization(from: lyricsObj)
        
        // 8. 提取翻译
        let translation = extractTranslation(from: lyricsObj)
        
        // 9. 返回 LyricsDto
        return LyricsDto(
            lines: lines,
            timeSynced: hasTimeSynced,
            isSyllableSynced: hasSyllableSynced,
            romanization: romanization,
            translation: translation
        )
    }
    
    // MARK: - Private Helpers
    
    private static func parseSyllables(_ syllablesArray: [SLObjPackValue]) -> [SyllableDto] {
        var result: [SyllableDto] = []
        
        for syllableValue in syllablesArray {
            guard let syllableObj = syllableValue.objectValue else {
                continue
            }
            
            guard let startTimeMs = syllableObj["startTimeMs"]?.doubleValue,
                  let numChars = syllableObj["numChars"]?.doubleValue else {
                continue
            }
            
            result.append(SyllableDto(
                startTimeMs: Int64(startTimeMs),
                numChars: Int64(numChars)
            ))
        }
        
        return result
    }
    
    private static func parseSyllablesFromArrays(startTimes: [SLObjPackValue], numChars: [SLObjPackValue]) -> [SyllableDto] {
        var result: [SyllableDto] = []
        
        for i in 0..<min(startTimes.count, numChars.count) {
            guard let startTime = startTimes[i].doubleValue,
                  let numChar = numChars[i].doubleValue else {
                continue
            }
            
            result.append(SyllableDto(
                startTimeMs: Int64(startTime),
                numChars: Int64(numChar)
            ))
        }
        
        return result
    }
    
    private static func extractRomanization(from lyricsObj: [String: SLObjPackValue]) -> LyricsRomanizationStatus {
        // 检查是否有 romanization 字段
        if let romanization = lyricsObj["romanization"]?.stringValue {
            switch romanization.lowercased() {
            case "romanized":
                return .romanized
            case "canberomanized":
                return .canBeRomanized
            default:
                return .original
            }
        }
        
        // 检查是否有罗马化歌词
        if let romanizedLines = lyricsObj["romanizedLines"]?.arrayValue,
           !romanizedLines.isEmpty {
            return .romanized
        }
        
        return .original
    }
    
    private static func extractTranslation(from lyricsObj: [String: SLObjPackValue]) -> LyricsTranslationDto? {
        guard let translationObj = lyricsObj["translation"]?.objectValue else {
            return nil
        }
        
        guard let languageCode = translationObj["language"]?.stringValue,
              let lines = translationObj["lines"]?.arrayValue else {
            return nil
        }
        
        let translatedLines = lines.compactMap { $0.stringValue }
        
        return LyricsTranslationDto(
            languageCode: languageCode,
            lines: translatedLines
        )
    }
}