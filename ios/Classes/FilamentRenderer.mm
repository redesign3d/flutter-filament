#import "FilamentRenderer.h"

#import <QuartzCore/CADisplayLink.h>

#undef DEBUG

#include <backend/BufferDescriptor.h>
#include <algorithm>
#include <cmath>
#include <filament/Camera.h>
#include <filament/Box.h>
#include <filament/Engine.h>
#include <filament/LightManager.h>
#include <filament/IndirectLight.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
#include <filament/Texture.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <gltfio/Animator.h>
#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/TextureProvider.h>
#include <gltfio/materials/uberarchive.h>
#include <image/Ktx1Bundle.h>
#include <ktxreader/Ktx1Reader.h>
#include <math/vec3.h>
#include <utils/Entity.h>
#include <utils/EntityManager.h>

using namespace filament;
using namespace filament::gltfio;
using namespace utils;

namespace {
Engine* SharedEngine() {
    static Engine* engine = Engine::create(Engine::Backend::METAL);
    return engine;
}

void ReleaseBuffer(void* buffer, size_t, void*) {
    free(buffer);
}

double ClampValue(double value, double minValue, double maxValue) {
    return std::max(minValue, std::min(value, maxValue));
}

double DegreesToRadians(double degrees) {
    return degrees * 3.141592653589793 / 180.0;
}

double LengthFloat3(const math::float3& value) {
    return std::sqrt(value.x * value.x + value.y * value.y + value.z * value.z);
}
}  // namespace

@implementation FilamentRenderer {
    Engine* _engine;
    Renderer* _renderer;
    View* _view;
    Scene* _scene;
    Camera* _camera;
    SwapChain* _swapChain;
    Entity _cameraEntity;
    Entity _lightEntity;
    MaterialProvider* _materialProvider;
    TextureProvider* _textureProvider;
    AssetLoader* _assetLoader;
    ResourceLoader* _resourceLoader;
    FilamentAsset* _asset;
    FilamentAsset* _pendingAsset;
    Animator* _animator;
    IndirectLight* _indirectLight;
    Texture* _iblTexture;
    Skybox* _skybox;
    Texture* _skyboxTexture;
    math::float3 _orbitTarget;
    double _yawDeg;
    double _pitchDeg;
    double _distance;
    double _minYawDeg;
    double _maxYawDeg;
    double _minPitchDeg;
    double _maxPitchDeg;
    double _minDistance;
    double _maxDistance;
    double _damping;
    double _sensitivity;
    double _velocityYaw;
    double _velocityPitch;
    uint64_t _lastFrameTimeNanos;
    bool _inertiaEnabled;
    bool _customCameraEnabled;
    double _customLookAt[9];
    double _customPerspective[3];
    double _cameraFovDegrees;
    double _cameraNear;
    double _cameraFar;
    int _animationIndex;
    bool _animationLoop;
    bool _animationPlaying;
    double _animationTimeSeconds;
    double _animationSpeed;
    uint64_t _lastAnimationFrameNanos;
    math::float3 _modelCenter;
    math::float3 _modelExtent;
    bool _hasModelBounds;
    CVPixelBufferRef _pixelBuffer;
    BOOL _paused;
    int _width;
    int _height;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = SharedEngine();
        _renderer = nullptr;
        _view = nullptr;
        _scene = nullptr;
        _camera = nullptr;
        _swapChain = nullptr;
        _materialProvider = nullptr;
        _textureProvider = nullptr;
        _assetLoader = nullptr;
        _resourceLoader = nullptr;
        _asset = nullptr;
        _pendingAsset = nullptr;
        _animator = nullptr;
        _indirectLight = nullptr;
        _iblTexture = nullptr;
        _skybox = nullptr;
        _skyboxTexture = nullptr;
        _orbitTarget = math::float3{0.0f, 0.0f, 0.0f};
        _yawDeg = 0.0;
        _pitchDeg = 0.0;
        _distance = 3.0;
        _minYawDeg = -180.0;
        _maxYawDeg = 180.0;
        _minPitchDeg = -89.0;
        _maxPitchDeg = 89.0;
        _minDistance = 0.05;
        _maxDistance = 100.0;
        _damping = 0.9;
        _sensitivity = 0.15;
        _velocityYaw = 0.0;
        _velocityPitch = 0.0;
        _lastFrameTimeNanos = 0;
        _inertiaEnabled = true;
        _customCameraEnabled = false;
        _customLookAt[0] = 0.0;
        _customLookAt[1] = 0.0;
        _customLookAt[2] = 3.0;
        _customLookAt[3] = 0.0;
        _customLookAt[4] = 0.0;
        _customLookAt[5] = 0.0;
        _customLookAt[6] = 0.0;
        _customLookAt[7] = 1.0;
        _customLookAt[8] = 0.0;
        _customPerspective[0] = 45.0;
        _customPerspective[1] = 0.05;
        _customPerspective[2] = 100.0;
        _cameraFovDegrees = 45.0;
        _cameraNear = 0.05;
        _cameraFar = 100.0;
        _animationIndex = 0;
        _animationLoop = true;
        _animationPlaying = false;
        _animationTimeSeconds = 0.0;
        _animationSpeed = 1.0;
        _lastAnimationFrameNanos = 0;
        _modelCenter = math::float3{0.0f, 0.0f, 0.0f};
        _modelExtent = math::float3{0.5f, 0.5f, 0.5f};
        _hasModelBounds = false;
        _pixelBuffer = nullptr;
        _paused = NO;
        _width = 1;
        _height = 1;
    }
    return self;
}

