#import "Core/SGCore.h"
#import "Downloads.h"
#import "DownloadsBridge.h"

NSNotificationName const SGDownloadsDidChangeNotification = @"spotifyglass.downloads.changed";

Class<SGDownloadsCompanion> SGDownloadsCompanion(void) {
    Class found = NSClassFromString(@"SAPTaurusBridge");
    if (found && [found respondsToSelector:@selector(interfaceVersion)]
        && [(Class<SGDownloadsCompanion>)found interfaceVersion] >= 1) return (Class<SGDownloadsCompanion>)found;
    return nil;
}

BOOL SGDownloadsAvailable(void) { return SGDownloadsCompanion() != nil; }

BOOL SGDownloadsActive(void) { return [SGDownloadsCompanion() downloadActive]; }

NSString *SGDownloadsSummary(void) {
    Class<SGDownloadsCompanion> companion = SGDownloadsCompanion();
    if (!companion) {
        return @"Downloads engine isn't loaded";
    }
    return [companion downloadSummary] ?: @"No download started";
}

NSString *SGDownloadsUnavailableReason(void) {
    return @"The Downloads engine is missing or could not load. Install a Taurus IPA built with Downloads. A tweak-only build or a build made with --no-downloads does not include the engine.";
}

NSString *SGDownloadsRowSummary(void) {
    if (!SGDownloadsAvailable()) return @"Unavailable";
    return SGDownloadsActive() ? @"Downloading" : @"Ready";
}
