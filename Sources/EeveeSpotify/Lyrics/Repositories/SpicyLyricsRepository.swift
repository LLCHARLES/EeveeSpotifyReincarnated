import Foundation

class SpicyLyricsRepository: LyricsRepository {
    
    static let shared = SpicyLyricsRepository()
    private init() {}
    
    private let session = URLSession.shared
    private let baseURL = "https://api.spicelyrics.com"  // 替换为实际 URL
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        // 构建请求
        guard let url = URL(string: "\(baseURL)/lyrics") else {
            throw LyricsError.invalidSource
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "trackId": query.spotifyTrackId ?? "",
            "title": query.title,
            "artist": query.primaryArtist
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
                // 使用 SpicyLyricsParser 解析
                let dto = try SpicyLyricsParser.parseLyrics(from: data)
                result = .success(dto)
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
}