//
//  CameraDeviceFormat.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 13.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

/**
 A serialisable representation of `AVCaptureDevice.Format`.
 */
struct CameraDeviceFormat: Equatable, CustomStringConvertible {
  let videoWidth: Int
  let videoHeight: Int

  let photoWidth: Int
  let photoHeight: Int

  let minFps: Double
  let maxFps: Double

  let minISO: Float
  let maxISO: Float

  let fieldOfView: Float

  let videoStabilizationModes: [VideoStabilizationMode]
  let autoFocusSystem: AutoFocusSystem

  let supportsVideoHdr: Bool
  let supportsPhotoHdr: Bool

  let supportsDepthCapture: Bool

  // MARK: – Initialisers -------------------------------------------------------

  init(fromFormat format: AVCaptureDevice.Format) {
    videoWidth  = Int(format.videoDimensions.width)
    videoHeight = Int(format.videoDimensions.height)

    photoWidth  = Int(format.photoDimensions.width)
    photoHeight = Int(format.photoDimensions.height)

    minFps = format.minFps
    maxFps = format.maxFps

    minISO = format.minISO
    maxISO = format.maxISO

    fieldOfView = format.videoFieldOfView

    videoStabilizationModes = format.videoStabilizationModes.map { VideoStabilizationMode(from: $0) }
    autoFocusSystem         = AutoFocusSystem(fromFocusSystem: format.autoFocusSystem)

    supportsVideoHdr     = format.supportsVideoHdr
    supportsPhotoHdr     = format.supportsPhotoHdr
    supportsDepthCapture = format.supportsDepthCapture
  }

  // MARK: – JS serialisation ---------------------------------------------------

  init(jsValue: NSDictionary) throws {
    // swiftlint:disable force_cast
    videoWidth               = jsValue["videoWidth"]               as! Int
    videoHeight              = jsValue["videoHeight"]              as! Int
    photoWidth               = jsValue["photoWidth"]               as! Int
    photoHeight              = jsValue["photoHeight"]              as! Int
    minFps                   = jsValue["minFps"]                   as! Double
    maxFps                   = jsValue["maxFps"]                   as! Double
    minISO                   = jsValue["minISO"]                   as! Float
    maxISO                   = jsValue["maxISO"]                   as! Float
    fieldOfView              = jsValue["fieldOfView"]              as! Float
    let modes                = jsValue["videoStabilizationModes"]  as! [String]
    videoStabilizationModes  = try modes.map { try VideoStabilizationMode(jsValue: $0) }
    autoFocusSystem          = try AutoFocusSystem(jsValue: jsValue["autoFocusSystem"] as! String)
    supportsVideoHdr         = jsValue["supportsVideoHdr"]         as! Bool
    supportsPhotoHdr         = jsValue["supportsPhotoHdr"]         as! Bool
    supportsDepthCapture     = jsValue["supportsDepthCapture"]     as! Bool
    // swiftlint:enable force_cast
  }

  func toJSValue() -> NSDictionary {
    [
      "videoStabilizationModes": videoStabilizationModes.map(\.jsValue),
      "autoFocusSystem":         autoFocusSystem.jsValue,
      "photoHeight":             photoHeight,
      "photoWidth":              photoWidth,
      "videoHeight":             videoHeight,
      "videoWidth":              videoWidth,
      "minISO":                  minISO,
      "maxISO":                  maxISO,
      "fieldOfView":             fieldOfView,
      "supportsVideoHdr":        supportsVideoHdr,
      "supportsPhotoHdr":        supportsPhotoHdr,
      "minFps":                  minFps,
      "maxFps":                  maxFps,
      "supportsDepthCapture":    supportsDepthCapture,
    ]
  }

  // MARK: – Helpers ------------------------------------------------------------

  func isEqualTo(format other: AVCaptureDevice.Format) -> Bool {
    let otherFormat = Self(fromFormat: other)
    return otherFormat == self
  }

  var description: String {
    "\(photoWidth)x\(photoHeight) | \(videoWidth)x\(videoHeight)@\(maxFps) (ISO: \(minISO)…\(maxISO))"
  }
}
