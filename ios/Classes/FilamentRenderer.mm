#import "FilamentRenderer.h"

#import <QuartzCore/CADisplayLink.h>

#undef DEBUG

#include <backend/BufferDescriptor.h>
#include <algorithm>
#include <cmath>
#include <functional>
#include <filament/Camera.h>
#include <filament/Box.h>
#include <filament/ColorGrading.h>
#include <filament/Color.h>
#include <filament/Engine.h>
#include <filament/LightManager.h>
#include <filament/IndirectLight.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
#include <filament/Texture.h>
#include <filament/VertexBuffer.h>
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
#include "utils/JobSystem.h"
#include <utils/Entity.h>
#include <utils/EntityManager.h>
#include <unordered_set>
#include <string>
#include <vector>

using namespace filament;
using namespace filament::gltfio;
using namespace utils;

@interface FilamentRenderer ()
- (void)applyResourcePath;
- (void)resetResourceLoader;
@end

namespace {
Engine* SharedEngine() {
    static Engine* engine = []() {
#if DEBUG
        NSLog(@"[FilamentWidget] Creating Filament Engine on thread %@", [NSThread currentThread]);
#endif
        return Engine::create(Engine::Backend::METAL);
    }();
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

void EnsureJobSystemAdopted(Engine* engine) {
    static thread_local bool adopted = false;
    if (!adopted && engine != nullptr) {
#if DEBUG
        NSLog(@"[FilamentWidget] Adopting JobSystem on thread %@", [NSThread currentThread]);
#endif
        engine->getJobSystem().adopt();
        adopted = true;
    }
}

struct Matrix4 {
    double m[16];
};

Matrix4 IdentityMatrix() {
    Matrix4 out{};
    out.m[0] = 1.0;
    out.m[5] = 1.0;
    out.m[10] = 1.0;
    out.m[15] = 1.0;
    return out;
}

Matrix4 MultiplyMatrix(const Matrix4& a, const Matrix4& b) {
    Matrix4 out{};
    for (int c = 0; c < 4; ++c) {
        const int col = c * 4;
        const double b0 = b.m[col];
        const double b1 = b.m[col + 1];
        const double b2 = b.m[col + 2];
        const double b3 = b.m[col + 3];
        out.m[col] = a.m[0] * b0 + a.m[4] * b1 + a.m[8] * b2 + a.m[12] * b3;
        out.m[col + 1] = a.m[1] * b0 + a.m[5] * b1 + a.m[9] * b2 + a.m[13] * b3;
        out.m[col + 2] = a.m[2] * b0 + a.m[6] * b1 + a.m[10] * b2 + a.m[14] * b3;
        out.m[col + 3] = a.m[3] * b0 + a.m[7] * b1 + a.m[11] * b2 + a.m[15] * b3;
    }
    return out;
}

Matrix4 TranslationMatrix(double tx, double ty, double tz) {
    Matrix4 out = IdentityMatrix();
    out.m[12] = tx;
    out.m[13] = ty;
    out.m[14] = tz;
    return out;
}

Matrix4 ScaleMatrix(double sx, double sy, double sz) {
    Matrix4 out = IdentityMatrix();
    out.m[0] = sx;
    out.m[5] = sy;
    out.m[10] = sz;
    return out;
}

Matrix4 RotationMatrix(double qx, double qy, double qz, double qw) {
    const double xx = qx * qx;
    const double yy = qy * qy;
    const double zz = qz * qz;
    const double xy = qx * qy;
    const double xz = qx * qz;
    const double yz = qy * qz;
    const double wx = qw * qx;
    const double wy = qw * qy;
    const double wz = qw * qz;
    const double m00 = 1.0 - 2.0 * (yy + zz);
    const double m01 = 2.0 * (xy - wz);
    const double m02 = 2.0 * (xz + wy);
    const double m10 = 2.0 * (xy + wz);
    const double m11 = 1.0 - 2.0 * (xx + zz);
    const double m12 = 2.0 * (yz - wx);
    const double m20 = 2.0 * (xz - wy);
    const double m21 = 2.0 * (yz + wx);
    const double m22 = 1.0 - 2.0 * (xx + yy);
    Matrix4 out{};
    out.m[0] = m00;
    out.m[1] = m10;
    out.m[2] = m20;
    out.m[4] = m01;
    out.m[5] = m11;
    out.m[6] = m21;
    out.m[8] = m02;
    out.m[9] = m12;
    out.m[10] = m22;
    out.m[15] = 1.0;
    return out;
}

math::float3 TransformPosition(const Matrix4& matrix, float x, float y, float z) {
    const double tx = matrix.m[0] * x + matrix.m[4] * y + matrix.m[8] * z + matrix.m[12];
    const double ty = matrix.m[1] * x + matrix.m[5] * y + matrix.m[9] * z + matrix.m[13];
    const double tz = matrix.m[2] * x + matrix.m[6] * y + matrix.m[10] * z + matrix.m[14];
    return math::float3{(float)tx, (float)ty, (float)tz};
}

int ToInt(id value, int fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value intValue] : fallback;
}

double ToDouble(id value, double fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value doubleValue] : fallback;
}

