#import "FilamentRenderer.h"

#import <QuartzCore/CADisplayLink.h>

#undef DEBUG

#include <backend/BufferDescriptor.h>
#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/LightManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/SwapChain.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/TextureProvider.h>
#include <gltfio/materials/uberarchive.h>
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
    _camera->setProjection(45.0, aspect, 0.05, 100.0, Camera::Fov::VERTICAL);
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
}

@end