- (void)setupWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                       width:(int)width
                      height:(int)height {
    if (_renderer == nullptr) {
        _renderer = _engine->createRenderer();
        _view = _engine->createView();
        _scene = _engine->createScene();
        _cameraEntity = EntityManager::get().create();
        _camera = _engine->createCamera(_cameraEntity);
        _view->setScene(_scene);
        _view->setCamera(_camera);
        [self setupLight];
        [self setupLoaders];
        Renderer::ClearOptions clearOptions;
        clearOptions.clear = true;
        clearOptions.clearColor = {0.0f, 0.0f, 0.0f, 0.0f};
        _renderer->setClearOptions(clearOptions);
    }
    [self updateSwapChain:pixelBuffer width:width height:height];
}

- (void)resizeWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        width:(int)width
                       height:(int)height {
    [self updateSwapChain:pixelBuffer width:width height:height];
}

- (NSArray<NSString *> *)beginModelLoad:(NSData *)data {
    [self clearSceneInternal];
    if (_assetLoader == nullptr) {
        return @[];
    }
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data.bytes);
    FilamentAsset* asset = _assetLoader->createAsset(bytes, (uint32_t)data.length);
    if (!asset) {
        return @[];
    }
    _pendingAsset = asset;
    size_t count = asset->getResourceUriCount();
    const char* const* uris = asset->getResourceUris();
    NSMutableArray<NSString*>* list = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; ++i) {
        if (uris[i] != nullptr) {
            [list addObject:[NSString stringWithUTF8String:uris[i]]];
        }
    }
    return list;
}

- (void)finishModelLoad:(NSDictionary<NSString *, NSData *> *)resources {
    if (_pendingAsset == nullptr) {
        return;
    }
    if (_resourceLoader == nullptr) {
        return;
    }
    for (NSString* key in resources) {
        NSData* data = resources[key];
        if (data.length == 0) {
            continue;
        }
        void* buffer = malloc(data.length);
        memcpy(buffer, data.bytes, data.length);
        ResourceLoader::BufferDescriptor descriptor(buffer, data.length, ReleaseBuffer);
        _resourceLoader->addResourceData(key.UTF8String, std::move(descriptor));
    }
    _resourceLoader->loadResources(_pendingAsset);
    _pendingAsset->releaseSourceData();
    _scene->addEntities(_pendingAsset->getEntities(), _pendingAsset->getEntityCount());
    _asset = _pendingAsset;
    _pendingAsset = nullptr;
    _resourceLoader->evictResourceData();
    [self updateBoundsFromAsset];
    FilamentInstance* instance = _asset ? _asset->getInstance() : nullptr;
    _animator = instance ? instance->getAnimator() : nullptr;
    _animationPlaying = false;
    _animationTimeSeconds = 0.0;
    _lastAnimationFrameNanos = 0;
}

