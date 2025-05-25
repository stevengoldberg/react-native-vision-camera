//
//  PhotoCaptureDelegate.swift
//  mrousavy
//
//  Created by Marc Rousavy on 15.12.20.
//  Copyright © 2020 mrousavy. All rights reserved.
//

import AVFoundation
import CoreImage
import ImageIO

// MARK: - PhotoCaptureDelegate

class PhotoCaptureDelegate: GlobalReferenceHolder, AVCapturePhotoCaptureDelegate {
  private let promise: Promise
  private let enableShutterSound: Bool
  private let cameraSessionDelegate: CameraSessionDelegate?
  private let metadataProvider: MetadataProvider
  private let path: URL
  private let isProRaw: Bool
  private let enableHDRGainMap: Bool
  
  // Track multiple photo callbacks for RAW+processed capture
  private var rawPhotoPath: URL?
  private var processedPhotoPath: URL?
  private var expectedPhotoCount: Int = 1
  private var receivedPhotoCount: Int = 0

  required init(promise: Promise,
                enableShutterSound: Bool,
                metadataProvider: MetadataProvider,
                path: URL,
                isProRaw: Bool = false,
                enableHDRGainMap: Bool = false,
                cameraSessionDelegate: CameraSessionDelegate?) {
    self.promise = promise
    self.enableShutterSound = enableShutterSound
    self.metadataProvider = metadataProvider
    self.path = path
    self.cameraSessionDelegate = cameraSessionDelegate
    self.isProRaw = isProRaw
    self.enableHDRGainMap = enableHDRGainMap
    
    // Determine expected photo count based on capture settings
    // If ProRAW is enabled and dual capture was requested, expect 2 photos
    // This will be confirmed by the actual photo settings when capture starts
    super.init()
    makeGlobal()
  }

  func photoOutput(_: AVCapturePhotoOutput, willCapturePhotoFor _: AVCaptureResolvedPhotoSettings) {
    if !enableShutterSound {
      // disable system shutter sound (see https://stackoverflow.com/a/55235949/5281431)
      AudioServicesDisposeSystemSoundID(1108)
    }

    // onShutter(..) event
    cameraSessionDelegate?.onCaptureShutter(shutterType: .photo)
  }

  func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    if let error = error as NSError? {
      self.cleanup()
      promise.reject(error: .capture(.unknown(message: error.description)), cause: error)
      return
    }

    do {
      receivedPhotoCount += 1
      
      // Follow Apple's documentation: check photo.isRawPhoto to determine format
      if photo.isRawPhoto {
        // Handle RAW (DNG) photo
        guard let dngData = photo.fileDataRepresentation() else {
          self.cleanup()
          promise.reject(error: .capture(.imageDataAccessError))
          return
        }
        
        // For RAW photos, use .dng extension
        rawPhotoPath = generatePhotoPath(originalPath: path, isRaw: true)
        try dngData.write(to: rawPhotoPath!)
        
        VisionLogger.log(level: .info, message: "Saved RAW photo to: \(rawPhotoPath!.path)")
        
      } else {
        // Handle processed (JPEG/HEIF) photo
        processedPhotoPath = generatePhotoPath(originalPath: path, isRaw: false)
        
        try FileUtils.writePhotoToFile(photo: photo,
                                       metadataProvider: metadataProvider,
                                       file: processedPhotoPath!)
        
        VisionLogger.log(level: .info, message: "Saved processed photo to: \(processedPhotoPath!.path)")
        
        // Extract HDR gain map if enabled and available
        if enableHDRGainMap, #available(iOS 14.1, *) {
          extractHDRGainMap(from: photo, basePath: processedPhotoPath!)
        }
      }
      
      // Check if we've received all expected photos
      let isComplete = shouldCompleteCapture(photo: photo)
      