NSDictionary* ParseGltfJson(NSData* data, NSData** outBinChunk) {
    if (outBinChunk) {
        *outBinChunk = nil;
    }
    if (data.length >= 12) {
        const uint8_t* bytes = (const uint8_t*)data.bytes;
        const uint32_t magic = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
        if (magic == 0x46546C67) {
            const uint32_t length = bytes[8] | (bytes[9] << 8) | (bytes[10] << 16) | (bytes[11] << 24);
            if (length > data.length || length < 12) {
                return nil;
            }
            size_t offset = 12;
            NSData* jsonChunk = nil;
            NSData* binChunk = nil;
            while (offset + 8 <= data.length) {
                const uint32_t chunkLength =
                    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
                const uint32_t chunkType =
                    bytes[offset + 4] | (bytes[offset + 5] << 8) | (bytes[offset + 6] << 16) | (bytes[offset + 7] << 24);
                offset += 8;
                if (offset + chunkLength > data.length) {
                    return nil;
                }
                NSData* chunkData = [data subdataWithRange:NSMakeRange(offset, chunkLength)];
                if (chunkType == 0x4E4F534A) {
                    jsonChunk = chunkData;
                } else if (chunkType == 0x004E4942) {
                    binChunk = chunkData;
                }
                offset += chunkLength;
            }
            if (!jsonChunk) {
                return nil;
            }
            NSDictionary* json = [NSJSONSerialization JSONObjectWithData:jsonChunk options:0 error:nil];
            if (outBinChunk) {
                *outBinChunk = binChunk;
            }
            return [json isKindOfClass:[NSDictionary class]] ? json : nil;
        }
    }
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

NSData* DecodeDataUri(NSString* uri) {
    NSRange comma = [uri rangeOfString:@","];
    if (comma.location == NSNotFound) {
        return nil;
    }
    NSString* meta = [uri substringWithRange:NSMakeRange(5, comma.location - 5)];
    NSString* dataPart = [uri substringFromIndex:comma.location + 1];
    if ([meta hasSuffix:@";base64"]) {
        return [[NSData alloc] initWithBase64EncodedString:dataPart options:0];
    }
    NSString* decoded = [dataPart stringByRemovingPercentEncoding] ?: dataPart;
    return [decoded dataUsingEncoding:NSUTF8StringEncoding];
}

NSData* ResolveResourceData(
    NSString* uri,
    NSDictionary<NSString*, NSData*>* resources,
    NSData* embeddedBin,
    NSString* basePath) {
    if (!uri) {
        return embeddedBin;
    }
    if ([uri hasPrefix:@"data:"]) {
        return DecodeDataUri(uri);
    }
    NSData* data = resources[uri];
    if (!data) {
        NSString* decoded = [uri stringByRemovingPercentEncoding];
        if (decoded) {
            data = resources[decoded];
        }
    }
    if (!data && [uri hasPrefix:@"./"]) {
        NSString* trimmed = [uri substringFromIndex:2];
        data = resources[trimmed];
    }
    if (!data) {
        NSString* last = uri.lastPathComponent;
        data = resources[last];
    }
    if (!data && basePath.length > 0) {
        NSString* candidate = uri;
        if ([candidate hasPrefix:@"/"]) {
            data = [NSData dataWithContentsOfFile:candidate];
        } else {
            data = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:candidate]];
        }
        if (!data) {
            NSString* decoded = [uri stringByRemovingPercentEncoding];
            if (decoded && ![decoded isEqualToString:uri]) {
                if ([decoded hasPrefix:@"/"]) {
                    data = [NSData dataWithContentsOfFile:decoded];
                } else {
                    data = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:decoded]];
                }
            }
        }
        if (!data && [uri hasPrefix:@"./"] && uri.length > 2) {
            NSString* trimmed = [uri substringFromIndex:2];
            data = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:trimmed]];
        }
        if (!data) {
            NSString* last = uri.lastPathComponent;
            data = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:last]];
        }
    }
    return data ?: embeddedBin;
}

struct BufferViewInfo {
    int buffer;
    size_t byteOffset;
    size_t byteLength;
    size_t byteStride;
};

struct AccessorInfo {
    int bufferView;
    size_t byteOffset;
    int componentType;
    size_t count;
    std::string type;
    bool hasSparse;
};

bool ReadAccessorVec3(
    const AccessorInfo& accessor,
    const std::vector<BufferViewInfo>& views,
    const std::vector<NSData*>& buffers,
    std::vector<float>& out) {
    if (accessor.bufferView < 0 || accessor.componentType != 5126 || accessor.type != "VEC3" || accessor.hasSparse) {
        return false;
    }
    if (accessor.bufferView >= (int)views.size()) {
        return false;
    }
    const BufferViewInfo& view = views[accessor.bufferView];
    if (view.buffer < 0 || view.buffer >= (int)buffers.size()) {
        return false;
    }
    NSData* data = buffers[view.buffer];
    if (!data) {
        return false;
    }
    const uint8_t* bytes = (const uint8_t*)data.bytes;
    const size_t length = data.length;
    const size_t stride = view.byteStride > 0 ? view.byteStride : sizeof(float) * 3;
    const size_t offset = view.byteOffset + accessor.byteOffset;
    if (offset + stride * std::max<size_t>(0, accessor.count - 1) + sizeof(float) * 3 > length) {
        return false;
    }
    out.resize(accessor.count * 3);
    size_t cursor = offset;
    size_t outIndex = 0;
    for (size_t i = 0; i < accessor.count; ++i) {
        float x = 0.0f;
        float y = 0.0f;
        float z = 0.0f;
        memcpy(&x, bytes + cursor, sizeof(float));
        memcpy(&y, bytes + cursor + sizeof(float), sizeof(float));
        memcpy(&z, bytes + cursor + sizeof(float) * 2, sizeof(float));
        out[outIndex++] = x;
        out[outIndex++] = y;
        out[outIndex++] = z;
        cursor += stride;
    }
    return true;
}

bool ReadAccessorIndices(
    const AccessorInfo& accessor,
    const std::vector<BufferViewInfo>& views,
    const std::vector<NSData*>& buffers,
    std::vector<uint32_t>& out) {
    if (accessor.bufferView < 0 || accessor.type != "SCALAR" || accessor.hasSparse) {
        return false;
    }
    if (accessor.bufferView >= (int)views.size()) {
        return false;
    }
    const BufferViewInfo& view = views[accessor.bufferView];
    if (view.buffer < 0 || view.buffer >= (int)buffers.size()) {
        return false;
    }
    NSData* data = buffers[view.buffer];
    if (!data) {
        return false;
    }
    const uint8_t* bytes = (const uint8_t*)data.bytes;
    const size_t length = data.length;
    size_t componentSize = 0;
    switch (accessor.componentType) {
        case 5121:
            componentSize = 1;
            break;
        case 5123:
            componentSize = 2;
            break;
        case 5125:
            componentSize = 4;
            break;
        default:
            return false;
    }
    const size_t stride = view.byteStride > 0 ? view.byteStride : componentSize;
    const size_t offset = view.byteOffset + accessor.byteOffset;
    if (offset + stride * std::max<size_t>(0, accessor.count - 1) + componentSize > length) {
        return false;
    }
    out.resize(accessor.count);
    size_t cursor = offset;
    for (size_t i = 0; i < accessor.count; ++i) {
        uint32_t value = 0;
        if (componentSize == 1) {
            value = bytes[cursor];
        } else if (componentSize == 2) {
            uint16_t tmp = 0;
            memcpy(&tmp, bytes + cursor, sizeof(uint16_t));
            value = tmp;
        } else {
            uint32_t tmp = 0;
            memcpy(&tmp, bytes + cursor, sizeof(uint32_t));
            value = tmp;
        }
        out[i] = value;
        cursor += stride;
    }
    return true;
}

