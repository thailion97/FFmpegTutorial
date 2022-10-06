//
//  FFPlayer0x32.m
//  FFmpegTutorial
//
//  Created by qianlongxu on 2022/7/20.
//

#import "FFPlayer0x32.h"
#import "MRThread.h"
#include <libavutil/pixdesc.h>
#include <libavformat/avformat.h>
#import "FFDecoder0x32.h"
#import "FFVideoScale.h"
#import "FFAudioResample.h"
#import "MRDispatch.h"
#import "FFPacketQueue.h"
#import "MRConvertUtil.h"
#import "MR0x32VideoFrameQueue.h"
#import "MR0x32VideoRenderer.h"
#import "MRAbstractLogger.h"

//视频宽；单位像素
kFFPlayer0x32InfoKey kFFPlayer0x32Width = @"kFFPlayer0x32Width";
//视频高；单位像素
kFFPlayer0x32InfoKey kFFPlayer0x32Height = @"kFFPlayer0x32Height";

@interface  FFPlayer0x32 ()<FFDecoderDelegate0x32>
{
    //音频流解码器
    FFDecoder0x32 *_audioDecoder;
    //视频流解码器
    FFDecoder0x32 *_videoDecoder;
    
    //图像格式转换/缩放器
    FFVideoScale *_videoScale;
    //音频重采样
    FFAudioResample *_audioResample;
    
    FFPacketQueue *_packetQueue;
    
    MR0x32VideoFrameQueue *_videoFrameQueue;
    //视频尺寸
    CGSize _videoSize;
    AVFormatContext * _formatCtx;
    //读包完毕？
    int _eof;
}

//读包线程
@property (nonatomic, strong) MRThread *readThread;
@property (nonatomic, strong) MRThread *decoderThread;
@property (nonatomic, strong) MRThread *videoThread;

@property (atomic, assign) int abort_request;
@property (nonatomic, copy) dispatch_block_t onErrorBlock;
@property (atomic, assign, readwrite) int videoPktCount;
@property (atomic, assign, readwrite) int audioPktCount;
@property (atomic, assign, readwrite) int videoFrameCount;
@property (atomic, assign, readwrite) int audioFrameCount;

@end

@implementation  FFPlayer0x32

static int decode_interrupt_cb(void *ctx)
{
    FFPlayer0x32 *player = (__bridge FFPlayer0x32 *)ctx;
    return player.abort_request;
}

- (void)_stop
{
    self.abort_request = 1;
    [_packetQueue cancel];
    [_videoFrameQueue cancel];
    
    //避免重复stop做无用功
    if (self.readThread) {
        [self.readThread cancel];
        [self.readThread join];
    }
    
    if (self.decoderThread) {
        [self.decoderThread cancel];
        [self.decoderThread join];
    }
    
    if (self.videoThread) {
        [self.videoThread cancel];
        [self.videoThread join];
    }
    
    //读包线程结束了，销毁下相关结构体
    avformat_close_input(&_formatCtx);
    [self performSelectorOnMainThread:@selector(didStop:) withObject:self waitUntilDone:YES];
}

- (void)didStop:(id)sender
{
    self.readThread = nil;
}

- (void)dealloc
{
    PRINT_DEALLOC;
}

//准备
- (void)prepareToPlay
{
    if (self.readThread) {
        NSAssert(NO, @"不允许重复创建");
    }
    
    _packetQueue = [[FFPacketQueue alloc] init];
    
    self.readThread = [[MRThread alloc] initWithTarget:self selector:@selector(readPacketsFunc) object:nil];
    self.readThread.name = @"mr-read";
    
    self.decoderThread = [[MRThread alloc] initWithTarget:self selector:@selector(decoderFunc) object:nil];
    self.decoderThread.name = @"mr-decoder";
    
    self.videoThread = [[MRThread alloc] initWithTarget:self selector:@selector(videoThreadFunc) object:nil];
    self.videoThread.name = @"mr-v-display";
}

