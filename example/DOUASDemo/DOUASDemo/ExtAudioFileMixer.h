//
//  ExtAudioFileMixer.h
//  音频的剪切与拼接
//
//  Created by 大王 on 16/5/17.
//  Copyright © 2016年 闫祥达. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

typedef void (^AudioFileFinash)();

@interface ExtAudioFileMixer : NSObject

+ (OSStatus)mixAudio:(NSURL *)audioPath1
            andAudio:(NSURL *)audioPath2
              toFile:(NSURL *)outputPath
  preferedSampleRate:(float)sampleRate
     AudioFileFinash:(AudioFileFinash)finash;

@end
