// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// Spleeter Core ML Model Manager Implementation

#import "SGSpleeterModelManager.h"
#import "miniz/miniz.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "miniz/miniz.c"
#pragma clang diagnostic pop
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const SGSpleeterModelStatusDidChangeNotification = @"spotifyglass.spleeter.modelStatusChanged";

static NSString *const kDefaultSpleeterZipURL = @"https://github.com/jiyimeta/swift-spleeter/releases/download/0.2.0/Spleeter4Model.mlmodelc.zip";
static NSString *const kPrefKeyDownloadURL = @"spotifyglass.spleeter.download_url";
static const int64_t kExpectedZipSize = 72765134;

@interface SGSpleeterModelManager () <NSURLSessionDownloadDelegate>
@property (nonatomic, assign) SGSpleeterModelState state;
@property (nonatomic, assign) float downloadProgress;
@property (nonatomic, copy, nullable) NSString *statusMessage;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, assign) NSTimeInterval lastProgressNotifyTime;
@end

@implementation SGSpleeterModelManager

+ (instancetype)sharedManager {
    static SGSpleeterModelManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SGSpleeterModelManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = SGSpleeterModelStateNotDownloaded;
        _downloadProgress = 0.0f;
        _statusMessage = nil;
        _lastProgressNotifyTime = 0;
        [self checkExistingInstallation];
    }
    return self;
}

- (NSString *)downloadURLString {
    NSString *val = [NSUserDefaults.standardUserDefaults stringForKey:kPrefKeyDownloadURL];
    if (val && val.length > 0) return val;
    return kDefaultSpleeterZipURL;
}

- (void)setDownloadURLString:(NSString *)downloadURLString {
    if (downloadURLString && downloadURLString.length > 0) {
        [NSUserDefaults.standardUserDefaults setObject:downloadURLString forKey:kPrefKeyDownloadURL];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kPrefKeyDownloadURL];
    }
}

- (NSURL *)baseDirectoryURL {
    NSURL *appSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
    return [appSupport URLByAppendingPathComponent:@"spoti.pw/Spleeter" isDirectory:YES];
}

- (NSURL *)modelDirectoryURL {
    return [[self baseDirectoryURL] URLByAppendingPathComponent:@"Spleeter4Model.mlmodelc" isDirectory:YES];
}

- (NSURL *)zipFileURL {
    return [[self baseDirectoryURL] URLByAppendingPathComponent:@"Spleeter4Model.mlmodelc.zip"];
}

- (NSURL *)modelURL {
    if (self.isModelReady) {
        return [self modelDirectoryURL];
    }
    return nil;
}

- (BOOL)isModelReady {
    return _state == SGSpleeterModelStateReady;
}

