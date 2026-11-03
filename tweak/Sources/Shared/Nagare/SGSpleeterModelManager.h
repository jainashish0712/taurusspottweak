// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// Spleeter Core ML Model Manager
// Handles background download, verification, local staging, import, and management of Spleeter 4-Stem Core ML model files.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const SGSpleeterModelStatusDidChangeNotification;

typedef NS_ENUM(NSInteger, SGSpleeterModelState) {
    SGSpleeterModelStateNotDownloaded = 0,
    SGSpleeterModelStateDownloading,
    SGSpleeterModelStateExtracting,
    SGSpleeterModelStateReady,
    SGSpleeterModelStateFailed
};

@interface SGSpleeterModelManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) SGSpleeterModelState state;
@property (nonatomic, readonly) float downloadProgress;
@property (nonatomic, readonly, copy, nullable) NSString *statusMessage;
@property (nonatomic, readonly) BOOL isModelReady;
@property (nonatomic, copy) NSString *downloadURLString;

- (nullable NSURL *)modelURL;
- (nullable NSString *)installedModelSizeString;

- (void)startDownloadIfNeeded;
- (void)startDownloadFromURLString:(NSString *)urlString;
- (void)cancelDownload;

- (void)importModelFromURL:(NSURL *)sourceURL completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;
- (BOOL)deleteInstalledModel:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
