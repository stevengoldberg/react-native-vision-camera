//
//  CameraSession+Configuration.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 12.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

// MARK: - CameraSession + Configuration
extension CameraSession {

  // MARK: Input Device --------------------------------------------------------

  /// Configures the Input Device (`cameraId`)
  func configureDevice(configuration: CameraConfiguration) throws {
    VisionLogger.log(level: .info, message: "Configuring Input Device...")

    // Remove all existing inputs
    for input in captureSession.inputs {
      captureSession.removeInput(input)
    }
    videoDeviceInput = nil

    #if targetEnvironment(simulator)
    throw CameraError.device(.notAvailableOnSimulator)
    #endif

    guard let cameraId = configuration.cameraId else {
      throw CameraError.device(.noDevice)
    }

    guard let videoDevice = AVCaptureDevice(uniqueID: cameraId) else {
      throw CameraError.device(.invalid)
    }

    let input = try AVCaptureDeviceInput(device: videoDevice)
    guard captureSession.canAddInput(input) else {
      throw CameraError.parameter(.unsupportedInput(inputDescriptor: "video-input"))
    }
    captureSession.addInput(input)
    videoDeviceInput = input

    // Tell the orientation-manager which sensor we use
    orientationManager.setInputDevice(videoDevice)

    VisionLogger.log(level: .info, message: "Successfully configured Input Device!")
  }

  // MARK: Outputs -------------------------------------------------------------

