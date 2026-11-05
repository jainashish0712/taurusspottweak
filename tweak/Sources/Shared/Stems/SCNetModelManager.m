// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Core ML Model Manager Implementation

#import "SCNetModelManager.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const SCNetModelStatusDidChangeNotification = @"spotifyglass.scnet.modelStatusChanged";

static NSString *const kSCNetBaseURL = @"https://huggingface.co/Ocean82/scnet-base/resolve/main/v1.0.0/SCNet_Base.mlmodelc/";

typedef struct {
    const char *relativePath;
    int64_t expectedSize;
    const char *expectedSHA256;
} SCNetModelFile;

static const SCNetModelFile kSCNetFiles[] = {
    {"metadata.json", 2232, "e090e29420e1c8b0401b52fa4dd7116de43eef647ca94b807b1df5a661ae26e6"},
    {"coremldata.bin", 385, "968b4fed2a6c1b045ed5139b19f77b63de99ce66cc14722180bbed8a30ac6641"},
    {"model.mil", 453829, "2a60e5a1a98c2d4476f64cf6bc39e9af8eb7e15ffa03bfc23ba53bc6767789c2"},
    {"weights/weight.bin", 45230464, "0d008b13e384c589ae7720924c9fb47802fdddeef23d4946e40f010ee0f11ef3"},
    {"analytics/coremldata.bin", 243, "b92a92964af1166f1d0f0e4178faa870bf40f71ee863b35df3f7ba9837497428"}
};

static const NSInteger kSCNetFileCount = sizeof(kSCNetFiles) / sizeof(kSCNetFiles[0]);

@interface SCNetModelManager () <NSURLSessionDownloadDelegate>
@property (nonatomic, assign) SCNetModelState state;
@property (nonatomic, assign) float downloadProgress;
@property (nonatomic, copy, nullable) NSString *statusMessage;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSURLSessionDownloadTask *> *tasks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *downloadedBytesPerFile;
@end

@implementation SCNetModelManager

+ (instancetype)sharedManager {
    static SCNetModelManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SCNetModelManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = SCNetModelStateNotDownloaded;
        _downloadProgress = 0.0f;
        _statusMessage = nil;
        _tasks = [NSMutableDictionary dictionary];
        _downloadedBytesPerFile = [NSMutableDictionary dictionary];
        [self checkExistingInstallation];
    }
    return self;
}

- (NSURL *)modelDirectoryURL {
    NSURL *appSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
    return [appSupport URLByAppendingPathComponent:@"spoti.pw/SCNet/SCNet_Base.mlmodelc" isDirectory:YES];
}

- (NSURL *)modelURL {
    if (self.isModelReady) {
        return [self modelDirectoryURL];
    }
    return nil;
}

- (BOOL)isModelReady {
    return _state == SCNetModelStateReady;
}

- (NSString *)sha256OfFile:(NSURL *)fileURL {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:nil];
    if (!handle) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    @try {
        while (1) {
            @autoreleasepool {
                NSData *chunk = [handle readDataOfLength:65536];
                if (!chunk || chunk.length == 0) break;
                CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
            }
        }
    } @catch (...) {
        [handle closeFile];
        return nil;
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

- (void)checkExistingInstallation {
    NSURL *dir = [self modelDirectoryURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir.path]) {
        _state = SCNetModelStateNotDownloaded;
        return;
    }

    BOOL allValid = YES;
    for (NSInteger i = 0; i < kSCNetFileCount; i++) {
        NSString *rel = [NSString stringWithUTF8String:kSCNetFiles[i].relativePath];
        NSURL *fileURL = [dir URLByAppendingPathComponent:rel];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fileURL.path error:nil];
        if (!attrs || [attrs fileSize] != kSCNetFiles[i].expectedSize) {
            allValid = NO;
            break;
        }
    }

    if (allValid) {
        _state = SCNetModelStateReady;
        _downloadProgress = 1.0f;
        _statusMessage = @"SCNet Ready";
    } else {
        _state = SCNetModelStateNotDownloaded;
    }
}

