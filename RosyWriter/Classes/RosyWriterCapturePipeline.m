
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 The class that creates and manages the AVCaptureSession
 */

#import "RosyWriterCapturePipeline.h"

#import "RosyWriterOpenGLRenderer.h"
#import "RosyWriterCPURenderer.h"
#import "RosyWriterCIFilterRenderer.h"
#import "RosyWriterOpenCVRenderer.h"

#import "MovieRecorder.h"

#import <CoreMedia/CMBufferQueue.h>
#import <CoreMedia/CMAudioClock.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <ImageIO/CGImageProperties.h>

/*
 RETAINED_BUFFER_COUNT is the number of pixel buffers we expect to hold on to from the renderer. This value informs the renderer how to size its buffer pool and how many pixel buffers to preallocate (done in the prepareWithOutputDimensions: method). Preallocation helps to lessen the chance of frame drops in our recording, in particular during recording startup. If we try to hold on to more buffers than RETAINED_BUFFER_COUNT then the renderer will fail to allocate new buffers from its pool and we will drop frames.

 A back of the envelope calculation to arrive at a RETAINED_BUFFER_COUNT of '6':
 - The preview path only has the most recent frame, so this makes the movie recording path the long pole.
 - The movie recorder internally does a dispatch_async to avoid blocking the caller when enqueuing to its internal asset writer.
 - Allow 2 frames of latency to cover the dispatch_async and the -[AVAssetWriterInput appendSampleBuffer:] call.
 - Then we allow for the encoder to retain up to 4 frames. Two frames are retained while being encoded/format converted, while the other two are to handle encoder format conversion pipelining and encoder startup latency.

 Really you need to test and measure the latency in your own application pipeline to come up with an appropriate number. 1080p BGRA buffers are quite large, so it's a good idea to keep this number as low as possible.
 
 RETAINED_BUFFER_COUNT是我们希望从渲染器获得的像素缓冲区数。此值通知渲染器如何调整其缓冲池的大小以及要预分配的像素缓冲区的数量（在prepareWithOutputDimensions：方法中完成）。预分配有助于减少我们的录制中出现帧丢失的机会，尤其是在录制启动过程中。如果我们尝试保留的缓冲区多于RETAINED_BUFFER_COUNT，则渲染器将无法从其池中分配新的缓冲区，并且将丢弃帧。

 包络线计算的后沿，得出RETAINED_BUFFER_COUNT为'6'：
 -预览路径仅具有最近的帧，因此这使电影录制路径成为长杆。
 -电影录像机在内部进行dispatch_async，以避免在排队到其内部资产编写器时阻塞调用方。
 -允许2帧延迟来覆盖dispatch_async和-[AVAssetWriterInput appendSampleBuffer：]调用。
 -然后，我们允许编码器保留最多4帧。在编码/格式转换时保留两个帧，而其他两个帧则用于处理编码器格式转换流水线和编码器启动延迟。

 确实，您需要在自己的应用程序管道中测试和测量延迟，以得出适当的数字。 1080p BGRA缓冲区很大，因此最好将此数字保持尽可能低。
 */

#define RETAINED_BUFFER_COUNT 6

#define RECORD_AUDIO 1

#define LOG_STATUS_TRANSITIONS 0

typedef NS_ENUM( NSInteger, RosyWriterRecordingStatus )
{
	RosyWriterRecordingStatusIdle = 0,
	RosyWriterRecordingStatusStartingRecording,
	RosyWriterRecordingStatusRecording,
	RosyWriterRecordingStatusStoppingRecording,
}; // internal state machine

@interface RosyWriterCapturePipeline () <AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate>
{
	NSMutableArray *_previousSecondTimestamps;

	AVCaptureSession *_captureSession;
	AVCaptureDevice *_videoDevice;
	AVCaptureConnection *_audioConnection;
	AVCaptureConnection *_videoConnection;
	AVCaptureVideoOrientation _videoBufferOrientation;
	BOOL _running;
	BOOL _startCaptureSessionOnEnteringForeground;
	id _applicationWillEnterForegroundNotificationObserver;
	NSDictionary *_videoCompressionSettings;
	NSDictionary *_audioCompressionSettings;
	
	dispatch_queue_t _sessionQueue;
	dispatch_queue_t _videoDataOutputQueue;
	
	id<RosyWriterRenderer> _renderer;
	BOOL _renderingEnabled;
	