- (nullable NSString *)installedModelSizeString {
    if (!self.isModelReady) return nil;
    NSURL *dir = [self modelDirectoryURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:dir includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 errorHandler:nil];
    int64_t totalBytes = 0;
    for (NSURL *fileURL in enumerator) {
        NSNumber *size = nil;
        [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size) totalBytes += size.longLongValue;
    }
    if (totalBytes <= 0) return nil;
    return [NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (BOOL)validateExtractedFiles {
    NSURL *modelDir = [self modelDirectoryURL];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSURL *milURL = [modelDir URLByAppendingPathComponent:@"model.mil"];
    NSURL *weightsURL = [modelDir URLByAppendingPathComponent:@"weights/weight.bin"];
    NSURL *coremlURL = [modelDir URLByAppendingPathComponent:@"coremldata.bin"];

    if (![fm fileExistsAtPath:milURL.path] || ![fm fileExistsAtPath:weightsURL.path] || ![fm fileExistsAtPath:coremlURL.path]) {
        return NO;
    }

    NSDictionary *milAttr = [fm attributesOfItemAtPath:milURL.path error:nil];
    NSDictionary *weightsAttr = [fm attributesOfItemAtPath:weightsURL.path error:nil];

    int64_t milSize = [milAttr fileSize];
    int64_t weightsSize = [weightsAttr fileSize];

    // model.mil is ~230KB, weight.bin is ~78MB
    if (milSize < 200000 || weightsSize < 70000000) {
        return NO;
    }

    return YES;
}

static BOOL SGExtractZipArchive(NSString *zipPath, NSString *destinationDirectory) {
    mz_zip_archive zip_archive;
    memset(&zip_archive, 0, sizeof(zip_archive));
    if (!mz_zip_reader_init_file(&zip_archive, [zipPath UTF8String], 0)) {
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    mz_uint num_files = mz_zip_reader_get_num_files(&zip_archive);

    for (mz_uint i = 0; i < num_files; i++) {
        mz_zip_archive_file_stat file_stat;
        if (!mz_zip_reader_file_stat(&zip_archive, i, &file_stat)) {
            continue;
        }

        NSString *filename = [NSString stringWithUTF8String:file_stat.m_filename];
        if (!filename || filename.length == 0) continue;

        // Strip leading directory name if archive wraps it in Spleeter4Model.mlmodelc/
        if ([filename hasPrefix:@"Spleeter4Model.mlmodelc/"]) {
            filename = [filename substringFromIndex:[@"Spleeter4Model.mlmodelc/" length]];
        }
        if (filename.length == 0) continue;

        NSString *targetPath = [destinationDirectory stringByAppendingPathComponent:filename];

        if (mz_zip_reader_is_file_a_directory(&zip_archive, i)) {
            [fm createDirectoryAtPath:targetPath withIntermediateDirectories:YES attributes:nil error:nil];
        } else {
            [fm createDirectoryAtPath:[targetPath stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
            mz_zip_reader_extract_to_file(&zip_archive, i, [targetPath UTF8String], 0);
        }
    }

    mz_zip_reader_end(&zip_archive);
    return YES;
}

- (void)checkExistingInstallation {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:[self baseDirectoryURL] withIntermediateDirectories:YES attributes:nil error:nil];

    if ([self validateExtractedFiles]) {
        self.state = SGSpleeterModelStateReady;
        self.downloadProgress = 1.0f;
        self.statusMessage = @"Spleeter 4-Stem Model Ready";
        [self notifyStatusChange];
        return;
    }

    // Check if zip exists locally in base directory
    NSURL *zipURL = [self zipFileURL];
    if ([fm fileExistsAtPath:zipURL.path]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:zipURL.path error:nil];
        if ([attrs fileSize] > 70000000) {
            self.statusMessage = @"Extracting Spleeter Model...";
            NSString *modelDirPath = [self modelDirectoryURL].path;
            [fm createDirectoryAtPath:modelDirPath withIntermediateDirectories:YES attributes:nil error:nil];
            if (SGExtractZipArchive(zipURL.path, modelDirPath) && [self validateExtractedFiles]) {
                self.state = SGSpleeterModelStateReady;
                self.downloadProgress = 1.0f;
                self.statusMessage = @"Spleeter 4-Stem Model Ready";
                return;
            }
        }
    }

    self.state = SGSpleeterModelStateNotDownloaded;
    self.downloadProgress = 0.0f;
    self.statusMessage = @"Model not downloaded (~72 MB)";
}

- (void)startDownloadIfNeeded {
    if (self.state == SGSpleeterModelStateReady || self.state == SGSpleeterModelStateDownloading || self.state == SGSpleeterModelStateExtracting) {
        return;
    }
    [self startDownloadFromURLString:self.downloadURLString];
}

- (void)startDownloadFromURLString:(NSString *)urlString {
    if (!urlString || urlString.length == 0) {
        urlString = kDefaultSpleeterZipURL;
    }
    self.downloadURLString = urlString;

    if (self.downloadTask) {
        [self.downloadTask cancel];
        self.downloadTask = nil;
    }

    self.state = SGSpleeterModelStateDownloading;
    self.downloadProgress = 0.0f;
    self.statusMessage = @"Connecting to model server...";
    [self notifyStatusChange];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60.0;
    config.timeoutIntervalForResource = 600.0;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    NSURL *url = [NSURL URLWithString:urlString];
    self.downloadTask = [self.session downloadTaskWithURL:url];
    [self.downloadTask resume];
}

- (void)cancelDownload {
    if (self.downloadTask) {
        [self.downloadTask cancel];
        self.downloadTask = nil;
    }
    self.state = SGSpleeterModelStateNotDownloaded;
    self.downloadProgress = 0.0f;
    self.statusMessage = @"Download cancelled";
    [self notifyStatusChange];
}

- (void)importModelFromURL:(NSURL *)sourceURL completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion {
    BOOL isAccessing = [sourceURL startAccessingSecurityScopedResource];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *ext = sourceURL.pathExtension.lowercaseString;
        BOOL isDirectory = NO;
        [fm fileExistsAtPath:sourceURL.path isDirectory:&isDirectory];

        NSString *targetDirPath = [self modelDirectoryURL].path;
        [fm createDirectoryAtPath:targetDirPath withIntermediateDirectories:YES attributes:nil error:nil];

        BOOL extractOk = NO;
        NSString *errMsg = nil;

        if ([ext isEqualToString:@"zip"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.state = SGSpleeterModelStateExtracting;
                self.statusMessage = @"Extracting model archive...";
                [self notifyStatusChange];
            });
            extractOk = SGExtractZipArchive(sourceURL.path, targetDirPath);
            if (!extractOk) errMsg = @"Failed to unpack zip archive.";
        } else if (isDirectory || [sourceURL.lastPathComponent hasSuffix:@".mlmodelc"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.state = SGSpleeterModelStateExtracting;
                self.statusMessage = @"Copying model files...";
                [self notifyStatusChange];
            });
            NSArray *items = [fm contentsOfDirectoryAtPath:sourceURL.path error:nil];
            for (NSString *item in items) {
                NSString *src = [sourceURL.path stringByAppendingPathComponent:item];
                NSString *dst = [targetDirPath stringByAppendingPathComponent:item];
                [fm removeItemAtPath:dst error:nil];
                [fm copyItemAtPath:src toPath:dst error:nil];
            }
            extractOk = YES;
        } else {
            errMsg = @"Selected file is not a .zip or .mlmodelc directory.";
        }

        if (isAccessing) {
            [sourceURL stopAccessingSecurityScopedResource];
        }

        if (extractOk && [self validateExtractedFiles]) {
            self.state = SGSpleeterModelStateReady;
            self.downloadProgress = 1.0f;
            self.statusMessage = @"Spleeter 4-Stem Model Ready";
            [self notifyStatusChange];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, nil);
            });
        } else {
            self.state = SGSpleeterModelStateFailed;
            self.statusMessage = errMsg ?: @"Validation failed: model.mil or weight.bin missing.";
            [self notifyStatusChange];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, self.statusMessage);
            });
        }
    });
}