- (void)setIndirectLightFromKTX:(NSData *)data {
    if (_scene == nullptr) {
        return;
    }
    if (_indirectLight) {
        _engine->destroy(_indirectLight);
        _indirectLight = nullptr;
    }
    if (_iblTexture) {
        _engine->destroy(_iblTexture);
        _iblTexture = nullptr;
    }
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data.bytes);
    auto* bundle = new image::Ktx1Bundle(bytes, (uint32_t)data.length);
    math::float3 sh[9];
    const bool hasSh = bundle->getSphericalHarmonics(sh);
    _iblTexture = ktxreader::Ktx1Reader::createTexture(_engine, bundle, true);
    IndirectLight::Builder builder;
    builder.reflections(_iblTexture);
    if (hasSh) {
        builder.irradiance(3, sh);
    }
    _indirectLight = builder.build(*_engine);
    _scene->setIndirectLight(_indirectLight);
}

- (void)setSkyboxFromKTX:(NSData *)data {
    if (_scene == nullptr) {
        return;
    }
    if (_skybox) {
        _engine->destroy(_skybox);
        _skybox = nullptr;
    }
    if (_skyboxTexture) {
        _engine->destroy(_skyboxTexture);
        _skyboxTexture = nullptr;
    }
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data.bytes);
    auto* bundle = new image::Ktx1Bundle(bytes, (uint32_t)data.length);
    _skyboxTexture = ktxreader::Ktx1Reader::createTexture(_engine, bundle, true);
    _skybox = Skybox::Builder().environment(_skyboxTexture).build(*_engine);
    _scene->setSkybox(_skybox);
}

- (void)frameModel:(BOOL)useWorldOrigin {
    if (!_hasModelBounds || useWorldOrigin) {
        _orbitTarget = math::float3{0.0f, 0.0f, 0.0f};
    } else {
        _orbitTarget = _modelCenter;
    }
    const float radius = _hasModelBounds ? (float)LengthFloat3(_modelExtent) : 1.0f;
    const double distance = [self computeDistanceForRadius:radius];
    _distance = ClampValue(distance, _minDistance, _maxDistance);
    _yawDeg = 0.0;
    _pitchDeg = 0.0;
}

- (void)setOrbitConstraintsWithMinPitch:(double)minPitch
                               maxPitch:(double)maxPitch
                                minYaw:(double)minYaw
                                maxYaw:(double)maxYaw {
    _minPitchDeg = minPitch;
    _maxPitchDeg = maxPitch;
    _minYawDeg = minYaw;
    _maxYawDeg = maxYaw;
    [self clampAngles];
}

- (void)setInertiaEnabled:(BOOL)enabled {
    _inertiaEnabled = enabled;
}

- (void)setInertiaParamsWithDamping:(double)damping sensitivity:(double)sensitivity {
    _damping = damping;
    _sensitivity = sensitivity;
}

- (void)setZoomLimitsWithMinDistance:(double)minDistance maxDistance:(double)maxDistance {
    _minDistance = minDistance;
    _maxDistance = maxDistance;
    _distance = ClampValue(_distance, _minDistance, _maxDistance);
}

- (void)orbitStart {
    _velocityYaw = 0.0;
    _velocityPitch = 0.0;
}

- (void)orbitDeltaWithDx:(double)dx dy:(double)dy {
    _yawDeg += dx * _sensitivity;
    _pitchDeg += dy * _sensitivity;
    [self clampAngles];
}

- (void)orbitEndWithVelocityX:(double)velocityX velocityY:(double)velocityY {
    if (!_inertiaEnabled) {
        _velocityYaw = 0.0;
        _velocityPitch = 0.0;
        return;
    }
    _velocityYaw = velocityX * _sensitivity;
    _velocityPitch = velocityY * _sensitivity;
}

- (void)zoomDelta:(double)scaleDelta {
    if (scaleDelta <= 0.0) {
        return;
    }
    _distance = ClampValue(_distance / scaleDelta, _minDistance, _maxDistance);
}