- (void)startDownloadIfNeeded {
    if (_state == SCNetModelStateReady || _state == SCNetModelStateDownloading) {
        return;
    }

    _state = SCNetModelStateDownloading;
    _downloadProgress = 0.0f;
    _statusMessage = @"Downloading SCNet Neural Model...";
    [self notifyStatus];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.allowsCellularAccess = YES;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];

    [self.tasks removeAllObjects];
    [self.downloadedBytesPerFile removeAllObjects];

    for (NSInteger i = 0; i < kSCNetFileCount; i++) {
        NSString *rel = [NSString stringWithUTF8String:kSCNetFiles[i].relativePath];
        NSString *fileURLString = [kSCNetBaseURL stringByAppendingString:rel];
        NSURL *url = [NSURL URLWithString:fileURLString];
        NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
        self.tasks[@(task.taskIdentifier)] = task;
        task.taskDescription = [NSString stringWithFormat:@"%ld", (long)i];
        [task resume];
    }
}

- (void)cancelDownload {
    if (_state == SCNetModelStateDownloading) {
        for (NSURLSessionDownloadTask *task in self.tasks.allValues) {
            [task cancel];
        }
        [self.tasks removeAllObjects];
        [self.session invalidateAndCancel];
        self.session = nil;
        _state = SCNetModelStateNotDownloaded;
        _downloadProgress = 0.0f;
        _statusMessage = @"Download cancelled";
        [self notifyStatus];
    }
}

- (void)notifyStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SCNetModelStatusDidChangeNotification object:self];
    });
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSInteger fileIndex = [downloadTask.taskDescription integerValue];
    self.downloadedBytesPerFile[@(fileIndex)] = @(totalBytesWritten);

    int64_t totalDownloaded = 0;
    int64_t totalExpected = 0;
    for (NSInteger i = 0; i < kSCNetFileCount; i++) {
        totalExpected += kSCNetFiles[i].expectedSize;
        totalDownloaded += [self.downloadedBytesPerFile[@(i)] longLongValue];
    }

    if (totalExpected > 0) {
        self.downloadProgress = (float)totalDownloaded / (float)totalExpected;
        self.statusMessage = [NSString stringWithFormat:@"Downloading SCNet: %.1f MB / %.1f MB (%.0f%%)",
                              (float)totalDownloaded / (1024.0f * 1024.0f),
                              (float)totalExpected / (1024.0f * 1024.0f),
                              self.downloadProgress * 100.0f];
        [self notifyStatus];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSInteger fileIndex = [downloadTask.taskDescription integerValue];
    if (fileIndex < 0 || fileIndex >= kSCNetFileCount) return;

    NSString *rel = [NSString stringWithUTF8String:kSCNetFiles[fileIndex].relativePath];
    NSURL *destDir = [self modelDirectoryURL];
    NSURL *finalURL = [destDir URLByAppendingPathComponent:rel];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:finalURL.URLByDeletingLastPathComponent.path withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:finalURL error:nil];

    NSError *moveErr = nil;
    [fm moveItemAtURL:location toURL:finalURL error:&moveErr];
    if (moveErr) {
        NSLog(@"[spotifyglass] SCNet failed to move %@: %@", rel, moveErr);
        self.state = SCNetModelStateFailed;
        self.statusMessage = @"Failed to save model file";
        [self notifyStatus];
        return;
    }

    [self.tasks removeObjectForKey:@(downloadTask.taskIdentifier)];

    if (self.tasks.count == 0) {
        // All files finished downloading, verify SHA-256
        BOOL allChecksumsMatch = YES;
        for (NSInteger i = 0; i < kSCNetFileCount; i++) {
            NSString *fileRel = [NSString stringWithUTF8String:kSCNetFiles[i].relativePath];
            NSURL *checkURL = [destDir URLByAppendingPathComponent:fileRel];
            NSString *calculated = [self sha256OfFile:checkURL];
            NSString *expected = [NSString stringWithUTF8String:kSCNetFiles[i].expectedSHA256];
            if (![calculated.lowercaseString isEqualToString:expected.lowercaseString]) {
                NSLog(@"[spotifyglass] SCNet checksum mismatch for %@: got %@ expected %@", fileRel, calculated, expected);
                allChecksumsMatch = NO;
                break;
            }
        }

        if (allChecksumsMatch) {
            self.state = SCNetModelStateReady;
            self.downloadProgress = 1.0f;
            self.statusMessage = @"SCNet Ready";
        } else {
            self.state = SCNetModelStateFailed;
            self.statusMessage = @"SCNet checksum validation failed";
        }
        [self notifyStatus];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && error.code != NSURLErrorCancelled) {
        NSLog(@"[spotifyglass] SCNet download error: %@", error);
        self.state = SCNetModelStateFailed;
        self.statusMessage = [NSString stringWithFormat:@"Download failed: %@", error.localizedDescription];
        [self notifyStatus];
    }
}

@end
