//
//  TakePhotoOptions.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 25.07.24.
//

import AVFoundation
import Foundation

struct TakePhotoOptions {
  var flash: Flash = .off
  var path: URL
  var enableAutoRedEyeReduction = false
  var enableAutoDistortionCorrection = false
  var enableShutterSound = true
  var enableProRaw = false
  var enableRawWithProcessed = false
  var enableHDRGainMap = false

  init(fromJSValue dictionary: NSDictionary) throws {
    // ProRaw
    if let enable = dictionary["enableProRaw"] as? Bool {
      enableProRaw = enable
    }
    // Raw with processed
    if let enable = dictionary["enableRawWithProcessed"] as? Bool {
      enableRawWithProcessed = enable
    }
    // HDR Gain Map
    if let enable = dictionary["enableHDRGainMap"] as? Bool {
      enableHDRGainMap = enable
    }
    // Flash
    if let flashOption = dictionary["flash"] as? String {
      flash = try Flash(jsValue: flashOption)
    }
    // Red-Eye reduction
    if let enable = dictionary["enableAutoRedEyeReduction"] as? Bool {
      enableAutoRedEyeReduction = enable
    }
    // Distortion correction
    if let enable = dictionary["enableAutoDistortionCorrection"] as? Bool {
      enableAutoDistortionCorrection = enable
    }
    // Shutter sound
    if let enable = dictionary["enableShutterSound"] as? Bool {
      enableShutterSound = enable
    }
    // Custom Path
    let fileExtension = enableProRaw ? "dng" : "jpg"
    if let customPath = dictionary["path"] as? String {
      path = try FileUtils.getFilePath(customDirectory: customPath, fileExtension: fileExtension)
    } else {
      // For ProRAW, save to temp directory and let JavaScript handle Photos library integration
      // For regular photos, save to camera directory as usual
      if enableProRaw {
        path = try FileUtils.getFilePath(directory: FileUtils.tempDirectory, fileExtension: fileExtension)
      } else {
        path = try FileUtils.getFilePath(fileExtension: fileExtension)
      }
    }
  }
}
