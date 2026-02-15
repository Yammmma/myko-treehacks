//
//  UIImage+Extensions.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/14/26.
//

import UIKit

extension UIImage {
    func base64EncodedString() -> String? {
        guard let imageData = self.jpegData(compressionQuality: 0.5) else { return nil }
        let base64String = imageData.base64EncodedString(options: [])
        // IMPORTANT: Sending Data URI prefix for compatibility
        return "data:image/jpeg;base64,\(base64String)"
    }
    
//    func changeWhiteToTransparent() -> UIImage? {
//        guard let rawImageRef = self.cgImage else { return nil }
//
//        // Define the color range for masking (white and near-white colors)
//        // The range is [min_red, max_red, min_green, max_green, min_blue, max_blue]
//        let colorMasking: [CGFloat] = [255, 255, 255, 255, 255, 255]
//
//        // Create a masked image reference
//        guard let maskedImageRef = rawImageRef.copy(maskingColorComponents: colorMasking) else { return nil }
//        
//        // Create a new UIImage from the masked image reference
//        let newImage = UIImage(cgImage: maskedImageRef)
//        
//        return newImage
//    }
}