std::vector<uint32_t> BuildWireframeEdges(const std::vector<uint32_t>& indices, int mode) {
    std::vector<uint32_t> edges;
    if (indices.size() < 3) {
        return edges;
    }
    std::unordered_set<uint64_t> seen;
    auto addEdge = [&](uint32_t a, uint32_t b) {
        const uint32_t minIndex = std::min(a, b);
        const uint32_t maxIndex = std::max(a, b);
        const uint64_t key = (uint64_t(minIndex) << 32) | maxIndex;
        if (seen.insert(key).second) {
            edges.push_back(a);
            edges.push_back(b);
        }
    };
    if (mode == 4) {
        const size_t triCount = indices.size() / 3;
        for (size_t i = 0; i < triCount; ++i) {
            const size_t base = i * 3;
            const uint32_t a = indices[base];
            const uint32_t b = indices[base + 1];
            const uint32_t c = indices[base + 2];
            addEdge(a, b);
            addEdge(b, c);
            addEdge(c, a);
        }
    } else if (mode == 5) {
        for (size_t i = 0; i + 2 < indices.size(); ++i) {
            uint32_t a = indices[i];
            uint32_t b = indices[i + 1];
            uint32_t c = indices[i + 2];
            if (i % 2 == 1) {
                std::swap(b, c);
            }
            addEdge(a, b);
            addEdge(b, c);
            addEdge(c, a);
        }
    } else if (mode == 6) {
        const uint32_t first = indices[0];
        for (size_t i = 1; i + 1 < indices.size(); ++i) {
            const uint32_t a = first;
            const uint32_t b = indices[i];
            const uint32_t c = indices[i + 1];
            addEdge(a, b);
            addEdge(b, c);
            addEdge(c, a);
        }
    }
    return edges;
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
    NSData* _pendingSourceData;
    std::string _resourceRoot;
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
    ColorGrading* _colorGrading;
    int _msaaSamples;
    bool _dynamicResolutionEnabled;
    bool _environmentEnabled;
    Material* _debugLineMaterial;
    MaterialInstance* _wireframeMaterialInstance;
    VertexBuffer* _wireframeVertexBuffer;
    IndexBuffer* _wireframeIndexBuffer;
    MaterialInstance* _boundsMaterialInstance;
    VertexBuffer* _boundsVertexBuffer;
    IndexBuffer* _boundsIndexBuffer;
    Entity _wireframeEntity;
    Entity _boundsEntity;
    bool _wireframeEnabled;
    bool _boundingBoxesEnabled;
    bool _hasWireframeData;
    std::vector<float> _wireframePositions;
    std::vector<uint32_t> _wireframeIndices;
    bool _debugLoggingEnabled;
    FilamentFpsCallback _fpsCallback;
    FilamentFrameCallback _frameCallback;
    uint64_t _fpsStartTimeNanos;
    int _fpsFrameCount;
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
        _engine = nullptr;
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
        _pendingSourceData = nil;
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
        _colorGrading = nullptr;
        _msaaSamples = 2;
        _dynamicResolutionEnabled = true;
        _environmentEnabled = true;
        _debugLineMaterial = nullptr;
        _wireframeMaterialInstance = nullptr;
        _wireframeVertexBuffer = nullptr;
        _wireframeIndexBuffer = nullptr;
        _boundsMaterialInstance = nullptr;
        _boundsVertexBuffer = nullptr;
        _boundsIndexBuffer = nullptr;
        _wireframeEntity = {};
        _boundsEntity = {};
        _wireframeEnabled = false;
        _boundingBoxesEnabled = false;
        _hasWireframeData = false;
        _debugLoggingEnabled = false;
        _fpsCallback = nil;
        _frameCallback = nil;
        _fpsStartTimeNanos = 0;
        _fpsFrameCount = 0;
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
    if (_engine == nullptr) {
        _engine = SharedEngine();
    }
    EnsureJobSystemAdopted(_engine);
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
        _view->setSampleCount((uint8_t)_msaaSamples);
        [self setDynamicResolutionEnabled:_dynamicResolutionEnabled];
        [self setToneMappingFilmic];
        _view->setShadowingEnabled(true);
    }
    [self updateSwapChain:pixelBuffer width:width height:height];
}

- (void)resizeWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        width:(int)width
                       height:(int)height {
    EnsureJobSystemAdopted(_engine);
    [self updateSwapChain:pixelBuffer width:width height:height];
}

