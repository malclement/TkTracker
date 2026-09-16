import simd

/// Fits the actual workshop and its team into the viewport, including room for
/// labels and controls. Independent of animation so the camera doesn't bob.
struct WorkshopCameraFrame {
    var target: SIMD3<Float>
    var position: SIMD3<Float>

    static func fit(minimum: SIMD3<Float>, maximum: SIMD3<Float>, aspect: Float,
                    fieldOfView: Float, azimuth: Float, elevation: Float, zoom: Float = 1) -> Self {
        let center = (minimum + maximum) / 2
        let direction = SIMD3<Float>(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let up = simd_cross(direction, right)
        let vertical = tan(fieldOfView * .pi / 360) * 0.80
        let horizontal = vertical * max(0.1, aspect)
        var distance: Float = 1
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    let corner = SIMD3<Float>(x, y, z) - center
                    let depth = simd_dot(corner, direction)
                    distance = max(distance, abs(simd_dot(corner, right)) / horizontal + depth,
                                   abs(simd_dot(corner, up)) / vertical + depth)
                }
            }
        }
        return Self(target: center, position: center + direction * distance / max(0.1, zoom))
    }
}