	MovieRecorder *_recorder;
	NSURL *_recordingURL;
	RosyWriterRecordingStatus _recordingStatus;
	
	UIBackgroundTaskIdentifier _pipelineRunningTask;
	
	__weak id<RosyWriterCapturePipelineDelegate> _delegate;
	dispatch_queue_t _delegateCallbackQueue;
}

// Redeclared readwrite
@property(atomic, readwrite) float videoFrameRate;
@property(atomic, readwrite) CMVideoDimensions videoDimensions;

// Because we specify __attribute__((NSObject)) ARC will manage the lifetime of the backing ivars even though they are CF types.
@property(nonatomic, strong) __attribute__((NSObject)) CVPixelBufferRef currentPreviewPixelBuffer;
@property(nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;
@property(nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef outputAudioFormatDescription;

@end

@implementation RosyWriterCapturePipeline

- (instancetype)initWithDelegate:(id<RosyWriterCapturePipelineDelegate>)delegate callbackQueue:(dispatch_queue_t)queue // delegate is weak referenced
{
	NSParameterAssert( delegate != nil );
	NSParameterAssert( queue != nil );
	
	self = [super init];
	if ( self )
	{
		_previousSecondTimestamps = [[NSMutableArray alloc] init];
		_recordingOrientation = AVCaptureVideoOrientationPortrait;
		
        // 录像保存地址
		_recordingURL = [[NSURL alloc] initFileURLWithPath:[NSString pathWithComponents:@[NSTemporaryDirectory(), @"Movie.MOV"]]];
		
		_sessionQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.session", DISPATCH_QUEUE_SERIAL );
		
		// In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
		// In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
		// Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
		// AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
        // 在多线程的生产者和消费者系统中，最好确保生产者不要浪费CPU时间
        // 在这个app中，我们开启视频输出帧使用默认的高优先级队列，并且下游的消费者使用默认的优先级队列
        // 音频使用默认的优先级队列，因为我们不会实时监控它，只是想把它放入视频中
        // 由于AudioDataOutput的缓冲区未从固定大小的池中分配出去，因此它比VideoDataOutput可以忍受更多的延迟
		_videoDataOutputQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.video", DISPATCH_QUEUE_SERIAL );
		dispatch_set_target_queue( _videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0 ) );
		
// USE_XXX_RENDERER is set in the project's build settings for each target
        // step0.1 - 设置OpenGL渲染
#if USE_OPENGL_RENDERER
		_renderer = [[RosyWriterOpenGLRenderer alloc] init];
#elif USE_CPU_RENDERER
		_renderer = [[RosyWriterCPURenderer alloc] init];
#elif USE_CIFILTER_RENDERER
		_renderer = [[RosyWriterCIFilterRenderer alloc] init];
#elif USE_OPENCV_RENDERER
		_renderer = [[RosyWriterOpenCVRenderer alloc] init];
#endif
				
		_pipelineRunningTask = UIBackgroundTaskInvalid;
		_delegate = delegate;
		_delegateCallbackQueue = queue;
	}
	return self;
}

- (void)dealloc
{
	[self teardownCaptureSession];
}

#pragma mark Capture Session 会话设置

// step1.1 - PipeLine开启会话
- (void)startRunning
{
	dispatch_sync( _sessionQueue, ^{
		[self setupCaptureSession];
		
		if ( _captureSession ) {
            // step 1.2 启动会话
			[_captureSession startRunning];
			_running = YES;
		}
	} );
}

- (void)stopRunning
{
	dispatch_sync( _sessionQueue, ^{
		_running = NO;
		
		// the captureSessionDidStopRunning method will stop recording if necessary as well, but we do it here so that the last video and audio samples are better aligned
		[self stopRecording]; // does nothing if we aren't currently recording
		
		[_captureSession stopRunning];
		
		[self captureSessionDidStopRunning];
		
		[self teardownCaptureSession];
	} );
}

// step1.3 - 配置会话，设置输入、输出
- (void)setupCaptureSession
{
	if ( _captureSession ) {
		return;
	}
	
	_captureSession = [[AVCaptureSession alloc] init];	

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionNotification:) name:nil object:_captureSession];
	_applicationWillEnterForegroundNotificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:[UIApplication sharedApplication] queue:nil usingBlock:^(NSNotification *note) {
		// Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
		// Client must stop us running before we can be deallocated
		[self applicationWillEnterForeground];
	}];
	
