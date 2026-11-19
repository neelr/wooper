import Foundation
import PencilKit

enum WebPenStyle {
    /// PencilKit's pen renderer drops paths with the old ~1.2-point footprint.
    /// Keep a visible nib even at light pressure or on devices with a large
    /// maximumPossibleForce; pressure can add weight without hiding the stroke.
    static func width(force: CGFloat, maximumForce: CGFloat) -> CGFloat {
        let pressure = maximumForce > 0 && force.isFinite && maximumForce.isFinite
            ? min(1, max(0, force / maximumForce)) : 0
        return 3 + pressure * 1.5
    }

    /// Recover already-saved thin pen strokes without moving them or changing
    /// highlights. The original file remains intact until the next normal save.
    static func recoveringLegacyInk(in drawing: PKDrawing) -> PKDrawing {
        var changed = false
        let strokes = drawing.strokes.map { stroke -> PKStroke in
            guard stroke.ink.inkType == .pen,
                  stroke.path.contains(where: { $0.size.width < 3 || $0.size.height < 3 }) else { return stroke }
            changed = true
            var result = stroke
            result.path = PKStrokePath(controlPoints: stroke.path.map { point in
                PKStrokePoint(location: point.location, timeOffset: point.timeOffset,
                              size: CGSize(width: max(3, point.size.width), height: max(3, point.size.height)),
                              opacity: point.opacity, force: point.force,
                              azimuth: point.azimuth, altitude: point.altitude)
            }, creationDate: stroke.path.creationDate)
            return result
        }
        return changed ? PKDrawing(strokes: strokes) : drawing
    }
}
