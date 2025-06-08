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
    // ProRAW capability is determined dynamically when the camera session is configured
    // and communicated via the onProRawCapabilityChanged event
    
    // Return ALL formats without ProRAW marking - ProRAW support is now device-level only
    let deviceFormats = self.formats.map { deviceFormat in
      return CameraDeviceFormat(fromFormat: deviceFormat)
    }
    
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
      "virtualDeviceSwitchOverVideoZoomFactors": virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue },
      "displayVideoZoomFactorMultiplier": getDisplayVideoZoomFactorMultiplier(),
      "minExposure": minExposureTargetBias,
      "maxExposure": maxExposureTargetBias,
      "isMultiCam": isMultiCam,
      "supportsLowLightBoost": isLowLightBoostSupported,
      "supportsFocus": isFocusPointOfInterestSupported,
      "hardwareLevel": HardwareLevel.full.jsValue,
      "sensorOrientation": sensorOrientation.jsValue,
      "formats": deviceFormats.map { $0.toJSValue() },
    ]
  }
  
  private func getDisplayVideoZoomFactorMultiplier() -> Double {
    if #available(iOS 18.0, *) {
      // Use the official API on iOS 18+
      return displayVideoZoomFactorMultiplier
    } else {
      // For older iOS versions, calculate equivalent using neutralZoomFactor
      // magnification = zoomFactor / neutralZoom, so multiplier = 1.0 / neutralZoom
      return 1.0 / neutralZoomFactor
    }
  }
}
