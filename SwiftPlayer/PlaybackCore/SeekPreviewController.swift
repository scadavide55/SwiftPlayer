import AVFoundation
import CoreGraphics
import Combine
import Foundation

@MainActor
struct ThumbnailCache {
    struct Entry { let image: CGImage; let time: Double; let bytes: Int }
    let byteLimit: Int
    let countLimit: Int
    private(set) var bytes = 0
    private(set) var entries: [Int: Entry] = [:]
    private var order: [Int] = []
    init(byteLimit: Int = 8 * 1024 * 1024, countLimit: Int = 32) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }
    mutating func entry(for key: Int) -> Entry? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry
    }
    mutating func insert(_ image: CGImage, time: Double, for key: Int) {
        let cost = image.bytesPerRow * image.height
        guard cost <= byteLimit, countLimit > 0 else { return }
        if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
        order.removeAll { $0 == key }
        entries[key] = Entry(image: image, time: time, bytes: cost)
        order.append(key)
        bytes += cost
        while bytes > byteLimit || entries.count > countLimit {
            let oldest = order.removeFirst()
            if let old = entries.removeValue(forKey: oldest) { bytes -= old.bytes }
        }
    }
    mutating func reset() { entries = [:]; order = []; bytes = 0 }
}

/// Throttled requests share one generator and a bounded, memory-only image cache.
/// Asset/request identifiers prevent late callbacks from changing a newer preview.
@MainActor
final class SeekPreviewController: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var imageTime: Double?
    @Published private(set) var isLoading = false
    private(set) var cache = ThumbnailCache()
    private var asset: AVAsset?
    private var generator: AVAssetImageGenerator?
    private var generation = UUID()
    private var requestIdentifier = UUID()
    private var desiredBucket: Int?
    private var pending: (bucket: Int, time: Double)?
    private var inFlightBucket: Int?
    private var throttle: Task<Void, Never>?

    deinit { throttle?.cancel(); generator?.cancelAllCGImageGeneration() }

    func attach(_ asset: AVAsset?) {
        if self.asset === asset { return }
        detach()
        self.asset = asset
        guard let asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        self.generator = generator
    }

    func request(time: Double, duration: Double) {
        guard generator != nil, time.isFinite, duration.isFinite, duration > 0 else { return }
        let time = min(max(time, 0), max(0, duration - 0.001))
        guard time < 1_000_000_000 else { return }
        let bucket = Int(time / 2)
        desiredBucket = bucket
        if let entry = cache.entry(for: bucket) {
            cancelPending()
            desiredBucket = bucket
            image = entry.image
            imageTime = entry.time
            return
        }
        if inFlightBucket == bucket { return }
        pending = (bucket, time)
        isLoading = true
        guard throttle == nil else { return }
        throttle = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self, let request = self.pending else { return }
            self.throttle = nil
            self.pending = nil
            self.generate(request)
        }
    }

    private func generate(_ request: (bucket: Int, time: Double)) {
        guard let generator else { return }
        generator.cancelAllCGImageGeneration()
        requestIdentifier = UUID()
        let identifier = requestIdentifier
        let assetGeneration = generation
        inFlightBucket = request.bucket
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: request.time, preferredTimescale: 600))]) {
            [weak self] _, image, actualTime, result, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == assetGeneration else { return }
                if result == .succeeded, let image, image.width <= 320, image.height <= 180, actualTime.seconds.isFinite {
                    self.cache.insert(image, time: actualTime.seconds, for: request.bucket)
                    if self.desiredBucket == request.bucket {
                        self.image = image
                        self.imageTime = actualTime.seconds
                    }
                }
                if self.requestIdentifier == identifier {
                    self.inFlightBucket = nil
                    if self.pending == nil { self.isLoading = false }
                }
            }
        }
    }

    private func cancelPending() {
        throttle?.cancel()
        throttle = nil
        pending = nil
        inFlightBucket = nil
        requestIdentifier = UUID()
        generator?.cancelAllCGImageGeneration()
        isLoading = false
    }
    func hide() {
        desiredBucket = nil
        cancelPending()
        image = nil
        imageTime = nil
    }
    func detach() {
        generation = UUID()
        hide()
        generator = nil
        asset = nil
        cache.reset()
    }
}