#if RECORD_AUDIO
	/* Audio */
    // 添加音频设备
	AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
	AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:nil];
    // 添加音频输入
	if ( [_captureSession canAddInput:audioIn] ) {
		[_captureSession addInput:audioIn];
	}
//	[audioIn release];
	
    // 创建音频输出
	AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
	// Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
	dispatch_queue_t audioCaptureQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.audio", DISPATCH_QUEUE_SERIAL );
	[audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
//	[audioCaptureQueue release];
	
    // 添加音频输出
	if ( [_captureSession canAddOutput:audioOut] ) {
		[_captureSession addOutput:audioOut];
	}
	_audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
//	[audioOut release];
#endif // RECORD_AUDIO
	
	/* Video */
    // 添加视频设备
	AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	NSError *videoDeviceError = nil;
    // 设置录像输入
	AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:&videoDeviceError];
	if ( [_captureSession canAddInput:videoIn] ) {
		[_captureSession addInput:videoIn];
        _videoDevice = videoDevice;
	}
	else {
		[self handleNonRecoverableCaptureSessionRuntimeError:videoDeviceError];
		return;
	}
	
    // 设置录像输出AVCaptureVideoDataOutput
	AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
	videoOut.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(_renderer.inputPixelFormat) };
	[videoOut setSampleBufferDelegate:self queue:_videoDataOutputQueue];
	
	// RosyWriter records videos and we prefer not to have any dropped frames in the video recording.
	// By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
	// We do however need to ensure that on average we can process frames in realtime.
	// If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
	videoOut.alwaysDiscardsLateVideoFrames = NO;
	
	if ( [_captureSession canAddOutput:videoOut] ) {
		[_captureSession addOutput:videoOut];
	}
	_videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
		
	int frameRate;
	NSString *sessionPreset = AVCaptureSessionPresetHigh;
	CMTime frameDuration = kCMTimeInvalid;
	// For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
	if ( [NSProcessInfo processInfo].processorCount == 1 )
	{
		if ( [_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480] ) {
			sessionPreset = AVCaptureSessionPreset640x480;
		}
		frameRate = 15;
	}
	else
	{
#if ! USE_OPENGL_RENDERER
		// When using the CPU renderers or the CoreImage renderer we lower the resolution to 720p so that all devices can maintain real-time performance (this is primarily for A5 based devices like iPhone 4s and iPod Touch 5th Generation).
		if ( [_captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720] ) {
			sessionPreset = AVCaptureSessionPreset1280x720;
		}
#endif // ! USE_OPENGL_RENDERER

		frameRate = 30;
	}
	
	_captureSession.sessionPreset = sessionPreset;
	
	frameDuration = CMTimeMake( 1, frameRate );

	NSError *error = nil;
	if ( [videoDevice lockForConfiguration:&error] ) {
		videoDevice.activeVideoMaxFrameDuration = frameDuration;
		videoDevice.activeVideoMinFrameDuration = frameDuration;
		[videoDevice unlockForConfiguration];
	}
	else {
		NSLog( @"videoDevice lockForConfiguration returned error %@", error );
	}

	// Get the recommended compression settings after configuring the session/device.
#if RECORD_AUDIO
	_audioCompressionSettings = [[audioOut recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] copy];
#endif
	_videoCompressionSettings = [[videoOut recommendedVideoSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] copy];
	
	_videoBufferOrientation = _videoConnection.videoOrientation;
	
	return;
}

- (void)teardownCaptureSession
{
	if ( _captureSession )
	{
		[[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_captureSession];
		
		[[NSNotificationCenter defaultCenter] removeObserver:_applicationWillEnterForegroundNotificationObserver];
		_applicationWillEnterForegroundNotificationObserver = nil;
		
		_captureSession = nil;
		
		_videoCompressionSettings = nil;
		_audioCompressionSettings = nil;
	}
}

- (void)captureSessionNotification:(NSNotification *)notification
{
	dispatch_async( _sessionQueue, ^{
		
		if ( [notification.name isEqualToString:AVCaptureSessionWasInterruptedNotification] )
		{
			NSLog( @"session interrupted" );
			
			[self captureSessionDidStopRunning];
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionInterruptionEndedNotification] )
		{
			NSLog( @"session interruption ended" );
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionRuntimeErrorNotification] )
		{
			[self captureSessionDidStopRunning];
			
			NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
			if ( error.code == AVErrorDeviceIsNotAvailableInBackground )
			{
				NSLog( @"device not available in background" );

				// Since we can't resume running while in the background we need to remember this for next time we come to the foreground
				if ( _running ) {
					_startCaptureSessionOnEnteringForeground = YES;
				}
			}
			else if ( error.code == AVErrorMediaServicesWereReset )
			{
				NSLog( @"media services were reset" );
				[self handleRecoverableCaptureSessionRuntimeError:error];
			}
			else
			{
				[self handleNonRecoverableCaptureSessionRuntimeError:error];
			}
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionDidStartRunningNotification] )
		{
			NSLog( @"session started running" );
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionDidStopRunningNotification] )
		{
			NSLog( @"session stopped running" );
		}
	} );
}

