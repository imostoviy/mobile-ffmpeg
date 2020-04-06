/*
 * Copyright (c) 2018 Taner Sener
 *
 * This file is part of MobileFFmpeg.
 *
 * MobileFFmpeg is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * MobileFFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with MobileFFmpeg.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "fftools_ffmpeg.h"

#include "MobileFFmpeg.h"
#include "ArchDetect.h"
#include "MobileFFmpegConfig.h"

#import <objc/runtime.h>
#import <objc/message.h>

/** Forward declaration for function defined in fftools_ffmpeg.c */
int ffmpeg_execute(int argc, char **argv, void (*preview_callback)(AVFrame *frame), bool preview_mode);

@implementation MobileFFmpeg

/** Global library version */
NSString *const MOBILE_FFMPEG_VERSION = @"4.3.1";

extern int lastReturnCode;
extern NSMutableString *lastCommandOutput;


MobileFFmpeg *thisInstance;

- (id)init {
    if (self = [super init]) {
        thisInstance = self;
    }
    [MobileFFmpeg initialize];
    return self;
}

+ (void)initialize {
    [MobileFFmpegConfig class];

    NSLog(@"Loaded mobile-ffmpeg-%@-%@-%@-%@\n", [MobileFFmpegConfig getPackageName], [ArchDetect getArch], [MobileFFmpegConfig getVersion], [MobileFFmpegConfig getBuildDate]);
}

/**
 * Synchronously executes FFmpeg with arguments provided.
 *
 * @param arguments FFmpeg command options/arguments as string array
 * @return zero on successful execution, 255 on user cancel and non-zero on error
 */
- (int)executeWithArguments: (NSArray*)arguments isPreview: (bool) is_preview {
    lastCommandOutput = [[NSMutableString alloc] init];

    char **commandCharPArray = (char **)av_malloc(sizeof(char*) * ([arguments count] + 1));

    /* PRESERVING CALLING FORMAT
     *
     * ffmpeg <arguments>
     */
    commandCharPArray[0] = (char *)av_malloc(sizeof(char) * ([LIB_NAME length] + 1));
    strcpy(commandCharPArray[0], [LIB_NAME UTF8String]);

    for (int i=0; i < [arguments count]; i++) {
        NSString *argument = [arguments objectAtIndex:i];
        commandCharPArray[i + 1] = (char *) [argument UTF8String];
    }

    // RUN
    lastReturnCode = ffmpeg_execute(([arguments count] + 1), commandCharPArray, &cCallbackWrapper, is_preview);

    // CLEANUP
    av_free(commandCharPArray[0]);
    av_free(commandCharPArray);

    return lastReturnCode;
}

/**
 * Synchronously executes FFmpeg command provided. Space character is used to split command
 * into arguments.
 *
 * @param command FFmpeg command
 * @return zero on successful execution, 255 on user cancel and non-zero on error
 */
- (int)execute: (NSString*)command {
    return [self executeWithArguments: [MobileFFmpeg parseArguments: command] isPreview: false];
}

- (int)executePreview: (NSString*)command {
    return [self executeWithArguments: [MobileFFmpeg parseArguments: command] isPreview: true];
}

/**
 * Synchronously executes FFmpeg command provided. Delimiter parameter is used to split
 * command into arguments.
 *
 * @param command FFmpeg command
 * @param delimiter arguments delimiter
 * @return zero on successful execution, 255 on user cancel and non-zero on error
 */
- (int)execute: (NSString*)command delimiter:(NSString*)delimiter {

    // SPLITTING ARGUMENTS
    NSArray* argumentArray = [command componentsSeparatedByString:(delimiter == nil ? @" ": delimiter)];
    return [self executeWithArguments:argumentArray isPreview: false];
}

/**
 * Cancels an ongoing operation.
 *
 * This function does not wait for termination to complete and returns immediately.
 */
- (void)cancel {
    cancel_operation();
}

/**
 * Parses the given command into arguments.
 *
 * @param command string command
 * @return array of arguments
 */