- (void)setCustomCameraEnabled:(BOOL)enabled {
    _customCameraEnabled = enabled;
}

- (void)setCustomCameraLookAtWithEyeX:(double)eyeX
                                eyeY:(double)eyeY
                                eyeZ:(double)eyeZ
                              centerX:(double)centerX
                              centerY:(double)centerY
                              centerZ:(double)centerZ
                                  upX:(double)upX
                                  upY:(double)upY
                                  upZ:(double)upZ {
    _customLookAt[0] = eyeX;
    _customLookAt[1] = eyeY;
    _customLookAt[2] = eyeZ;
    _customLookAt[3] = centerX;
    _customLookAt[4] = centerY;
    _customLookAt[5] = centerZ;
    _customLookAt[6] = upX;
    _customLookAt[7] = upY;
    _customLookAt[8] = upZ;
}

- (void)setCustomPerspectiveWithFov:(double)fovDegrees
                               near:(double)nearPlane
                                far:(double)farPlane {
    _customPerspective[0] = fovDegrees;
    _customPerspective[1] = nearPlane;
    _customPerspective[2] = farPlane;
}

- (int)getAnimationCount {
    return _animator ? (int)_animator->getAnimationCount() : 0;
}

- (double)getAnimationDuration:(int)index {
    if (!_animator || index < 0 || index >= (int)_animator->getAnimationCount()) {
        return 0.0;
    }
    return _animator->getAnimationDuration(index);
}

- (void)playAnimation:(int)index loop:(BOOL)loop {
    if (!_animator || _animator->getAnimationCount() == 0) {
        return;
    }
    _animationIndex = std::max(0, std::min(index, (int)_animator->getAnimationCount() - 1));
    _animationLoop = loop;
    _animationPlaying = true;
    _animationTimeSeconds = 0.0;
    _lastAnimationFrameNanos = 0;
    _animator->applyAnimation(_animationIndex, 0.0f);
    _animator->updateBoneMatrices();
}

- (void)pauseAnimation {
    _animationPlaying = false;
    _lastAnimationFrameNanos = 0;
}

- (void)seekAnimation:(double)seconds {
    if (!_animator) {
        return;
    }
    double duration = _animator->getAnimationDuration(_animationIndex);
    if (duration > 0.0) {
        _animationTimeSeconds = ClampValue(seconds, 0.0, duration);
    } else {
        _animationTimeSeconds = std::max(0.0, seconds);
    }
    _animator->applyAnimation(_animationIndex, (float)_animationTimeSeconds);
    _animator->updateBoneMatrices();
}

- (void)setAnimationSpeed:(double)speed {
    _animationSpeed = speed;
}

- (void)clearScene {
    [self clearSceneInternal];
}

- (void)renderFrame:(uint64_t)frameTimeNanos {
    if (_paused) {
        return;
    }
    if (_renderer == nullptr || _swapChain == nullptr) {
        return;
    }
    [self updateAnimation:frameTimeNanos];
    [self updateCamera:frameTimeNanos];
    if (_renderer->beginFrame(_swapChain, frameTimeNanos)) {
        _renderer->render(_view);
        _renderer->endFrame();
    }
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
}

- (void)destroyRenderer {
    [self clearSceneInternal];
    if (_resourceLoader) {
        delete _resourceLoader;
        _resourceLoader = nullptr;
    }
    if (_assetLoader) {
        AssetLoader::destroy(&_assetLoader);
        _assetLoader = nullptr;
    }
    if (_textureProvider) {
        delete _textureProvider;
        _textureProvider = nullptr;
    }
    if (_materialProvider) {
        _materialProvider->destroyMaterials();
        delete _materialProvider;
        _materialProvider = nullptr;
    }
    if (_indirectLight) {
        _engine->destroy(_indirectLight);
        _indirectLight = nullptr;
    }
    if (_iblTexture) {
        _engine->destroy(_iblTexture);
        _iblTexture = nullptr;
    }
    if (_skybox) {
        _engine->destroy(_skybox);
        _skybox = nullptr;
    }
    if (_skyboxTexture) {
        _engine->destroy(_skyboxTexture);
        _skyboxTexture = nullptr;
    }
    if (_swapChain) {
        _engine->destroy(_swapChain);
        _swapChain = nullptr;
    }
    if (_view) {
        _engine->destroy(_view);
        _view = nullptr;
    }
    if (_scene) {
        _engine->destroy(_scene);
        _scene = nullptr;
    }
    if (_renderer) {
        _engine->destroy(_renderer);
        _renderer = nullptr;
    }
    if (_camera) {
        _engine->destroyCameraComponent(_cameraEntity);
        _camera = nullptr;
    }
    EntityManager::get().destroy(_cameraEntity);
    if (_lightEntity) {
        _engine->destroy(_lightEntity);
        _lightEntity.clear();
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = nullptr;
    }
}

