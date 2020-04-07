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
        _previewCallback([thisInstance getCVPixelBufferRefFromAVFrame:frame]);
    }
}

-(CVPixelBufferRef)getCVPixelBufferRefFromAVFrame:(AVFrame *)avframe {
    @synchronized (self) {
        if (!avframe || !avframe->data[0]) {
            return NULL;
        }

        CVPixelBufferRef outputPixelBuffer = NULL;

        NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:

                                 @(avframe->linesize[0]), kCVPixelBufferBytesPerRowAlignmentKey,
                                 [NSNumber numberWithBool:YES], kCVPixelBufferOpenGLESCompatibilityKey,
                                 [NSDictionary dictionary], kCVPixelBufferIOSurfacePropertiesKey,
                                 nil];


        if (avframe->linesize[1] != avframe->linesize[2]) {
            return  NULL;
        }

        size_t srcPlaneSize = avframe->linesize[1]*avframe->height/2;
        size_t dstPlaneSize = srcPlaneSize *2;
        uint8_t *dstPlane = malloc(dstPlaneSize);

        // interleave Cb and Cr plane
        for(size_t i = 0; i<srcPlaneSize; i++){
            dstPlane[2*i  ]=avframe->data[1][i];
            dstPlane[2*i+1]=avframe->data[2][i];
        }


        int ret = CVPixelBufferCreate(kCFAllocatorDefault,
                                      avframe->width,
                                      avframe->height,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      (__bridge CFDictionaryRef)(options),
                                      &outputPixelBuffer);

        CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);

        size_t bytePerRowY = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
        size_t bytesPerRowUV = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);

        void* base =  CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
        memcpy(base, avframe->data[0], bytePerRowY*avframe->height);

        base = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
        memcpy(base, dstPlane, bytesPerRowUV*avframe->height/2);

        CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);

        free(dstPlane);

        if(ret != kCVReturnSuccess)
        {
            NSLog(@"CVPixelBufferCreate Failed");
            return NULL;
        }

        return outputPixelBuffer;
    }
}

void cCallbackWrapper(AVFrame *frame) {
    typedef void (*send_type)(id, SEL, AVFrame*);
    send_type objective_c_func = (send_type)objc_msgSend;
    objective_c_func(thisInstance, sel_getUid("parseFrameAndPassPixelBufferRefToCallback:"), frame);
}

@end
