import Flutter
import AVFoundation

/// Registers a method channel for native square video cropping.
/// Uses AVFoundation to center-crop video to 1:1 aspect ratio.
class VideoCropPlugin {
    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.rendergames.rlink/video_crop",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "cropToSquare":
                guard let args = call.arguments as? [String: Any],
                      let input = args["input"] as? String,
                      let output = args["output"] as? String else {
                    result(FlutterError(code: "ARGS", message: "Missing input/output", details: nil))
                    return
                }
                cropToSquare(inputPath: input, outputPath: output) { success in
                    DispatchQueue.main.async {
                        result(success)
                    }
                }
            case "mergeVideos":
                guard let args = call.arguments as? [String: Any],
                      let inputs = args["inputs"] as? [String],
                      let output = args["output"] as? String,
                      inputs.count >= 2 else {
                    result(FlutterError(code: "ARGS", message: "mergeVideos: need inputs + output", details: nil))
                    return
                }
                mergeVideos(inputPaths: inputs, outputPath: output) { success in
                    DispatchQueue.main.async {
                        result(success)
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func cropToSquare(inputPath: String, outputPath: String, completion: @escaping (Bool) -> Void) {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)

        // Remove existing output file
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: inputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            NSLog("[VideoCrop] No video track found")
            completion(false)
            return
        }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform

        // Determine actual video dimensions after applying the track's transform.
        // Portrait videos have a 90-degree rotation, so width < height after transform.
        let txSize = naturalSize.applying(transform)
        let width = abs(txSize.width)
        let height = abs(txSize.height)
        let side = min(width, height)

        NSLog("[VideoCrop] Source: %.0fx%.0f, crop to %.0fx%.0f", width, height, side, side)

        // Build composition
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { completion(false); return }

        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        do {
            try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        } catch {
            NSLog("[VideoCrop] Insert video error: %@", error.localizedDescription)
            completion(false)
            return
        }

        // Add audio track if present
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        // Video composition with crop
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = CGSize(width: side, height: side)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)

        // Build a transform that:
        // 1. Applies the original track transform (handles rotation)
        // 2. Translates to center-crop to square
        let offsetX = -(width - side) / 2.0
        let offsetY = -(height - side) / 2.0
        let cropTranslation = CGAffineTransform(translationX: offsetX, y: offsetY)
        let finalTransform = transform.concatenating(cropTranslation)
        layerInstruction.setTransform(finalTransform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Export
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetMediumQuality
        ) else {
            NSLog("[VideoCrop] Could not create export session")
            completion(false)
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                NSLog("[VideoCrop] Export completed")
                completion(true)
            default:
                NSLog("[VideoCrop] Export failed: %@",
                      exportSession.error?.localizedDescription ?? "unknown")
                completion(false)
            }
        }
    }

    /// Последовательная склейка клипов (смена фронт/тыл во время записи).
    private static func mergeVideos(inputPaths: [String], outputPath: String, completion: @escaping (Bool) -> Void) {
        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(false)
            return
        }
        let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        for path in inputPaths {
            let url = URL(fileURLWithPath: path)
            let asset = AVAsset(url: url)
            let dur = asset.duration
            if dur == .invalid || dur.seconds <= 0 {
                NSLog("[VideoMerge] Skip empty asset: %@", path)
                continue
            }
            if let v = asset.tracks(withMediaType: .video).first {
                do {
                    try compVideo.insertTimeRange(
                        CMTimeRange(start: .zero, duration: dur),
                        of: v,
                        at: cursor
                    )
                } catch {
                    NSLog("[VideoMerge] insert video failed: %@", error.localizedDescription)
                    completion(false)
                    return
                }
            }
            if let a = asset.tracks(withMediaType: .audio).first, let audioTrack = compAudio {
                do {
                    try audioTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: dur),
                        of: a,
                        at: cursor
                    )
                } catch {
                    NSLog("[VideoMerge] insert audio failed: %@", error.localizedDescription)
                }
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        if cursor == .zero {
            completion(false)
            return
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetMediumQuality
        ) else {
            completion(false)
            return
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                NSLog("[VideoMerge] Export OK → %@", outputPath)
                completion(true)
            default:
                NSLog("[VideoMerge] Export failed: %@",
                      exportSession.error?.localizedDescription ?? "unknown")
                completion(false)
            }
        }
    }
}