- (NSArray<NSString *> *)beginModelLoad:(NSData *)data {
    EnsureJobSystemAdopted(_engine);
    [self clearSceneInternal];
    [self resetResourceLoader];
    if (_assetLoader == nullptr) {
        return @[];
    }
    _pendingSourceData = data;
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data.bytes);
    FilamentAsset* asset = _assetLoader->createAsset(bytes, (uint32_t)data.length);
    if (!asset) {
        _pendingSourceData = nil;
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

- (BOOL)finishModelLoad:(NSDictionary<NSString *, NSData *> *)resources {
    EnsureJobSystemAdopted(_engine);
    if (_pendingAsset == nullptr || _resourceLoader == nullptr) {
        return NO;
    }
    std::unordered_set<std::string> addedKeys;
    auto addResource = [&](const std::string& key, NSData* data) {
        if (key.empty()) {
            return;
        }
        if (!addedKeys.insert(key).second) {
            return;
        }
        void* buffer = malloc(data.length);
        memcpy(buffer, data.bytes, data.length);
        ResourceLoader::BufferDescriptor descriptor(buffer, data.length, ReleaseBuffer);
        _resourceLoader->addResourceData(key.c_str(), std::move(descriptor));
    };
    auto combinePath = [&](const std::string& base, const std::string& uri) -> std::string {
        if (base.empty() || uri.empty()) {
            return uri;
        }
        const size_t slash = base.find_last_of("/\\");
        if (slash == std::string::npos) {
            return uri;
        }
        return base.substr(0, slash + 1) + uri;
    };
    auto addResourceVariants = [&](const std::string& uri, NSData* data) {
        addResource(uri, data);
        if (!uri.empty()) {
            addResource(combinePath(_resourceRoot, uri), data);
            if (uri.rfind("./", 0) == 0 && uri.size() > 2) {
                std::string trimmed = uri.substr(2);
                addResource(trimmed, data);
                addResource(combinePath(_resourceRoot, trimmed), data);
            }
        }
    };
    for (NSString* key in resources) {
        NSData* data = resources[key];
        if (data.length == 0) {
            continue;
        }
        std::string uri(key.UTF8String);
        addResourceVariants(uri, data);
        NSString* decodedKey = [key stringByRemovingPercentEncoding];
        if (decodedKey && ![decodedKey isEqualToString:key]) {
            std::string decodedUri(decodedKey.UTF8String);
            addResourceVariants(decodedUri, data);
        }
    }
    const bool loaded = _resourceLoader->loadResources(_pendingAsset);
    if (!loaded) {
        [self logDebug:@"ResourceLoader failed to load resources."];
        if (_assetLoader) {
            _assetLoader->destroyAsset(_pendingAsset);
        }
        _pendingAsset = nullptr;
        _pendingSourceData = nil;
        _resourceLoader->evictResourceData();
        return NO;
    }
    [self buildWireframeData:resources];
    _engine->flushAndWait();
    _pendingAsset->releaseSourceData();
    _pendingSourceData = nil;
    _scene->addEntities(_pendingAsset->getEntities(), _pendingAsset->getEntityCount());
    _asset = _pendingAsset;
    _pendingAsset = nullptr;
    [self updateBoundsFromAsset];
    FilamentInstance* instance = _asset ? _asset->getInstance() : nullptr;
    _animator = instance ? instance->getAnimator() : nullptr;
    _animationPlaying = false;
    _animationTimeSeconds = 0.0;
    _lastAnimationFrameNanos = 0;
    [self updateWireframe];
    [self rebuildBoundsRenderable];
    return YES;
}

- (void)setIndirectLightFromKTX:(NSData *)data {
    EnsureJobSystemAdopted(_engine);
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
    EnsureJobSystemAdopted(_engine);
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
    _scene->setSkybox(_environmentEnabled ? _skybox : nullptr);
}

- (void)frameModel:(BOOL)useWorldOrigin {
    EnsureJobSystemAdopted(_engine);
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
    EnsureJobSystemAdopted(_engine);
    _minPitchDeg = minPitch;
    _maxPitchDeg = maxPitch;
    _minYawDeg = minYaw;
    _maxYawDeg = maxYaw;
    [self clampAngles];
}

- (void)setInertiaEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    _inertiaEnabled = enabled;
}

- (void)setInertiaParamsWithDamping:(double)damping sensitivity:(double)sensitivity {
    EnsureJobSystemAdopted(_engine);
    _damping = damping;
    _sensitivity = sensitivity;
}

- (void)setZoomLimitsWithMinDistance:(double)minDistance maxDistance:(double)maxDistance {
    EnsureJobSystemAdopted(_engine);
    _minDistance = minDistance;
    _maxDistance = maxDistance;
    _distance = ClampValue(_distance, _minDistance, _maxDistance);
}

- (void)orbitStart {
    EnsureJobSystemAdopted(_engine);
    _velocityYaw = 0.0;
    _velocityPitch = 0.0;
}

- (void)orbitDeltaWithDx:(double)dx dy:(double)dy {
    EnsureJobSystemAdopted(_engine);
    _yawDeg -= dx * _sensitivity;
    _pitchDeg += dy * _sensitivity;
    [self clampAngles];
}

- (void)orbitEndWithVelocityX:(double)velocityX velocityY:(double)velocityY {
    EnsureJobSystemAdopted(_engine);
    if (!_inertiaEnabled) {
        _velocityYaw = 0.0;
        _velocityPitch = 0.0;
        return;
    }
    _velocityYaw = -velocityX * _sensitivity;
    _velocityPitch = velocityY * _sensitivity;
}

- (void)zoomDelta:(double)scaleDelta {
    EnsureJobSystemAdopted(_engine);
    if (scaleDelta <= 0.0) {
        return;
    }
    _distance = ClampValue(_distance / scaleDelta, _minDistance, _maxDistance);
}

- (void)setCustomCameraEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
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
    EnsureJobSystemAdopted(_engine);
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
    EnsureJobSystemAdopted(_engine);
    _customPerspective[0] = fovDegrees;
    _customPerspective[1] = nearPlane;
    _customPerspective[2] = farPlane;
}

- (void)setMsaa:(int)samples {
    EnsureJobSystemAdopted(_engine);
    if (samples == 2 || samples == 4) {
        _msaaSamples = samples;
    } else {
        _msaaSamples = 1;
    }
    if (_view) {
        _view->setSampleCount((uint8_t)_msaaSamples);
    }
}

- (void)setDynamicResolutionEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    _dynamicResolutionEnabled = enabled;
    if (!_view) {
        return;
    }
    View::DynamicResolutionOptions options = _view->getDynamicResolutionOptions();
    options.enabled = enabled;
    options.minScale = 0.5f;
    options.maxScale = 1.0f;
    options.sharpness = 0.9f;
    _view->setDynamicResolutionOptions(options);
}

- (void)setEnvironmentEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    _environmentEnabled = enabled;
    if (!_scene) {
        return;
    }
    _scene->setSkybox(enabled ? _skybox : nullptr);
}

- (void)setToneMappingFilmic {
    EnsureJobSystemAdopted(_engine);
    if (!_view) {
        return;
    }
    if (_colorGrading) {
        _engine->destroy(_colorGrading);
        _colorGrading = nullptr;
    }
    _colorGrading = ColorGrading::Builder()
        .toneMapping(ColorGrading::ToneMapping::FILMIC)
        .build(*_engine);
    _view->setColorGrading(_colorGrading);
}

- (void)setShadowsEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    if (_view) {
        _view->setShadowingEnabled(enabled);
    }
}

- (void)setWireframeEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    _wireframeEnabled = enabled;
    [self updateWireframe];
}

- (void)setBoundingBoxesEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    _boundingBoxesEnabled = enabled;
    [self rebuildBoundsRenderable];
}

- (void)setDebugLoggingEnabled:(BOOL)enabled {
    EnsureJobSystemAdopted(_engine);
    _debugLoggingEnabled = enabled;
    [self logDebug:[NSString stringWithFormat:@"Debug logging %@.", enabled ? @"enabled" : @"disabled"]];
}

- (void)setFpsCallback:(FilamentFpsCallback)callback {
    _fpsCallback = [callback copy];
}

- (void)setFrameCallback:(FilamentFrameCallback)callback {
    _frameCallback = [callback copy];
}

