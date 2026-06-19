import Foundation

func fetch() async {
    let track = "ไกลแค่ไหน คือ ใกล้"
    let artist = "getsunova"
    let album = ""

    let tEnc = track.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let aEnc = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let alEnc = album.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let urlStr = "https://lrclib.net/api/get?track_name=\(tEnc)&artist_name=\(aEnc)&album_name=\(alEnc)"
    
    print("URL:", urlStr)
    
    guard let url = URL(string: urlStr) else { return }
    var req = URLRequest(url: url)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        print("Status:", (response as? HTTPURLResponse)?.statusCode ?? 0)
        print("Data:", String(data: data, encoding: .utf8) ?? "")
    } catch {
        print("Error:", error)
    }
}

Task {
    await fetch()
    exit(0)
}
RunLoop.main.run()
