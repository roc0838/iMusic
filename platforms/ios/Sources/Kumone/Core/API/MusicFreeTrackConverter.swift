#if os(iOS)
import Foundation

/// Converts a MusicFree `IMusicItem` search result into iMusic's `Track`.
///
/// MusicFree IDs are frequently opaque strings (`bvid`, hashes, paths), while
/// `Track.id` is an Int used only for in-process identity. The original item is
/// preserved verbatim in `sourceMetadata["mf.itemJSON"]`; playback and lyrics
/// hand it back to the plugin, so no field is lost in the round trip.
enum MusicFreeTrackConverter {
    static func track(from item: [String: Any], platform: String, sourceID: String) -> Track? {
        let title = text(item, keys: ["title", "name", "songName"])
        guard !title.isEmpty else { return nil }

        let rawID = text(item, keys: ["id", "songmid", "songId", "hash", "mid"])
        let identifier = rawID.isEmpty ? title + "|" + artistText(item) : rawID
        let stableID = stableNumericID(identifier)

        let artist = artistText(item)
        let album = text(item, keys: ["album", "albumName"])
        let artwork = text(item, keys: ["artwork", "picUrl", "cover", "img", "avatar"])

        let durationMS: Int
        if let number = number(item, keys: ["duration", "dt", "interval"]) {
            durationMS = number > 10_000 ? Int(number) : Int(number * 1000)
        } else {
            durationMS = 0
        }

        var metadata: [String: String] = [
            "mf.itemJSON": jsonString(item) ?? "{}",
            "mf.platform": platform,
            "mf.sourceID": sourceID,
            "songmid": identifier,
            "songId": identifier,
            "source": platform
        ]
        if !artwork.isEmpty { metadata["artwork"] = artwork }

        let track = Track(
            id: stableID,
            name: title,
            artists: artist.isEmpty ? [] : [ArtistRef(id: 0, name: artist, picUrl: artwork.isEmpty ? nil : artwork)],
            album: AlbumRef(id: 0, name: album, picUrl: artwork.isEmpty ? nil : artwork),
            durationMS: durationMS,
            source: platform,
            sourceMetadata: metadata
        )
        return track.normalizedForLXPlayback()
    }

    private static func artistText(_ item: [String: Any]) -> String {
        if let array = item["artist"] as? [[String: Any]] {
            let names = array.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty { return names.joined(separator: " / ") }
        }
        if let list = item["artists"] as? [String] {
            let names = list.filter { !$0.isEmpty }
            if !names.isEmpty { return names.joined(separator: " / ") }
        }
        return text(item, keys: ["artist", "artists", "author", "singer"])
    }

    private static func text(_ item: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = item[key] as? String, !value.isEmpty { return value }
            if let value = item[key] as? NSNumber {
                let double = value.doubleValue
                return double.rounded() == double ? String(Int(double)) : String(double)
            }
        }
        return ""
    }

    private static func number(_ item: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = item[key] as? NSNumber { return value.doubleValue }
            if let value = item[key] as? String, let double = Double(value) { return double }
        }
        return nil
    }

    private static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// FNV-1a over the provider ID. Deterministic across launches so queue
    /// identity stays stable; only the lower 60 bits are used to avoid sign
    /// overflow on 32-bit hosts.
    private static func stableNumericID(_ value: String) -> Int {
        var hash: UInt64 = 1_466_959_818_833_629_442
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash & 0x0f_ff_ff_ff_ff_ff_ff_ff)
    }
}
#endif
