import UIKit
import AVFoundation
import Vision
import VideoToolbox
import CoreLocation

enum Mode {
    case left, right
}

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @IBOutlet weak var tickImgView: UIImageView!
    @IBOutlet weak var addressLbl: UILabel!
    @IBOutlet weak var customView: UIView!
    @IBOutlet weak var mapOuterView: UIView!
    @IBOutlet weak var switchBtn: UIButton!
    @IBOutlet weak var trackSleepLabel: UILabel!
    
    private var cameraInput: AVCaptureInput?
    private var eyesClosed = false
    private var timer: Timer = Timer()
    private var isUserMoving = true
    private var navigationTimer = Timer()
    var localAudioPlayer:AVAudioPlayer?
    private var isFaceCorrectlyAligned = false
    private let captureSession = AVCaptureSession()
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var drawings: [CAShapeLayer] = []
    lazy var locationManager: CLLocationManager = {
        var _locationManager = CLLocationManager()
        _locationManager.delegate = self
        _locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        _locationManager.activityType = . automotiveNavigation
        _locationManager.distanceFilter = 10.0  // Movement threshold for new events
        //  _locationManager.allowsBackgroundLocationUpdates = true // allow in background
        
        return _locationManager
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.switchBtn.layer.cornerRadius = 10
        self.switchBtn.clipsToBounds = true
        addressLbl.text = ""
        self.view.bringSubviewToFront(self.trackSleepLabel)
        self.trackSleepLabel.isHidden = true
        self.view.bringSubviewToFront(addressLbl)
        self.isFaceDetectionAllowed()
        UIApplication.shared.isIdleTimerDisabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(batteryLevelDidChange), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        tickImgView.isHidden = true
        let mapView = MapView.shared.getMapFor(view: self.view)
        MapView.shared.delegate = self
        self.mapOuterView.addSubview(mapView)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(true)
        locationManager.requestAlwaysAuthorization()
        if CLLocationManager.authorizationStatus() != .authorizedWhenInUse {
            locationManager.requestWhenInUseAuthorization()
        }else{
            locationManager.startUpdatingLocation()
        }
        if let battery = (UIApplication.shared.delegate as? AppDelegate)?.batteryLevel {
            let batteryLevel = Int(battery * 100)
            if batteryLevel < 30 {
                let alertVC = UIAlertController(title: "Battery Status", message: "The battery of the phone is low. Please charge it.", preferredStyle: .alert)
                alertVC.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                self.present(alertVC, animated: true, completion: nil)
            }
        }
        self.view.bringSubviewToFront(customView)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(true)
        self.localAudioPlayer?.stop()
        self.localAudioPlayer = nil
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection) {
            
            guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            let ciimg = CIImage(cvPixelBuffer: frame)
            DispatchQueue.main.async { [weak self] in
                if let weakSelf = self {
                    if weakSelf.isUserMoving && weakSelf.switchBtn.title(for: .normal)?.lowercased() == "on" {
                        weakSelf.detect(ciimage: ciimg)
                        weakSelf.detectFace(in: frame)
                    } else {
                        weakSelf.clearDrawings()
                    }
                }
            }
        }
    
    private func addCameraInput() {
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front).devices.first else {
                fatalError("No back camera device found, please make sure to run SimpleLaneDetection in an iOS device and not a simulator")
        }
        cameraInput = try! AVCaptureDeviceInput(device: device)
        if let input = cameraInput {
            self.captureSession.addInput(input)
        }
    }
    
    private func showCameraFeed() {
        self.previewLayer.videoGravity = .resizeAspectFill
        self.customView.layer.addSublayer(self.previewLayer)
        self.previewLayer.frame = self.customView.bounds
    }
    
    private func getCameraFrames() {
        self.videoDataOutput.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as NSString) : NSNumber(value: kCVPixelFormatType_32BGRA)] as [String : Any]
        self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
        self.videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera_frame_processing_queue"))
        self.captureSession.addOutput(self.videoDataOutput)
        guard let connection = self.videoDataOutput.connection(with: AVMediaType.video),
            connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = .portrait
    }
    
    private func detectFace(in image: CVPixelBuffer) {
        let faceDetectionRequest = VNDetectFaceLandmarksRequest(completionHandler: { (request: VNRequest, error: Error?) in
            DispatchQueue.main.async {
                if let results = request.results as? [VNFaceObservation] {
                    if results.isEmpty && !(self.localAudioPlayer?.isPlaying ?? false) {
                        self.trackSleepLabel.isHidden = true
                        self.customView.isHidden = false
                        let path = Bundle.main.path(forResource: "faceAlign.m4a", ofType:nil)!
                        let url = URL(fileURLWithPath: path)
                        do {
                            self.localAudioPlayer = try AVAudioPlayer(contentsOf: url)
                            self.localAudioPlayer?.delegate = self
                            self.localAudioPlayer?.play()
                            self.eyesClosed = false
                            self.navigationController?.navigationBar.bringSubviewToFront(self.switchBtn)
                        } catch {}
                    }
                    self.handleFaceDetectionResults(results)
                } else {
                    self.clearDrawings()
                    self.timer.invalidate()
                    self.eyesClosed = false
                    if !(self.localAudioPlayer?.isPlaying ?? false) {
                        self.trackSleepLabel.isHidden = true
                        self.customView.isHidden = false
                        let path = Bundle.main.path(forResource: "faceAlign.m4a", ofType:nil)!
                        let url = URL(fileURLWithPath: path)
                        do {
                            self.localAudioPlayer = try AVAudioPlayer(contentsOf: url)
                            self.localAudioPlayer?.delegate = self
                            self.localAudioPlayer?.play()
                            self.eyesClosed = false
                            self.navigationController?.navigationBar.bringSubviewToFront(self.switchBtn)
                        } catch {}
                    }
                }
            }
        })
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .leftMirrored, options: [:])
        try? imageRequestHandler.perform([faceDetectionRequest])
    }
    
    private func handleFaceDetectionResults(_ observedFaces: [VNFaceObservation]) {
        
        self.clearDrawings()
        let facesBoundingBoxes: [CAShapeLayer] = observedFaces.flatMap({ (observedFace: VNFaceObservation) -> [CAShapeLayer] in
            let faceBoundingBoxOnScreen = self.previewLayer.layerRectConverted(fromMetadataOutputRect: observedFace.boundingBox)
            let faceBoundingBoxPath = CGPath(rect: faceBoundingBoxOnScreen, transform: nil)
            let faceBoundingBoxShape = CAShapeLayer()
            faceBoundingBoxShape.path = faceBoundingBoxPath
            faceBoundingBoxShape.fillColor = UIColor.clear.cgColor
            faceBoundingBoxShape.strokeColor = UIColor.clear.cgColor
            var newDrawings = [CAShapeLayer]()
            newDrawings.append(faceBoundingBoxShape)
            if let landmarks = observedFace.landmarks {
                
                newDrawings = newDrawings + self.drawFaceFeatures(landmarks, screenBoundingBox: faceBoundingBoxOnScreen)
            }
            return newDrawings
        })
        facesBoundingBoxes.forEach({ faceBoundingBox in self.view.layer.addSublayer(faceBoundingBox) })
        self.drawings = facesBoundingBoxes
    }
    
    private func clearDrawings() {
        self.drawings.forEach({ drawing in drawing.removeFromSuperlayer() })
    }
    
    private func drawFaceFeatures(_ landmarks: VNFaceLandmarks2D, screenBoundingBox: CGRect) -> [CAShapeLayer] {
        var faceFeaturesDrawings: [CAShapeLayer] = []
        if let leftEye = landmarks.leftEye {
            let eyeDrawing = self.drawEye(leftEye, screenBoundingBox: screenBoundingBox, mode: .left)
            faceFeaturesDrawings.append(eyeDrawing)
        }
        if let rightEye = landmarks.rightEye {
            let eyeDrawing = self.drawEye(rightEye, screenBoundingBox: screenBoundingBox, mode: .right)
            faceFeaturesDrawings.append(eyeDrawing)
        }
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            self.eyeStatus(leftEye: leftEye, rightEye: rightEye, screenBoundingBox: screenBoundingBox)
        }
        // draw other face features here
        return faceFeaturesDrawings
    }
    
    private func drawEye(_ eye: VNFaceLandmarkRegion2D, screenBoundingBox: CGRect, mode: Mode) -> CAShapeLayer {
        let eyePath = CGMutablePath()
        let eyePathPoints = eye.normalizedPoints
            .map({ eyePoint in
                CGPoint(
                    x: eyePoint.y * screenBoundingBox.height + screenBoundingBox.origin.x,
                    y: eyePoint.x * screenBoundingBox.width + screenBoundingBox.origin.y)
            })
        eyePath.addLines(between: eyePathPoints)
        eyePath.closeSubpath()

        let eyeDrawing = CAShapeLayer()
        eyeDrawing.path = eyePath
        eyeDrawing.fillColor = UIColor.clear.cgColor
        eyeDrawing.strokeColor = UIColor.clear.cgColor
        
        return eyeDrawing
    }

    private func eyeStatus(leftEye: VNFaceLandmarkRegion2D, rightEye: VNFaceLandmarkRegion2D, screenBoundingBox: CGRect) {
        let leftEyePathPoints = leftEye.normalizedPoints
            .map({ eyePoint in
                CGPoint(
                    x: eyePoint.y * screenBoundingBox.height + screenBoundingBox.origin.x,
                    y: eyePoint.x * screenBoundingBox.width + screenBoundingBox.origin.y)
            })
        let rightEyePathPoints = rightEye.normalizedPoints
            .map({ eyePoint in
                CGPoint(
                    x: eyePoint.y * screenBoundingBox.height + screenBoundingBox.origin.x,
                    y: eyePoint.x * screenBoundingBox.width + screenBoundingBox.origin.y)
            })
        
        if leftEyePathPoints.indices.contains(0) && leftEyePathPoints.indices.contains(1) && leftEyePathPoints.indices.contains(5) && rightEyePathPoints.indices.contains(0) && rightEyePathPoints.indices.contains(1) && rightEyePathPoints.indices.contains(5) {
            if leftEyePathPoints[1].distanceToPoint(otherPoint: leftEyePathPoints[5]) < 7 && rightEyePathPoints[1].distanceToPoint(otherPoint: rightEyePathPoints[5]) < 7 {
                self.eyesClosed = true
                if !(self.timer.isValid) {
                    timer.invalidate()
                    timer = Timer.scheduledTimer(timeInterval: 4, target: self, selector: #selector(checkEyesStateAndAlarm), userInfo: nil, repeats: true)

                }
            } else {
                timer.invalidate()
                self.eyesClosed = false
                if localAudioPlayer?.url?.absoluteString.contains("wakeUp.mp3") ?? false {
                    localAudioPlayer?.stop()
                }
            }
        }
    }
    
    func isFaceDetectionAllowed() {
        if self.switchBtn.title(for: .normal)?.lowercased() == "on" {
            self.addCameraInput()
            self.showCameraFeed()
            self.getCameraFrames()
            self.captureSession.startRunning()
            self.customView.isHidden = false
            self.view.bringSubviewToFront(self.switchBtn)
        } else {
            if let input = cameraInput {
                self.captureSession.removeInput(input)
            }
            self.captureSession.removeOutput(self.videoDataOutput)
            self.previewLayer.removeFromSuperlayer()
            self.captureSession.stopRunning()
            self.customView.isHidden = true
        }
    }
    
    @IBAction func tapOnAllow(_ sender: Any) {
        self.switchBtn.setTitle(self.switchBtn.titleLabel?.text?.lowercased() == "on" ? "OFF" : "ON", for: .normal)
        self.isFaceDetectionAllowed()
    }
    
    @objc func checkEyesStateAndAlarm() {
        if self.eyesClosed && !(self.localAudioPlayer?.isPlaying ?? false) {
            self.trackSleepLabel.isHidden = false
            self.customView.isHidden = true
            let path = Bundle.main.path(forResource: "wakeUp.mp3", ofType:nil)!
            let url = URL(fileURLWithPath: path)
            do {
                self.localAudioPlayer = try AVAudioPlayer(contentsOf: url)
                localAudioPlayer?.delegate = self
                self.localAudioPlayer?.play()
            } catch {}
        }
    }
    
    @objc func userNavigationStop() {
        self.isUserMoving = false
    }
    
    func detect(ciimage:CIImage) {
        let imageOptions =  NSDictionary(object: NSNumber(value: 5) as NSNumber, forKey: CIDetectorImageOrientation as NSString)
        let personciImage = ciimage
        let accuracy = [CIDetectorAccuracy: CIDetectorAccuracyHigh, CIDetectorEyeBlink: true] as [String : Any]
        let faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: accuracy)
        let faces = faceDetector?.features(in: ciimage, options: [CIDetectorEyeBlink : true, CIDetectorImageOrientation: 5])
        
        //success
        if let face = faces?.first as? CIFaceFeature {
            print(face.leftEyePosition)
            print(face.rightEyePosition)
            if 81...99 ~= -face.faceAngle {
                if !isFaceCorrectlyAligned {
                    if !(self.localAudioPlayer?.isPlaying ?? false) {
                        let path = Bundle.main.path(forResource: "CorrectAngle.m4a", ofType:nil)!
                        let url = URL(fileURLWithPath: path)
                        do {
                            self.localAudioPlayer = try AVAudioPlayer(contentsOf: url)
                            localAudioPlayer?.delegate = self
                            self.localAudioPlayer?.play()
                            DispatchQueue.main.async {
                                self.trackSleepLabel.isHidden = false
                                self.customView.isHidden = true
                                self.tickImgView.isHidden = false
                                self.view.bringSubviewToFront(self.tickImgView)
                                self.trackSleepLabel.isHidden = false
                                self.customView.isHidden = true
                            }
                        } catch {}
                        self.isFaceCorrectlyAligned = true
                    }
                }
            } else {
                isFaceCorrectlyAligned = false
                self.eyesClosed = false
                self.timer.invalidate()
                if !(self.localAudioPlayer?.isPlaying ?? false) {
                    self.trackSleepLabel.isHidden = true
                    self.customView.isHidden = false
                    let path = Bundle.main.path(forResource: "lineUp.m4a", ofType:nil)!
                    let url = URL(fileURLWithPath: path)
                    do {
                        self.localAudioPlayer = try AVAudioPlayer(contentsOf: url)
                        localAudioPlayer?.delegate = self
                        self.localAudioPlayer?.play()
                    } catch {}
                }
            }
        }
    }
    
    @objc func batteryLevelDidChange(_ notification: Notification) {
        if let battery = (UIApplication.shared.delegate as? AppDelegate)?.batteryLevel {
            let batteryLevel = Int(battery * 100)
            if batteryLevel < 30 {
                let alertVC = UIAlertController(title: "Battery Status", message: "The battery of the phone is low. Please charge it.", preferredStyle: .alert)
                alertVC.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                self.present(alertVC, animated: true, completion: nil)
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.batteryLevelDidChangeNotification, object: nil)
    }
}

extension ViewController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player.url?.absoluteString.contains("CorrectAngle.m4a") ?? false {
            self.tickImgView.isHidden = true
            self.trackSleepLabel.isHidden = false
            self.customView.isHidden = true
        }
    }
}

extension ViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
//        if let speed = locations.first?.speed, speed > 0 {
//            self.isUserMoving = true
//            navigationTimer.invalidate()
//            navigationTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(userNavigationStop), userInfo: nil, repeats: false)
//        }
        if let coordinate = locations.first?.coordinate {
            MapView.shared.setCamera(coordinate: coordinate)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse:
            manager.startUpdatingLocation()
            break
        case .authorizedAlways:
            manager.startUpdatingLocation()
            break
        case .denied:
            //handle denied
            break
        case .notDetermined:
             manager.requestWhenInUseAuthorization()
           break
        default:
            break
        }
    }
}

extension ViewController: MapViewCallback {
    func setAdderss(adr: String) {
        self.addressLbl.text = adr
        self.view.bringSubviewToFront(self.addressLbl)
        UIView.animate(withDuration: 0.25) {
            self.view.layoutIfNeeded()
        }
    }
}
