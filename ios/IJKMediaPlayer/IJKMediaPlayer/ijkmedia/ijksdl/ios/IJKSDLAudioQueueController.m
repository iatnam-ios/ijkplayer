/*
 * IJKSDLAudioQueueController.m
 *
 * Copyright (c) 2013-2014 Bilibili
 * Copyright (c) 2013-2014 Zhang Rui <bbcallen@gmail.com>
 *
 * based on https://github.com/kolyvan/kxmovie
 *
 * This file is part of ijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "IJKSDLAudioQueueController.h"
#import "IJKSDLAudioKit.h"
#import "ijksdl_log.h"

#import <AVFoundation/AVFoundation.h>

#define kIJKAudioQueueNumberBuffers (3)

@implementation IJKSDLAudioQueueController {
    AudioQueueRef _audioQueueRef;
    AUGraph mGraph;
    AudioUnit eqUnit;
    AudioUnit genericOutputUnit;
    void* __nullable buffer[kIJKAudioQueueNumberBuffers];
    AudioTimeStamp renderTimeStamp;
    AudioQueueBufferRef _audioQueueBufferRefArray[kIJKAudioQueueNumberBuffers];
    
    BOOL _isPaused;
    BOOL _isStopped;
    BOOL _isEqualizerOn;

    volatile BOOL _isAborted;
    NSLock *_lock;
}

- (id)initWithAudioSpec:(const SDL_AudioSpec *)aSpec
{
    self = [super init];
    if (self) {
        if (aSpec == NULL) {
            self = nil;
            return nil;
        }
        _spec = *aSpec;
        _isEqualizerOn = NO;

        if (aSpec->format != AUDIO_S16SYS) {
            NSLog(@"aout_open_audio: unsupported format %d\n", (int)aSpec->format);
            return nil;
        }

        if (aSpec->channels > 2) {
            NSLog(@"aout_open_audio: unsupported channels %d\n", (int)aSpec->channels);
            return nil;
        }

        /* Get the current format */
        AudioStreamBasicDescription tapFormat;
        IJKSDLGetAudioStreamBasicDescriptionFromSpec(&_spec, &tapFormat);

        SDL_CalculateAudioSpec(&_spec);

        if (_spec.size == 0) {
            NSLog(@"aout_open_audio: unexcepted audio spec size %u", _spec.size);
            return nil;
        }

        /* Set the desired format */
        AudioQueueRef audioQueueRef;
        OSStatus status = AudioQueueNewOutput(&tapFormat,
                                              IJKSDLAudioQueueOuptutCallback,
                                              (__bridge void *) self,
                                              NULL,
                                              kCFRunLoopCommonModes,
                                              0,
                                              &audioQueueRef);
        if (status != noErr) {
            NSLog(@"AudioQueue: AudioQueueNewOutput failed (%d)\n", (int)status);
            self = nil;
            return nil;
        }
        
        UInt32 maxFrames = 4096;
        AudioQueueProcessingTapRef tapRef;
        status = AudioQueueProcessingTapNew(audioQueueRef, tapProc, (__bridge void *) self, kAudioQueueProcessingTap_PreEffects, &maxFrames, &tapFormat, &tapRef);
        
        AUNode eqNode;
        AUNode convertToEffectNode;
        AUNode convertFromEffectNode;
        AUNode genericOutputNode;
        AudioUnit convertToEffectUnit;
        AudioUnit convertFromEffectUnit;
        
        status = NewAUGraph(&mGraph);
        status = AUGraphOpen(mGraph);
        
        AudioComponentDescription audioComponentDescription;
        audioComponentDescription.componentType = kAudioUnitType_Effect;
        audioComponentDescription.componentSubType = kAudioUnitSubType_NBandEQ;
        audioComponentDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
        audioComponentDescription.componentFlags = 0;
        audioComponentDescription.componentFlagsMask = 0;
        
        status = AUGraphAddNode(mGraph, &audioComponentDescription, &eqNode);
        status = AUGraphNodeInfo(mGraph, eqNode, NULL, &eqUnit);
        
        audioComponentDescription.componentType = kAudioUnitType_FormatConverter;
        audioComponentDescription.componentSubType = kAudioUnitSubType_AUConverter;
        
        status = AUGraphAddNode(mGraph, &audioComponentDescription, &convertToEffectNode);
        status = AUGraphNodeInfo(mGraph, convertToEffectNode, NULL, &convertToEffectUnit);

        status = AUGraphAddNode(mGraph, &audioComponentDescription, &convertFromEffectNode);
        status = AUGraphNodeInfo(mGraph, convertFromEffectNode, NULL, &convertFromEffectUnit);
        
        audioComponentDescription.componentType = kAudioUnitType_Output;
        audioComponentDescription.componentSubType = kAudioUnitSubType_GenericOutput;
        
        status = AUGraphAddNode(mGraph, &audioComponentDescription, &genericOutputNode);
        status = AUGraphNodeInfo(mGraph, genericOutputNode, NULL, &genericOutputUnit);
        
        AudioStreamBasicDescription effectFormat;
        UInt32 sizeEffect = sizeof(effectFormat);
        UInt32 sizeTap = sizeof(tapFormat);
        status = AudioUnitGetProperty(eqUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      0,
                                      &effectFormat,
                                      &sizeEffect);
        
        status = AudioUnitSetProperty(convertToEffectUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &tapFormat,
                                      sizeTap);
        
        status = AudioUnitSetProperty(convertToEffectUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      0,
                                      &effectFormat,
                                      sizeEffect);
        
        status = AudioUnitSetProperty(convertFromEffectUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &effectFormat,
                                      sizeEffect);
        
        status = AudioUnitSetProperty(convertFromEffectUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      0,
                                      &tapFormat,
                                      sizeTap);
        
        status = AudioUnitSetProperty(genericOutputUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &tapFormat,
                                      sizeTap);
        
        status = AudioUnitSetProperty(genericOutputUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      0,
                                      &tapFormat,
                                      sizeTap);
        
        status = AudioUnitSetProperty(eqUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, (UInt32)sizeof(UInt32));
        status = AudioUnitSetProperty(convertToEffectUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, (UInt32)sizeof(UInt32));
        status = AudioUnitSetProperty(convertFromEffectUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, (UInt32)sizeof(UInt32));
        status = AudioUnitSetProperty(genericOutputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, (UInt32)sizeof(UInt32));
        
        status = AUGraphConnectNodeInput(mGraph, convertToEffectNode, 0, eqNode, 0);
        status = AUGraphConnectNodeInput(mGraph, eqNode, 0, convertFromEffectNode, 0);
        status = AUGraphConnectNodeInput(mGraph, convertFromEffectNode, 0, genericOutputNode, 0);
        
        renderTimeStamp.mSampleTime = 0;
        renderTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
        
        AURenderCallbackStruct callback;
        callback.inputProc = (AURenderCallback) RenderCallback;
        callback.inputProcRefCon = (__bridge void*) self;
        status = AudioUnitSetProperty(convertToEffectUnit,
                                      kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Global,
                                      0, &callback, sizeof(callback));
        if (status != noErr) {
            ALOGE("AudioUnit: render callback setup failed (%d)\n", (int)status);
            self = nil;
            return nil;
        }
        
        status = AUGraphInitialize(mGraph);
        if (status != noErr) {
            NSLog(@"AUGRAPH: Init failed (%d)\n", (int)status);
            self = nil;
            return nil;
        }

        UInt32 propValue = 1;
        AudioQueueSetProperty(audioQueueRef, kAudioQueueProperty_EnableTimePitch, &propValue, sizeof(propValue));
        propValue = 1;
        AudioQueueSetProperty(_audioQueueRef, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
        propValue = kAudioQueueTimePitchAlgorithm_Spectral;
        AudioQueueSetProperty(_audioQueueRef, kAudioQueueProperty_TimePitchAlgorithm, &propValue, sizeof(propValue));

        status = AudioQueueStart(audioQueueRef, NULL);
        if (status != noErr) {
            NSLog(@"AudioQueue: AudioQueueStart failed (%d)\n", (int)status);
            self = nil;
            return nil;
        }

        _audioQueueRef = audioQueueRef;

        for (int i = 0;i < kIJKAudioQueueNumberBuffers; i++)
        {
            AudioQueueAllocateBuffer(audioQueueRef, _spec.size, &_audioQueueBufferRefArray[i]);
            _audioQueueBufferRefArray[i]->mAudioDataByteSize = _spec.size;
            memset(_audioQueueBufferRefArray[i]->mAudioData, 0, _spec.size);
            AudioQueueEnqueueBuffer(audioQueueRef, _audioQueueBufferRefArray[i], 0, NULL);
        }
        /*-
        status = AudioQueueStart(audioQueueRef, NULL);
        if (status != noErr) {
            NSLog(@"AudioQueue: AudioQueueStart failed (%d)\n", (int)status);
            self = nil;
            return nil;
        }
         */

        _isStopped = NO;

        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

- (void)play
{
    if (!_audioQueueRef)
        return;

    self.spec.callback(self.spec.userdata, NULL, 0);

    @synchronized(_lock) {
        _isPaused = NO;
        NSError *error = nil;
        if (NO == [[AVAudioSession sharedInstance] setActive:YES error:&error]) {
            NSLog(@"AudioQueue: AVAudioSession.setActive(YES) failed: %@\n", error ? [error localizedDescription] : @"nil");
        }

        OSStatus status = AudioQueueStart(_audioQueueRef, NULL);
        if (status != noErr)
            NSLog(@"AudioQueue: AudioQueueStart failed (%d)\n", (int)status);
    }
}

- (void)pause
{
    if (!_audioQueueRef)
        return;

    @synchronized(_lock) {
        if (_isStopped)
            return;

        _isPaused = YES;
        OSStatus status = AudioQueuePause(_audioQueueRef);
        if (status != noErr)
            NSLog(@"AudioQueue: AudioQueuePause failed (%d)\n", (int)status);
    }
}

- (void)flush
{
    if (!_audioQueueRef)
        return;

    @synchronized(_lock) {
        if (_isStopped)
            return;

        if (_isPaused == YES) {
            for (int i = 0; i < kIJKAudioQueueNumberBuffers; i++)
            {
                if (_audioQueueBufferRefArray[i] && _audioQueueBufferRefArray[i]->mAudioData) {
                    _audioQueueBufferRefArray[i]->mAudioDataByteSize = _spec.size;
                    memset(_audioQueueBufferRefArray[i]->mAudioData, 0, _spec.size);
                }
            }
        } else {
            AudioQueueFlush(_audioQueueRef);
        }
    }
}

- (void)stop
{
    if (!_audioQueueRef)
        return;

    @synchronized(_lock) {
        if (_isStopped)
            return;

        _isStopped = YES;
    }

    // do not lock AudioQueueStop, or may be run into deadlock
    AudioQueueStop(_audioQueueRef, true);
    AudioQueueDispose(_audioQueueRef, true);
    DisposeAUGraph(mGraph);
}

- (void)close
{
    [self stop];
    _audioQueueRef = nil;
}

- (void)setPlaybackRate:(float)playbackRate
{
    if (fabsf(playbackRate - 1.0f) <= 0.000001) {
        UInt32 propValue = 1;
        AudioQueueSetProperty(_audioQueueRef, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
        AudioQueueSetParameter(_audioQueueRef, kAudioQueueParam_PlayRate, 1.0f);
    } else {
        UInt32 propValue = 0;
        AudioQueueSetProperty(_audioQueueRef, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
        AudioQueueSetParameter(_audioQueueRef, kAudioQueueParam_PlayRate, playbackRate);
    }
}

- (void)setPlaybackVolume:(float)playbackVolume
{
    float aq_volume = playbackVolume;
    if (fabsf(aq_volume - 1.0f) <= 0.000001) {
        AudioQueueSetParameter(_audioQueueRef, kAudioQueueParam_Volume, 1.f);
    } else {
        AudioQueueSetParameter(_audioQueueRef, kAudioQueueParam_Volume, aq_volume);
    }
}

- (double)get_latency_seconds
{
    return ((double)(kIJKAudioQueueNumberBuffers)) * _spec.samples / _spec.freq;
}

- (void)setListEQ:(NSArray *)listEQ
{
    AudioUnit audioUnit = self->eqUnit;
    if (audioUnit)
    {
        NSArray *array = @[ @32.0f , @64.0f, @125.0f, @250.0f, @500.0f, @1000.0f, @2000.0f, @4000.0f, @8000.0f, @16000.0f ];
        OSStatus status = noErr;
        UInt32 numBands = 10;
        status = AudioUnitSetProperty(audioUnit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &numBands, sizeof(numBands));
        
        for (int i = 0; i < listEQ.count; i++) {
            float number = [listEQ[i] floatValue];
            
            status = AudioUnitSetParameter(audioUnit, kAUNBandEQParam_FilterType + i, kAudioUnitScope_Global, 0, kAUNBandEQFilterType_Parametric, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_FilterType): %d", (int)status);
            
            status = AudioUnitSetParameter(audioUnit, kAUNBandEQParam_Frequency + i, kAudioUnitScope_Global, 0, [array[i] floatValue], 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_Frequency): %d", (int)status);
            
            status = AudioUnitSetParameter(audioUnit, kAUNBandEQParam_Bandwidth + i, kAudioUnitScope_Global, 0, 0.5, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_Bandwidth): %d", (int)status);
            
            status = AudioUnitSetParameter(audioUnit, kAUNBandEQParam_Gain + i, kAudioUnitScope_Global, 0, number, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_Gain): %d", (int)status);
            
            status = AudioUnitSetParameter(audioUnit, kAUNBandEQParam_BypassBand + i, kAudioUnitScope_Global, 0, 0, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_BypassBand): %d", (int)status);
        }
    }
}

- (void)setEqualizerValue:(float)value forBand:(int)bandTag {
    if (bandTag < 0) {
        if (fabsf(value - 1.0f) <= 0.000001) {
            _isEqualizerOn = YES;
        } else {
            _isEqualizerOn = NO;
        }
        return;
    } else if (bandTag < 10) {
        if (eqUnit)
        {
            NSArray *array = @[ @32.0f , @64.0f, @125.0f, @250.0f, @500.0f, @1000.0f, @2000.0f, @4000.0f, @8000.0f, @16000.0f ];

            OSStatus status = noErr;
            status = AudioUnitSetParameter(eqUnit, kAUNBandEQParam_FilterType + bandTag, kAudioUnitScope_Global, 0, kAUNBandEQFilterType_Parametric, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_FilterType): %d", (int)status);
            
            status = AudioUnitSetParameter(eqUnit, kAUNBandEQParam_Frequency + bandTag, kAudioUnitScope_Global, 0, [array[bandTag] floatValue], 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_Frequency): %d", (int)status);
            
            status = AudioUnitSetParameter(eqUnit, kAUNBandEQParam_Bandwidth + bandTag, kAudioUnitScope_Global, 0, 0.5, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_Bandwidth): %d", (int)status);
            
            status = AudioUnitSetParameter(eqUnit, kAUNBandEQParam_Gain + bandTag, kAudioUnitScope_Global, 0, value, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_Gain): %d", (int)status);
            
            status = AudioUnitSetParameter(eqUnit, kAUNBandEQParam_BypassBand + bandTag, kAudioUnitScope_Global, 0, 0, 0);
            if (noErr != status) NSLog(@"AudioUnitSetParameter(kAUNBandEQParam_BypassBand): %d", (int)status);
        }
    } else {
        return;
    }
}


static void IJKSDLAudioQueueOuptutCallback(void * inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    @autoreleasepool {
        IJKSDLAudioQueueController* aqController = (__bridge IJKSDLAudioQueueController *) inUserData;

        if (!aqController) {
            // do nothing;
        } else if (aqController->_isPaused || aqController->_isStopped) {
            memset(inBuffer->mAudioData, aqController.spec.silence, inBuffer->mAudioDataByteSize);
        } else {
            (*aqController.spec.callback)(aqController.spec.userdata, inBuffer->mAudioData, inBuffer->mAudioDataByteSize);
        }

        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

static void tapProc(void *inClientData,
                    AudioQueueProcessingTapRef inAQTap,
                    UInt32 inNumberFrames, AudioTimeStamp *ioTimeStamp,
                    AudioQueueProcessingTapFlags *ioFlags,
                    UInt32 * outNumberFrames,
                    AudioBufferList * ioData)
{
    
    UInt32 getSourceFlags = 0;
    UInt32 getSourceFrames = 0;
    
    OSStatus status = noErr;
    status = AudioQueueProcessingTapGetSourceAudio(inAQTap, inNumberFrames, ioTimeStamp, &getSourceFlags, &getSourceFrames, ioData);
    
    IJKSDLAudioQueueController* aqController = (__bridge IJKSDLAudioQueueController *) inClientData;
    
    if (!aqController) {
        
    }
    else if (aqController->_isEqualizerOn) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            aqController->buffer[i] = ioData->mBuffers[i].mData;
            ioData->mBuffers[i].mData = NULL;
        }
        
        AudioUnitRenderActionFlags actionFlags = 0;
        AudioUnitRender(aqController->genericOutputUnit, &actionFlags, &(aqController->renderTimeStamp), 0, inNumberFrames, ioData);
    }
}

static OSStatus RenderCallback(void                        *inRefCon,
                               AudioUnitRenderActionFlags  *ioActionFlags,
                               const AudioTimeStamp        *inTimeStamp,
                               UInt32                      inBusNumber,
                               UInt32                      inNumberFrames,
                               AudioBufferList             *ioData)
{
    IJKSDLAudioQueueController* aqController = (__bridge IJKSDLAudioQueueController *) inRefCon;
    aqController->renderTimeStamp.mSampleTime += inNumberFrames;
    
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        ioData->mBuffers[i].mData = aqController->buffer[i];
    }
    
    return noErr;
}

@end