// Private helpers

- (void)setupLight {
    _lightEntity = EntityManager::get().create();
    LightManager::Builder(LightManager::Type::DIRECTIONAL)
        .color(LinearColor{1.0f})
        .intensity(100000.0f)
        .direction(math::float3{0.0f, -1.0f, -0.5f})
        .castShadows(true)
        .build(*_engine, _lightEntity);
    _scene->addEntity(_lightEntity);
}

- (void)setupLoaders {
    _materialProvider = createUbershaderProvider(
        _engine, UBERARCHIVE_DEFAULT_DATA, UBERARCHIVE_DEFAULT_SIZE);
    AssetConfiguration config;
    config.engine = _engine;
    config.materials = _materialProvider;
    config.names = nullptr;
    config.entities = nullptr;
    config.defaultNodeName = nullptr;
    config.ext = nullptr;
    _assetLoader = AssetLoader::create(config);

    ResourceConfiguration resourceConfig;
    resourceConfig.engine = _engine;
    resourceConfig.gltfPath = nullptr;
    resourceConfig.normalizeSkinningWeights = true;
    _resourceLoader = new ResourceLoader(resourceConfig);

    _textureProvider = createStbProvider(_engine);
    _resourceLoader->addTextureProvider("image/png", _textureProvider);
    _resourceLoader->addTextureProvider("image/jpeg", _textureProvider);
}

- (void)updateSwapChain:(CVPixelBufferRef)pixelBuffer
                  width:(int)width
                 height:(int)height {
    if (_swapChain != nullptr) {
        _engine->destroy(_swapChain);
        _swapChain = nullptr;
    }
    if (_pixelBuffer != nullptr) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = nullptr;
    }
    _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    uint64_t flags = SwapChain::CONFIG_APPLE_CVPIXELBUFFER | SwapChain::CONFIG_TRANSPARENT;
    _swapChain = _engine->createSwapChain((void*)_pixelBuffer, flags);
    _width = width > 0 ? width : 1;
    _height = height > 0 ? height : 1;
    _view->setViewport({0, 0, (uint32_t)_width, (uint32_t)_height});
    const double aspect = (double)_width / (double)_height;
    _camera->setProjection(_cameraFovDegrees, aspect, _cameraNear, _cameraFar, Camera::Fov::VERTICAL);
}

- (void)clearSceneInternal {
    if (_asset && _assetLoader) {
        _scene->removeEntities(_asset->getEntities(), _asset->getEntityCount());
        _assetLoader->destroyAsset(_asset);
        _asset = nullptr;
    }
    if (_pendingAsset && _assetLoader) {
        _assetLoader->destroyAsset(_pendingAsset);
        _pendingAsset = nullptr;
    }
    _animator = nullptr;
    _animationPlaying = false;
    _animationTimeSeconds = 0.0;
    _lastAnimationFrameNanos = 0;
}

- (double)computeDistanceForRadius:(double)radius {
    const double halfFov = std::max(0.01, DegreesToRadians(_cameraFovDegrees) * 0.5);
    const double minDistance = radius / std::sin(halfFov);
    return std::max(minDistance, 0.05);
}

- (void)clampAngles {
    _yawDeg = ClampValue(_yawDeg, _minYawDeg, _maxYawDeg);
    _pitchDeg = ClampValue(_pitchDeg, _minPitchDeg, _maxPitchDeg);
}