      if isComplete {
        // Return the primary photo path (RAW if available, otherwise processed)
        let primaryPath = rawPhotoPath ?? processedPhotoPath ?? path
        let isRawResult = rawPhotoPath != nil
        
        let exif = photo.metadata["{Exif}"] as? [String: Any]
        let width = exif?["PixelXDimension"]
        let height = exif?["PixelYDimension"]
        let exifOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
        let cgOrientation = CGImagePropertyOrientation(rawValue: exifOrientation) ?? CGImagePropertyOrientation.up
        let orientation = getOrientation(forExifOrientation: cgOrientation)
        let isMirrored = getIsMirrored(forExifOrientation: cgOrientation)

        var result: [String: Any] = [
          "path": primaryPath.absoluteString,
          "width": width as Any,
          "height": height as Any,
          "orientation": orientation,
          "isMirrored": isMirrored,
          "isRawPhoto": isRawResult,
          "metadata": photo.metadata,
          "thumbnail": photo.embeddedThumbnailPhotoFormat as Any,
        ]
        
        // If dual capture, include both paths
        if rawPhotoPath != nil && processedPhotoPath != nil {
          result["rawPath"] = rawPhotoPath!.absoluteString
          result["processedPath"] = processedPhotoPath!.absoluteString
        }
        
        self.cleanup()
        promise.resolve(result)
      }
      
    } catch let error as CameraError {
      self.cleanup()
      promise.reject(error: error)
    } catch {
      self.cleanup()
      promise.reject(error: .capture(.unknown(message: "An unknown error occured while capturing the photo!")), cause: error as NSError)
    }
  }

  func photoOutput(_: AVCapturePhotoOutput, didFinishCaptureFor _: AVCaptureResolvedPhotoSettings, error: Error?) {
    // This method is called after all photo processing is complete
    // We handle completion in didFinishProcessingPhoto, so only handle errors here
    if let error = error as NSError? {
      self.cleanup()
      if error.code == -11807 {
        promise.reject(error: .capture(.insufficientStorage), cause: error)
      } else {
        promise.reject(error: .capture(.unknown(message: error.description)), cause: error)
      }
    }
  }

  private func getOrientation(forExifOrientation exifOrientation: CGImagePropertyOrientation) -> String {
    switch exifOrientation {
    case .up, .upMirrored:
      return "portrait"
    case .down, .downMirrored:
      return "portrait-upside-down"
    case .left, .leftMirrored:
      return "landscape-left"
    case .right, .rightMirrored:
      return "landscape-right"
    default:
      return "portrait"
    }
  }

  private func getIsMirrored(forExifOrientation exifOrientation: CGImagePropertyOrientation) -> Bool {
    switch exifOrientation {
    case .upMirrored, .rightMirrored, .downMirrored, .leftMirrored:
      return true
    default:
      return false
    }
  }

  private func shouldCompleteCapture(photo: AVCapturePhoto) -> Bool {
    // For single format capture, complete immediately
    if !isProRaw {
      return true
    }
    
    // For RAW-only capture, complete after receiving the RAW photo
    if isProRaw && rawPhotoPath != nil && processedPhotoPath == nil {
      // Check if this was RAW-only or if we should expect a processed photo too
      // If we only requested RAW, complete now
      return true
    }
    
    // For dual capture, wait for both photos
    if rawPhotoPath != nil && processedPhotoPath != nil {
      return true
    }
    
    // Continue waiting for more photos
    return false
  }
  
  private func generatePhotoPath(originalPath: URL, isRaw: Bool) -> URL {
    let directory = originalPath.deletingLastPathComponent()
    let baseFilename = originalPath.deletingPathExtension().lastPathComponent
    let fileExtension = isRaw ? "dng" : "jpg"
    let suffix = isRaw ? "_raw" : "_processed"
    
    // If dual capture, add suffix to differentiate files
    let finalFilename = (rawPhotoPath != nil || processedPhotoPath != nil) ? 
      "\(baseFilename)\(suffix).\(fileExtension)" : 
      "\(baseFilename).\(fileExtension)"
    
    return directory.appendingPathComponent(finalFilename)
  }
  
  private func extractHDRGainMap(from photo: AVCapturePhoto, basePath: URL) {
    guard let photoData = photo.fileDataRepresentation() else { return }
    
    let ciImage = CIImage(data: photoData, options: [.auxiliaryHDRGainMap: true])
    if let gainMapImage = ciImage {
      let context = CIContext()
      if let gainMapData = context.jpegRepresentation(of: gainMapImage, colorSpace: CGColorSpaceCreateDeviceGray(), options: [:]) {
        let gainMapPath = basePath.appendingPathExtension("gainmap.jpg")
        try? gainMapData.write(to: gainMapPath)
        VisionLogger.log(level: .info, message: "Saved HDR gain map to: \(gainMapPath.path)")
      }
    }
  }
  
  private func cleanup() {
    removeGlobal()
  }
}
