//
//  AVCaptureDevice+toDictionary.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 21.09.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation

extension AVCaptureDevice {
  func toDictionary() -> [String: Any] {
    VisionLogger.log(level: .info, message: "Checking ProRAW capability for device: \(self.localizedName) (\(self.position.descriptor))")
    
    // Device-level ProRAW support will be determined when the camera session is actually configured
    // to avoid expensive session creation during device enumeration. 
    // Use getCameraSessionInfo() after camera initialization to get the real capability.
    let deviceSupportsProRaw = false
    
    // Return ALL formats without ProRAW marking - ProRAW support is now device-level only
    let deviceFormats = self.formats.map { deviceFormat in
      return CameraDeviceFormat(fromFormat: deviceFormat)
    }
    
    VisionLogger.log(level: .info, message: "Device supports ProRAW: \(deviceSupportsProRaw), returning \(deviceFormats.count) formats")

    return [
      "id": uniqueID,
      "physicalDevices": physicalDevices.map(\.deviceType.physicalDeviceDescriptor),
      "position": position.descriptor,
      "name": localizedName,
      "hasFlash": hasFlash,
      "hasTorch": hasTorch,
      "minFocusDistance": minFocusDistance,
      "minZoom": minAvailableVideoZoomFactor,
      "maxZoom": maxAvailableVideoZoomFactor,
      "neutralZoom": neutralZoomFactor,
      "minExposure": minExposureTargetBias,
      "maxExposure": maxExposureTargetBias,
      "isMultiCam": isMultiCam,
      "supportsProRaw": deviceSupportsProRaw,
      "supportsLowLightBoost": isLowLightBoostSupported,
      "supportsFocus": isFocusPointOfInterestSupported,
      "hardwareLevel": HardwareLevel.full.jsValue,
      "sensorOrientation": sensorOrientation.jsValue,
      "formats": deviceFormats.map { $0.toJSValue() },
    ]
  }
}
