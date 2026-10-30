#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

const struct mach_header_64 *SGSpotifyExecutable(intptr_t *slide);
BOOL SGRebindImport(const char *symbol, void *replacement, void **original);