#pragma -mark 读包线程
//读包循环
- (void)readPacketLoop:(AVFormatContext *)formatCtx
{
    AVPacket pkt1, *pkt = &pkt1;
    //创建一个frame就行了，可以复用
    AVFrame *frame = av_frame_alloc();
    //循环读包
    for (;;) {
        
        //调用了stop方法，则不再读包
        if (self.abort_request) {
            break;
        }
        
        //读包
        int ret = av_read_frame(formatCtx, pkt);
        //读包出错
        if (ret < 0) {
            //读到最后结束了
            if ((ret == AVERROR_EOF || avio_feof(formatCtx->pb))) {
                //标志为读包结束
                av_log(NULL, AV_LOG_DEBUG, "stream eof:%s\n",formatCtx->url);
                //send null packet,let decoder eof.
                pkt->data = NULL;
                pkt->size = 0;
                pkt->stream_index = _videoDecoder.streamIdx;
                [_packetQueue enQueue:pkt];
                pkt->stream_index = _audioDecoder.streamIdx;
                [_packetQueue enQueue:pkt];
                break;
            }
            
            if (formatCtx->pb && formatCtx->pb->error) {
                break;
            }
            
            /* wait 10 ms */
            mr_msleep(10);
            continue;
        } else {
            AVStream *stream = _formatCtx->streams[pkt->stream_index];
            switch (stream->codecpar->codec_type) {
                case AVMEDIA_TYPE_VIDEO:
                {
                    if (pkt->data != NULL) {
                        self.videoPktCount++;
                    }
                    [_packetQueue enQueue:pkt];
                }
                    break;
                case AVMEDIA_TYPE_AUDIO:
                {
                    if (pkt->data != NULL) {
                        self.audioPktCount++;
                    }
                    [_packetQueue enQueue:pkt];
                }
                    break;
                default:
                    break;
            }
            if (self.onReadPkt) {
                self.onReadPkt(self.audioPktCount,self.videoPktCount);
            }
        }
    }
    
    av_frame_free(&frame);
}

#pragma mark - 查找最优的音视频流
- (void)findBestStreams:(AVFormatContext *)formatCtx result:(int (*) [AVMEDIA_TYPE_NB])st_index {

    int first_video_stream = -1;
    int first_h264_stream = -1;
    //查找H264格式的视频流
    for (int i = 0; i < formatCtx->nb_streams; i++) {
        AVStream *st = formatCtx->streams[i];
        enum AVMediaType type = st->codecpar->codec_type;
        st->discard = AVDISCARD_ALL;

        if (type == AVMEDIA_TYPE_VIDEO) {
            enum AVCodecID codec_id = st->codecpar->codec_id;
            if (codec_id == AV_CODEC_ID_H264) {
                if (first_h264_stream < 0) {
                    first_h264_stream = i;
                    break;
                }
                if (first_video_stream < 0) {
                    first_video_stream = i;
                }
            }
        }
    }
    //h264优先
    (*st_index)[AVMEDIA_TYPE_VIDEO] = first_h264_stream != -1 ? first_h264_stream : first_video_stream;
    //根据上一步确定的视频流查找最优的视频流
    (*st_index)[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, (*st_index)[AVMEDIA_TYPE_VIDEO], -1, NULL, 0);
    //参照视频流查找最优的音频流
    (*st_index)[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, (*st_index)[AVMEDIA_TYPE_AUDIO], (*st_index)[AVMEDIA_TYPE_VIDEO], NULL, 0);
}