- (void)updateCamera:(uint64_t)frameTimeNanos {
    if (_camera == nullptr) {
        return;
    }
    const double aspect = (double)_width / (double)_height;
    if (_customCameraEnabled) {
        _camera->setProjection(
            _customPerspective[0],
            aspect,
            _customPerspective[1],
            _customPerspective[2],
            Camera::Fov::VERTICAL
        );
        _camera->lookAt(
            math::double3{_customLookAt[0], _customLookAt[1], _customLookAt[2]},
            math::double3{_customLookAt[3], _customLookAt[4], _customLookAt[5]},
            math::double3{_customLookAt[6], _customLookAt[7], _customLookAt[8]}
        );
        return;
    }

    if (_lastFrameTimeNanos == 0) {
        _lastFrameTimeNanos = frameTimeNanos;
    } else {
        const double deltaSeconds = (frameTimeNanos - _lastFrameTimeNanos) / 1e9;
        _lastFrameTimeNanos = frameTimeNanos;
        if (_inertiaEnabled) {
            if (std::abs(_velocityYaw) < 0.0001 && std::abs(_velocityPitch) < 0.0001) {
                _velocityYaw = 0.0;
                _velocityPitch = 0.0;
            } else {
                _yawDeg += _velocityYaw * deltaSeconds;
                _pitchDeg += _velocityPitch * deltaSeconds;
                [self clampAngles];
                const double decay = std::pow(_damping, deltaSeconds * 60.0);
                _velocityYaw *= decay;
                _velocityPitch *= decay;
            }
        }
    }

    const double yawRad = DegreesToRadians(_yawDeg);
    const double pitchRad = DegreesToRadians(_pitchDeg);
    const double cosPitch = std::cos(pitchRad);
    const double sinPitch = std::sin(pitchRad);
    const double sinYaw = std::sin(yawRad);
    const double cosYaw = std::cos(yawRad);

    const double x = _distance * cosPitch * sinYaw;
    const double y = _distance * sinPitch;
    const double z = _distance * cosPitch * cosYaw;

    const math::double3 eye{_orbitTarget.x + x, _orbitTarget.y + y, _orbitTarget.z + z};
    const math::double3 center{_orbitTarget.x, _orbitTarget.y, _orbitTarget.z};
    _camera->lookAt(eye, center, math::double3{0.0, 1.0, 0.0});
    _camera->setProjection(_cameraFovDegrees, aspect, _cameraNear, _cameraFar, Camera::Fov::VERTICAL);
}

- (void)updateAnimation:(uint64_t)frameTimeNanos {
    if (!_animator || !_animationPlaying) {
        return;
    }
    if (_lastAnimationFrameNanos == 0) {
        _lastAnimationFrameNanos = frameTimeNanos;
        return;
    }
    const double deltaSeconds = (frameTimeNanos - _lastAnimationFrameNanos) / 1e9;
    _lastAnimationFrameNanos = frameTimeNanos;
    const double duration = _animator->getAnimationDuration(_animationIndex);
    if (duration <= 0.0) {
        return;
    }
    _animationTimeSeconds += deltaSeconds * _animationSpeed;
    if (_animationLoop) {
        _animationTimeSeconds = std::fmod(_animationTimeSeconds, duration);
        if (_animationTimeSeconds < 0.0) {
            _animationTimeSeconds += duration;
        }
    } else {
        if (_animationTimeSeconds >= duration) {
            _animationTimeSeconds = duration;
            _animationPlaying = false;
        } else if (_animationTimeSeconds < 0.0) {
            _animationTimeSeconds = 0.0;
            _animationPlaying = false;
        }
    }
    _animator->applyAnimation(_animationIndex, (float)_animationTimeSeconds);
    _animator->updateBoneMatrices();
}

- (void)updateBoundsFromAsset {
    if (_asset == nullptr) {
        _hasModelBounds = false;
        return;
    }
    const filament::Aabb bounds = _asset->getBoundingBox();
    if (bounds.isEmpty()) {
        _hasModelBounds = false;
        return;
    }
    _modelCenter = bounds.center();
    _modelExtent = bounds.extent();
    _hasModelBounds = true;
}

@end