- (void)setResourcePath:(NSString *)path {
    EnsureJobSystemAdopted(_engine);
    if (path.length == 0) {
        _resourceRoot.clear();
    } else {
        _resourceRoot = std::string(path.UTF8String);
    }
    [self applyResourcePath];
}

- (int)getAnimationCount {
    EnsureJobSystemAdopted(_engine);
    return _animator ? (int)_animator->getAnimationCount() : 0;
}

- (double)getAnimationDuration:(int)index {
    EnsureJobSystemAdopted(_engine);
    if (!_animator || index < 0 || index >= (int)_animator->getAnimationCount()) {
        return 0.0;
    }
    return _animator->getAnimationDuration(index);
}

- (void)playAnimation:(int)index loop:(BOOL)loop {
    EnsureJobSystemAdopted(_engine);
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
    EnsureJobSystemAdopted(_engine);
    _animationPlaying = false;
    _lastAnimationFrameNanos = 0;
}

- (void)seekAnimation:(double)seconds {
    EnsureJobSystemAdopted(_engine);
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
    EnsureJobSystemAdopted(_engine);
    _animationSpeed = speed;
}

- (void)clearScene {
    EnsureJobSystemAdopted(_engine);
    [self clearSceneInternal];
}

- (void)renderFrame:(uint64_t)frameTimeNanos {
    EnsureJobSystemAdopted(_engine);
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
        if (_frameCallback) {
            _frameCallback();
        }
        [self updateFps:frameTimeNanos];
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
    if (_colorGrading) {
        _engine->destroy(_colorGrading);
        _colorGrading = nullptr;
    }
    [self destroyWireframeRenderable];
    _wireframePositions.clear();
    _wireframeIndices.clear();
    _hasWireframeData = false;
    if (_wireframeMaterialInstance) {
        _engine->destroy(_wireframeMaterialInstance);
        _wireframeMaterialInstance = nullptr;
    }
    _frameCallback = nil;
    if (_boundsMaterialInstance) {
        _engine->destroy(_boundsMaterialInstance);
        _boundsMaterialInstance = nullptr;
    }
    if (_debugLineMaterial) {
        _engine->destroy(_debugLineMaterial);
        _debugLineMaterial = nullptr;
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
    resourceConfig.gltfPath = _resourceRoot.empty() ? nullptr : _resourceRoot.c_str();
    resourceConfig.normalizeSkinningWeights = true;
    _resourceLoader = new ResourceLoader(resourceConfig);

    _textureProvider = createStbProvider(_engine);
    _resourceLoader->addTextureProvider("image/png", _textureProvider);
    _resourceLoader->addTextureProvider("image/jpeg", _textureProvider);
    [self applyResourcePath];
}

- (void)applyResourcePath {
    if (_resourceLoader == nullptr) {
        return;
    }
    if (_resourceRoot.empty()) {
        return;
    }
    ResourceConfiguration resourceConfig;
    resourceConfig.engine = _engine;
    resourceConfig.gltfPath = _resourceRoot.c_str();
    resourceConfig.normalizeSkinningWeights = true;
    _resourceLoader->setConfiguration(resourceConfig);
}

- (void)resetResourceLoader {
    if (_resourceLoader != nullptr) {
        _resourceLoader->evictResourceData();
        delete _resourceLoader;
        _resourceLoader = nullptr;
    }
    ResourceConfiguration resourceConfig;
    resourceConfig.engine = _engine;
    resourceConfig.gltfPath = _resourceRoot.empty() ? nullptr : _resourceRoot.c_str();
    resourceConfig.normalizeSkinningWeights = true;
    _resourceLoader = new ResourceLoader(resourceConfig);
    if (_textureProvider == nullptr) {
        _textureProvider = createStbProvider(_engine);
    }
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
    _pendingSourceData = nil;
    [self destroyWireframeRenderable];
    _wireframePositions.clear();
    _wireframeIndices.clear();
    _hasWireframeData = false;
    [self destroyBoundsRenderable];
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

- (Material*)ensureDebugLineMaterial {
    if (_debugLineMaterial) {
        return _debugLineMaterial;
    }
    NSBundle* bundle = [NSBundle bundleForClass:[FilamentRenderer class]];
    NSURL* url = [bundle URLForResource:@"wireframe" withExtension:@"filamat"];
    if (!url) {
        [self logDebug:@"wireframe.filamat not found in bundle."];
        return nullptr;
    }
    NSData* data = [NSData dataWithContentsOfURL:url];
    if (!data) {
        [self logDebug:@"Failed to load wireframe.filamat data."];
        return nullptr;
    }
    _debugLineMaterial = Material::Builder()
        .package(data.bytes, data.length)
        .build(*_engine);
    return _debugLineMaterial;
}

- (void)buildWireframeData:(NSDictionary<NSString *, NSData *> *)resources {
    _wireframePositions.clear();
    _wireframeIndices.clear();
    _hasWireframeData = false;
    if (!_pendingSourceData) {
        return;
    }
    NSData* binChunk = nil;
    NSDictionary* json = ParseGltfJson(_pendingSourceData, &binChunk);
    if (!json) {
        return;
    }
    NSArray* buffersJson = json[@"buffers"];
    NSArray* bufferViewsJson = json[@"bufferViews"];
    NSArray* accessorsJson = json[@"accessors"];
    NSArray* meshesJson = json[@"meshes"];
    if (![buffersJson isKindOfClass:[NSArray class]] ||
        ![bufferViewsJson isKindOfClass:[NSArray class]] ||
        ![accessorsJson isKindOfClass:[NSArray class]] ||
        ![meshesJson isKindOfClass:[NSArray class]]) {
        return;
    }
    NSMutableDictionary<NSString*, NSData*>* resourceMap =
        resources ? [resources mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString* key in resources) {
        NSData* data = resources[key];
        if (key.length == 0 || data.length == 0) {
            continue;
        }
        NSString* decoded = [key stringByRemovingPercentEncoding];
        if (decoded && ![decoded isEqualToString:key]) {
            resourceMap[decoded] = data;
        }
        if ([key hasPrefix:@"./"] && key.length > 2) {
            NSString* trimmed = [key substringFromIndex:2];
            resourceMap[trimmed] = data;
        }
        NSString* last = key.lastPathComponent;
        if (last.length > 0 && ![last isEqualToString:key]) {
            resourceMap[last] = data;
        }
    }
    NSString* basePath = nil;
    if (!_resourceRoot.empty()) {
        NSString* rootPath = [NSString stringWithUTF8String:_resourceRoot.c_str()];
        if (rootPath.length > 0) {
            basePath = [rootPath stringByDeletingLastPathComponent];
        }
    }
    std::vector<NSData*> buffers;
    buffers.reserve(buffersJson.count);
    for (id entry in buffersJson) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            return;
        }
        NSDictionary* buffer = (NSDictionary*)entry;
        NSString* uri = [buffer[@"uri"] isKindOfClass:[NSString class]] ? buffer[@"uri"] : nil;
        NSData* data = ResolveResourceData(uri, resourceMap, binChunk, basePath);
        if (!data) {
            return;
        }
        buffers.push_back(data);
    }
    std::vector<BufferViewInfo> views;
    views.reserve(bufferViewsJson.count);
    for (id entry in bufferViewsJson) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary* view = (NSDictionary*)entry;
        BufferViewInfo info{};
        info.buffer = ToInt(view[@"buffer"], -1);
        info.byteOffset = (size_t)ToInt(view[@"byteOffset"], 0);
        info.byteLength = (size_t)ToInt(view[@"byteLength"], 0);
        info.byteStride = (size_t)ToInt(view[@"byteStride"], 0);
        views.push_back(info);
    }
    std::vector<AccessorInfo> accessors;
    accessors.reserve(accessorsJson.count);
    for (id entry in accessorsJson) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary* accessor = (NSDictionary*)entry;
        AccessorInfo info{};
        info.bufferView = ToInt(accessor[@"bufferView"], -1);
        info.byteOffset = (size_t)ToInt(accessor[@"byteOffset"], 0);
        info.componentType = ToInt(accessor[@"componentType"], -1);
        info.count = (size_t)ToInt(accessor[@"count"], 0);
        info.hasSparse = accessor[@"sparse"] != nil;
        NSString* type = [accessor[@"type"] isKindOfClass:[NSString class]] ? accessor[@"type"] : @"";
        info.type = type.UTF8String ? type.UTF8String : "";
        accessors.push_back(info);
    }
    NSArray* nodesJson = [json[@"nodes"] isKindOfClass:[NSArray class]] ? json[@"nodes"] : @[];
    const size_t nodeCount = nodesJson.count;
    std::vector<Matrix4> local(nodeCount, IdentityMatrix());
    std::vector<std::vector<int>> children(nodeCount);
    std::vector<bool> hasParent(nodeCount, false);
    for (size_t i = 0; i < nodeCount; ++i) {
        NSDictionary* node = [nodesJson[i] isKindOfClass:[NSDictionary class]] ? nodesJson[i] : nil;
        if (!node) {
            continue;
        }
        NSArray* matrixArray = [node[@"matrix"] isKindOfClass:[NSArray class]] ? node[@"matrix"] : nil;
        if (matrixArray && matrixArray.count == 16) {
            Matrix4 mat{};
            for (int m = 0; m < 16; ++m) {
                mat.m[m] = ToDouble(matrixArray[m], (m % 5 == 0) ? 1.0 : 0.0);
            }
            local[i] = mat;
        } else {
            NSArray* t = [node[@"translation"] isKindOfClass:[NSArray class]] ? node[@"translation"] : nil;
            NSArray* r = [node[@"rotation"] isKindOfClass:[NSArray class]] ? node[@"rotation"] : nil;
            NSArray* s = [node[@"scale"] isKindOfClass:[NSArray class]] ? node[@"scale"] : nil;
            const double tx = t ? ToDouble(t[0], 0.0) : 0.0;
            const double ty = t ? ToDouble(t[1], 0.0) : 0.0;
            const double tz = t ? ToDouble(t[2], 0.0) : 0.0;
            const double qx = r ? ToDouble(r[0], 0.0) : 0.0;
            const double qy = r ? ToDouble(r[1], 0.0) : 0.0;
            const double qz = r ? ToDouble(r[2], 0.0) : 0.0;
            const double qw = r ? ToDouble(r[3], 1.0) : 1.0;
            const double sx = s ? ToDouble(s[0], 1.0) : 1.0;
            const double sy = s ? ToDouble(s[1], 1.0) : 1.0;
            const double sz = s ? ToDouble(s[2], 1.0) : 1.0;
            Matrix4 mat = MultiplyMatrix(
                TranslationMatrix(tx, ty, tz),
                MultiplyMatrix(RotationMatrix(qx, qy, qz, qw), ScaleMatrix(sx, sy, sz))
            );
            local[i] = mat;
        }
        NSArray* childrenArray = [node[@"children"] isKindOfClass:[NSArray class]] ? node[@"children"] : nil;
        if (childrenArray) {
            std::vector<int> list;
            list.reserve(childrenArray.count);
            for (id childValue in childrenArray) {
                const int childIndex = ToInt(childValue, -1);
                list.push_back(childIndex);
                if (childIndex >= 0 && childIndex < (int)nodeCount) {
                    hasParent[childIndex] = true;
                }
            }
            children[i] = list;
        }
    }
    std::vector<Matrix4> world(nodeCount, IdentityMatrix());
    std::vector<int> roots;
    NSArray* scenesJson = [json[@"scenes"] isKindOfClass:[NSArray class]] ? json[@"scenes"] : nil;
    const int sceneIndex = ToInt(json[@"scene"], 0);
    if (scenesJson && scenesJson.count > 0) {
        NSDictionary* scene = [scenesJson[std::max(0, std::min(sceneIndex, (int)scenesJson.count - 1))] isKindOfClass:[NSDictionary class]]
            ? scenesJson[std::max(0, std::min(sceneIndex, (int)scenesJson.count - 1))]
            : nil;
        NSArray* sceneNodes = [scene[@"nodes"] isKindOfClass:[NSArray class]] ? scene[@"nodes"] : nil;
        if (sceneNodes) {
            for (id nodeValue in sceneNodes) {
                const int nodeIndex = ToInt(nodeValue, -1);
                if (nodeIndex >= 0 && nodeIndex < (int)nodeCount) {
                    roots.push_back(nodeIndex);
                }
            }
        }
    }
    if (roots.empty()) {
        for (size_t i = 0; i < nodeCount; ++i) {
            if (!hasParent[i]) {
                roots.push_back((int)i);
            }
        }
    }
    if (roots.empty()) {
        roots.push_back(0);
    }
    std::function<void(int, const Matrix4&)> walk = [&](int index, const Matrix4& parent) {
        if (index < 0 || index >= (int)nodeCount) {
            return;
        }
        Matrix4 worldMatrix = MultiplyMatrix(parent, local[index]);
        world[index] = worldMatrix;
        for (int child : children[index]) {
            walk(child, worldMatrix);
        }
    };
    Matrix4 identity = IdentityMatrix();
    for (int root : roots) {
        walk(root, identity);
    }
    for (size_t nodeIndex = 0; nodeIndex < nodeCount; ++nodeIndex) {
        NSDictionary* node = [nodesJson[nodeIndex] isKindOfClass:[NSDictionary class]] ? nodesJson[nodeIndex] : nil;
        if (!node) {
            continue;
        }
        const int meshIndex = ToInt(node[@"mesh"], -1);
        if (meshIndex < 0 || meshIndex >= (int)meshesJson.count) {
            continue;
        }
        NSDictionary* mesh = [meshesJson[meshIndex] isKindOfClass:[NSDictionary class]] ? meshesJson[meshIndex] : nil;
        NSArray* primitives = [mesh[@"primitives"] isKindOfClass:[NSArray class]] ? mesh[@"primitives"] : nil;
        if (!mesh || !primitives) {
            continue;
        }
        for (id primEntry in primitives) {
            NSDictionary* primitive = [primEntry isKindOfClass:[NSDictionary class]] ? primEntry : nil;
            NSDictionary* attributes = [primitive[@"attributes"] isKindOfClass:[NSDictionary class]] ? primitive[@"attributes"] : nil;
            if (!primitive || !attributes) {
                continue;
            }
            const int positionIndex = ToInt(attributes[@"POSITION"], -1);
            if (positionIndex < 0 || positionIndex >= (int)accessors.size()) {
                continue;
            }
            std::vector<float> positions;
            if (!ReadAccessorVec3(accessors[positionIndex], views, buffers, positions)) {
                continue;
            }
            const size_t vertexCount = positions.size() / 3;
            if (vertexCount == 0) {
                continue;
            }
            std::vector<float> transformed(positions.size());
            for (size_t i = 0; i < positions.size(); i += 3) {
                math::float3 p = TransformPosition(world[nodeIndex], positions[i], positions[i + 1], positions[i + 2]);
                transformed[i] = p.x;
                transformed[i + 1] = p.y;
                transformed[i + 2] = p.z;
            }
            const uint32_t baseVertex = (uint32_t)(_wireframePositions.size() / 3);
            _wireframePositions.insert(_wireframePositions.end(), transformed.begin(), transformed.end());
            std::vector<uint32_t> indices;
            if (primitive[@"indices"]) {
                const int indexAccessorIndex = ToInt(primitive[@"indices"], -1);
                if (indexAccessorIndex < 0 || indexAccessorIndex >= (int)accessors.size()) {
                    continue;
                }
                if (!ReadAccessorIndices(accessors[indexAccessorIndex], views, buffers, indices)) {
                    continue;
                }
            } else {
                indices.resize(vertexCount);
                for (size_t i = 0; i < vertexCount; ++i) {
                    indices[i] = (uint32_t)i;
                }
            }
            bool valid = true;
            for (uint32_t idx : indices) {
                if (idx >= vertexCount) {
                    valid = false;
                    break;
                }
            }
            if (!valid) {
                continue;
            }
            const int mode = ToInt(primitive[@"mode"], 4);
            std::vector<uint32_t> edges = BuildWireframeEdges(indices, mode);
            if (edges.empty()) {
                continue;
            }
            for (uint32_t edge : edges) {
                _wireframeIndices.push_back(baseVertex + edge);
            }
        }
    }
    if (!_wireframePositions.empty()) {
        float minX = _wireframePositions[0];
        float maxX = _wireframePositions[0];
        float minY = _wireframePositions[1];
        float maxY = _wireframePositions[1];
        float minZ = _wireframePositions[2];
        float maxZ = _wireframePositions[2];
        for (size_t i = 0; i + 2 < _wireframePositions.size(); i += 3) {
            const float x = _wireframePositions[i];
            const float y = _wireframePositions[i + 1];
            const float z = _wireframePositions[i + 2];
            minX = std::min(minX, x);
            maxX = std::max(maxX, x);
            minY = std::min(minY, y);
            maxY = std::max(maxY, y);
            minZ = std::min(minZ, z);
            maxZ = std::max(maxZ, z);
        }
        const float cx = (minX + maxX) * 0.5f;
        const float cy = (minY + maxY) * 0.5f;
        const float cz = (minZ + maxZ) * 0.5f;
        const float scale = 1.01f;
        for (size_t i = 0; i + 2 < _wireframePositions.size(); i += 3) {
            _wireframePositions[i] = cx + (_wireframePositions[i] - cx) * scale;
            _wireframePositions[i + 1] = cy + (_wireframePositions[i + 1] - cy) * scale;
            _wireframePositions[i + 2] = cz + (_wireframePositions[i + 2] - cz) * scale;
        }
    }
    if (!_wireframePositions.empty() && !_wireframeIndices.empty()) {
        _hasWireframeData = true;
    }
}