+ (NSArray*)parseArguments: (NSString*)command {
    NSMutableArray *argumentArray = [[NSMutableArray alloc] init];
    NSMutableString *currentArgument = [[NSMutableString alloc] init];

    bool singleQuoteStarted = false;
    bool doubleQuoteStarted = false;

    for (int i = 0; i < command.length; i++) {
        unichar previousChar;
        if (i > 0) {
            previousChar = [command characterAtIndex:(i - 1)];
        } else {
            previousChar = 0;
        }
        unichar currentChar = [command characterAtIndex:i];

        if (currentChar == ' ') {
            if (singleQuoteStarted || doubleQuoteStarted) {
                [currentArgument appendFormat: @"%C", currentChar];
            } else if ([currentArgument length] > 0) {
                [argumentArray addObject: currentArgument];
                currentArgument = [[NSMutableString alloc] init];
            }
        } else if (currentChar == '\'' && (previousChar == 0 || previousChar != '\\')) {
            if (singleQuoteStarted) {
                singleQuoteStarted = false;
            } else if (doubleQuoteStarted) {
                [currentArgument appendFormat: @"%C", currentChar];
            } else {
                singleQuoteStarted = true;
            }
        } else if (currentChar == '\"' && (previousChar == 0 || previousChar != '\\')) {
            if (doubleQuoteStarted) {
                doubleQuoteStarted = false;
            } else if (singleQuoteStarted) {
                [currentArgument appendFormat: @"%C", currentChar];
            } else {
                doubleQuoteStarted = true;
            }
        } else {
            [currentArgument appendFormat: @"%C", currentChar];
        }
    }

    if ([currentArgument length] > 0) {
        [argumentArray addObject: currentArgument];
    }

    return argumentArray;
}

-(void) parseFrameAndPassPixelBufferRefToCallback: (AVFrame *) frame {
    if (_previewCallback != nil) {
        CVPixelBufferRef pbuf = NULL;
        [self getPixelBuffer:pbuf from:frame];
        _previewCallback(&pbuf);
    }
}

-(void)getPixelBuffer:(CVPixelBufferRef *)pbuf from:(AVFrame *)frame {
    @synchronized (self) {
        
        if(!frame || !frame->data[0])
            return;
        
        NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                                 @(frame->linesize[0]), kCVPixelBufferBytesPerRowAlignmentKey,
                                 [NSNumber numberWithBool:YES], kCVPixelBufferOpenGLESCompatibilityKey,
                                 [NSDictionary dictionary], kCVPixelBufferIOSurfacePropertiesKey,
                                 nil];
        
        
        if (frame->linesize[1] != frame->linesize[2]) {
            return;
        }
        
        size_t srcPlaneSize = frame->linesize[1]*frame->height/2;
        size_t dstPlaneSize = srcPlaneSize *2;
        uint8_t *dstPlane = malloc(dstPlaneSize);
        
        // interleave Cb and Cr plane
        for(size_t i = 0; i<srcPlaneSize; i++){
            dstPlane[2*i  ]=frame->data[1][i];
            dstPlane[2*i+1]=frame->data[2][i];
        }
        
        
        int ret = CVPixelBufferCreate(kCFAllocatorDefault,
                                      frame->width,
                                      frame->height,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      (__bridge CFDictionaryRef)(options),
                                      pbuf);
        
        CVPixelBufferLockBaseAddress(*pbuf, 0);
        
        size_t bytePerRowY = CVPixelBufferGetBytesPerRowOfPlane(*pbuf, 0);
        size_t bytesPerRowUV = CVPixelBufferGetBytesPerRowOfPlane(*pbuf, 1);
        
        void* base =  CVPixelBufferGetBaseAddressOfPlane(*pbuf, 0);
        memcpy(base, frame->data[0], bytePerRowY*frame->height);
        
        base = CVPixelBufferGetBaseAddressOfPlane(*pbuf, 1);
        memcpy(base, dstPlane, bytesPerRowUV*frame->height/2);
        
        
        CVPixelBufferUnlockBaseAddress(*pbuf, 0);
        
        free(dstPlane);
        
        
        if(ret != kCVReturnSuccess)
        {
            NSLog(@"CVPixelBufferCreate Failed");
        }
        
    }
}

void cCallbackWrapper(AVFrame *frame) {
    typedef void (*send_type)(id, SEL, AVFrame*);
    send_type objective_c_func = (send_type)objc_msgSend;
    objective_c_func(thisInstance, sel_getUid("parseFrameAndPassPixelBufferRefToCallback:"), frame);
}

@end
