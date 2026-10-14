import Foundation
import ImageIO

/// Where a photo was taken, read from its EXIF GPS block.
///
/// An imported photo says where *it* was captured; the phone's current location (what live capture
/// uses) is wrong for an old photo or one sent by someone else. Without GPS, callers must use no
/// location at all rather than the phone's.
public enum ImageLocation {

    public static func coordinate(in data: Data) -> (latitude: Double, longitude: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              var longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        // EXIF stores magnitudes plus a hemisphere reference.
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { longitude = -longitude }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }   // (0,0) is the "no fix" placeholder
        return (latitude, longitude)
    }
}
