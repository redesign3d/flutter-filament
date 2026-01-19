#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface FilamentRenderer : NSObject

- (void)setupWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                       width:(int)width
                      height:(int)height;

- (void)resizeWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        width:(int)width
                       height:(int)height;

- (NSArray<NSString *> *)beginModelLoad:(NSData *)data;

- (void)finishModelLoad:(NSDictionary<NSString *, NSData *> *)resources;

- (void)clearScene;

- (void)renderFrame:(uint64_t)frameTimeNanos;

- (void)setPaused:(BOOL)paused;

- (void)destroyRenderer;

@end

NS_ASSUME_NONNULL_END
