/* vim: set ft=objc fenc=utf-8 sw=2 ts=2 et: */
/*
 *  DOUAudioStreamer - A Core Audio based streaming audio player for iOS/Mac:
 *
 *      http://github.com/douban/DOUAudioStreamer
 *
 *  Copyright 2013 Douban Inc.  All rights reserved.
 *
 *  Use and distribution licensed under the BSD license.  See
 *  the LICENSE file for full text.
 *
 *  Authors:
 *      Chongyu Zhu <lembacon@gmail.com>
 *
 */

#import "DOUAudioEventLoop.h"
#import "DOUAudioStreamer.h"
#import "DOUAudioStreamer_Private.h"
#import "DOUAudioFileProvider.h"
#import "DOUAudioPlaybackItem.h"
#import "DOUAudioLPCM.h"
#import "DOUAudioDecoder.h"
#import "DOUAudioRenderer.h"
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <pthread.h>
#include <sched.h>

static const NSUInteger kBufferTime = 200;
static NSString *const kVolumeKey = @"DOUAudioStreamerVolume";

typedef NS_ENUM(uint64_t, event_type) {
  event_play,
  event_pause,
  event_streamer_changed,
  event_provider_events,
  event_finalizing,
#if TARGET_OS_IPHONE
  event_interruption_begin,
  event_interruption_end,
#endif /* TARGET_OS_IPHONE */

  event_first = event_play,
#if TARGET_OS_IPHONE
  event_last = event_interruption_end,
#else /* TARGET_OS_IPHONE */
  event_last = event_finalizing,
#endif /* TARGET_OS_IPHONE */

  event_timeout
};

@interface DOUAudioEventLoop () {
@private
  DOUAudioRenderer *_renderer;
  DOUAudioStreamer *_currentStreamer;

  NSUInteger _decoderBufferSize;
  DOUAudioFileProviderEventBlock _fileProviderEventBlock;

  int _kq;
  pthread_mutex_t _mutex;
  pthread_t _thread;
}
@end

@implementation DOUAudioEventLoop

@synthesize currentStreamer = _currentStreamer;

+ (instancetype)sharedEventLoop
{
  static DOUAudioEventLoop *sharedEventLoop = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedEventLoop = [[DOUAudioEventLoop alloc] init];
  });

  return sharedEventLoop;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _kq = kqueue();
    pthread_mutex_init(&_mutex, NULL);

    _renderer = [DOUAudioRenderer rendererWithBufferTime:kBufferTime];
    [_renderer setUp];

    if ([[NSUserDefaults standardUserDefaults] objectForKey:kVolumeKey] != nil) {
      [self setVolume:[[NSUserDefaults standardUserDefaults] doubleForKey:kVolumeKey]];
    }
    else {
      [self setVolume:1.0];
    }

    _decoderBufferSize = [[self class] _decoderBufferSize];
#if TARGET_OS_IPHONE
    [self _setupAudioSession];
#endif /* TARGET_OS_IPHONE */
    [self _setupFileProviderEventBlock];
    [self _enableEvents];
    [self _createThread];
  }

  return self;
}

- (void)dealloc
{
  [self _sendEvent:event_finalizing];
  pthread_join(_thread, NULL);

  close(_kq);
  pthread_mutex_destroy(&_mutex);
}

+ (NSUInteger)_decoderBufferSize
{
  AudioStreamBasicDescription format = [DOUAudioDecoder defaultOutputFormat];
  return kBufferTime * format.mSampleRate * format.mChannelsPerFrame * format.mBitsPerChannel / 8 / 1000;
}

#if TARGET_OS_IPHONE

- (void)_handleAudioSessionInterruptionWithState:(UInt32)state
{
  if (state == kAudioSessionBeginInterruption) {
    [_renderer stop];
    [self _sendEvent:event_interruption_begin];
  }
  else if (state == kAudioSessionEndInterruption) {
    [self _sendEvent:event_interruption_end];
  }
}

static void audio_session_interruption_listener(void *inClientData, UInt32 inInterruptionState)
{
  __unsafe_unretained DOUAudioEventLoop *eventLoop = (__bridge DOUAudioEventLoop *)inClientData;
  [eventLoop _handleAudioSessionInterruptionWithState:inInterruptionState];
}

static void audio_route_change_listener(void *inClientData,
                                        AudioSessionPropertyID inID,
                                        UInt32 inDataSize,
                                        const void *inData)
{
  if (inID != kAudioSessionProperty_AudioRouteChange) {
    return;
  }

  CFDictionaryRef routeChangeDictionary = (CFDictionaryRef)inData;
  CFNumberRef routeChangeReasonRef = CFDictionaryGetValue(routeChangeDictionary,
                                                          CFSTR(kAudioSession_AudioRouteChangeKey_Reason));

  SInt32 routeChangeReason;
  CFNumberGetValue(routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);

  if (routeChangeReason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) {
    __unsafe_unretained DOUAudioEventLoop *eventLoop = (__bridge DOUAudioEventLoop *)inClientData;
    [eventLoop pause];
  }
}

