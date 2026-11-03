// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Core ML Model Manager
// Handles background download, SHA-256 verification, and local staging of SCNet Core ML model files.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const SCNetModelStatusDidChangeNotification;

typedef NS_ENUM(NSInteger, SCNetModelState) {
    SCNetModelStateNotDownloaded = 0,
    SCNetModelStateDownloading,
    SCNetModelStateReady,
    SCNetModelStateFailed
};

@interface SCNetModelManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) SCNetModelState state;
@property (nonatomic, readonly) float downloadProgress;
@property (nonatomic, readonly, copy, nullable) NSString *statusMessage;
@property (nonatomic, readonly) BOOL isModelReady;

- (nullable NSURL *)modelURL;
- (void)startDownloadIfNeeded;
- (void)cancelDownload;

@end

NS_ASSUME_NONNULL_END
