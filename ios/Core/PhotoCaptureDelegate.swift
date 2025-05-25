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
import Foundation

// MARK: - PhotoCaptureDelegate

class PhotoCaptureDelegate: GlobalReferenceHolder, AVCapturePhotoCaptureDelegate {
  private let promise: Promise
  private let enableShutterSound: Bool
  private let cameraSessionDelegate: CameraSessionDelegate?
  private let metadataProvider: MetadataProvider
  private let path: URL
  private let isProRaw: Bool
  private let enableHDRGainMap: Bool
  
  // Track photo capture state
  private var rawPhotoPath: URL?
  private var processedPhotoPath: URL?
  private var receivedPhotoCount: Int = 0
  private var isCleanedUp: Bool = false

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
    
    super.init()
    makeGlobal()
  }
  
  deinit {
    // Ensure cleanup is called even if something goes wrong
    cleanup()
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
      VisionLogger.log(level: .error, message: "Photo processing error: \(error)")
      self.cleanup()
      promise.reject(error: .capture(.unknown(message: error.description)), cause: error)
      return
    }

    // Extract data from photo immediately before any processing
    let photoData: Data?
    let isRawPhoto = photo.isRawPhoto
    
    // Deep copy metadata to avoid retaining photo object references
    let photoMetadata: [String: Any] = photo.metadata.compactMapValues { value -> Any? in
      if let dict = value as? [String: Any] {
        return dict.compactMapValues { $0 }
      }
      return value
    }
    let photoOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32 ?? CGImagePropertyOrientation.up.rawValue
    
    if isRawPhoto {
      photoData = photo.fileDataRepresentation()
    } else {
      photoData = nil
    }

    autoreleasepool {
      do {
        receivedPhotoCount += 1
      
        if isRawPhoto {
          // Handle RAW (DNG) photo
          guard let dngData = photoData else {
            self.cleanup()
            promise.reject(error: .capture(.imageDataAccessError))
            return
          }
          
          rawPhotoPath = generatePhotoPath(originalPath: path, isRaw: true)
          try dngData.write(to: rawPhotoPath!, options: [.atomic])
          
        } else {
          // Handle processed (JPEG/HEIF) photo
          processedPhotoPath = generatePhotoPath(originalPath: path, isRaw: false)
          
          autoreleasepool {
            try FileUtils.writePhotoToFile(photo: photo,
                                           metadataProvider: metadataProvider,
                                           file: processedPhotoPath!)
          }
          
          // HDR gain map extraction disabled to prevent resource leaks
          if enableHDRGainMap {
            VisionLogger.log(level: .warning, message: "HDR gain map extraction disabled to prevent resource leaks")
          }
        }
      
        // Check if capture is complete
        let isComplete = shouldCompleteCapture(isRawPhoto: isRawPhoto)
      
        if isComplete {
          // Return the primary photo path (RAW if available, otherwise processed)
          let primaryPath = rawPhotoPath ?? processedPhotoPath ?? path
          let isRawResult = rawPhotoPath != nil
          
          let exif = photoMetadata["{Exif}"] as? [String: Any]
          let width = exif?["PixelXDimension"]
          let height = exif?["PixelYDimension"]
          let cgOrientation = CGImagePropertyOrientation(rawValue: photoOrientation) ?? CGImagePropertyOrientation.up
          let orientation = getOrientation(forExifOrientation: cgOrientation)
          let isMirrored = getIsMirrored(forExifOrientation: cgOrientation)

          var result: [String: Any] = [
            "path": primaryPath.absoluteString,
            "width": width as Any,
            "height": height as Any,
            "orientation": orientation,
            "isMirrored": isMirrored,
            "isRawPhoto": isRawResult,
            "metadata": photoMetadata,
            "thumbnail": [:],
          ]
          
          // If dual capture, include both paths
          if rawPhotoPath != nil && processedPhotoPath != nil {
            result["rawPath"] = rawPhotoPath!.absoluteString
            result["processedPath"] = processedPhotoPath!.absoluteString
          }
          
          // Complete immediately for all photo types
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
  }

  func photoOutput(_: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
    // This method is called after all photo processing is complete
    if let error = error as NSError? {
      VisionLogger.log(level: .error, message: "Capture completion error: \(error)")
      self.cleanup()
      if error.code == -11807 {
        promise.reject(error: .capture(.insufficientStorage), cause: error)
      } else {
        promise.reject(error: .capture(.unknown(message: error.description)), cause: error)
      }
    }
    // Photo processing is handled in didFinishProcessingPhoto
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

  private func shouldCompleteCapture(isRawPhoto: Bool) -> Bool {
    // For single format capture (JPEG only), complete immediately
    if !isProRaw {
      return true
    }
    
    // For ProRAW with embedded thumbnail, complete immediately after receiving the single ProRAW file
    return true
  }
  
  private func generatePhotoPath(originalPath: URL, isRaw: Bool) -> URL {
    // For single format capture, use the original path directly
    if !isProRaw || (rawPhotoPath == nil && processedPhotoPath == nil) {
      // For ProRAW single format, ensure proper extension
      if isProRaw && isRaw {
        return originalPath.deletingPathExtension().appendingPathExtension("dng")
      }
      return originalPath
    }
    
    // For dual capture, generate differentiated paths in the same directory
    let directory = originalPath.deletingLastPathComponent()
    let baseFilename = originalPath.deletingPathExtension().lastPathComponent
    let fileExtension = isRaw ? "dng" : "jpg"
    let suffix = isRaw ? "_raw" : "_processed"
    
    let finalFilename = "\(baseFilename)\(suffix).\(fileExtension)"
    return directory.appendingPathComponent(finalFilename)
  }
  
  private func extractHDRGainMap(from photo: AVCapturePhoto, basePath: URL) {
    guard let photoData = photo.fileDataRepresentation() else { 
      VisionLogger.log(level: .warning, message: "Failed to get photo data representation")
      return 
    }
    
    // Use autoreleasepool to ensure proper cleanup of Core Image resources
    autoreleasepool {
      // Create CIImage with HDR gain map data
      guard let ciImage = CIImage(data: photoData, options: [.auxiliaryHDRGainMap: true]) else {
        VisionLogger.log(level: .warning, message: "Failed to create CIImage with HDR gain map")
        return
      }
      
      // Create a local CIContext for this operation
      let context = CIContext()
      
      // Extract gain map data with proper error handling
      guard let gainMapData = context.jpegRepresentation(
        of: ciImage, 
        colorSpace: CGColorSpaceCreateDeviceGray(), 
        options: [:]
      ) else {
        VisionLogger.log(level: .warning, message: "Failed to create JPEG representation of HDR gain map")
        return
      }
      
      // Save gain map file
      do {
        let gainMapPath = basePath.appendingPathExtension("gainmap.jpg")
        try gainMapData.write(to: gainMapPath)
      } catch {
        VisionLogger.log(level: .error, message: "Failed to save HDR gain map: \(error)")
      }
    }
  }
  
  private func cleanup() {
    // Prevent double cleanup
    guard !isCleanedUp else { 
      return 
    }
    isCleanedUp = true
    
    // Clear photo paths to release any file references
    rawPhotoPath = nil
    processedPhotoPath = nil
    
    // Remove from global reference holder
    removeGlobal()
  }
}