- (void)_setupAudioSession
{
  AudioSessionInitialize(NULL, NULL, audio_session_interruption_listener, (__bridge void *)self);

  UInt32 audioCategory = kAudioSessionCategory_MediaPlayback;
  AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory);

  AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audio_route_change_listener, (__bridge void *)self);

  AudioSessionSetActive(TRUE);
}

#endif /* TARGET_OS_IPHONE */

- (void)_setupFileProviderEventBlock
{
  __unsafe_unretained DOUAudioEventLoop *eventLoop = self;
  _fileProviderEventBlock = ^{
    [eventLoop _sendEvent:event_provider_events];
  };
}

- (void)_enableEvents
{
  for (uint64_t event = event_first; event <= event_last; ++event) {
    struct kevent kev;
    EV_SET(&kev, event, EVFILT_USER, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, NULL);
    kevent(_kq, &kev, 1, NULL, 0, NULL);
  }
}

- (void)_sendEvent:(event_type)event
{
  struct kevent kev;
  EV_SET(&kev, event, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
  kevent(_kq, &kev, 1, NULL, 0, NULL);
}

- (event_type)_waitForEvent
{
  return [self _waitForEventWithTimeout:NSUIntegerMax];
}

- (event_type)_waitForEventWithTimeout:(NSUInteger)timeout
{
  struct timespec _ts;
  struct timespec *ts = NULL;
  if (timeout != NSUIntegerMax) {
    ts = &_ts;

    ts->tv_sec = timeout / 1000;
    ts->tv_nsec = (timeout % 1000) * 1000;
  }

  while (1) {
    struct kevent kev;
    int n = kevent(_kq, NULL, 0, &kev, 1, ts);
    if (n > 0) {
      if (kev.filter == EVFILT_USER &&
          kev.ident >= event_first &&
          kev.ident <= event_last) {
        return kev.ident;
      }
    }
    else {
      break;
    }
  }

  return event_timeout;
}

- (BOOL)_handleEvent:(event_type)event withStreamer:(DOUAudioStreamer **)streamer
{
  if (event == event_play) {
    if (*streamer != nil &&
        [*streamer status] == DOUAudioStreamerPaused) {
      [*streamer setStatus:DOUAudioStreamerPlaying];
    }
  }
  else if (event == event_pause) {
    if (*streamer != nil &&
        [*streamer status] != DOUAudioStreamerPaused) {
      [_renderer stop];
      [*streamer setStatus:DOUAudioStreamerPaused];
    }
  }
  else if (event == event_streamer_changed) {
    [_renderer stop];
    [_renderer flush];

    [[*streamer fileProvider] setEventBlock:NULL];
    *streamer = _currentStreamer;
    [[*streamer fileProvider] setEventBlock:_fileProviderEventBlock];
  }
  else if (event == event_provider_events) {
    if (*streamer != nil &&
        [*streamer status] == DOUAudioStreamerBuffering) {
      [*streamer setStatus:DOUAudioStreamerPlaying];
    }
  }
  else if (event == event_finalizing) {
    return NO;
  }
#if TARGET_OS_IPHONE
  else if (event == event_interruption_begin) {
    if (*streamer != nil &&
        [*streamer status] != DOUAudioStreamerPaused) {
      [self performSelector:@selector(pause) onThread:[NSThread mainThread] withObject:nil waitUntilDone:NO];
      [*streamer setPausedByInterruption:YES];
    }
  }
  else if (event == event_interruption_end) {
    AudioSessionSetActive(TRUE);

    if (*streamer != nil &&
        [*streamer status] == DOUAudioStreamerPaused &&
        [*streamer isPausedByInterruption]) {
      [*streamer setPausedByInterruption:NO];
      [self performSelector:@selector(play) onThread:[NSThread mainThread] withObject:nil waitUntilDone:NO];
    }
  }
#endif /* TARGET_OS_IPHONE */
  else if (event == event_timeout) {
  }

  return YES;
}

- (void)_handleStreamer:(DOUAudioStreamer *)streamer
{
  if (streamer == nil) {
    return;
  }

  if ([streamer status] != DOUAudioStreamerPlaying) {
    return;
  }

  if ([[streamer fileProvider] isFailed]) {
    [streamer setError:[NSError errorWithDomain:kDOUAudioStreamerErrorDomain
                                           code:DOUAudioStreamerNetworkError
                                       userInfo:nil]];
    [streamer setStatus:DOUAudioStreamerError];
    return;
  }

  if (![[streamer fileProvider] isReady]) {
    [streamer setStatus:DOUAudioStreamerBuffering];
    return;
  }

  if ([streamer playbackItem] == nil) {
    [streamer setPlaybackItem:[DOUAudioPlaybackItem playbackItemWithFileProvider:[streamer fileProvider]]];
    if (![[streamer playbackItem] open]) {
      [streamer setError:[NSError errorWithDomain:kDOUAudioStreamerErrorDomain
                                             code:DOUAudioStreamerDecodingError
                                         userInfo:nil]];
      [streamer setStatus:DOUAudioStreamerError];
      return;
    }

    [streamer setDuration:(NSTimeInterval)[[streamer playbackItem] estimatedDuration] / 1000.0];
  }

  if ([streamer decoder] == nil) {
    [streamer setDecoder:[DOUAudioDecoder decoderWithPlaybackItem:[streamer playbackItem]
                                                       bufferSize:_decoderBufferSize]];
    if (![[streamer decoder] setUp]) {
      [streamer setError:[NSError errorWithDomain:kDOUAudioStreamerErrorDomain
                                             code:DOUAudioStreamerDecodingError
                                         userInfo:nil]];
      [streamer setStatus:DOUAudioStreamerError];
      return;
    }
  }

  switch ([[streamer decoder] decodeOnce]) {
  case DOUAudioDecoderSucceeded:
    break;

  case DOUAudioDecoderFailed:
    [streamer setError:[NSError errorWithDomain:kDOUAudioStreamerErrorDomain
                                           code:DOUAudioStreamerDecodingError
                                       userInfo:nil]];
    [streamer setStatus:DOUAudioStreamerError];
    return;

  case DOUAudioDecoderEndEncountered:
    [streamer setStatus:DOUAudioStreamerFinished];
    return;

  case DOUAudioDecoderWaiting:
    [streamer setStatus:DOUAudioStreamerBuffering];
    return;
  }

  void *bytes = NULL;
  NSUInteger length = 0;
  [[[streamer decoder] lpcm] readBytes:&bytes length:&length];
  if (bytes != NULL) {
    [_renderer renderBytes:bytes length:length];
    free(bytes);
  }
}

- (void)_eventLoop
{
  DOUAudioStreamer *streamer = nil;

  while (1) {
    @autoreleasepool {
      if (streamer != nil) {
        switch ([streamer status]) {
        case DOUAudioStreamerPaused:
        case DOUAudioStreamerFinished:
        case DOUAudioStreamerBuffering:
        case DOUAudioStreamerError:
          if (![self _handleEvent:[self _waitForEvent]
                     withStreamer:&streamer]) {
            return;
          }
          break;

        default:
          break;
        }
      }
      else {
        if (![self _handleEvent:[self _waitForEvent]
                   withStreamer:&streamer]) {
          return;
        }
      }

      if (![self _handleEvent:[self _waitForEventWithTimeout:0]
                 withStreamer:&streamer]) {
        return;
      }

      if (streamer != nil) {
        [self _handleStreamer:streamer];
      }
    }
  }
}

static void *event_loop_main(void *info)
{
  pthread_setname_np("com.douban.audio-streamer.event-loop");

  __unsafe_unretained DOUAudioEventLoop *eventLoop = (__bridge DOUAudioEventLoop *)info;
  @autoreleasepool {
    [eventLoop _eventLoop];
  }

  return NULL;
}

- (void)_createThread
{
  pthread_attr_t attr;
  struct sched_param sched_param;
  int sched_policy = SCHED_FIFO;

  pthread_attr_init(&attr);
  pthread_attr_setschedpolicy(&attr, sched_policy);
  sched_param.sched_priority = sched_get_priority_max(sched_policy);
  pthread_attr_setschedparam(&attr, &sched_param);

  pthread_create(&_thread, &attr, event_loop_main, (__bridge void *)self);

  pthread_attr_destroy(&attr);
}

- (void)setCurrentStreamer:(DOUAudioStreamer *)currentStreamer
{
  if (_currentStreamer != currentStreamer) {
    _currentStreamer = currentStreamer;
    [self _sendEvent:event_streamer_changed];
  }
}

- (NSTimeInterval)currentTime
{
  return (NSTimeInterval)[_renderer currentTime] / 1000.0;
}

- (double)volume
{
  return [_renderer volume];
}

- (void)setVolume:(double)volume
{
  [_renderer setVolume:volume];
  [[NSUserDefaults standardUserDefaults] setDouble:volume forKey:kVolumeKey];
}

- (void)play
{
  [self _sendEvent:event_play];
}

- (void)pause
{
  [self _sendEvent:event_pause];
}

@end