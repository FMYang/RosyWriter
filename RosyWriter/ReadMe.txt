
RosyWriter

This sample demonstrates how to use AVCaptureVideoDataOutput to bring frames from the camera into various processing pipelines, including CPU-based, OpenGL (i.e. on the GPU), CoreImage filters, and OpenCV. It also demonstrates best practices for writing the processed output of these pipelines to a movie file using AVAssetWriter.

The project includes a different target for each of the different processing pipelines.

Classes
RosyWriterViewController
-- This file contains the view controller logic, including support for the Record button and video preview.
RosyWriterCapturePipeline
-- This file manages the audio and video capture pipelines, including the AVCaptureSession, the various queues, and resource management.

Renderers
RosyWriterRenderer
-- This file defines a generic protocol for renderer objects used by RosyWriterCapturePipeline.
RosyWriterOpenGLRenderer
-- This file manages the OpenGL (GPU) processing for the "rosy" effect and delivers rendered buffers.
RosyWriterCPURenderer
-- This file manages the CPU processing for the "rosy" effect and delivers rendered buffers.
RosyWriterCIFilterRenderer
-- This file manages the CoreImage processing for the "rosy" effect and delivers rendered buffers.
RosyWriterOpenCVRenderer
-- This file manages the delivery of frames to an OpenCV processing block and delivers rendered buffers.

RosyWriterAppDelegate
-- This file is a standard application delegate class.

Shaders
myFilter
-- OpenGL shader code for the "rosy" effect

Utilities
MovieRecorder
-- Illustrates real-time use of AVAssetWriter to record the displayed effect.
OpenGLPixelBufferView
-- This is a view that displays pixel buffers on the screen using OpenGL.

GL
-- Utilities used by the GL processing pipeline.


===============================================================
Copyright © 2016 Apple Inc. All rights reserved.


RosyWriter

该示例演示了如何使用AVCaptureVideoDataOutput将来自摄像机的帧带入各种处理管道，包括基于CPU，OpenGL（即在GPU上），CoreImage过滤器和OpenCV。它还演示了使用AVAssetWriter将这些管道的处理后的输出写入影片文件的最佳实践。

该项目为每个不同的处理管道包括一个不同的目标。

Classes
RosyWriterViewController
-该文件包含视图控制器逻辑，包括对“记录”按钮和视频预览的支持。
RosyWriterCapturePipeline
-该文件管理音频和视频捕获管道，包括AVCaptureSession，各种队列和资源管理。

渲染器(Renderers)
RosyWriterRenderer
-此文件为RosyWriterCapturePipeline使用的渲染器对象定义了通用协议。
RosyWriterOpenGLRenderer
-此文件管理“玫瑰色”效果的OpenGL（GPU）处理并提供渲染的缓冲区。
RosyWriterCPURenderer
-此文件管理“玫瑰色”效果的CPU处理并提供渲染的缓冲区。
RosyWriterCIFilterRenderer
-该文件管理CoreImage处理中的“玫瑰色”效果并提供渲染的缓冲区。
RosyWriterOpenCVRenderer
-该文件管理帧到OpenCV处理块的传递并传递渲染的缓冲区。

RosyWriterAppDelegate
-此文件是标准的应用程序委托类。

着色器(Shaders)
myFilter
-用于“玫瑰色”效果的OpenGL着色器代码

实用工具(Utilities)
电影录像机
-说明了实时使用AVAssetWriter来记录显示的效果。
OpenGLPixelBufferView
-这是一个使用OpenGL在屏幕上显示像素缓冲区的视图。

GL
-GL处理管道使用的实用程序。


============================================ =============
版权所有©2016 Apple Inc.保留所有权利。
