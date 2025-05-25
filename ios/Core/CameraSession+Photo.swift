//
//  CameraSession+Photo.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 11.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

extension CameraSession {
    /**
     Takes a photo.
     `takePhoto` is only available if `photo={true}`.
     */
    func takePhoto(options: TakePhotoOptions, promise: Promise) {
        // Run on Camera Queue
        CameraQueues.cameraQueue.async {
            // Get Photo Output configuration
            guard let configuration = self.configuration else {
                promise.reject(error: .session(.cameraNotReady))
                return
            }
            guard configuration.photo != .disabled else {
                // User needs to enable photo={true}
                promise.reject(error: .capture(.photoNotEnabled))
                return
            }
            
            // Check if Photo Output is available
            guard let photoOutput = self.photoOutput,
                  let videoDeviceInput = self.videoDeviceInput else {
                // Camera is not yet ready
                promise.reject(error: .session(.cameraNotReady))
                return
            }
            
            // Check ProRAW support
            if options.enableProRaw {
                guard #available(iOS 14.3, *) else {
                    promise.reject(error: .capture(.proRawNotSupported))
                    return
                }
                
                let device = videoDeviceInput.device
                guard photoOutput.isAppleProRAWSupported && photoOutput.isAppleProRAWEnabled else {
                    promise.reject(error: .capture(.proRawNotSupported))
                    return
                }
            }
            
            // Check HDR gain map support
            if options.enableHDRGainMap {
                guard #available(iOS 14.1, *) else {
                    promise.reject(error: .capture(.hdrGainMapNotSupported))
                    return
                }
            }
            
            VisionLogger.log(level: .info, message: "Capturing photo...")
            
            // Create photo settings
            var photoSettings: AVCapturePhotoSettings
            
            if options.enableProRaw, #available(iOS 14.3, *) {

              if !photoOutput.isAppleProRAWEnabled {
                photoOutput.isAppleProRAWEnabled = true
                VisionLogger.log(level: .info, message: "ProRAW enabled on photo output")
              }
                // Follow Apple's documentation: choose appropriate RAW format
                // Prefer Apple ProRAW when enabled, fall back to Bayer RAW when not
                let query = photoOutput.isAppleProRAWEnabled ?
                    { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } :
                    { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
                
                // Retrieve the RAW format, favoring the Apple ProRAW format when it's in an enabled state
                guard let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: query) else {
                    promise.reject(error: .capture(.proRawNotSupported))
                    return
                }
                
                // Always do dual capture for ProRAW to get full-size JPEG embedded in DNG
                // This is how Camera app creates full-quality previews
                let processedFormat = [AVVideoCodecKey: AVVideoCodecType.hevc]
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: processedFormat)
                VisionLogger.log(level: .info, message: "Capturing ProRAW with embedded full-size HEVC")
                
                VisionLogger.log(level: .info, message: "Using RAW pixel format: \(rawFormat) (ProRAW enabled: \(photoOutput.isAppleProRAWEnabled))")
            } else {
                // Regular photo settings
                photoSettings = AVCapturePhotoSettings()
            }
            
            // set photo resolution
            if #available(iOS 16.0, *) {
                let formatDimensions = videoDeviceInput.device.activeFormat.photoDimensions
                
                if options.enableProRaw {
                    // For ProRAW dual capture, we might want different resolutions
                    // RAW should be full resolution, but processed can be smaller for preview
                    // Use 12MP (4032×3024) for processed preview - good quality but not huge file size
                    let previewDimensions = CMVideoDimensions(width: 4032, height: 3024)
                    
                    // If format is already 12MP or smaller, use format dimensions
                    // If format is larger, use 12MP for better file size
                    let usePreviewDimensions = formatDimensions.width > previewDimensions.width
                    let targetDimensions = usePreviewDimensions ? previewDimensions : formatDimensions
                    
                    photoSettings.maxPhotoDimensions = targetDimensions
                    VisionLogger.log(level: .info, message: "Set ProRAW dual capture dimensions to: \(targetDimensions.width)x\(targetDimensions.height) (format: \(formatDimensions.width)x\(formatDimensions.height))")
                } else {
                    // For regular photos, use format's native dimensions
                    photoSettings.maxPhotoDimensions = formatDimensions
                    VisionLogger.log(level: .info, message: "Set photo dimensions to format native: \(formatDimensions.width)x\(formatDimensions.height)")
                }
                VisionLogger.log(level: .info, message: "Photo output maxPhotoDimensions: \(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height)")
            } else {
                photoSettings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
                VisionLogger.log(level: .info, message: "High resolution photo enabled: \(photoOutput.isHighResolutionCaptureEnabled)")
            }
            
            // depth data
            photoSettings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
            if #available(iOS 12.0, *) {
                photoSettings.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isPortraitEffectsMatteDeliveryEnabled
            }
            
            // quality prioritization
            if #available(iOS 13.0, *) {
                photoSettings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
            }
            
            // red-eye reduction
            photoSettings.isAutoRedEyeReductionEnabled = options.enableAutoRedEyeReduction
            
            // distortion correction
            if #available(iOS 14.1, *) {
                photoSettings.isAutoContentAwareDistortionCorrectionEnabled = options.enableAutoDistortionCorrection
            }
            
            // flash
            if options.flash != .off {
                guard videoDeviceInput.device.hasFlash else {
                    // If user enabled flash, but the device doesn't have a flash, throw an error.
                    promise.reject(error: .capture(.flashNotAvailable))
                    return
                }
            }
            if videoDeviceInput.device.isFlashAvailable {
                photoSettings.flashMode = options.flash.toFlashMode()
            }
            
            // Actually do the capture!
            let photoCaptureDelegate = PhotoCaptureDelegate(promise: promise,
                                                            enableShutterSound: options.enableShutterSound,
                                                            metadataProvider: self.metadataProvider,
                                                            path: options.path,
                                                            isProRaw: options.enableProRaw,
                                                            enableHDRGainMap: options.enableHDRGainMap,
                                                            cameraSessionDelegate: self.delegate)
            photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureDelegate)
            
            // Assume that `takePhoto` is always called with the same parameters, so prepare the next call too.
            photoOutput.setPreparedPhotoSettingsArray([photoSettings], completionHandler: nil)
        }
    }
}
