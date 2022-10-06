//
//  MR0x32VideoRenderer.h
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2022/7/20.
//  Copyright © 2021 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import <CoreMedia/CMSampleBuffer.h>
#import "MR0x32VideoRendererProtocol.h"
#import "MRPlatform.h"

NS_ASSUME_NONNULL_BEGIN

@interface MR0x32VideoRenderer : UIView <MR0x32VideoRendererProtocol>

- (void)displaySampleBuffer:(CMSampleBufferRef)buffer;
- (void)cleanScreen;

@end

NS_ASSUME_NONNULL_END
