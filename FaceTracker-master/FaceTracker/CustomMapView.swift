import Foundation
import CoreLocation
import SwiftyJSON

class CustomMapView {
    
    init() {
    }
    
    func getLocationFromAddress(address : String, completion: @escaping((CLLocationCoordinate2D?)-> Void)) {
        let geoCoder = CLGeocoder()
        geoCoder.geocodeAddressString(address) { (placemarks, error) in
            guard
                let placemarks = placemarks,
                let location = placemarks.first?.location
            else {
                completion(nil)
                return
            }
            completion(location.coordinate)
        }
    }
}