- (BOOL)deleteInstalledModel:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *modelDir = [self modelDirectoryURL];
    NSURL *zipFile = [self zipFileURL];

    BOOL ok1 = [fm removeItemAtURL:modelDir error:error];
    [fm removeItemAtURL:zipFile error:nil];

    self.state = SGSpleeterModelStateNotDownloaded;
    self.downloadProgress = 0.0f;
    self.statusMessage = @"Model not downloaded (~72 MB)";
    [self notifyStatusChange];
    return ok1;
}

- (void)notifyStatusChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGSpleeterModelStatusDidChangeNotification object:self];
    });
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    int64_t expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : kExpectedZipSize;
    float progress = (float)totalBytesWritten / (float)expected;
    if (progress > 1.0f) progress = 1.0f;
    self.downloadProgress = progress;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastProgressNotifyTime > 0.1 || progress >= 1.0f) {
        self.lastProgressNotifyTime = now;
        self.statusMessage = [NSString stringWithFormat:@"Downloading Spleeter Model (%.0f%%)...", progress * 100.0f];
        [self notifyStatusChange];
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *zipURL = [self zipFileURL];
    [fm removeItemAtURL:zipURL error:nil];

    NSError *moveError = nil;
    [fm moveItemAtURL:location toURL:zipURL error:&moveError];
    if (moveError) {
        self.state = SGSpleeterModelStateFailed;
        self.statusMessage = [NSString stringWithFormat:@"Failed to save model zip: %@", moveError.localizedDescription];
        [self notifyStatusChange];
        return;
    }

    self.state = SGSpleeterModelStateExtracting;
    self.statusMessage = @"Extracting neural weights...";
    [self notifyStatusChange];

    NSString *modelDirPath = [self modelDirectoryURL].path;
    [fm createDirectoryAtPath:modelDirPath withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL ok = SGExtractZipArchive(zipURL.path, modelDirPath);
    if (ok && [self validateExtractedFiles]) {
        self.state = SGSpleeterModelStateReady;
        self.downloadProgress = 1.0f;
        self.statusMessage = @"Spleeter 4-Stem Model Ready";
    } else {
        self.state = SGSpleeterModelStateFailed;
        self.statusMessage = @"Extraction verification failed";
    }
    [self notifyStatusChange];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error && error.code != NSURLErrorCancelled) {
        self.state = SGSpleeterModelStateFailed;
        self.statusMessage = [NSString stringWithFormat:@"Download failed: %@", error.localizedDescription];
        [self notifyStatusChange];
    }
}

@end