- (void)readPacketsFunc
{
    NSParameterAssert(self.contentPath);
        
    if (![self.contentPath hasPrefix:@"/"]) {
        avformat_network_init();
    }
    
    AVFormatContext *formatCtx = avformat_alloc_context();
    
    if (!formatCtx) {
        self.error = _make_nserror_desc(FFPlayerErrorCode_AllocFmtCtxFailed, @"创建 AVFormatContext 失败！");
        [self performErrorResultOnMainThread];
        return;
    }
    
    formatCtx->interrupt_callback.callback = decode_interrupt_cb;
    formatCtx->interrupt_callback.opaque = (__bridge void *)self;
    
    /*
     打开输入流，读取文件头信息，不会打开解码器；
     */
    //低版本是 av_open_input_file 方法
    const char *moviePath = [self.contentPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    //打开文件流，读取头信息；
    if (0 != avformat_open_input(&formatCtx, moviePath , NULL, NULL)) {
        //释放内存
        avformat_free_context(formatCtx);
        //当取消掉时，不给上层回调
        if (self.abort_request) {
            return;
        }
        self.error = _make_nserror_desc(FFPlayerErrorCode_OpenFileFailed, @"文件打开失败！");
        [self performErrorResultOnMainThread];
        return;
    }
    
    /* 刚才只是打开了文件，检测了下文件头而已，并不知道流信息；因此开始读包以获取流信息
     设置读包探测大小和最大时长，避免读太多的包！
    */
    formatCtx->probesize = 500 * 1024;
    formatCtx->max_analyze_duration = 5 * AV_TIME_BASE;
#if DEBUG
    NSTimeInterval begin = [[NSDate date] timeIntervalSinceReferenceDate];
#endif
    if (0 != avformat_find_stream_info(formatCtx, NULL)) {
        avformat_close_input(&formatCtx);
        self.error = _make_nserror_desc(FFPlayerErrorCode_StreamNotFound, @"不能找到流！");
        [self performErrorResultOnMainThread];
        //出错了，销毁下相关结构体
        avformat_close_input(&formatCtx);
        return;
    }
    
#if DEBUG
    NSTimeInterval end = [[NSDate date] timeIntervalSinceReferenceDate];
    //用于查看详细信息，调试的时候打出来看下很有必要
    av_dump_format(formatCtx, 0, moviePath, false);
    
    MRFF_DEBUG_LOG(@"avformat_find_stream_info coast time:%g",end-begin);
#endif
    
    //确定最优的音视频流
    int st_index[AVMEDIA_TYPE_NB];
    memset(st_index, -1, sizeof(st_index));
    [self findBestStreams:formatCtx result:&st_index];
    
    //打开解码器，创建解码线程
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0){
        _audioDecoder = [self openStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_AUDIO]];
        if (!_audioDecoder) {
            av_log(NULL, AV_LOG_ERROR, "can't open audio stream.");
            self.error = _make_nserror_desc(FFPlayerErrorCode_AudioDecoderOpenFailed, @"音频解码器打开失败！");
            [self performErrorResultOnMainThread];
            //出错了，销毁下相关结构体
            avformat_close_input(&formatCtx);
            return;
        } else {
            _audioResample = [self createAudioResampleIfNeed];
        }
    }
    
    NSMutableDictionary *dumpDic = [NSMutableDictionary dictionary];
    
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0){
        _videoDecoder = [self openStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_VIDEO]];
        if (!_videoDecoder) {
            av_log(NULL, AV_LOG_ERROR, "can't open video stream.");
            self.error = _make_nserror_desc(FFPlayerErrorCode_VideoDecoderOpenFailed, @"音频解码器打开失败！");
            [self performErrorResultOnMainThread];
            //出错了，销毁下相关结构体
            avformat_close_input(&formatCtx);
            return;
        } else {
            _videoSize = CGSizeMake(_videoDecoder.picWidth, _videoDecoder.picHeight);
            [dumpDic setObject:@(_videoDecoder.picWidth) forKey:kFFPlayer0x32Width];
            [dumpDic setObject:@(_videoDecoder.picHeight) forKey:kFFPlayer0x32Height];
            _videoScale = [self createVideoScaleIfNeed];
        }
    }
    
    _videoFrameQueue = [[MR0x32VideoFrameQueue alloc] init];
    
    mr_sync_main_queue(^{
        if (self.onStreamOpened) {
            self.onStreamOpened(dumpDic);
        }
    });
    
    _formatCtx = formatCtx;
    [self.decoderThread start];
    [self.videoThread start];
    //循环读包
    [self readPacketLoop:formatCtx];
}

#pragma mark - 视频像素格式转换

