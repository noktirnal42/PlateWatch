import PlateKit

/// Public camera title/timestamp bands are scene metadata, never vehicle lettering.
/// Applied before plate hypotheses/markings are built. Center-frame vehicle text is unchanged.
/// Conservative default: OCR in the top 15% and bottom 10% of public-feed frames cannot supply evidence.
public enum CameraCaptionFilter {
    public static func isInCaptionBand(_ box: NormalizedBox) -> Bool {
        let center = box.y + box.height / 2
        return center < 0.15 || center > 0.90
    }
}