- (void)handleRecoverableCaptureSessionRuntimeError:(NSError *)error
{
	if ( _running ) {
		[_captureSession startRunning];
	}
}

- (void)handleNonRecoverableCaptureSessionRuntimeError:(NSError *)error
{
	NSLog( @"fatal runtime error %@, code %i", error, (int)error.code );
	
	_running = NO;
	[self teardownCaptureSession];
	
	[self invokeDelegateCallbackAsync:^{
		[_delegate capturePipeline:self didStopRunningWithError:error];
	}];
}

- (void)captureSessionDidStopRunning
{
	[self stopRecording]; // a no-op if we aren't recording
	[self teardownVideoPipeline];
}

- (void)applicationWillEnterForeground
{
	NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
	
	dispatch_sync( _sessionQueue, ^{
		
		if ( _startCaptureSessionOnEnteringForeground )
		{
			NSLog( @"-[%@ %@] manually restarting session", [self class], NSStringFromSelector(_cmd) );
			
			_startCaptureSessionOnEnteringForeground = NO;
			if ( _running ) {
				[_captureSession startRunning];
			}
		}
	} );
}

#pragma mark Capture Pipeline

- (void)setupVideoPipelineWithInputFormatDescription:(CMFormatDescriptionRef)inputFormatDescription
{
	NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
	
	[self videoPipelineWillStartRunning];
	
	self.videoDimensions = CMVideoFormatDescriptionGetDimensions( inputFormatDescription );
	[_renderer prepareForInputWithFormatDescription:inputFormatDescription outputRetainedBufferCountHint:RETAINED_BUFFER_COUNT];
	
	if ( ! _renderer.operatesInPlace && [_renderer respondsToSelector:@selector(outputFormatDescription)] ) {
		self.outputVideoFormatDescription = _renderer.outputFormatDescription;
	}
	else {
		self.outputVideoFormatDescription = inputFormatDescription;
	}
}

// synchronous, blocks until the pipeline is drained, don't call from within the pipeline
- (void)teardownVideoPipeline
{
	// The session is stopped so we are guaranteed that no new buffers are coming through the video data output.
	// There may be inflight buffers on _videoDataOutputQueue however.
	// Synchronize with that queue to guarantee no more buffers are in flight.
	// Once the pipeline is drained we can tear it down safely.

	NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
	
	dispatch_sync( _videoDataOutputQueue, ^{
		
		if ( ! self.outputVideoFormatDescription ) {
			return;
		}
		
		self.outputVideoFormatDescription = NULL;
		[_renderer reset];
		self.currentPreviewPixelBuffer = NULL;
		
		NSLog( @"-[%@ %@] finished teardown", [self class], NSStringFromSelector(_cmd) );
		
		[self videoPipelineDidFinishRunning];
	} );
}

- (void)videoPipelineWillStartRunning
{
	NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
	
	NSAssert( _pipelineRunningTask == UIBackgroundTaskInvalid, @"should not have a background task active before the video pipeline starts running" );
	
	_pipelineRunningTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
		NSLog( @"video capture pipeline background task expired" );
	}];
}

- (void)videoPipelineDidFinishRunning
{
	NSLog( @"-[%@ %@] called", [self class], NSStringFromSelector(_cmd) );
	
	NSAssert( _pipelineRunningTask != UIBackgroundTaskInvalid, @"should have a background task active when the video pipeline finishes running" );
	
	[[UIApplication sharedApplication] endBackgroundTask:_pipelineRunningTask];
	_pipelineRunningTask = UIBackgroundTaskInvalid;
}

