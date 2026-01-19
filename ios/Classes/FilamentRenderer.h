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

- (void)setIndirectLightFromKTX:(NSData *)data;

- (void)setSkyboxFromKTX:(NSData *)data;

- (void)frameModel:(BOOL)useWorldOrigin;

- (void)setOrbitConstraintsWithMinPitch:(double)minPitch
                               maxPitch:(double)maxPitch
                                minYaw:(double)minYaw
                                maxYaw:(double)maxYaw;

- (void)setInertiaEnabled:(BOOL)enabled;

- (void)setInertiaParamsWithDamping:(double)damping sensitivity:(double)sensitivity;

- (void)setZoomLimitsWithMinDistance:(double)minDistance maxDistance:(double)maxDistance;

- (void)orbitStart;

- (void)orbitDeltaWithDx:(double)dx dy:(double)dy;

- (void)orbitEndWithVelocityX:(double)velocityX velocityY:(double)velocityY;

- (void)zoomDelta:(double)scaleDelta;

- (void)setCustomCameraEnabled:(BOOL)enabled;

- (void)setCustomCameraLookAtWithEyeX:(double)eyeX
                                eyeY:(double)eyeY
                                eyeZ:(double)eyeZ
                              centerX:(double)centerX
                              centerY:(double)centerY
                              centerZ:(double)centerZ
                                  upX:(double)upX
                                  upY:(double)upY
                                  upZ:(double)upZ;

- (void)setCustomPerspectiveWithFov:(double)fovDegrees
                               near:(double)nearPlane
                                far:(double)farPlane;

- (int)getAnimationCount;

- (double)getAnimationDuration:(int)index;

- (void)playAnimation:(int)index loop:(BOOL)loop;

- (void)pauseAnimation;

- (void)seekAnimation:(double)seconds;

- (void)setAnimationSpeed:(double)speed;

- (void)clearScene;

- (void)renderFrame:(uint64_t)frameTimeNanos;

- (void)setPaused:(BOOL)paused;

- (void)destroyRenderer;

@end

NS_ASSUME_NONNULL_END
