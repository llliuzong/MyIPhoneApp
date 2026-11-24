import CoreLocation
import Foundation

enum GCJ02 {
    // Offline approximation for comparing mainland China GPS fixes with Amap points.
    // Keep the original GPS coordinates in the stored track.
    static func fromGPS(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let latitude = point.latitude
        let longitude = point.longitude
        guard (0.8293...55.8271).contains(latitude), (72.004...137.8347).contains(longitude) else {
            return point
        }

        let x = longitude - 105
        let y = latitude - 35
        let waves = (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        let latitudeBase: Double = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
        let latitudeWaves = 20 * sin(y * .pi) + 40 * sin(y * .pi / 3)
        let latitudeLongWaves = 160 * sin(y * .pi / 12) + 320 * sin(y * .pi / 30)
        let latitudeOffset = latitudeBase + waves + (latitudeWaves + latitudeLongWaves) * 2 / 3

        let longitudeBase: Double = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
        let longitudeWaves = 20 * sin(x * .pi) + 40 * sin(x * .pi / 3)
        let longitudeLongWaves = 150 * sin(x * .pi / 12) + 300 * sin(x * .pi / 30)
        let longitudeOffset = longitudeBase + waves + (longitudeWaves + longitudeLongWaves) * 2 / 3

        let earthRadius = 6_378_245.0
        let eccentricitySquared = 0.006693421622965943
        let radians = latitude * .pi / 180
        let sine = sin(radians)
        let magic = 1 - eccentricitySquared * sine * sine
        let root = sqrt(magic)
        let meridianRadius = earthRadius * (1 - eccentricitySquared) / (magic * root)
        let parallelRadius = earthRadius * cos(radians) / root
        return CLLocationCoordinate2D(
            latitude: latitude + latitudeOffset / meridianRadius * 180 / .pi,
            longitude: longitude + longitudeOffset / parallelRadius * 180 / .pi
        )
    }
}