- (void)updateWireframe {
    if (!_scene) {
        return;
    }
    [self destroyWireframeRenderable];
    if (!_wireframeEnabled || !_hasWireframeData) {
        return;
    }
    if (_wireframePositions.empty() || _wireframeIndices.empty()) {
        return;
    }
    Material* material = [self ensureDebugLineMaterial];
    if (!material) {
        return;
    }
    if (!_wireframeMaterialInstance) {
        _wireframeMaterialInstance = material->createInstance();
        _wireframeMaterialInstance->setParameter(
            "color",
            RgbaType::LINEAR,
            LinearColorA{0.0f, 0.85f, 1.0f, 0.6f}
        );
    }
    const size_t vertexCount = _wireframePositions.size() / 3;
    const size_t indexCount = _wireframeIndices.size();
    if (vertexCount == 0 || indexCount == 0) {
        return;
    }
    float* vertices = (float*)malloc(sizeof(float) * _wireframePositions.size());
    uint32_t* indices = (uint32_t*)malloc(sizeof(uint32_t) * _wireframeIndices.size());
    if (!vertices || !indices) {
        if (vertices) {
            free(vertices);
        }
        if (indices) {
            free(indices);
        }
        return;
    }
    memcpy(vertices, _wireframePositions.data(), sizeof(float) * _wireframePositions.size());
    memcpy(indices, _wireframeIndices.data(), sizeof(uint32_t) * _wireframeIndices.size());
    _wireframeVertexBuffer = VertexBuffer::Builder()
        .bufferCount(1)
        .vertexCount((uint32_t)vertexCount)
        .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3)
        .build(*_engine);
    _wireframeIndexBuffer = IndexBuffer::Builder()
        .indexCount((uint32_t)indexCount)
        .bufferType(IndexBuffer::IndexType::UINT)
        .build(*_engine);
    _wireframeVertexBuffer->setBufferAt(
        *_engine,
        0,
        VertexBuffer::BufferDescriptor(vertices, sizeof(float) * _wireframePositions.size(), ReleaseBuffer)
    );
    _wireframeIndexBuffer->setBuffer(
        *_engine,
        IndexBuffer::BufferDescriptor(indices, sizeof(uint32_t) * _wireframeIndices.size(), ReleaseBuffer)
    );
    _wireframeEntity = EntityManager::get().create();
    RenderableManager::Builder(1)
        .culling(false)
        .castShadows(false)
        .receiveShadows(false)
        .material(0, _wireframeMaterialInstance)
        .geometry(0, RenderableManager::PrimitiveType::LINES, _wireframeVertexBuffer, _wireframeIndexBuffer)
        .build(*_engine, _wireframeEntity);
    _scene->addEntity(_wireframeEntity);
    [self logDebug:@"Wireframe enabled."];
}

