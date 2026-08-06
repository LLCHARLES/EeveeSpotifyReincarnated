import Foundation

class SpicyLyricsRepository: LyricsRepository {
    
    private let session = URLSession.shared
    private let baseURL = "https://api.spicelyrics.com"  // 替换为实际 URL
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        // 构建请求
        guard let url = URL(string: "\(baseURL)/search") else {
            throw LyricsError.invalidSource
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "title": query.title,
            "artist": query.primaryArtist,
            "spotifyId": query.spotifyTrackId ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<LyricsDto, Error>?
        
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = .failure(error)
                return
            }
            
            guard let data = data else {
                result = .failure(LyricsError.noSuchSong)
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let dto = self.parseLyrics(json) {
                    result = .success(dto)
                } else {
                    result = .failure(LyricsError.noSuchSong)
                }
            } catch {
                result = .failure(error)
            }
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        
        switch result {
        case .success(let dto):
            return dto
        case .failure(let error):
            throw error
        case .none:
            throw LyricsError.noSuchSong
        }
    }
    
    // MARK: - Parsing
    
    private func parseLyrics(_ json: [String: Any]?) -> LyricsDto? {
        guard let json = json else { return nil }
        
        // 判断是否有时间同步
        if let lines = json["lines"] as? [[String: Any]],
           let firstLine = lines.first,
           firstLine["startTime"] != nil {
            return parseTimeSyncedLyrics(json)
        } else {
            return parseUnsyncedLyrics(json)
        }
    }
    
    // MARK: - 时间同步歌词解析
    
    private func parseTimeSyncedLyrics(_ json: [String: Any]) -> LyricsDto? {
        guard let linesData = json["lines"] as? [[String: Any]] else {
            return nil
        }
        
        var lines: [LyricsLineDto] = []
        var hasRomanized = false
        
        for entry in linesData {
            // 提取文本和开始时间
            let lineText = entry["text"] as? String ?? ""
            let startTime = entry["startTime"] as? Double ?? 0.0
            
            // 检查是否有罗马化版本
            if entry["romanized"] != nil {
                hasRomanized = true
            }
            
            // 处理音节（如果有）
            var syllables: [SyllableDto]? = nil
            if let syllableData = entry["syllables"] as? [[String: Any]] {
                syllables = syllableData.compactMap { syl in
                    guard let start = syl["startTime"] as? Double,
                          let numChars = syl["numChars"] as? Int else {
                        return nil
                    }
                    return SyllableDto(
                        startTimeMs: Int64(start * 1000),
                        numChars: Int64(numChars)
                    )
                }
            }
            
            lines.append(LyricsLineDto(
                words: lineText,
                startTimeMs: Int64(startTime * 1000),
                syllables: syllables
            ))
        }
        
        // 判断罗马化状态
        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.words).canBeRomanized ? .canBeRomanized : .original)
        
        return LyricsDto(
            lines: lines,
            timeSynced: true,
            isSyllableSynced: lines.contains { $0.syllables != nil },
            romanization: romanization,
            translation: nil
        )
    }
    
    // MARK: - 无时间同步歌词解析
    
    private func parseUnsyncedLyrics(_ json: [String: Any]) -> LyricsDto? {
        guard let linesData = json["lines"] as? [[String: Any]] else {
            return nil
        }
        
        let lines = linesData.compactMap { entry -> LyricsLineDto? in
            guard let text = entry["text"] as? String else { return nil }
            return LyricsLineDto(
                words: text,
                startTimeMs: nil,
                syllables: nil
            )
        }
        
        let romanization: LyricsRomanizationStatus = lines.map(\.words).canBeRomanized
            ? .canBeRomanized : .original
        
        return LyricsDto(
            lines: lines,
            timeSynced: false,
            isSyllableSynced: false,
            romanization: romanization,
            translation: nil
        )
    }
    
    // MARK: - 空歌词
    
    private func emptyDto() -> LyricsDto {
        LyricsDto(
            lines: [],
            timeSynced: false,
            isSyllableSynced: false,
            romanization: .original,
            translation: nil
        )
    }
}