- (FFVideoScale *)createVideoScaleIfNeed
{
    //未指定期望像素格式
    if (self.supportedPixelFormat == MR_PIX_FMT_NONE) {
        NSAssert(NO, @"supportedPixelFormats can't be none!");
        return nil;
    }
    
    //当前视频的像素格式
    const enum AVPixelFormat format = _videoDecoder.format;
    
    bool matched = false;
    MRPixelFormat firstSupportedFmt = MR_PIX_FMT_NONE;
    for (int i = MR_PIX_FMT_BEGIN; i <= MR_PIX_FMT_END; i ++) {
        const MRPixelFormat fmt = i;
        if (self.supportedPixelFormat == fmt) {
            if (firstSupportedFmt == MR_PIX_FMT_NONE) {
                firstSupportedFmt = fmt;
            }
            
            if (format == MRPixelFormat2AV(fmt)) {
                matched = true;
                break;
            }
        }
    }
    
    if (matched) {
        //期望像素格式包含了当前视频像素格式，则直接使用当前格式，不再转换。
        return nil;
    }
    
    if (firstSupportedFmt == MR_PIX_FMT_NONE) {
        NSAssert(NO, @"supportedPixelFormats is invalid!");
        return nil;
    }
    
    int dest = MRPixelFormat2AV(firstSupportedFmt);
    if ([FFVideoScale checkCanConvertFrom:format to:dest]) {
        //创建像素格式转换上下文
        av_log(NULL, AV_LOG_INFO, "will scale %d to %d (%dx%d)",format,dest,_videoDecoder.picWidth,_videoDecoder.picHeight);
        FFVideoScale *scale = [[FFVideoScale alloc] initWithSrcPixFmt:format dstPixFmt:dest picWidth:_videoDecoder.picWidth picHeight:_videoDecoder.picHeight];
        return scale;
    } else {
        NSAssert(NO, @"can't scale from %d to %d",format,dest);
        return nil;
    }
}

//音频重采样
- (FFAudioResample *)createAudioResampleIfNeed
{
    //未指定期望音频格式
    if (self.supportedSampleFormat == MR_SAMPLE_FMT_NONE) {
        NSAssert(NO, @"supportedSampleFormats can't be none!");
        return nil;
    }
    
    //未指定支持的比特率就使用目标音频的
    if (self.supportedSampleRate == 0) {
        self.supportedSampleRate = _audioDecoder.sampleRate;
    }
    
    //当前视频的像素格式
    const enum AVSampleFormat format = _audioDecoder.format;
    
    bool matched = false;
    MRSampleFormat firstSupportedFmt = MR_SAMPLE_FMT_NONE;
    for (int i = MR_SAMPLE_FMT_BEGIN; i <= MR_SAMPLE_FMT_END; i ++) {
        const MRSampleFormat fmt = i;
        if (self.supportedSampleFormat == fmt) {
            if (firstSupportedFmt == MR_SAMPLE_FMT_NONE) {
                firstSupportedFmt = fmt;
            }
            
            if (format == MRSampleFormat2AV(fmt)) {
                matched = true;
                break;
            }
        }
    }
    
    if (matched) {
        //采样率不匹配
        if (self.supportedSampleRate != _audioDecoder.sampleRate) {
            firstSupportedFmt = AVSampleFormat2MR(format);
            matched = NO;
        }
    }
    
    if (matched) {
        //期望音频格式包含了当前音频格式，则直接使用当前格式，不再转换。
        av_log(NULL, AV_LOG_INFO, "audio not need resample!\n");
        return nil;
    }
    
    if (firstSupportedFmt == MR_SAMPLE_FMT_NONE) {
        NSAssert(NO, @"supportedSampleFormats is invalid!");
        return nil;
    }
    
    //创建音频格式转换上下文
    FFAudioResample *resample = [[FFAudioResample alloc] initWithSrcSampleFmt:format
                                                                         dstSampleFmt:MRSampleFormat2AV(firstSupportedFmt)
                                                                   srcChannel:_audioDecoder.channelLayout
                                                                           dstChannel:_audioDecoder.channelLayout
                                                                              srcRate:_audioDecoder.sampleRate
                                                                              dstRate:self.supportedSampleRate];
    return resample;
}

#pragma mark - 解码


- (FFDecoder0x32 *)openStreamComponent:(AVFormatContext *)ic streamIdx:(int)idx
{
    FFDecoder0x32 *decoder = [FFDecoder0x32 new];
    decoder.ic = ic;
    decoder.streamIdx = idx;
    if ([decoder open] == 0) {
        decoder.delegate = self;
        return decoder;
    } else {
        return nil;
    }
}

