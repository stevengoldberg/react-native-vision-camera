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
                
                // Use ProRAW with embedded JPEG thumbnail following Apple's WWDC21 documentation
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
                
                // Add embedded JPEG thumbnail to the ProRAW file
                if let thumbnailCodecType = photoSettings.availableRawEmbeddedThumbnailPhotoCodecTypes.first {
                    let formatDimensions = videoDeviceInput.device.activeFormat.photoDimensions
                    
                    // Use full resolution for embedded thumbnail to get best quality
                    photoSettings.rawEmbeddedThumbnailPhotoFormat = [
                        AVVideoCodecKey: thumbnailCodecType,
                        AVVideoWidthKey: formatDimensions.width,
                        AVVideoHeightKey: formatDimensions.height
                    ]
                }
            } else {
                // Regular photo settings
                photoSettings = AVCapturePhotoSettings()
            }
            
            // set photo resolution
            if #available(iOS 16.0, *) {
                let formatDimensions = videoDeviceInput.device.activeFormat.photoDimensions
                
                if options.enableProRaw {
                    // For ProRAW with embedded thumbnail, use full resolution
                    // The embedded thumbnail provides the processed version within the DNG file
                    photoSettings.maxPhotoDimensions = formatDimensions
                } else {
                    // For regular photos, use format's native dimensions
                    photoSettings.maxPhotoDimensions = formatDimensions
                }
            } else {
                photoSettings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
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
            
            // Don't prepare settings for ProRAW captures as they can be resource-intensive
            // and may cause system-wide resource leaks. Only prepare for regular photos.
            if !options.enableProRaw {
                photoOutput.setPreparedPhotoSettingsArray([photoSettings], completionHandler: nil)
            }
        }
    }
}
