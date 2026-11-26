// ilvtg — location emulation in the location picker.
// Copied into submodules/LocationUI/Sources/ by ci/prepare.py.

import Foundation
import CoreLocation
import SwiftSignalKit
import TelegramCore

/// The map's user location, replaced by the emulated point while emulation is on. Re-emits when
/// emulation is switched, so the picker's rows update.
func ilvEmulatedUserLocation(_ userLocation: Signal<CLLocation?, NoError>) -> Signal<CLLocation?, NoError> {
    return combineLatest(userLocation, IlvLocationEmulation.updates)
    |> map { location, _ -> CLLocation? in
        if let coordinate = IlvLocationEmulation.coordinate {
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: coordinate.0, longitude: coordinate.1), altitude: 0.0, horizontalAccuracy: 10.0, verticalAccuracy: -1.0, timestamp: Date())
        }
        return location
    }
}

func ilvLocationEmulationTitle() -> String {
    let ru = (Locale.preferredLanguages.first ?? "").hasPrefix("ru")
    if IlvLocationEmulation.isEnabled {
        return ru ? "Выключить эмуляцию геопозиции" : "Turn off location emulation"
    }
    return ru ? "Эмулировать геопозицию здесь" : "Emulate location here"
}

func ilvLocationEmulationSubtitle() -> String {
    let ru = (Locale.preferredLanguages.first ?? "").hasPrefix("ru")
    if let coordinate = IlvLocationEmulation.coordinate {
        return (ru ? "Сейчас: " : "Now: ") + String(format: "%.5f, %.5f", coordinate.0, coordinate.1)
    }
    return ru ? "Ваша геопозиция будет в центре карты" : "Your location becomes the center of the map"
}

/// Switches emulation: off if it is on, otherwise on at `coordinate` (the map center).
func ilvToggleLocationEmulation(coordinate: CLLocationCoordinate2D?) {
    if IlvLocationEmulation.isEnabled {
        IlvLocationEmulation.disable()
    } else if let coordinate = coordinate, CLLocationCoordinate2DIsValid(coordinate) {
        IlvLocationEmulation.enable(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