- (void)rebuildBoundsRenderable {
    [self destroyBoundsRenderable];
    if (!_scene || !_boundingBoxesEnabled || !_hasModelBounds) {
        return;
    }
    Material* material = [self ensureDebugLineMaterial];
    if (!material) {
        return;
    }
    if (!_boundsMaterialInstance) {
        _boundsMaterialInstance = material->createInstance();
        _boundsMaterialInstance->setParameter(
            "color",
            RgbaType::LINEAR,
            LinearColorA{1.0f, 0.3f, 0.3f, 0.8f}
        );
    }
    const float minX = _modelCenter.x - _modelExtent.x;
    const float minY = _modelCenter.y - _modelExtent.y;
    const float minZ = _modelCenter.z - _modelExtent.z;
    const float maxX = _modelCenter.x + _modelExtent.x;
    const float maxY = _modelCenter.y + _modelExtent.y;
    const float maxZ = _modelCenter.z + _modelExtent.z;

    auto* vertices = (math::float3*) malloc(sizeof(math::float3) * 8);
    auto* indices = (uint32_t*) malloc(sizeof(uint32_t) * 24);
    vertices[0] = { minX, minY, minZ };
    vertices[1] = { minX, minY, maxZ };
    vertices[2] = { minX, maxY, minZ };
    vertices[3] = { minX, maxY, maxZ };
    vertices[4] = { maxX, minY, minZ };
    vertices[5] = { maxX, minY, maxZ };
    vertices[6] = { maxX, maxY, minZ };
    vertices[7] = { maxX, maxY, maxZ };

    const uint32_t edgeIndices[24] = {
        0, 1, 1, 3, 3, 2, 2, 0,
        4, 5, 5, 7, 7, 6, 6, 4,
        0, 4, 2, 6, 1, 5, 3, 7,
    };
    memcpy(indices, edgeIndices, sizeof(edgeIndices));

    _boundsVertexBuffer = VertexBuffer::Builder()
        .bufferCount(1)
        .vertexCount(8)
        .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3)
        .build(*_engine);
    _boundsIndexBuffer = IndexBuffer::Builder()
        .indexCount(24)
        .bufferType(IndexBuffer::IndexType::UINT)
        .build(*_engine);
    _boundsVertexBuffer->setBufferAt(
        *_engine,
        0,
        VertexBuffer::BufferDescriptor(vertices, sizeof(math::float3) * 8, ReleaseBuffer)
    );
    _boundsIndexBuffer->setBuffer(
        *_engine,
        IndexBuffer::BufferDescriptor(indices, sizeof(uint32_t) * 24, ReleaseBuffer)
    );

    _boundsEntity = EntityManager::get().create();
    RenderableManager::Builder(1)
        .culling(false)
        .castShadows(false)
        .receiveShadows(false)
        .material(0, _boundsMaterialInstance)
        .geometry(0, RenderableManager::PrimitiveType::LINES, _boundsVertexBuffer, _boundsIndexBuffer)
        .build(*_engine, _boundsEntity);
    _scene->addEntity(_boundsEntity);
    [self logDebug:@"Bounding box enabled."];
}