- (void)decodePkt:(AVPacket *)pkt
{
    AVStream *stream = _formatCtx->streams[pkt->stream_index];
    switch (stream->codecpar->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
        {
            [_videoDecoder sendPacket:pkt];
        }
            break;
        case AVMEDIA_TYPE_AUDIO:
        {
            [_audioDecoder sendPacket:pkt];
        }
            break;
        default:
            break;
    }
}

- (void)decoderFunc
{
    while (!self.abort_request) {
        __weakSelf__
        [_packetQueue deQueue:^(AVPacket * pkt) {
            __strongSelf__
            if (pkt) {
                [self decodePkt:pkt];
            }
        }];
    }
}

#pragma mark - FFDecoderDelegate0x32

- (void)decoder:(FFDecoder0x32 *)decoder reveivedAFrame:(AVFrame *)aFrame
{
    if (decoder == _audioDecoder) {
        AVFrame *audioFrame = nil;
        if (_audioResample) {
            if (![_audioResample resampleFrame:aFrame out:&audioFrame]) {
                self.error = _make_nserror_desc(FFPlayerErrorCode_ResampleFrameFailed, @"音频帧重采样失败！");
                [self performErrorResultOnMainThread];
                return;
            }
        } else {
            audioFrame = aFrame;
        }
        
        self.audioFrameCount++;
        if (self.onDecoderAudioFrame) {
            self.onDecoderAudioFrame(self.audioFrameCount, audioFrame);
        }
    } else if (decoder == _videoDecoder) {
        AVFrame *videoFrame = nil;
        if (_videoScale) {
            if (![_videoScale rescaleFrame:aFrame out:&videoFrame]) {
                self.error = _make_nserror_desc(FFPlayerErrorCode_RescaleFrameFailed, @"视频帧重转失败！");
                [self performErrorResultOnMainThread];
                return;
            }
        } else {
            videoFrame = aFrame;
        }
        
        self.videoFrameCount++;
        [self enQueueVideoFrame:videoFrame];
    }
}

#pragma - mark Video

- (void)videoThreadFunc
{
    while (!_abort_request) {
        NSTimeInterval begin = CFAbsoluteTimeGetCurrent();
        [_videoFrameQueue asyncDeQueue:^(AVFrame * _Nullable frame) {
            if (frame) {
                [self displayVideoFrame:frame];
            } else {
                NSLog(@"has no video frame to display.");
            }
        }];
        NSTimeInterval end = CFAbsoluteTimeGetCurrent();
        int remained = 33 - (end - begin) * 1000;
        if (remained > 0) {
            mr_msleep(remained);
        }
    }
}

- (void)enQueueVideoFrame:(AVFrame *)frame
{
    const char *fmt_str = av_pixel_fmt_to_string(frame->format);
    
    self.videoPixelInfo = [NSString stringWithFormat:@"(%s)%dx%d",fmt_str,frame->width,frame->height];
    [_videoFrameQueue enQueue:frame];
}

- (void)displayVideoFrame:(AVFrame *)frame
{
    @autoreleasepool {
        CVPixelBufferRef pixelBuffer = [MRConvertUtil pixelBufferFromAVFrame:frame opt:NULL];
        CMSampleBufferRef sample = [MRConvertUtil cmSampleBufferRefFromCVPixelBufferRef:pixelBuffer];
        CFRetain(sample);
        mr_sync_main_queue(^{
            [[self _videoRender] displaySampleBuffer:sample];
            CFRelease(sample);
        });
    }
}

- (void)performErrorResultOnMainThread
{
    mr_sync_main_queue(^{
        if (self.onError) {
            self.onError(self.error);
        }
    });
}

- (void)play
{
    [self.readThread start];
}

- (void)asyncStop
{
    [self performSelectorInBackground:@selector(_stop) withObject:self];
}

- (void)onError:(dispatch_block_t)block
{
    self.onErrorBlock = block;
}

- (int)videoFrameQueueSize
{
    return (int)[_videoFrameQueue size];
}

- (MR0x32VideoRenderer *)_videoRender
{
    return (MR0x32VideoRenderer *)_videoRender;
}

- (UIView<MR0x32VideoRendererProtocol> *)videoRender
{
    if (!_videoRender) {
        MR0x32VideoRenderer * videoRender = [[MR0x32VideoRenderer alloc] init];
        _videoRender = videoRender;
    }
    return _videoRender;
}

@end