  /// Configures Photo-, Video- and Metadata-outputs
  func configureOutputs(configuration: CameraConfiguration) throws {
    VisionLogger.log(level: .info, message: "Configuring Outputs...")

    // Remove current outputs
    for output in captureSession.outputs {
      captureSession.removeOutput(output)
    }
    photoOutput = nil
    videoOutput = nil
    codeScannerOutput = nil

    // ───────────── Photo Output ────────────────────────────────────────────
    if case let .enabled(photo) = configuration.photo {
      VisionLogger.log(level: .info, message: "Adding Photo output...")

      let output = AVCapturePhotoOutput()
      guard captureSession.canAddOutput(output) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "photo-output"))
      }
      captureSession.addOutput(output)

      if #available(iOS 13.0, *) {
        output.maxPhotoQualityPrioritization =
          .init(fromQualityBalance: photo.qualityBalance)
      }
      if output.isDepthDataDeliverySupported {
        output.isDepthDataDeliveryEnabled = photo.enableDepthData
      }
      if output.isPortraitEffectsMatteDeliverySupported {
        output.isPortraitEffectsMatteDeliveryEnabled = photo.enablePortraitEffectsMatte
      }
      output.isMirrored = configuration.isMirrored

      // ──── ProRAW support will be configured AFTER format is set ────────────
      // (Moved to configureProRawSupport method called after format configuration)
      // ────────────────────────────────────────────────────────────────────

      photoOutput = output
    }

    // ───────────── Video Output ────────────────────────────────────────────
    if case .enabled = configuration.video {
      let output = AVCaptureVideoDataOutput()
      guard captureSession.canAddOutput(output) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "video-output"))
      }
      captureSession.addOutput(output)

      output.setSampleBufferDelegate(self, queue: CameraQueues.videoQueue)
      output.alwaysDiscardsLateVideoFrames = true

      if configuration.isMirrored {
        output.isMirrored = true
        if output.orientation.isLandscape {
          output.orientation = output.orientation.flipped()
        }
      }

      videoOutput = output
    }

    // ───────────── Code-Scanner Output ─────────────────────────────────────
    if case let .enabled(codeScanner) = configuration.codeScanner {
      let output = AVCaptureMetadataOutput()
      guard captureSession.canAddOutput(output) else {
        throw CameraError.codeScanner(.notCompatibleWithOutputs)
      }
      captureSession.addOutput(output)

      output.setMetadataObjectsDelegate(self, queue: CameraQueues.codeScannerQueue)

      for type in codeScanner.options.codeTypes {
        if !output.availableMetadataObjectTypes.contains(type) {
          throw CameraError.codeScanner(.codeTypeNotSupported(codeType: type.descriptor))
        }
      }
      output.metadataObjectTypes = codeScanner.options.codeTypes
      if let rect = codeScanner.options.regionOfInterest {
        output.rectOfInterest = rect
      }

      codeScannerOutput = output
    }

    // Re-initialise orientation settings
    configurePreviewOrientation(orientationManager.previewOrientation)
    configureOutputOrientation(orientationManager.outputOrientation)

    VisionLogger.log(level: .info, message: "Successfully configured all outputs!")
    delegate?.onSessionInitialized()
  }

  // MARK: Video Stabilisation --------------------------------------------------

  func configureVideoStabilization(configuration: CameraConfiguration) {
    for output in captureSession.outputs {
      for connection in output.connections where connection.isVideoStabilizationSupported {
        connection.preferredVideoStabilizationMode =
          configuration.videoStabilizationMode.toAVCaptureVideoStabilizationMode()
      }
    }
  }

  // MARK: Format ---------------------------------------------------------------

  /// Activates the requested `format`
  func configureFormat(configuration: CameraConfiguration, device: AVCaptureDevice) throws {
    guard let targetFormat = configuration.format else { return }

    let current = CameraDeviceFormat(fromFormat: device.activeFormat)
    if current == targetFormat { return }

    guard let format = device.formats.first(where: { targetFormat.isEqualTo(format: $0) }) else {
      throw CameraError.format(.invalidFormat)
    }
    device.activeFormat = format
  }

  // Called after `configureFormat` to apply pixel-format settings to `videoOutput`
  func configureVideoOutputFormat(configuration: CameraConfiguration) {
    guard case let .enabled(video) = configuration.video,
          let videoOutput else { return }

    do {
      let pixelFormat = try video.getPixelFormat(for: videoOutput)
      videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
    } catch { onConfigureError(error) }
  }

  /// Sets max-photo dimensions or turns on high-resolution capture
  func configurePhotoOutputFormat(configuration _: CameraConfiguration) {
    guard let videoDeviceInput, let photoOutput else { return }

    let format = videoDeviceInput.device.activeFormat
    if #available(iOS 16.0, *) {
      photoOutput.maxPhotoDimensions = format.photoDimensions
    } else {
      photoOutput.isHighResolutionCaptureEnabled = true
    }
  }

  // MARK: Side-properties (FPS, Low-light boost …) ----------------------------

  func configureSideProps(configuration: CameraConfiguration, device: AVCaptureDevice) throws {
    // FPS
    if let minFps = configuration.minFps,
       let maxFps = configuration.maxFps {
      let ranges = device.activeFormat.videoSupportedFrameRateRanges
      if !ranges.contains(where: { $0.minFrameRate <= Double(minFps) }) ||
         !ranges.contains(where: { $0.maxFrameRate >= Double(maxFps) }) {
        throw CameraError.format(.invalidFps(fps: Int(minFps)))
      }
      device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: minFps)
      device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: maxFps)
    } else {
      device.activeVideoMaxFrameDuration = .invalid
      device.activeVideoMinFrameDuration = .invalid
    }

    // Low-light boost
    if device.automaticallyEnablesLowLightBoostWhenAvailable != configuration.enableLowLightBoost {
      guard device.isLowLightBoostSupported else {
        throw CameraError.device(.lowLightBoostNotSupported)
      }
      device.automaticallyEnablesLowLightBoostWhenAvailable = configuration.enableLowLightBoost
    }

    // Default AF/AE box centre
    if device.isFocusModeSupported(.continuousAutoFocus) {
      if device.isFocusPointOfInterestSupported {
        device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
      device.focusMode = .continuousAutoFocus
    }
    if device.isExposureModeSupported(.continuousAutoExposure) {
      if device.isExposurePointOfInterestSupported {
        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
      device.exposureMode = .continuousAutoExposure
    }
  }

  // MARK: Torch ----------------------------------------------------------------

  func configureTorch(configuration: CameraConfiguration, device: AVCaptureDevice) throws {
    let torchMode = configuration.torch.toTorchMode()
    if device.torchMode != torchMode {
      guard device.hasTorch else { throw CameraError.device(.flashUnavailable) }

      device.torchMode = torchMode
      if torchMode == .on {
        try device.setTorchModeOn(level: 1.0)
      }
    }
  }

  // MARK: Zoom / Exposure ------------------------------------------------------

  func configureZoom(configuration: CameraConfiguration, device: AVCaptureDevice) {
    guard let zoom = configuration.zoom else { return }
    let clamped = max(min(zoom, device.activeFormat.videoMaxZoomFactor),
                      device.minAvailableVideoZoomFactor)
    device.videoZoomFactor = clamped
  }

  func configureExposure(configuration: CameraConfiguration, device: AVCaptureDevice) {
    guard let bias = configuration.exposure else { return }
    let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
    device.setExposureTargetBias(clamped)
  }

  // MARK: Audio ---------------------------------------------------------------

  func configureAudioSession(configuration: CameraConfiguration) throws {
    VisionLogger.log(level: .info, message: "Configuring Audio Session...")

    audioCaptureSession.automaticallyConfiguresApplicationAudioSession = false
    let enableAudio = configuration.audio != .disabled

    if enableAudio &&
        AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
      throw CameraError.permission(.microphone)
    }

    // Inputs
    for input in audioCaptureSession.inputs { audioCaptureSession.removeInput(input) }
    audioDeviceInput = nil

    if enableAudio {
      guard let mic = AVCaptureDevice.default(for: .audio) else {
        throw CameraError.device(.microphoneUnavailable)
      }
      let input = try AVCaptureDeviceInput(device: mic)
      guard audioCaptureSession.canAddInput(input) else {
        throw CameraError.parameter(.unsupportedInput(inputDescriptor: "audio-input"))
      }
      audioCaptureSession.addInput(input)
      audioDeviceInput = input
    }

    // Outputs
    for output in audioCaptureSession.outputs { audioCaptureSession.removeOutput(output) }
    audioOutput = nil

    if enableAudio {
      let output = AVCaptureAudioDataOutput()
      guard audioCaptureSession.canAddOutput(output) else {
        throw CameraError.parameter(.unsupportedOutput(outputDescriptor: "audio-output"))
      }
      output.setSampleBufferDelegate(self, queue: CameraQueues.audioQueue)
      audioCaptureSession.addOutput(output)
      audioOutput = output
    }
  }

  // MARK: ProRAW Support (called AFTER format configuration) ------------------

  func configureProRawSupport(configuration: CameraConfiguration) {
    guard case let .enabled(photo) = configuration.photo,
          let photoOutput = photoOutput,
          let videoDeviceInput = videoDeviceInput else { return }
    
    if #available(iOS 14.3, *) {
      VisionLogger.log(level: .info, message: "Configuring photo output ProRAW support...")
      VisionLogger.log(level: .info, message: "photo.enableProRaw: \(photo.enableProRaw)")
      VisionLogger.log(level: .info, message: "output.isAppleProRAWSupported: \(photoOutput.isAppleProRAWSupported)")
      VisionLogger.log(level: .info, message: "Current active format: \(videoDeviceInput.device.activeFormat.photoDimensions.width)x\(videoDeviceInput.device.activeFormat.photoDimensions.height)")
      
      if photo.enableProRaw {
        if photoOutput.isAppleProRAWSupported {
          photoOutput.isAppleProRAWEnabled           = true
          photoOutput.isHighResolutionCaptureEnabled = true // mandatory for RAW/ProRAW
          VisionLogger.log(level: .info, message: "✅ ProRAW enabled on photo output")
          
        } else {
          VisionLogger.log(level: .warning, message: "❌ ProRAW requested but output.isAppleProRAWSupported = false")
          VisionLogger.log(level: .warning, message: "This usually means the current format doesn't support ProRAW.")
        }
      } else {
        VisionLogger.log(level: .info, message: "ProRAW not requested (enableProRaw = false)")
      }
    } else {
      VisionLogger.log(level: .info, message: "iOS < 14.3, ProRAW not available")
    }
  }
}