- (void)videoPipelineDidRunOutOfBuffers
{
	// We have run out of buffers.
	// Tell the delegate so that it can flush any cached buffers.
	
	[self invokeDelegateCallbackAsync:^{
		[_delegate capturePipelineDidRunOutOfPreviewBuffers:self];
	}];
}

- (void)setRenderingEnabled:(BOOL)renderingEnabled
{
	@synchronized( _renderer ) {
		_renderingEnabled = renderingEnabled;
	}
}

- (BOOL)renderingEnabled
{
	@synchronized( _renderer ) {
		return _renderingEnabled;
	}
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate 输出视频帧回调
// 输出视频帧的时候调用AVCaptureVideoDataOutput
// step3 - 渲染预览视图
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
	CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription( sampleBuffer );
	
	if ( connection == _videoConnection )
	{
		if ( self.outputVideoFormatDescription == NULL ) {
			// Don't render the first sample buffer.
			// This gives us one frame interval (33ms at 30fps) for setupVideoPipelineWithInputFormatDescription: to complete.
			// Ideally this would be done asynchronously to ensure frames don't back up on slower devices.
			[self setupVideoPipelineWithInputFormatDescription:formatDescription];
		}
		else {
			[self renderVideoSampleBuffer:sampleBuffer];
		}
	}
	else if ( connection == _audioConnection )
	{
		self.outputAudioFormatDescription = formatDescription;
		
		@synchronized( self ) {
			if ( _recordingStatus == RosyWriterRecordingStatusRecording ) {
				[_recorder appendAudioSampleBuffer:sampleBuffer];
			}
		}
	}
}

// step3.1 - 渲染视频帧缓存
- (void)renderVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
	CVPixelBufferRef renderedPixelBuffer = NULL;
	CMTime timestamp = CMSampleBufferGetPresentationTimeStamp( sampleBuffer );
	
	[self calculateFramerateAtTimestamp:timestamp];
	
	// We must not use the GPU while running in the background.
	// setRenderingEnabled: takes the same lock so the caller can guarantee no GPU usage once the setter returns.
	@synchronized( _renderer )
	{
		if ( _renderingEnabled ) {
            // 获取视频帧的像素缓存
			CVPixelBufferRef sourcePixelBuffer = CMSampleBufferGetImageBuffer( sampleBuffer );
            // 获取像素渲染缓存
			renderedPixelBuffer = [_renderer copyRenderedPixelBuffer:sourcePixelBuffer];
		}
		else {
			return;
		}
	}
	
	if ( renderedPixelBuffer )
	{
		@synchronized( self )
		{
            // step3.2 - 输出预览
			[self outputPreviewPixelBuffer:renderedPixelBuffer];
			
			if ( _recordingStatus == RosyWriterRecordingStatusRecording ) {
                // step3.2.1 调用MovieRecorder的appendVideoPixelBuffer方法添加到视频像素缓存，渲染
				[_recorder appendVideoPixelBuffer:renderedPixelBuffer withPresentationTime:timestamp];
			}
		}
		
		CFRelease( renderedPixelBuffer );
	}
	else
	{
		[self videoPipelineDidRunOutOfBuffers];
	}
}

// call under @synchronized( self )
- (void)outputPreviewPixelBuffer:(CVPixelBufferRef)previewPixelBuffer
{
	// Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
	// Note that access to currentPreviewPixelBuffer is protected by the @synchronized lock
	self.currentPreviewPixelBuffer = previewPixelBuffer;
	
	[self invokeDelegateCallbackAsync:^{
		
		CVPixelBufferRef currentPreviewPixelBuffer = NULL;
		@synchronized( self )
		{
			currentPreviewPixelBuffer = self.currentPreviewPixelBuffer;
			if ( currentPreviewPixelBuffer ) {
				CFRetain( currentPreviewPixelBuffer );
				self.currentPreviewPixelBuffer = NULL;
			}
		}
		
		if ( currentPreviewPixelBuffer ) {
			[_delegate capturePipeline:self previewPixelBufferReadyForDisplay:currentPreviewPixelBuffer];
			CFRelease( currentPreviewPixelBuffer );
		}
	}];
}

#pragma mark Recording