- (void)destroyWireframeRenderable {
    if (_wireframeEntity) {
        if (_scene && _scene->hasEntity(_wireframeEntity)) {
            _scene->remove(_wireframeEntity);
        }
        _engine->destroy(_wireframeEntity);
        _wireframeEntity.clear();
    }
    if (_wireframeVertexBuffer) {
        _engine->destroy(_wireframeVertexBuffer);
        _wireframeVertexBuffer = nullptr;
    }
    if (_wireframeIndexBuffer) {
        _engine->destroy(_wireframeIndexBuffer);
        _wireframeIndexBuffer = nullptr;
    }
}

- (void)destroyBoundsRenderable {
    if (_boundsEntity) {
        if (_scene && _scene->hasEntity(_boundsEntity)) {
            _scene->remove(_boundsEntity);
        }
        _engine->destroy(_boundsEntity);
        _boundsEntity.clear();
    }
    if (_boundsVertexBuffer) {
        _engine->destroy(_boundsVertexBuffer);
        _boundsVertexBuffer = nullptr;
    }
    if (_boundsIndexBuffer) {
        _engine->destroy(_boundsIndexBuffer);
        _boundsIndexBuffer = nullptr;
    }
}

- (void)updateFps:(uint64_t)frameTimeNanos {
    if (!_fpsCallback) {
        return;
    }
    if (_fpsStartTimeNanos == 0) {
        _fpsStartTimeNanos = frameTimeNanos;
        _fpsFrameCount = 0;
    }
    _fpsFrameCount += 1;
    const uint64_t elapsed = frameTimeNanos - _fpsStartTimeNanos;
    if (elapsed >= 1'000'000'000) {
        const double fpsValue = _fpsFrameCount * 1e9 / (double)elapsed;
        _fpsCallback(fpsValue);
        _fpsStartTimeNanos = frameTimeNanos;
        _fpsFrameCount = 0;
    }
}

- (void)logDebug:(NSString*)message {
    if (_debugLoggingEnabled) {
        NSLog(@"[FilamentWidget] %@", message);
    }
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
