import Foundation

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 15
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private let session: URLSession

    private static let apiUrl        = "https://api.spicylyrics.org"
    private static let authHeaderKey = "SpicyLyrics-WebAuth"
    private static let clientVersion = "6.1.1"

    // MARK: - Token wait

    private func waitForToken(timeout: TimeInterval = 5.0) -> String? {
        if let token = spotifyAccessToken { return token }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let token = spotifyAccessToken { return token }
        }
        return nil
    }

    // MARK: - Network

    private func performQuery(trackId: String) throws -> Data {
        guard let url = URL(string: "\(SpicyLyricsRepository.apiUrl)/query") else {
            throw LyricsError.decodingError
        }

        let body: [String: Any] = [
            "queries": [
                [
                    "operation": "lyrics",
                    "variables": [
                        "id":   trackId,
                        "auth": SpicyLyricsRepository.authHeaderKey
                    ]
                ]
            ],
            "client": ["version": SpicyLyricsRepository.clientVersion]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SpicyLyricsRepository.clientVersion, forHTTPHeaderField: "SpicyLyrics-Version")
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.7680.179 Spotify/1.2.92.148 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("\"Windows\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("\"Not-A.Brand\";v=\"24\", \"Chromium\";v=\"146\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")

        if let token = waitForToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: SpicyLyricsRepository.authHeaderKey)
            writeDebugLog("[SpicyLyrics] Using captured token for \(trackId)")
        } else {
            writeDebugLog("[SpicyLyrics] No token available for \(trackId) — proceeding unauthenticated")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        session.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError {
            writeDebugLog("[SpicyLyrics] Network error for \(trackId): \(error)")
            throw error
        }
        guard let data = responseData else {
            writeDebugLog("[SpicyLyrics] No data for \(trackId)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[SpicyLyrics] Received \(data.count) bytes for track \(trackId)")
        return data
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard !trackId.isEmpty else {
            writeDebugLog("[SpicyLyrics] Empty track ID")
            throw LyricsError.noSuchSong
        }
        let data = try performQuery(trackId: trackId)
        let dto = try SpicyLyricsParser.parseLyrics(from: data)
    
    // ✅ 加日志
        print("[SpicyLyrics] ✅ 返回 LyricsDto，行数: \(dto.lines.count)，isSyllableSynced=\(dto.isSyllableSynced)")
    
        return dto
    }
}