/// step2.1 - 开始录制
- (void)startRecording
{
	@synchronized( self )
	{
		if ( _recordingStatus != RosyWriterRecordingStatusIdle ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already recording" userInfo:nil];
			return;
		}
		
		[self transitionToRecordingStatus:RosyWriterRecordingStatusStartingRecording error:nil];
	}
	
	dispatch_queue_t callbackQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.recordercallback", DISPATCH_QUEUE_SERIAL ); // guarantee ordering of callbacks with a serial queue
    
    // step2.2 - 初始化视频录像器MovieRecorder
	MovieRecorder *recorder = [[MovieRecorder alloc] initWithURL:_recordingURL delegate:self callbackQueue:callbackQueue];
	
#if RECORD_AUDIO
    // 添加音频轨道
	[recorder addAudioTrackWithSourceFormatDescription:self.outputAudioFormatDescription settings:_audioCompressionSettings];
#endif // RECORD_AUDIO
	
    // 设置镜像
	CGAffineTransform videoTransform = [self transformFromVideoBufferOrientationToOrientation:self.recordingOrientation withAutoMirroring:NO]; // Front camera recording shouldn't be mirrored

    // 添加视频轨道
	[recorder addVideoTrackWithSourceFormatDescription:self.outputVideoFormatDescription transform:videoTransform settings:_videoCompressionSettings];
	_recorder = recorder;
	
    // 准备好录制
	[recorder prepareToRecord]; // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
}

- (void)stopRecording
{
	@synchronized( self )
	{
		if ( _recordingStatus != RosyWriterRecordingStatusRecording ) {
			return;
		}
		
		[self transitionToRecordingStatus:RosyWriterRecordingStatusStoppingRecording error:nil];
	}
	
	[_recorder finishRecording]; // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
}

#pragma mark MovieRecorder Delegate

- (void)movieRecorderDidFinishPreparing:(MovieRecorder *)recorder
{
	@synchronized( self )
	{
		if ( _recordingStatus != RosyWriterRecordingStatusStartingRecording ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StartingRecording state" userInfo:nil];
			return;
		}
		
		[self transitionToRecordingStatus:RosyWriterRecordingStatusRecording error:nil];
	}
}

- (void)movieRecorder:(MovieRecorder *)recorder didFailWithError:(NSError *)error
{
	@synchronized( self )
	{
		_recorder = nil;
		[self transitionToRecordingStatus:RosyWriterRecordingStatusIdle error:error];
	}
}

// step4.1 - 录制停止的代理方法
- (void)movieRecorderDidFinishRecording:(MovieRecorder *)recorder
{
	@synchronized( self )
	{
		if ( _recordingStatus != RosyWriterRecordingStatusStoppingRecording ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
			return;
		}
		
		// No state transition, we are still in the process of stopping.
		// We will be stopped once we save to the assets library.
	}
	
	_recorder = nil;
	
    // step4.2 - 将录制的视频保存到相册
	ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
	[library writeVideoAtPathToSavedPhotosAlbum:_recordingURL completionBlock:^(NSURL *assetURL, NSError *error) {
		
		[[NSFileManager defaultManager] removeItemAtURL:_recordingURL error:NULL];
		
 		@synchronized( self )
		{
			if ( _recordingStatus != RosyWriterRecordingStatusStoppingRecording ) {
				@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
				return;
			}
			[self transitionToRecordingStatus:RosyWriterRecordingStatusIdle error:error];
		}
	}];
}

#pragma mark Recording State Machine

// call under @synchonized( self )
- (void)transitionToRecordingStatus:(RosyWriterRecordingStatus)newStatus error:(NSError *)error
{
	RosyWriterRecordingStatus oldStatus = _recordingStatus;
	_recordingStatus = newStatus;
	
#if LOG_STATUS_TRANSITIONS
	NSLog( @"RosyWriterCapturePipeline recording state transition: %@->%@", [self stringForRecordingStatus:oldStatus], [self stringForRecordingStatus:newStatus] );
#endif
	
	if ( newStatus != oldStatus )
	{
		dispatch_block_t delegateCallbackBlock = nil;
		
		if ( error && ( newStatus == RosyWriterRecordingStatusIdle ) )
		{
			delegateCallbackBlock = ^{ [_delegate capturePipeline:self recordingDidFailWithError:error]; };
		}
		else
		{
			if ( ( oldStatus == RosyWriterRecordingStatusStartingRecording ) && ( newStatus == RosyWriterRecordingStatusRecording ) ) {
				delegateCallbackBlock = ^{ [_delegate capturePipelineRecordingDidStart:self]; };
			}
			else if ( ( oldStatus == RosyWriterRecordingStatusRecording ) && ( newStatus == RosyWriterRecordingStatusStoppingRecording ) ) {
				delegateCallbackBlock = ^{ [_delegate capturePipelineRecordingWillStop:self]; };
			}
			else if ( ( oldStatus == RosyWriterRecordingStatusStoppingRecording ) && ( newStatus == RosyWriterRecordingStatusIdle ) ) {
				delegateCallbackBlock = ^{ [_delegate capturePipelineRecordingDidStop:self]; };
			}
		}
		
		if ( delegateCallbackBlock )
		{
			[self invokeDelegateCallbackAsync:delegateCallbackBlock];
		}
	}
}

