import AppKit
import ImageIO

class ScreenCaptureManager {
    /// Capture the frontmost window of a specific application by PID.
    /// Falls back to full-screen capture if the window cannot be found.
    static func captureAppWindow(pid: pid_t) -> URL? {
        // Find the frontmost on-screen window belonging to this PID
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else {
            log("ScreenCaptureManager: Could not get window list, falling back to full screen")
            return captureScreen()
        }

        // Find the first regular window for this PID (skip menu bar, status items, etc.)
        let targetWindow = windowList.first { info in
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0  // Normal window layer
            else { return false }
            return true
        }

        guard let windowInfo = targetWindow,
              let windowID = windowInfo[kCGWindowNumber] as? CGWindowID else {
            log("ScreenCaptureManager: No window found for PID \(pid), falling back to full screen")
            return captureScreen()
        }

        let ownerName = windowInfo[kCGWindowOwnerName as CFString] as? String ?? "unknown"

        // Capture just this window (including its shadow for context)
        guard let image = CGWindowListCreateImage(
            .null,  // Use the window's own bounds
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            log("ScreenCaptureManager: Could not capture window for PID \(pid), falling back to full screen")
            return captureScreen()
        }

        log("ScreenCaptureManager: Captured window of '\(ownerName)' (PID \(pid), \(image.width)×\(image.height))")
        return saveImage(image)
    }

    /// Capture the entire main display.
    static func captureScreen() -> URL? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            log("ScreenCaptureManager: Could not capture screen")
            return nil
        }

        log("ScreenCaptureManager: Captured full screen (\(image.width)×\(image.height))")
        return saveImage(image)
    }

    /// Maximum raw JPEG size in bytes (~3.5 MB keeps base64 under the 5 MB API limit).
    private static let maxJPEGBytes = 3_500_000

    /// Downscale a CGImage so its longest edge is at most `maxEdge` pixels.
    private static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let w = image.width
        let h = image.height
        guard max(w, h) > maxEdge else { return image }
        let scale = CGFloat(maxEdge) / CGFloat(max(w, h))
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    /// Save a CGImage as JPEG and return the file URL.
    /// Downscales large images and adjusts quality to stay under the API size limit.
    private static func saveImage(_ image: CGImage) -> URL? {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log("ScreenCaptureManager: Could not find documents directory")
            return nil
        }
        let screenshotsDirectory = documentsDirectory
            .appendingPathComponent("Fazm")
            .appendingPathComponent("Screenshots")

        do {
            try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            log("ScreenCaptureManager: Error creating directory: \(error)")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileName = "screenshot-\(timestamp).jpg"
        let fileURL = screenshotsDirectory.appendingPathComponent(fileName)

        // Downscale Retina captures to max 1568px on the longest edge.
        // Claude API enforces a 2000px limit per image in multi-image conversations;
        // staying at 1568 leaves headroom for the API's stricter "many-image" path.
        let scaled = downscale(image, maxEdge: 1568)

        // Try JPEG at decreasing quality until under size limit
        for quality in stride(from: 0.7, through: 0.3, by: -0.1) {
            guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
                log("ScreenCaptureManager: Could not create image destination")
                return nil
            }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                log("ScreenCaptureManager: Could not save image")
                return nil
            }
            if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int,
               size <= maxJPEGBytes {
                log("ScreenCaptureManager: Screenshot saved to \(fileURL.path) (\(size / 1024)KB, quality=\(String(format: "%.1f", quality)))")
                return fileURL
            }
        }

        // Even at lowest quality it's too big — save anyway (bridge will handle gracefully)
        log("ScreenCaptureManager: Screenshot saved to \(fileURL.path) (may exceed size limit)")
        return fileURL
    }
}
