
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 The OpenGL ES view
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

@interface OpenGLPixelBufferView : UIView

/// 显示像素缓存区的图像
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;
/// 清空像素缓存区的缓存
- (void)flushPixelBufferCache;
/// 重置
- (void)reset;

@end