#if LOG_STATUS_TRANSITIONS

- (NSString *)stringForRecordingStatus:(RosyWriterRecordingStatus)status
{
	NSString *statusString = nil;
	
	switch ( status )
	{
		case RosyWriterRecordingStatusIdle:
			statusString = @"Idle";
			break;
		case RosyWriterRecordingStatusStartingRecording:
			statusString = @"StartingRecording";
			break;
		case RosyWriterRecordingStatusRecording:
			statusString = @"Recording";
			break;
		case RosyWriterRecordingStatusStoppingRecording:
			statusString = @"StoppingRecording";
			break;
		default:
			statusString = @"Unknown";
			break;
	}
	return statusString;
}

#endif // LOG_STATUS_TRANSITIONS

#pragma mark Utilities

- (void)invokeDelegateCallbackAsync:(dispatch_block_t)callbackBlock
{
	dispatch_async( _delegateCallbackQueue, ^{
		@autoreleasepool {
			callbackBlock();
		}
	} );
}

// Auto mirroring: Front camera is mirrored; back camera isn't
// 自动镜像，前置摄像头镜像，后置摄像头不镜像
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror
{
	CGAffineTransform transform = CGAffineTransformIdentity;
		
	// Calculate offsets from an arbitrary reference orientation (portrait)
	CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( orientation );
	CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( _videoBufferOrientation );
	
	// Find the difference in angle between the desired orientation and the video orientation
	CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
	transform = CGAffineTransformMakeRotation( angleOffset );

	if ( _videoDevice.position == AVCaptureDevicePositionFront )
	{
		if ( mirror ) {
			transform = CGAffineTransformScale( transform, -1, 1 );
		}
		else {
			if ( UIInterfaceOrientationIsPortrait( (UIInterfaceOrientation)orientation ) ) {
				transform = CGAffineTransformRotate( transform, M_PI );
			}
		}
	}
	
	return transform;
}

static CGFloat angleOffsetFromPortraitOrientationToOrientation(AVCaptureVideoOrientation orientation)
{
	CGFloat angle = 0.0;
	
	switch ( orientation )
	{
		case AVCaptureVideoOrientationPortrait:
			angle = 0.0;
			break;
		case AVCaptureVideoOrientationPortraitUpsideDown:
			angle = M_PI;
			break;
		case AVCaptureVideoOrientationLandscapeRight:
			angle = -M_PI_2;
			break;
		case AVCaptureVideoOrientationLandscapeLeft:
			angle = M_PI_2;
			break;
		default:
			break;
	}
	
	return angle;
}

- (void)calculateFramerateAtTimestamp:(CMTime)timestamp
{
	[_previousSecondTimestamps addObject:[NSValue valueWithCMTime:timestamp]];
	
	CMTime oneSecond = CMTimeMake( 1, 1 );
	CMTime oneSecondAgo = CMTimeSubtract( timestamp, oneSecond );
	
	while( CMTIME_COMPARE_INLINE( [_previousSecondTimestamps[0] CMTimeValue], <, oneSecondAgo ) ) {
		[_previousSecondTimestamps removeObjectAtIndex:0];
	}
	
	if ( [_previousSecondTimestamps count] > 1 )
	{
		const Float64 duration = CMTimeGetSeconds( CMTimeSubtract( [[_previousSecondTimestamps lastObject] CMTimeValue], [_previousSecondTimestamps[0] CMTimeValue] ) );
		const float newRate = (float)( [_previousSecondTimestamps count] - 1 ) / duration;
		self.videoFrameRate = newRate;
	}
}

@end
