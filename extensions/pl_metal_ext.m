/*
   pl_metal_ext.m
*/

/*
Index of this file:
// [SECTION] includes
// [SECTION] global data
// [SECTION] internal structs & types
// [SECTION] internal api
// [SECTION] public api implementation
// [SECTION] internal api implementation
// [SECTION] extension loading
// [SECTION] unity build
*/

//-----------------------------------------------------------------------------
// [SECTION] includes
//-----------------------------------------------------------------------------

#include "pilotlight.h"
#include "pl_os.h"
#include "pl_profile.h"
#include "pl_memory.h"
#include "pl_graphics_ext.c"

// pilotlight ui
#include "pl_ui.h"
#include "pl_ui_metal.h"

// metal stuff
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

//-----------------------------------------------------------------------------
// [SECTION] global data
//-----------------------------------------------------------------------------

const plFileApiI* gptFile = NULL;

//-----------------------------------------------------------------------------
// [SECTION] internal structs & types
//-----------------------------------------------------------------------------

@interface plTrackedMetalBuffer : NSObject
@property (nonatomic, strong) id<MTLBuffer> buffer;
@property (nonatomic, assign) double        lastReuseTime;
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer;
@end

@implementation plTrackedMetalBuffer
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer
{
    if ((self = [super init]))
    {
        _buffer = buffer;
        _lastReuseTime = pl_get_io()->dTime;
    }
    return self;
}
@end

typedef struct _plMetalDynamicBuffer
{
    uint32_t                 uByteOffset;
    uint32_t                 uHandle;
    plDeviceMemoryAllocation tMemory;
    id<MTLBuffer>            tBuffer;
} plMetalDynamicBuffer;

typedef struct _plMetalSwapchain
{
    int unused;
} plMetalSwapchain;

typedef struct _plMetalRenderPassLayout
{
    int unused;
} plMetalRenderPassLayout;

typedef struct _plMetalRenderPass
{
    MTLRenderPassDescriptor* ptRenderPassDescriptor;
    plRenderPassAttachments* sbtFrameBuffers;
} plMetalRenderPass;

typedef struct _plMetalBuffer
{
    id<MTLBuffer> tBuffer;
    id<MTLHeap>   tHeap;
} plMetalBuffer;

typedef struct _plFrameContext
{
    dispatch_semaphore_t tFrameBoundarySemaphore;

    // temporary bind group stuff
    uint32_t       uCurrentArgumentBuffer;
    plMetalBuffer* sbtArgumentBuffers;
    size_t         szCurrentArgumentOffset;

    // dynamic buffer stuff
    uint32_t              uCurrentBufferIndex;
    plMetalDynamicBuffer* sbtDynamicBuffers;
} plFrameContext;

typedef struct _plMetalTexture
{
    id<MTLTexture> tTexture;
    id<MTLHeap>    tHeap;
} plMetalTexture;

typedef struct _plMetalSampler
{
    id<MTLSamplerState> tSampler;
} plMetalSampler;

typedef struct _plMetalBindGroup
{
    id<MTLBuffer> tShaderArgumentBuffer;
    plBindGroupLayout tLayout;
    uint32_t uOffset;
} plMetalBindGroup;

typedef struct _plMetalShader
{
    id<MTLDepthStencilState>   tDepthStencilState;
    id<MTLRenderPipelineState> tRenderPipelineState;
    MTLCullMode                tCullMode;
    id<MTLLibrary>             library;
} plMetalShader;

typedef struct _plMetalComputeShader
{
    id<MTLComputePipelineState> tPipelineState;
    id<MTLLibrary> library;
} plMetalComputeShader;

typedef struct _plMetalPipelineEntry
{
    id<MTLDepthStencilState>   tDepthStencilState;
    id<MTLRenderPipelineState> tSolidRenderPipelineState;
    id<MTLRenderPipelineState> tLineRenderPipelineState;
    pl3DDrawFlags              tFlags;
    uint32_t                   uSampleCount;
} plMetalPipelineEntry;

typedef struct _plGraphicsMetal
{
    plTempAllocator     tTempAllocator;
    id<MTLCommandQueue> tCmdQueue;
    CAMetalLayer*       pMetalLayer;

    uint64_t                 uNextFenceValue;
    id<MTLSharedEvent>       tStagingEvent;
    MTLSharedEventListener*  ptSharedEventListener;
    id<MTLBuffer>            tStagingBuffer;
    plDeviceMemoryAllocation tStagingMemory;
    id<MTLFence>             atPassFences[64];
    uint32_t                 uCurrentPassFenceIndex;
    
    plFrameContext*          sbFrames;
    plMetalTexture*          sbtTexturesHot;
    plMetalSampler*          sbtSamplersHot;
    plMetalBindGroup*        sbtBindGroupsHot;
    plMetalBuffer*           sbtBuffersHot;
    plMetalShader*           sbtShadersHot;
    plMetalComputeShader*    sbtComputeShadersHot;
    plMetalRenderPass*       sbtRenderPassesHot;
    plMetalRenderPassLayout* sbtRenderPassLayoutsHot;
    
    // drawing
    plMetalPipelineEntry*           sbtPipelineEntries;
    id<MTLFunction>                 tSolidVertexFunction;
    id<MTLFunction>                 tLineVertexFunction;
    id<MTLFunction>                 tFragmentFunction;
    NSMutableArray<plTrackedMetalBuffer*>* bufferCache;
    double                          lastBufferCachePurge;

    // per frame
    id<CAMetalDrawable>         tCurrentDrawable;
    id<MTLCommandBuffer>        tCurrentCommandBuffer;
    id<MTLRenderCommandEncoder> tCurrentRenderEncoder;
} plGraphicsMetal;

typedef struct _plDeviceMetal
{
    id<MTLDevice> tDevice;
} plDeviceMetal;

//-----------------------------------------------------------------------------
// [SECTION] internal api
//-----------------------------------------------------------------------------

// conversion between pilotlight & vulkan types
static MTLSamplerMinMagFilter pl__metal_filter(plFilter tFilter);
static MTLSamplerAddressMode  pl__metal_wrap(plWrapMode tWrap);
static MTLCompareFunction     pl__metal_compare(plCompareMode tCompare);
static MTLPixelFormat         pl__metal_format(plFormat tFormat);
static MTLCullMode            pl__metal_cull(plCullMode tCullMode);
static MTLLoadAction          pl__metal_load_op   (plLoadOp tOp);
static MTLStoreAction         pl__metal_store_op  (plStoreOp tOp);
static MTLDataType            pl__metal_data_type  (plDataType tType);
static MTLRenderStages        pl__metal_stage_flags(plStageFlags tFlags);

static void                  pl__garbage_collect(plGraphics* ptGraphics);
static plTrackedMetalBuffer* pl__dequeue_reusable_buffer(plGraphics* ptGraphics, NSUInteger length);
static plMetalPipelineEntry* pl__get_3d_pipelines(plGraphics* ptGraphics, pl3DDrawFlags tFlags, uint32_t uSampleCount, MTLRenderPassDescriptor* ptRenderPassDescriptor);

// device memory allocators specifics
static plDeviceMemoryAllocation pl_allocate_dedicated(struct plDeviceMemoryAllocatorO* ptInst, uint32_t uTypeFilter, uint64_t ulSize, uint64_t ulAlignment, const char* pcName);
static void                     pl_free_dedicated    (struct plDeviceMemoryAllocatorO* ptInst, plDeviceMemoryAllocation* ptAllocation);

static plDeviceMemoryAllocation pl_allocate_staging_uncached(struct plDeviceMemoryAllocatorO* ptInst, uint32_t uTypeFilter, uint64_t ulSize, uint64_t ulAlignment, const char* pcName);
static void                     pl_free_staging_uncached    (struct plDeviceMemoryAllocatorO* ptInst, plDeviceMemoryAllocation* ptAllocation);

static plDeviceMemoryAllocation pl_allocate_buddy(struct plDeviceMemoryAllocatorO* ptInst, uint32_t uTypeFilter, uint64_t ulSize, uint64_t ulAlignment, const char* pcName);

// device memory allocator general
static plDeviceAllocationBlock* pl_get_allocator_blocks(struct plDeviceMemoryAllocatorO* ptInst, uint32_t* puSizeOut);

//-----------------------------------------------------------------------------
// [SECTION] public api implementation
//-----------------------------------------------------------------------------

static plFrameContext*
pl__get_frame_resources(plGraphics* ptGraphics)
{
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    return &ptMetalGraphics->sbFrames[ptGraphics->uCurrentFrameIndex];
}

static void*
pl_get_ui_texture_handle(plGraphics* ptGraphics, plTextureViewHandle tHandle)
{
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    plTextureView* ptView = pl__get_texture_view(&ptGraphics->tDevice, tHandle);
    return ptMetalGraphics->sbtTexturesHot[ptView->tTexture.uIndex].tTexture;
}

static plRenderPassLayoutHandle
pl_create_render_pass_layout(plDevice* ptDevice, const plRenderPassLayoutDescription* ptDesc)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    uint32_t uResourceIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtRenderPassLayoutFreeIndices) > 0)
        uResourceIndex = pl_sb_pop(ptGraphics->sbtRenderPassLayoutFreeIndices);
    else
    {
        uResourceIndex = pl_sb_size(ptGraphics->sbtRenderPassLayoutsCold);
        pl_sb_add(ptGraphics->sbtRenderPassLayoutsCold);
        pl_sb_push(ptGraphics->sbtRenderPassLayoutGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtRenderPassLayoutsHot);
    }

    plRenderPassLayoutHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtRenderPassLayoutGenerations[uResourceIndex],
        .uIndex = uResourceIndex
    };

    plRenderPassLayout tLayout = {
        .tDesc = *ptDesc,
        .tSampleCount = 1
    };

    for(uint32_t i = 0; i < 16; i++)
    {
        if(ptDesc->atRenderTargets[i].tFormat == PL_FORMAT_UNKNOWN)
        {
            break;
        }

        if(tLayout.tDesc.atRenderTargets[i].tSampleCount != 1)
            tLayout.tSampleCount = tLayout.tDesc.atRenderTargets[i].tSampleCount;
    }

    ptMetalGraphics->sbtRenderPassLayoutsHot[uResourceIndex] = (plMetalRenderPassLayout){0};
    ptGraphics->sbtRenderPassLayoutsCold[uResourceIndex] = tLayout;
    return tHandle;
}

static void
pl_update_render_pass_attachments(plDevice* ptDevice, plRenderPassHandle tHandle, plVec2 tDimensions, const plRenderPassAttachments* ptAttachments)
{

    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGfx = ptGraphics->_pInternalData;

    plRenderPass* ptRenderPass = &ptGraphics->sbtRenderPassesCold[tHandle.uIndex];
    plMetalRenderPass* ptMetalRenderPass = &ptMetalGfx->sbtRenderPassesHot[tHandle.uIndex];
    ptRenderPass->tDesc.tDimensions = tDimensions;

    pl_sb_reset(ptMetalRenderPass->sbtFrameBuffers);
    for(uint32_t i = 0; i < ptRenderPass->tDesc.uAttachmentSets; i++)
    {
        pl_sb_push(ptMetalRenderPass->sbtFrameBuffers, ptAttachments[i]);
    }
}

static plRenderPassHandle
pl_create_render_pass(plDevice* ptDevice, const plRenderPassDescription* ptDesc, const plRenderPassAttachments* ptAttachments)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    uint32_t uResourceIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtRenderPassFreeIndices) > 0)
        uResourceIndex = pl_sb_pop(ptGraphics->sbtRenderPassFreeIndices);
    else
    {
        uResourceIndex = pl_sb_size(ptGraphics->sbtRenderPassesCold);
        pl_sb_add(ptGraphics->sbtRenderPassesCold);
        pl_sb_push(ptGraphics->sbtRenderPassGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtRenderPassesHot);
    }

    plRenderPassHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtRenderPassGenerations[uResourceIndex],
        .uIndex = uResourceIndex
    };

    plRenderPass tRenderPass = {
        .tDesc = *ptDesc
    };

    plRenderPassLayout* ptLayout = &ptGraphics->sbtRenderPassLayoutsCold[ptDesc->tLayout.uIndex];

    plMetalRenderPass* ptMetalRenderPass = &ptMetalGraphics->sbtRenderPassesHot[uResourceIndex];
    pl_sb_reserve(ptMetalRenderPass->sbtFrameBuffers, ptDesc->uAttachmentSets);

    // render pass descriptor
    ptMetalRenderPass->ptRenderPassDescriptor = [MTLRenderPassDescriptor new];

    if(ptLayout->tDesc.tDepthTarget.tFormat != PL_FORMAT_UNKNOWN)
    {
        ptMetalRenderPass->ptRenderPassDescriptor.depthAttachment.loadAction = pl__metal_load_op(ptDesc->tDepthTarget.tLoadOp);
        ptMetalRenderPass->ptRenderPassDescriptor.depthAttachment.storeAction = pl__metal_store_op(ptDesc->tDepthTarget.tStoreOp);
        ptMetalRenderPass->ptRenderPassDescriptor.depthAttachment.clearDepth = ptDesc->tDepthTarget.fClearZ;
    }

    for(uint32_t i = 0; i < 16; i++)
    {
        if(ptLayout->tDesc.atRenderTargets[i].tFormat == PL_FORMAT_UNKNOWN)
        {
            break;
        }

        if(ptLayout->tDesc.atRenderTargets[i].tSampleCount != 1)
            ptLayout->tSampleCount = ptLayout->tDesc.atRenderTargets[i].tSampleCount;

        ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[i].loadAction = pl__metal_load_op(ptDesc->atRenderTargets[i].tLoadOp);
        ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[i].storeAction = pl__metal_store_op(ptDesc->atRenderTargets[i].tStoreOp);
        ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[i].clearColor = MTLClearColorMake(
            ptDesc->atRenderTargets[i].tClearColor.r,
            ptDesc->atRenderTargets[i].tClearColor.g,
            ptDesc->atRenderTargets[i].tClearColor.b,
            ptDesc->atRenderTargets[i].tClearColor.a
            );
    }

    for(uint32_t i = 0; i < ptDesc->uAttachmentSets; i++)
    {
        pl_sb_push(ptMetalRenderPass->sbtFrameBuffers, ptAttachments[i]);
    }

    ptGraphics->sbtRenderPassesCold[uResourceIndex] = tRenderPass;
    return tHandle;
}

static void
pl_copy_buffer_to_texture(plDevice* ptDevice, plBufferHandle tBufferHandle, plTextureHandle tTextureHandle, uint32_t uRegionCount, const plBufferImageCopy* ptRegions)
{
    plGraphics*      ptGraphics       = ptDevice->ptGraphics;
    plDeviceMetal*   ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    id<MTLCommandBuffer> commandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];
    commandBuffer.label = @"Buffer to Texture Blit Encoder";

    id<MTLBlitCommandEncoder> blitEncoder = commandBuffer.blitCommandEncoder;
    blitEncoder.label = @"Buffer to Texture Blit Encoder";

    plMetalBuffer* ptBuffer = &ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex];
    plMetalTexture* ptTexture = &ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex];
    plTexture* ptColdTexture = pl__get_texture(ptDevice, tTextureHandle);

    for(uint32_t i = 0; i < uRegionCount; i++)
    {

        MTLOrigin tOrigin;
        tOrigin.x = ptRegions[i].iImageOffsetX;
        tOrigin.y = ptRegions[i].iImageOffsetY;
        tOrigin.z = ptRegions[i].iImageOffsetZ;

        MTLSize tSize;
        tSize.width  = ptRegions[i].tImageExtent.uWidth;
        tSize.height = ptRegions[i].tImageExtent.uHeight;
        tSize.depth  = ptRegions[i].tImageExtent.uDepth;

        NSUInteger uBytesPerRow = tSize.width * pl__format_stride(ptColdTexture->tDesc.tFormat);
        [blitEncoder copyFromBuffer:ptBuffer->tBuffer
            sourceOffset:ptRegions[i].szBufferOffset
            sourceBytesPerRow:uBytesPerRow 
            sourceBytesPerImage:0 
            sourceSize:tSize 
            toTexture:ptTexture->tTexture
            destinationSlice:ptRegions[i].uBaseArrayLayer
            destinationLevel:0 
            destinationOrigin:tOrigin];
    }

    [blitEncoder endEncoding];
    [commandBuffer commit];
}

static void
pl_transfer_image_to_buffer(plDevice* ptDevice, plTextureHandle tTexture, plBufferHandle tBuffer)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    const plTexture* ptTexture = pl__get_texture(ptDevice, tTexture);
    const plMetalTexture* ptMetalTexture = &ptMetalGraphics->sbtTexturesHot[tTexture.uIndex];
    const plMetalBuffer* ptMetalBuffer = &ptMetalGraphics->sbtBuffersHot[tBuffer.uIndex];

    // copy from cpu to gpu once staging buffer is free
    [ptMetalGraphics->tStagingEvent notifyListener:ptMetalGraphics->ptSharedEventListener
                        atValue:ptMetalGraphics->uNextFenceValue + 2
                        block:^(id<MTLSharedEvent> sharedEvent, uint64_t value) {
        sharedEvent.signaledValue = ptMetalGraphics->uNextFenceValue;
    }];

    id<MTLCommandBuffer> commandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];
    commandBuffer.label = @"Heap Transfer Blit Encoder";

    [commandBuffer encodeWaitForEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue++];

    id<MTLBlitCommandEncoder> blitEncoder = commandBuffer.blitCommandEncoder;
    blitEncoder.label = @"Heap Transfer Blit Encoder";

    MTLOrigin tOrigin;
    tOrigin.x = 0;
    tOrigin.y = 0;
    tOrigin.z = 0;
    MTLSize tSize;
    tSize.width = ptTexture->tDesc.tDimensions.x;
    tSize.height = ptTexture->tDesc.tDimensions.y;
    tSize.depth = ptTexture->tDesc.tDimensions.z;

    const uint32_t uFormatStride = pl__format_stride(ptTexture->tDesc.tFormat);

    [blitEncoder copyFromTexture:ptMetalTexture->tTexture
        sourceSlice:0
        sourceLevel:0
        sourceOrigin:tOrigin
        sourceSize:tSize
        toBuffer:ptMetalBuffer->tBuffer
        destinationOffset:0
        destinationBytesPerRow:ptTexture->tDesc.tDimensions.x * uFormatStride
        destinationBytesPerImage:0];

    [blitEncoder endEncoding];
    [commandBuffer encodeSignalEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue];
    [commandBuffer commit];

    // wait for cpu to gpu copying to take place before continuing
    while(true)
    {
        if(ptMetalGraphics->tStagingEvent.signaledValue == ptMetalGraphics->uNextFenceValue)
            break;
    }

}

static plBufferHandle
pl_create_buffer(plDevice* ptDevice, const plBufferDescription* ptDesc, const char* pcName)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    uint32_t uBufferIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtBufferFreeIndices) > 0)
        uBufferIndex = pl_sb_pop(ptGraphics->sbtBufferFreeIndices);
    else
    {
        uBufferIndex = pl_sb_size(ptGraphics->sbtBuffersCold);
        pl_sb_add(ptGraphics->sbtBuffersCold);
        pl_sb_push(ptGraphics->sbtBufferGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtBuffersHot);
    }

    plBufferHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtBufferGenerations[uBufferIndex],
        .uIndex = uBufferIndex
    };

    plBuffer tBuffer = {
        .tDescription = *ptDesc
    };

    if(pcName)
    {
        pl_sprintf(tBuffer.tDescription.acDebugName, "%s", pcName);
    }

    if(ptDesc->tMemory == PL_MEMORY_GPU_CPU)
    {
        tBuffer.tMemoryAllocation = ptDevice->tStagingUnCachedAllocator.allocate(ptDevice->tStagingUnCachedAllocator.ptInst, 0, ptDesc->uByteSize, 0, pcName);

        plMetalBuffer tMetalBuffer = {
            .tBuffer = [(id<MTLHeap>)tBuffer.tMemoryAllocation.uHandle newBufferWithLength:ptDesc->uByteSize options:MTLResourceStorageModeShared offset:0]
        };
        tMetalBuffer.tBuffer.label = [NSString stringWithUTF8String:ptDesc->acDebugName];
        memset(tMetalBuffer.tBuffer.contents, 0, ptDesc->uByteSize);
        
        if(ptDesc->puInitialData)
            memcpy(tMetalBuffer.tBuffer.contents, ptDesc->puInitialData, ptDesc->uInitialDataByteSize);

        tBuffer.tMemoryAllocation.pHostMapped = tMetalBuffer.tBuffer.contents;
        tBuffer.tMemoryAllocation.ulOffset = 0;
        tBuffer.tMemoryAllocation.ulSize = ptDesc->uByteSize;
        tMetalBuffer.tHeap = (id<MTLHeap>)tBuffer.tMemoryAllocation.uHandle;
        ptMetalGraphics->sbtBuffersHot[uBufferIndex] = tMetalBuffer;
    }
    else if(ptDesc->tMemory == PL_MEMORY_GPU)
    {
        // copy from cpu to gpu once staging buffer is free
        [ptMetalGraphics->tStagingEvent notifyListener:ptMetalGraphics->ptSharedEventListener
                            atValue:ptMetalGraphics->uNextFenceValue++
                            block:^(id<MTLSharedEvent> sharedEvent, uint64_t value) {
            if(ptDesc->puInitialData)
                memcpy(ptMetalGraphics->tStagingBuffer.contents, ptDesc->puInitialData, ptDesc->uInitialDataByteSize);
            sharedEvent.signaledValue = ptMetalGraphics->uNextFenceValue;
        }];

        // wait for cpu to gpu copying to take place before continuing
        while(true)
        {
            if(ptMetalGraphics->tStagingEvent.signaledValue == ptMetalGraphics->uNextFenceValue)
                break;
        }

        plDeviceMemoryAllocatorI* ptAllocator = ptDesc->uByteSize > PL_DEVICE_BUDDY_BLOCK_SIZE ? &ptDevice->tLocalDedicatedAllocator : &ptDevice->tLocalBuddyAllocator;
        tBuffer.tMemoryAllocation = ptAllocator->allocate(ptAllocator->ptInst, MTLStorageModePrivate, ptDesc->uByteSize, 0, pcName);

        id<MTLCommandBuffer> commandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];
        commandBuffer.label = @"Heap Transfer Blit Encoder";

        [commandBuffer encodeWaitForEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue++];

        id<MTLBlitCommandEncoder> blitEncoder = commandBuffer.blitCommandEncoder;
        blitEncoder.label = @"Heap Transfer Blit Encoder";

        MTLSizeAndAlign tSizeAndAlign = [ptMetalDevice->tDevice heapBufferSizeAndAlignWithLength:ptDesc->uByteSize options:MTLResourceStorageModePrivate];

        plMetalBuffer tMetalBuffer = {
            .tBuffer = [(id<MTLHeap>)tBuffer.tMemoryAllocation.uHandle newBufferWithLength:ptDesc->uByteSize options:MTLResourceStorageModePrivate offset:tBuffer.tMemoryAllocation.ulOffset]
        };
        tMetalBuffer.tBuffer.label = [NSString stringWithUTF8String:ptDesc->acDebugName];

        [blitEncoder copyFromBuffer:ptMetalGraphics->tStagingBuffer sourceOffset:0 toBuffer:tMetalBuffer.tBuffer destinationOffset:0 size:ptDesc->uByteSize];

        [blitEncoder endEncoding];
        [commandBuffer encodeSignalEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue];
        [commandBuffer commit];

        tMetalBuffer.tHeap = (id<MTLHeap>)tBuffer.tMemoryAllocation.uHandle;
        ptMetalGraphics->sbtBuffersHot[uBufferIndex] = tMetalBuffer;
    }
    else if(ptDesc->tMemory == PL_MEMORY_CPU)
    {
        tBuffer.tMemoryAllocation = ptDevice->tStagingCachedAllocator.allocate(ptDevice->tStagingCachedAllocator.ptInst, MTLStorageModePrivate, ptDesc->uByteSize, 0, pcName);

        plMetalBuffer tMetalBuffer = {
            .tBuffer = [(id<MTLHeap>)tBuffer.tMemoryAllocation.uHandle newBufferWithLength:ptDesc->uByteSize options:MTLResourceStorageModeShared offset:0]
        };
        tMetalBuffer.tBuffer.label = [NSString stringWithUTF8String:ptDesc->acDebugName];
        memset(tMetalBuffer.tBuffer.contents, 0, ptDesc->uByteSize);

        if(ptDesc->puInitialData)
            memcpy(tMetalBuffer.tBuffer.contents, ptDesc->puInitialData, ptDesc->uInitialDataByteSize);

        tBuffer.tMemoryAllocation.pHostMapped = tMetalBuffer.tBuffer.contents;
        tBuffer.tMemoryAllocation.ulOffset = 0;
        tBuffer.tMemoryAllocation.ulSize = ptDesc->uByteSize;
        tMetalBuffer.tHeap = (id<MTLHeap>)tBuffer.tMemoryAllocation.uHandle;
        ptMetalGraphics->sbtBuffersHot[uBufferIndex] = tMetalBuffer;
    }

    ptGraphics->sbtBuffersCold[uBufferIndex] = tBuffer;
    return tHandle;
}

static void
pl_update_texture(plDevice* ptDevice, plTextureHandle tHandle, size_t szSize, const void* pData)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    // copy from cpu to gpu once staging buffer is free
    [ptMetalGraphics->tStagingEvent notifyListener:ptMetalGraphics->ptSharedEventListener
                        atValue:ptMetalGraphics->uNextFenceValue++
                        block:^(id<MTLSharedEvent> sharedEvent, uint64_t value) {
        if(pData)
            memcpy(ptMetalGraphics->tStagingBuffer.contents, pData, szSize);
        sharedEvent.signaledValue = ptMetalGraphics->uNextFenceValue;
    }];

    // wait for cpu to gpu copying to take place before continuing
    while(true)
    {
        if(ptMetalGraphics->tStagingEvent.signaledValue == ptMetalGraphics->uNextFenceValue)
            break;
    }

    id<MTLCommandBuffer> commandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];
    commandBuffer.label = @"Heap Transfer Blit Encoder";

    [commandBuffer encodeWaitForEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue++];

    plMetalTexture tMetalTexture = ptMetalGraphics->sbtTexturesHot[tHandle.uIndex];
    plTexture tTexture = ptGraphics->sbtTexturesCold[tHandle.uIndex];

    id<MTLBlitCommandEncoder> blitEncoder = commandBuffer.blitCommandEncoder;
    blitEncoder.label = @"Heap Transfer Blit Encoder";

    NSUInteger uBytesPerRow = szSize / tTexture.tDesc.tDimensions.y;
    uBytesPerRow = uBytesPerRow / tTexture.tDesc.uLayers;
    MTLOrigin tOrigin;
    tOrigin.x = 0;
    tOrigin.y = 0;
    tOrigin.z = 0;
    MTLSize tSize;
    tSize.width = tTexture.tDesc.tDimensions.x;
    tSize.height = tTexture.tDesc.tDimensions.y;
    tSize.depth = tTexture.tDesc.tDimensions.z;
    for(uint32_t i = 0; i < tTexture.tDesc.uLayers; i++)
        [blitEncoder copyFromBuffer:ptMetalGraphics->tStagingBuffer sourceOffset:uBytesPerRow * tTexture.tDesc.tDimensions.y * i sourceBytesPerRow:uBytesPerRow sourceBytesPerImage:0 sourceSize:tSize toTexture:tMetalTexture.tTexture destinationSlice:i destinationLevel:0 destinationOrigin:tOrigin];

    if(tTexture.tDesc.uMips > 1)
        [blitEncoder generateMipmapsForTexture:tMetalTexture.tTexture];

    [blitEncoder endEncoding];
    [commandBuffer encodeSignalEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue];
    [commandBuffer commit];
}

static plTextureHandle
pl_create_texture(plDevice* ptDevice, plTextureDesc tDesc, size_t szSize, const void* pData, const char* pcName)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    uint32_t uTextureIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtTextureFreeIndices) > 0)
        uTextureIndex = pl_sb_pop(ptGraphics->sbtTextureFreeIndices);
    else
    {
        uTextureIndex = pl_sb_size(ptGraphics->sbtTexturesCold);
        pl_sb_add(ptGraphics->sbtTexturesCold);
        pl_sb_push(ptGraphics->sbtTextureGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtTexturesHot);
    }

    plTextureHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtTextureGenerations[uTextureIndex],
        .uIndex = uTextureIndex
    };

    if(tDesc.uMips == 0)
        tDesc.uMips = (uint32_t)floorf(log2f((float)pl_maxi((int)tDesc.tDimensions.x, (int)tDesc.tDimensions.y))) + 1u;

    plTexture tTexture = {
        .tDesc = tDesc
    };

    // copy from cpu to gpu once staging buffer is free
    [ptMetalGraphics->tStagingEvent notifyListener:ptMetalGraphics->ptSharedEventListener
                        atValue:ptMetalGraphics->uNextFenceValue++
                        block:^(id<MTLSharedEvent> sharedEvent, uint64_t value) {
        if(pData)
            memcpy(ptMetalGraphics->tStagingBuffer.contents, pData, szSize);
        sharedEvent.signaledValue = ptMetalGraphics->uNextFenceValue;
    }];

    // wait for cpu to gpu copying to take place before continuing
    while(true)
    {
        if(ptMetalGraphics->tStagingEvent.signaledValue == ptMetalGraphics->uNextFenceValue)
            break;
    }


    MTLTextureDescriptor* ptTextureDescriptor = [[MTLTextureDescriptor alloc] init];
    ptTextureDescriptor.pixelFormat = pl__metal_format(tDesc.tFormat);
    ptTextureDescriptor.width = tDesc.tDimensions.x;
    ptTextureDescriptor.height = tDesc.tDimensions.y;
    ptTextureDescriptor.mipmapLevelCount = tDesc.uMips;
    ptTextureDescriptor.storageMode = MTLStorageModePrivate;
    ptTextureDescriptor.arrayLength = 1;
    ptTextureDescriptor.depth = tDesc.tDimensions.z;
    ptTextureDescriptor.sampleCount = tDesc.tSamples;

    if(tDesc.tUsage & PL_TEXTURE_USAGE_SAMPLED)
        ptTextureDescriptor.usage |= MTLTextureUsageShaderRead;
    if(tDesc.tUsage & PL_TEXTURE_USAGE_COLOR_ATTACHMENT)
        ptTextureDescriptor.usage |= MTLTextureUsageRenderTarget;
    if(tDesc.tUsage & PL_TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT)
        ptTextureDescriptor.usage |= MTLTextureUsageRenderTarget;

    // if(tDesc.tUsage & PL_TEXTURE_USAGE_TRANSIENT_ATTACHMENT)
    //     ptTextureDescriptor.storageMode = MTLStorageModeMemoryless;

    if(tDesc.tSamples > 1)
        ptTextureDescriptor.textureType = MTLTextureType2DMultisample;
    else if(tDesc.tType == PL_TEXTURE_TYPE_2D)
        ptTextureDescriptor.textureType = MTLTextureType2D;
    else if(tDesc.tType == PL_TEXTURE_TYPE_CUBE)
        ptTextureDescriptor.textureType = MTLTextureTypeCube;
    else
    {
        PL_ASSERT(false && "unsupported texture type");
    }

    MTLSizeAndAlign tSizeAndAlign = [ptMetalDevice->tDevice heapTextureSizeAndAlignWithDescriptor:ptTextureDescriptor];
    plDeviceMemoryAllocatorI* ptAllocator = tSizeAndAlign.size > PL_DEVICE_BUDDY_BLOCK_SIZE ? &ptGraphics->tDevice.tLocalDedicatedAllocator : &ptGraphics->tDevice.tLocalBuddyAllocator;
    tTexture.tMemoryAllocation = ptAllocator->allocate(ptAllocator->ptInst, ptTextureDescriptor.storageMode, tSizeAndAlign.size, tSizeAndAlign.align, pcName);

    plMetalTexture tMetalTexture = {
        .tTexture = [(id<MTLHeap>)tTexture.tMemoryAllocation.uHandle newTextureWithDescriptor:ptTextureDescriptor offset:tTexture.tMemoryAllocation.ulOffset],
        .tHeap = (id<MTLHeap>)tTexture.tMemoryAllocation.uHandle
    };
    tMetalTexture.tTexture.label = [NSString stringWithUTF8String:pcName];

    if(pData)
    {
        id<MTLCommandBuffer> commandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];
        commandBuffer.label = @"Heap Transfer Blit Encoder";

        [commandBuffer encodeWaitForEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue++];

        id<MTLBlitCommandEncoder> blitEncoder = commandBuffer.blitCommandEncoder;
        blitEncoder.label = @"Heap Transfer Blit Encoder";

        NSUInteger uBytesPerRow = szSize / tDesc.tDimensions.y;
        uBytesPerRow = uBytesPerRow / tDesc.uLayers;
        MTLOrigin tOrigin;
        tOrigin.x = 0;
        tOrigin.y = 0;
        tOrigin.z = 0;
        MTLSize tSize;
        tSize.width = tDesc.tDimensions.x;
        tSize.height = tDesc.tDimensions.y;
        tSize.depth = tDesc.tDimensions.z;
        for(uint32_t i = 0; i < tDesc.uLayers; i++)
            [blitEncoder copyFromBuffer:ptMetalGraphics->tStagingBuffer sourceOffset:uBytesPerRow * tDesc.tDimensions.y * i sourceBytesPerRow:uBytesPerRow sourceBytesPerImage:0 sourceSize:tSize toTexture:tMetalTexture.tTexture destinationSlice:i destinationLevel:0 destinationOrigin:tOrigin];

        if(tDesc.uMips > 1)
            [blitEncoder generateMipmapsForTexture:tMetalTexture.tTexture];

        [blitEncoder endEncoding];
        [commandBuffer encodeSignalEvent:ptMetalGraphics->tStagingEvent value:ptMetalGraphics->uNextFenceValue];
        [commandBuffer commit];
    }
    ptMetalGraphics->sbtTexturesHot[uTextureIndex] = tMetalTexture;
    ptGraphics->sbtTexturesCold[uTextureIndex] = tTexture;
    [ptTextureDescriptor release];
    return tHandle;
}


static plTextureViewHandle
pl_create_texture_view(plDevice* ptDevice, const plTextureViewDesc* ptViewDesc, const plSampler* ptSampler, plTextureHandle tTextureHandle, const char* pcName)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    plTexture* ptTexture = pl__get_texture(ptDevice, tTextureHandle);
    plMetalTexture* ptMetalTexture = &ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex];

    uint32_t uTextureViewIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtTextureViewFreeIndices) > 0)
        uTextureViewIndex = pl_sb_pop(ptGraphics->sbtTextureViewFreeIndices);
    else
    {
        uTextureViewIndex = pl_sb_size(ptGraphics->sbtTextureViewsCold);
        pl_sb_add(ptGraphics->sbtTextureViewsCold);
        pl_sb_push(ptGraphics->sbtTextureViewGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtSamplersHot);
    }

    plTextureViewHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtTextureViewGenerations[uTextureViewIndex],
        .uIndex = uTextureViewIndex
    };

    plTextureView tTextureView = {
        .tSampler         = *ptSampler,
        .tTextureViewDesc = *ptViewDesc,
        .tTexture         = tTextureHandle
    };

    if(ptViewDesc->uMips == 0)
        tTextureView.tTextureViewDesc.uMips = ptTexture->tDesc.uMips;

    MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
    samplerDesc.minFilter = pl__metal_filter(ptSampler->tFilter);
    samplerDesc.magFilter = pl__metal_filter(ptSampler->tFilter);
    samplerDesc.mipFilter = MTLSamplerMipFilterLinear;
    samplerDesc.normalizedCoordinates = YES;
    samplerDesc.supportArgumentBuffers = YES;
    samplerDesc.sAddressMode = pl__metal_wrap(ptSampler->tHorizontalWrap);
    samplerDesc.tAddressMode = pl__metal_wrap(ptSampler->tVerticalWrap);
    samplerDesc.borderColor = MTLSamplerBorderColorTransparentBlack;
    samplerDesc.compareFunction = pl__metal_compare(ptSampler->tCompare);
    samplerDesc.lodMinClamp = ptSampler->fMinMip;
    samplerDesc.lodMaxClamp = ptSampler->fMaxMip;
    samplerDesc.label = [NSString stringWithUTF8String:pcName];

    plMetalSampler tMetalSampler = {
        .tSampler = [ptMetalDevice->tDevice newSamplerStateWithDescriptor:samplerDesc]
    };

    ptMetalGraphics->sbtSamplersHot[uTextureViewIndex] = tMetalSampler;
    ptGraphics->sbtTextureViewsCold[uTextureViewIndex] = tTextureView;
    return tHandle;
}

static plBindGroupHandle
pl_get_temporary_bind_group(plDevice* ptDevice, plBindGroupLayout* ptLayout)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plFrameContext* ptFrame = pl__get_frame_resources(ptGraphics);

    uint32_t uBindGroupIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtBindGroupFreeIndices) > 0)
        uBindGroupIndex = pl_sb_pop(ptGraphics->sbtBindGroupFreeIndices);
    else
    {
        uBindGroupIndex = pl_sb_size(ptGraphics->sbtBindGroupsCold);
        pl_sb_add(ptGraphics->sbtBindGroupsCold);
        pl_sb_push(ptGraphics->sbtBindGroupGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtBindGroupsHot);
    }

    plBindGroupHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtBindGroupGenerations[uBindGroupIndex],
        .uIndex = uBindGroupIndex
    };

    plBindGroup tBindGroup = {
        .tLayout = *ptLayout
    };

    NSUInteger argumentBufferLength = sizeof(MTLResourceID) * ptLayout->uTextureCount * 2 + sizeof(void*) * ptLayout->uBufferCount;


    if(argumentBufferLength + ptFrame->szCurrentArgumentOffset > PL_DEVICE_ALLOCATION_BLOCK_SIZE)
    {
        ptFrame->uCurrentArgumentBuffer++;
        if(ptFrame->uCurrentArgumentBuffer >= pl_sb_size(ptFrame->sbtArgumentBuffers))
        {
            plMetalBuffer tArgumentBuffer = {
                .tBuffer = [ptMetalDevice->tDevice newBufferWithLength:PL_DEVICE_ALLOCATION_BLOCK_SIZE options:0]
            };
            pl_sb_push(ptFrame->sbtArgumentBuffers, tArgumentBuffer);
        }
         ptFrame->szCurrentArgumentOffset = 0;
    }

    plMetalBindGroup tMetalBindGroup = {
        .tShaderArgumentBuffer = ptFrame->sbtArgumentBuffers[ptFrame->uCurrentArgumentBuffer].tBuffer,
        .uOffset = ptFrame->szCurrentArgumentOffset
    };
    ptFrame->szCurrentArgumentOffset += argumentBufferLength;

    [tMetalBindGroup.tShaderArgumentBuffer retain];
    tMetalBindGroup.tShaderArgumentBuffer.label = [NSString stringWithUTF8String:"temp bind group"];

    ptMetalGraphics->sbtBindGroupsHot[uBindGroupIndex] = tMetalBindGroup;
    ptGraphics->sbtBindGroupsCold[uBindGroupIndex] = tBindGroup;
    pl_queue_bind_group_for_deletion(ptDevice, tHandle);
    return tHandle;
}

static plBindGroupHandle
pl_create_bind_group(plDevice* ptDevice, plBindGroupLayout* ptLayout)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    uint32_t uBindGroupIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtBindGroupFreeIndices) > 0)
        uBindGroupIndex = pl_sb_pop(ptGraphics->sbtBindGroupFreeIndices);
    else
    {
        uBindGroupIndex = pl_sb_size(ptGraphics->sbtBindGroupsCold);
        pl_sb_add(ptGraphics->sbtBindGroupsCold);
        pl_sb_push(ptGraphics->sbtBindGroupGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtBindGroupsHot);
    }

    plBindGroupHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtBindGroupGenerations[uBindGroupIndex],
        .uIndex = uBindGroupIndex
    };

    plBindGroup tBindGroup = {
        .tLayout = *ptLayout
    };

    NSUInteger argumentBufferLength = sizeof(MTLResourceID) * ptLayout->uTextureCount * 2 + sizeof(void*) * ptLayout->uBufferCount;

    plMetalBindGroup tMetalBindGroup = {
        .tShaderArgumentBuffer = [ptMetalDevice->tDevice newBufferWithLength:argumentBufferLength options:0]
    };
    tMetalBindGroup.tShaderArgumentBuffer.label = [NSString stringWithUTF8String:"bind group"];

    ptMetalGraphics->sbtBindGroupsHot[uBindGroupIndex] = tMetalBindGroup;
    ptGraphics->sbtBindGroupsCold[uBindGroupIndex] = tBindGroup;
    return tHandle;
}

static void
pl_update_bind_group(plDevice* ptDevice, plBindGroupHandle* ptGroup, uint32_t uBufferCount, plBufferHandle* atBuffers, size_t* aszBufferRanges, uint32_t uTextureViewCount, plTextureViewHandle* atTextureViews)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;

    plMetalBindGroup* ptMetalBindGroup = &ptMetalGraphics->sbtBindGroupsHot[ptGroup->uIndex];
    plBindGroup* ptBindGroup = &ptGraphics->sbtBindGroupsCold[ptGroup->uIndex];

    const char* pcDescriptorStart = ptMetalBindGroup->tShaderArgumentBuffer.contents;
    

    // start of buffers
    float** ptBufferResources = (float**)&pcDescriptorStart[ptMetalBindGroup->uOffset];
    for(uint32_t i = 0; i < uBufferCount; i++)
    {
        plMetalBuffer* ptMetalBuffer = &ptMetalGraphics->sbtBuffersHot[atBuffers[i].uIndex];
        ptBufferResources[i] = (float*)ptMetalBuffer->tBuffer.gpuAddress;
        ptBindGroup->tLayout.aBuffers[i].tBuffer = atBuffers[i];
    }

    // start of textures
    char* pcStartOfBuffers = (char*)&pcDescriptorStart[ptMetalBindGroup->uOffset];

    MTLResourceID* ptResources = (MTLResourceID*)(&pcStartOfBuffers[sizeof(void*) * uBufferCount]);
    for(uint32_t i = 0; i < uTextureViewCount; i++)
    {
        
        plMetalTexture* ptMetalTexture = &ptMetalGraphics->sbtTexturesHot[ptGraphics->sbtTextureViewsCold[atTextureViews[i].uIndex].tTexture.uIndex];
        plMetalSampler* ptMetalSampler = &ptMetalGraphics->sbtSamplersHot[atTextureViews[i].uIndex];
        ptResources[i * 2] = ptMetalTexture->tTexture.gpuResourceID;
        ptResources[i * 2 + 1] = ptMetalSampler->tSampler.gpuResourceID;
        ptBindGroup->tLayout.aTextures[i].tTextureView = atTextureViews[i];
    }

    ptMetalBindGroup->tLayout = ptBindGroup->tLayout;
}

static plDynamicBinding
pl_allocate_dynamic_data(plDevice* ptDevice, size_t szSize)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptDevice->_pInternalData;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plFrameContext* ptFrame = pl__get_frame_resources(ptGraphics);

    PL_ASSERT(szSize <= PL_MAX_DYNAMIC_DATA_SIZE && "Dynamic data size too large");

    plMetalDynamicBuffer* ptDynamicBuffer = NULL;

    // first call this frame
    if(ptFrame->uCurrentBufferIndex == UINT32_MAX)
    {
        ptFrame->uCurrentBufferIndex = 0;
        ptDynamicBuffer = &ptFrame->sbtDynamicBuffers[0];
        ptDynamicBuffer->uByteOffset = 0;
    }
    ptDynamicBuffer = &ptFrame->sbtDynamicBuffers[ptFrame->uCurrentBufferIndex];

    // check if current block has room
    if(ptDynamicBuffer->uByteOffset + szSize > PL_DEVICE_ALLOCATION_BLOCK_SIZE)
    {
        ptFrame->uCurrentBufferIndex++;
        
        // check if we have available block
        if(ptFrame->uCurrentBufferIndex + 1 > pl_sb_size(ptFrame->sbtDynamicBuffers)) // create new buffer
        {
            // dynamic buffer stuff
            pl_sb_add(ptFrame->sbtDynamicBuffers);
            ptDynamicBuffer = &ptFrame->sbtDynamicBuffers[ptFrame->uCurrentBufferIndex];
            ptDynamicBuffer->uByteOffset = 0;
            static char atNameBuffer[PL_MAX_NAME_LENGTH] = {0};
            pl_sprintf(atNameBuffer, "D-BUF-F%d-%d", (int)ptGraphics->uCurrentFrameIndex, (int)ptFrame->uCurrentBufferIndex);

            ptDynamicBuffer->tMemory = ptGraphics->tDevice.tStagingUnCachedAllocator.allocate(ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst, 0, PL_DEVICE_ALLOCATION_BLOCK_SIZE, 0, atNameBuffer);
            ptDynamicBuffer->tBuffer = [(id<MTLHeap>)ptDynamicBuffer->tMemory.uHandle newBufferWithLength:PL_DEVICE_ALLOCATION_BLOCK_SIZE options:MTLResourceStorageModeShared offset:0];
            ptDynamicBuffer->tBuffer.label = [NSString stringWithUTF8String:"buddy allocator"];
        }

        ptDynamicBuffer = &ptFrame->sbtDynamicBuffers[ptFrame->uCurrentBufferIndex];
        ptDynamicBuffer->uByteOffset = 0;
    }

    plDynamicBinding tDynamicBinding = {
        .uBufferHandle = ptFrame->uCurrentBufferIndex,
        .uByteOffset   = ptDynamicBuffer->uByteOffset,
        .pcData        = &ptDynamicBuffer->tBuffer.contents[ptDynamicBuffer->uByteOffset]
    };
    ptDynamicBuffer->uByteOffset = pl_align_up((size_t)ptDynamicBuffer->uByteOffset + PL_MAX_DYNAMIC_DATA_SIZE, 256);
    return tDynamicBinding;
}

static plComputeShaderHandle
pl_get_compute_shader_variant(plDevice* ptDevice, plComputeShaderHandle tHandle, const plComputeShaderVariant* ptVariant)
{
    plGraphics*       ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal*   ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    plComputeShader* ptShader = &ptGraphics->sbtComputeShadersCold[tHandle.uIndex];

    size_t uTotalConstantSize = 0;
    for(uint32_t i = 0; i < ptShader->tDescription.uConstantCount; i++)
    {
        const plSpecializationConstant* ptConstant = &ptShader->tDescription.atConstants[i];
        uTotalConstantSize += pl__get_data_type_size(ptConstant->tType);
    }

    const uint64_t ulVariantHash = pl_hm_hash(ptVariant->pTempConstantData, uTotalConstantSize, 0);
    const uint64_t ulIndex = pl_hm_lookup(&ptShader->tVariantHashmap, ulVariantHash);

    if(ulIndex != UINT64_MAX)
        return ptShader->_sbtVariantHandles[ulIndex];

    uint32_t uNewResourceIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtComputeShaderFreeIndices) > 0)
        uNewResourceIndex = pl_sb_pop(ptGraphics->sbtComputeShaderFreeIndices);
    else
    {
        uNewResourceIndex = pl_sb_size(ptGraphics->sbtComputeShadersCold);
        pl_sb_add(ptGraphics->sbtComputeShadersCold);
        pl_sb_push(ptGraphics->sbtComputeShaderGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtComputeShadersHot);
    }
    ptShader = &ptGraphics->sbtComputeShadersCold[tHandle.uIndex];
    plMetalComputeShader* ptMetalShader = &ptMetalGraphics->sbtComputeShadersHot[uNewResourceIndex];


    plComputeShaderHandle tVariantHandle = {
        .uGeneration = ++ptGraphics->sbtComputeShaderGenerations[uNewResourceIndex],
        .uIndex = uNewResourceIndex
    };

    pl_hm_insert(&ptShader->tVariantHashmap, ulVariantHash, pl_sb_size(ptShader->_sbtVariantHandles));
    pl_sb_push(ptShader->_sbtVariantHandles, tVariantHandle);

    MTLFunctionConstantValues* ptConstantValues = [MTLFunctionConstantValues new];

    const char* pcConstantData = ptVariant->pTempConstantData;
    for(uint32_t i = 0; i < ptShader->tDescription.uConstantCount; i++)
    {
        const plSpecializationConstant* ptConstant = &ptShader->tDescription.atConstants[i];
        [ptConstantValues setConstantValue:&pcConstantData[ptConstant->uOffset] type:pl__metal_data_type(ptConstant->tType) atIndex:ptConstant->uID];
    }

    NSError* error = nil;
    id<MTLFunction> computeFunction = [ptMetalShader->library newFunctionWithName:@"kernel_main" constantValues:ptConstantValues error:&error];

    if (computeFunction == nil)
    {
        NSLog(@"Error: failed to find Metal shader functions in library: %@", error);
    }

    const plMetalComputeShader tMetalShader = {
        .tPipelineState = [ptMetalDevice->tDevice newComputePipelineStateWithFunction:computeFunction error:&error]
    };

    if (error != nil)
        NSLog(@"Error: failed to create Metal pipeline state: %@", error);

    ptMetalGraphics->sbtComputeShadersHot[uNewResourceIndex] = tMetalShader;
    ptGraphics->sbtComputeShadersCold[uNewResourceIndex] = *ptShader;
    ptGraphics->sbtComputeShadersCold[uNewResourceIndex]._sbtVariantHandles = NULL;
    memset(&ptGraphics->sbtComputeShadersCold[uNewResourceIndex].tVariantHashmap, 0, sizeof(plHashMap));
    return tVariantHandle;
}

static plComputeShaderHandle
pl_create_compute_shader(plDevice* ptDevice, const plComputeShaderDescription* ptDescription)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    uint32_t uResourceIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtComputeShaderFreeIndices) > 0)
        uResourceIndex = pl_sb_pop(ptGraphics->sbtComputeShaderFreeIndices);
    else
    {
        uResourceIndex = pl_sb_size(ptGraphics->sbtComputeShadersCold);
        pl_sb_add(ptGraphics->sbtComputeShadersCold);
        pl_sb_push(ptGraphics->sbtComputeShaderGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtComputeShadersHot);
    }

    plComputeShaderHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtComputeShaderGenerations[uResourceIndex],
        .uIndex = uResourceIndex
    };

    plComputeShader tShader = {
        .tDescription = *ptDescription
    };

    plMetalComputeShader* ptMetalShader = &ptMetalGraphics->sbtComputeShadersHot[uResourceIndex];

    if(ptDescription->pcShaderEntryFunc == NULL)
        tShader.tDescription.pcShaderEntryFunc = "kernel_main";

    // read in shader source code
    unsigned uShaderFileSize = 0;
    gptFile->read(tShader.tDescription.pcShader, &uShaderFileSize, NULL, "rb");
    char* pcFileData = pl_temp_allocator_alloc(&ptMetalGraphics->tTempAllocator, uShaderFileSize + 1);
    gptFile->read(tShader.tDescription.pcShader, &uShaderFileSize, pcFileData, "rb");

    // compile shader source
    NSError* error = nil;
    NSString* shaderSource = [NSString stringWithUTF8String:pcFileData];
    MTLCompileOptions* ptCompileOptions = [MTLCompileOptions new];
    ptMetalShader->library = [ptMetalDevice->tDevice  newLibraryWithSource:shaderSource options:ptCompileOptions error:&error];
    if (ptMetalShader->library == nil)
    {
        NSLog(@"Error: failed to create Metal library: %@", error);
    }
    pl_temp_allocator_reset(&ptMetalGraphics->tTempAllocator);

    size_t uTotalConstantSize = 0;
    for(uint32_t i = 0; i < tShader.tDescription.uConstantCount; i++)
    {
        const plSpecializationConstant* ptConstant = &tShader.tDescription.atConstants[i];
        uTotalConstantSize += pl__get_data_type_size(ptConstant->tType);
    }

    const plComputeShaderVariant tMainShaderVariant = {.pTempConstantData = tShader.tDescription.pTempConstantData};

    plComputeShaderVariant *ptVariants = pl_temp_allocator_alloc(&ptMetalGraphics->tTempAllocator, sizeof(plComputeShaderVariant) * (tShader.tDescription.uVariantCount + 1));
    ptVariants[0] = tMainShaderVariant;
    for(uint32_t i = 0; i < tShader.tDescription.uVariantCount; i++)
    {
        ptVariants[i + 1] = tShader.tDescription.ptVariants[i];
    }

    for(uint32_t i = 0; i < tShader.tDescription.uVariantCount + 1; i++)
    {
       const plComputeShaderVariant *ptVariant = &ptVariants[i];

        uint32_t uNewResourceIndex = UINT32_MAX;

        if(i == 0)
            uNewResourceIndex = uResourceIndex;
        else
        {
            if(pl_sb_size(ptGraphics->sbtComputeShaderFreeIndices) > 0)
                uNewResourceIndex = pl_sb_pop(ptGraphics->sbtComputeShaderFreeIndices);
            else
            {
                uNewResourceIndex = pl_sb_size(ptGraphics->sbtComputeShadersCold);
                pl_sb_add(ptGraphics->sbtComputeShadersCold);
                pl_sb_push(ptGraphics->sbtComputeShaderGenerations, UINT32_MAX);
                pl_sb_add(ptMetalGraphics->sbtComputeShadersHot);
                ptMetalShader = &ptMetalGraphics->sbtComputeShadersHot[uResourceIndex];
            }
        }

        plComputeShaderHandle tVariantHandle = {
            .uGeneration = ++ptGraphics->sbtComputeShaderGenerations[uNewResourceIndex],
            .uIndex = uNewResourceIndex
        };

        const uint64_t ulVariantHash = pl_hm_hash(ptVariant->pTempConstantData, uTotalConstantSize, 0);
        pl_hm_insert(&tShader.tVariantHashmap, ulVariantHash, pl_sb_size(tShader._sbtVariantHandles));
        pl_sb_push(tShader._sbtVariantHandles, tVariantHandle);

        MTLFunctionConstantValues* ptConstantValues = [MTLFunctionConstantValues new];

        const char* pcConstantData = ptVariant->pTempConstantData;
        for(uint32_t i = 0; i < tShader.tDescription.uConstantCount; i++)
        {
            const plSpecializationConstant* ptConstant = &tShader.tDescription.atConstants[i];
            [ptConstantValues setConstantValue:&pcConstantData[ptConstant->uOffset] type:pl__metal_data_type(ptConstant->tType) atIndex:ptConstant->uID];
        }

        id<MTLFunction> computeFunction = [ptMetalShader->library newFunctionWithName:@"kernel_main" constantValues:ptConstantValues error:&error];

        if (computeFunction == nil)
        {
            NSLog(@"Error: failed to find Metal shader functions in library: %@", error);
        }

        const plMetalComputeShader tMetalShader = {
            .tPipelineState = [ptMetalDevice->tDevice newComputePipelineStateWithFunction:computeFunction error:&error]
        };

        if (error != nil)
            NSLog(@"Error: failed to create Metal pipeline state: %@", error);

        ptGraphics->sbtComputeShadersCold[uNewResourceIndex] = tShader;
        if(i == 0)
        {
            ptMetalShader->tPipelineState = tMetalShader.tPipelineState;
        }
        else
        {
            ptMetalGraphics->sbtComputeShadersHot[uNewResourceIndex] = tMetalShader;
            ptGraphics->sbtComputeShadersCold[uNewResourceIndex]._sbtVariantHandles = NULL;
            memset(&ptGraphics->sbtComputeShadersCold[uNewResourceIndex].tVariantHashmap, 0, sizeof(plHashMap));
        }
    }
    ptGraphics->sbtComputeShadersCold[uResourceIndex] = tShader;
    return tHandle;
}

static plShaderHandle
pl_get_shader_variant(plDevice* ptDevice, plShaderHandle tHandle, const plShaderVariant* ptVariant)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;
    plShader* ptShader = &ptGraphics->sbtShadersCold[tHandle.uIndex];

    size_t uTotalConstantSize = 0;
    for(uint32_t i = 0; i < ptShader->tDescription.uConstantCount; i++)
    {
        const plSpecializationConstant* ptConstant = &ptShader->tDescription.atConstants[i];
        uTotalConstantSize += pl__get_data_type_size(ptConstant->tType);
    }

    const uint64_t ulVariantHash = pl_hm_hash(ptVariant->pTempConstantData, uTotalConstantSize, ptVariant->tGraphicsState.ulValue);
    const uint64_t ulIndex = pl_hm_lookup(&ptShader->tVariantHashmap, ulVariantHash);

    if(ulIndex != UINT64_MAX)
        return ptShader->_sbtVariantHandles[ulIndex];;

    uint32_t uNewResourceIndex = UINT32_MAX;

    if(pl_sb_size(ptGraphics->sbtShaderFreeIndices) > 0)
        uNewResourceIndex = pl_sb_pop(ptGraphics->sbtShaderFreeIndices);
    else
    {
        uNewResourceIndex = pl_sb_size(ptGraphics->sbtShadersCold);
        pl_sb_add(ptGraphics->sbtShadersCold);
        pl_sb_push(ptGraphics->sbtShaderGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtShadersHot);
        ptShader = &ptGraphics->sbtShadersCold[tHandle.uIndex];
    }

    plMetalShader* ptMetalShader = &ptMetalGraphics->sbtShadersHot[tHandle.uIndex];
    MTLFunctionConstantValues* ptConstantValues = [MTLFunctionConstantValues new];

    const char* pcConstantData = ptVariant->pTempConstantData;
    for(uint32_t i = 0; i < ptShader->tDescription.uConstantCount; i++)
    {
        const plSpecializationConstant* ptConstant = &ptShader->tDescription.atConstants[i];
        [ptConstantValues setConstantValue:&pcConstantData[ptConstant->uOffset] type:pl__metal_data_type(ptConstant->tType) atIndex:ptConstant->uID];
    }

    NSError* error = nil;
    id<MTLFunction> vertexFunction = [ptMetalShader->library newFunctionWithName:@"vertex_main" constantValues:ptConstantValues error:&error];
    id<MTLFunction> fragmentFunction = [ptMetalShader->library newFunctionWithName:@"fragment_main" constantValues:ptConstantValues error:&error];

    if (vertexFunction == nil || fragmentFunction == nil)
    {
        NSLog(@"Error: failed to find Metal shader functions in library: %@", error);
    }

    MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = pl__metal_compare((plCompareMode)ptVariant->tGraphicsState.ulDepthMode);
    depthDescriptor.depthWriteEnabled = ptVariant->tGraphicsState.ulDepthWriteEnabled ? YES : NO;

    // vertex layout
    MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3; // position
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.layouts[0].stepRate = 1;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    vertexDescriptor.layouts[0].stride = sizeof(float) * 3;

    MTLRenderPipelineDescriptor* pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.vertexDescriptor = vertexDescriptor;
    pipelineDescriptor.rasterSampleCount = ptGraphics->sbtRenderPassLayoutsCold[ptShader->tDescription.tRenderPassLayout.uIndex].tSampleCount;

    // renderpass stuff
    const plRenderPassLayout* ptLayout = &ptGraphics->sbtRenderPassLayoutsCold[ptShader->tDescription.tRenderPassLayout.uIndex];

    pipelineDescriptor.colorAttachments[0].pixelFormat = pl__metal_format(ptLayout->tDesc.atRenderTargets[0].tFormat);
    pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
    pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
    pipelineDescriptor.depthAttachmentPixelFormat = pl__metal_format(ptLayout->tDesc.tDepthTarget.tFormat);
    // pipelineDescriptor.stencilAttachmentPixelFormat = ptMetalRenderPass->ptRenderPassDescriptor.stencilAttachment.texture.pixelFormat;

    const plMetalShader tMetalShader = {
        .tDepthStencilState   = [ptMetalDevice->tDevice newDepthStencilStateWithDescriptor:depthDescriptor],
        .tRenderPipelineState = [ptMetalDevice->tDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error],
        .tCullMode            = pl__metal_cull(ptVariant->tGraphicsState.ulCullMode)
    };

    if (error != nil)
        NSLog(@"Error: failed to create Metal pipeline state: %@", error);

    plShaderHandle tVariantHandle = {
        .uGeneration = ++ptGraphics->sbtShaderGenerations[uNewResourceIndex],
        .uIndex = uNewResourceIndex
    };
    
    pl_hm_insert(&ptShader->tVariantHashmap, ulVariantHash, pl_sb_size(ptShader->_sbtVariantHandles));
    pl_sb_push(ptShader->_sbtVariantHandles, tVariantHandle);

    ptGraphics->sbtShadersCold[uNewResourceIndex] = *ptShader;
    ptMetalGraphics->sbtShadersHot[uNewResourceIndex] = tMetalShader;
    ptGraphics->sbtShadersCold[uNewResourceIndex]._sbtVariantHandles = NULL;
    memset(&ptGraphics->sbtShadersCold[uNewResourceIndex].tVariantHashmap, 0, sizeof(plHashMap));
    return tVariantHandle;
}

static plShaderHandle
pl_create_shader(plDevice* ptDevice, const plShaderDescription* ptDescription)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    uint32_t uResourceIndex = UINT32_MAX;
    if(pl_sb_size(ptGraphics->sbtShaderFreeIndices) > 0)
        uResourceIndex = pl_sb_pop(ptGraphics->sbtShaderFreeIndices);
    else
    {
        uResourceIndex = pl_sb_size(ptGraphics->sbtShadersCold);
        pl_sb_add(ptGraphics->sbtShadersCold);
        pl_sb_push(ptGraphics->sbtShaderGenerations, UINT32_MAX);
        pl_sb_add(ptMetalGraphics->sbtShadersHot);
    }

    plShaderHandle tHandle = {
        .uGeneration = ++ptGraphics->sbtShaderGenerations[uResourceIndex],
        .uIndex = uResourceIndex
    };

    plShader tShader = {
        .tDescription = *ptDescription
    };

    plMetalShader* ptMetalShader = &ptMetalGraphics->sbtShadersHot[uResourceIndex];

    if(ptDescription->pcPixelShaderEntryFunc == NULL)
        tShader.tDescription.pcPixelShaderEntryFunc = "fragment_main";

    if(ptDescription->pcVertexShaderEntryFunc == NULL)
        tShader.tDescription.pcVertexShaderEntryFunc = "vertex_main";

    // vertex layout
    MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3; // position
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.layouts[0].stepRate = 1;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    vertexDescriptor.layouts[0].stride = sizeof(float) * 3;

    // read in shader source code
    unsigned uShaderFileSize = 0;
    gptFile->read(tShader.tDescription.pcVertexShader, &uShaderFileSize, NULL, "rb");
    char* pcFileData = pl_temp_allocator_alloc(&ptMetalGraphics->tTempAllocator, uShaderFileSize + 1);
    memset(pcFileData, 0, uShaderFileSize + 1);
    gptFile->read(tShader.tDescription.pcVertexShader, &uShaderFileSize, pcFileData, "rb");

    // prepare preprocessor defines
    MTLCompileOptions* ptCompileOptions = [MTLCompileOptions new];

    // compile shader source
    NSError* error = nil;
    NSString* shaderSource = [NSString stringWithUTF8String:pcFileData];
    ptMetalShader->library = [ptMetalDevice->tDevice  newLibraryWithSource:shaderSource options:ptCompileOptions error:&error];
    if (ptMetalShader->library == nil)
    {
        NSLog(@"Error: failed to create Metal library: %@", error);
    }

    pl_temp_allocator_reset(&ptMetalGraphics->tTempAllocator);

    // renderpass stuff
    const plRenderPassLayout* ptLayout = &ptGraphics->sbtRenderPassLayoutsCold[tShader.tDescription.tRenderPassLayout.uIndex];

    size_t uTotalConstantSize = 0;
    for(uint32_t i = 0; i < tShader.tDescription.uConstantCount; i++)
    {
        const plSpecializationConstant* ptConstant = &tShader.tDescription.atConstants[i];
        uTotalConstantSize += pl__get_data_type_size(ptConstant->tType);
    }

    const plShaderVariant tMainShaderVariant = {.pTempConstantData = tShader.tDescription.pTempConstantData, .tGraphicsState = tShader.tDescription.tGraphicsState};
    plShaderVariant *ptVariants = pl_temp_allocator_alloc(&ptMetalGraphics->tTempAllocator, sizeof(plShaderVariant) * (tShader.tDescription.uVariantCount + 1));
    ptVariants[0] = tMainShaderVariant;
    for(uint32_t i = 0; i < tShader.tDescription.uVariantCount; i++)
    {
        ptVariants[i + 1] = tShader.tDescription.ptVariants[i];
    }
    for(uint32_t i = 0; i < tShader.tDescription.uVariantCount + 1; i++)
    {
        const plShaderVariant *ptVariant = &ptVariants[i];

        uint32_t uNewResourceIndex = UINT32_MAX;

        if(i == 0)
            uNewResourceIndex = uResourceIndex;
        else
        {
            if(pl_sb_size(ptGraphics->sbtShaderFreeIndices) > 0)
                uNewResourceIndex = pl_sb_pop(ptGraphics->sbtShaderFreeIndices);
            else
            {
                uNewResourceIndex = pl_sb_size(ptGraphics->sbtShadersCold);
                pl_sb_add(ptGraphics->sbtShadersCold);
                pl_sb_push(ptGraphics->sbtShaderGenerations, UINT32_MAX);
                pl_sb_add(ptMetalGraphics->sbtShadersHot);
                ptMetalShader = &ptMetalGraphics->sbtShadersHot[uResourceIndex];
            }
        }

        MTLFunctionConstantValues* ptConstantValues = [MTLFunctionConstantValues new];

        const char* pcConstantData = ptVariant->pTempConstantData;
        for(uint32_t i = 0; i < tShader.tDescription.uConstantCount; i++)
        {
            const plSpecializationConstant* ptConstant = &tShader.tDescription.atConstants[i];
            [ptConstantValues setConstantValue:&pcConstantData[ptConstant->uOffset] type:pl__metal_data_type(ptConstant->tType) atIndex:ptConstant->uID];
        }

        id<MTLFunction> vertexFunction = [ptMetalShader->library newFunctionWithName:@"vertex_main" constantValues:ptConstantValues error:&error];
        id<MTLFunction> fragmentFunction = [ptMetalShader->library newFunctionWithName:@"fragment_main" constantValues:ptConstantValues error:&error];

        if (vertexFunction == nil || fragmentFunction == nil)
        {
            NSLog(@"Error: failed to find Metal shader functions in library: %@", error);
        }

        MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
        depthDescriptor.depthCompareFunction = pl__metal_compare((plCompareMode)ptVariant->tGraphicsState.ulDepthMode);
        depthDescriptor.depthWriteEnabled = ptVariant->tGraphicsState.ulDepthWriteEnabled ? YES : NO;

        MTLRenderPipelineDescriptor* pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineDescriptor.rasterSampleCount = ptGraphics->sbtRenderPassLayoutsCold[tShader.tDescription.tRenderPassLayout.uIndex].tSampleCount;

        pipelineDescriptor.colorAttachments[0].pixelFormat = pl__metal_format(ptLayout->tDesc.atRenderTargets[0].tFormat);
        pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        pipelineDescriptor.depthAttachmentPixelFormat = pl__metal_format(ptLayout->tDesc.tDepthTarget.tFormat);
        // pipelineDescriptor.stencilAttachmentPixelFormat = ptMetalRenderPass->ptRenderPassDescriptor.stencilAttachment.texture.pixelFormat;

        const plMetalShader tMetalShader = {
            .tDepthStencilState   = [ptMetalDevice->tDevice newDepthStencilStateWithDescriptor:depthDescriptor],
            .tRenderPipelineState = [ptMetalDevice->tDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error],
            .tCullMode            = pl__metal_cull(ptVariant->tGraphicsState.ulCullMode)
        };

        if (error != nil)
            NSLog(@"Error: failed to create Metal pipeline state: %@", error);

        plShaderHandle tVariantHandle = {
            .uGeneration = ++ptGraphics->sbtShaderGenerations[uNewResourceIndex],
            .uIndex = uNewResourceIndex
        };
        
        const uint64_t ulVariantHash = pl_hm_hash(ptVariant->pTempConstantData, uTotalConstantSize, ptVariant->tGraphicsState.ulValue);
        pl_hm_insert(&tShader.tVariantHashmap, ulVariantHash, pl_sb_size(tShader._sbtVariantHandles));
        pl_sb_push(tShader._sbtVariantHandles, tVariantHandle);

        ptGraphics->sbtShadersCold[uNewResourceIndex] = tShader;

        if(i == 0)
        {
            ptMetalShader->tDepthStencilState = tMetalShader.tDepthStencilState;
            ptMetalShader->tRenderPipelineState = tMetalShader.tRenderPipelineState;
            ptMetalShader->tCullMode = tMetalShader.tCullMode;
        }
        else
        {
            ptMetalGraphics->sbtShadersHot[uNewResourceIndex] = tMetalShader;
            ptGraphics->sbtShadersCold[uNewResourceIndex]._sbtVariantHandles = NULL;
            memset(&ptGraphics->sbtShadersCold[uNewResourceIndex].tVariantHashmap, 0, sizeof(plHashMap));
        }
    }
    pl_temp_allocator_reset(&ptMetalGraphics->tTempAllocator);
    return tHandle;
}

static void
pl_initialize_graphics(plGraphics* ptGraphics)
{
    plIO* ptIOCtx = pl_get_io();

    ptGraphics->_pInternalData = PL_ALLOC(sizeof(plGraphicsMetal));
    memset(ptGraphics->_pInternalData, 0, sizeof(plGraphicsMetal));

    ptGraphics->tDevice._pInternalData = PL_ALLOC(sizeof(plDeviceMetal));
    memset(ptGraphics->tDevice._pInternalData, 0, sizeof(plDeviceMetal));

    ptGraphics->tSwapchain._pInternalData = PL_ALLOC(sizeof(plMetalSwapchain));
    memset(ptGraphics->tSwapchain._pInternalData, 0, sizeof(plMetalSwapchain));

    ptGraphics->tDevice.ptGraphics = ptGraphics;
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;
    ptMetalDevice->tDevice = (__bridge id)ptIOCtx->pBackendPlatformData;

    ptGraphics->uFramesInFlight = 2;
    ptGraphics->tSwapchain.uImageCount = 2;
    ptGraphics->tSwapchain.tFormat = PL_FORMAT_B8G8R8A8_UNORM;
    ptGraphics->tSwapchain.tDepthFormat = PL_FORMAT_D32_FLOAT;
    pl_sb_resize(ptGraphics->tSwapchain.sbtSwapchainTextureViews, 2);

    // create command queue
    ptMetalGraphics->tCmdQueue = [ptMetalDevice->tDevice newCommandQueue];

    ptGraphics->tSwapchain.tMsaaSamples = 4;
    if([ptMetalDevice->tDevice supportsTextureSampleCount:8])
        ptGraphics->tSwapchain.tMsaaSamples = 8;

    // line rendering
    {
        NSError* error = nil;

        // read in shader source code
        unsigned uShaderFileSize0 = 0;
        gptFile->read("../shaders/metal/draw_3d_line.metal", &uShaderFileSize0, NULL, "r");
        char* pcFileData0 = PL_ALLOC(uShaderFileSize0 + 1);
        gptFile->read("../shaders/metal/draw_3d_line.metal", &uShaderFileSize0, pcFileData0, "r");
        NSString* lineShaderSource = [NSString stringWithUTF8String:pcFileData0];


        id<MTLLibrary> library = [ptMetalDevice->tDevice newLibraryWithSource:lineShaderSource options:nil error:&error];
        if (library == nil)
        {
            NSLog(@"Error: failed to create Metal library: %@", error);
        }

        ptMetalGraphics->tLineVertexFunction = [library newFunctionWithName:@"vertex_main"];
        ptMetalGraphics->tFragmentFunction = [library newFunctionWithName:@"fragment_main"];

        unsigned uShaderFileSize1 = 0;
        gptFile->read("../shaders/metal/draw_3d.metal", &uShaderFileSize1, NULL, "r");
        char* pcFileData1 = PL_ALLOC(uShaderFileSize1 + 1);
        gptFile->read("../shaders/metal/draw_3d.metal", &uShaderFileSize1, pcFileData1, "r");

        NSString* solidShaderSource = [NSString stringWithUTF8String:pcFileData1];
        id<MTLLibrary> library1 = [ptMetalDevice->tDevice newLibraryWithSource:solidShaderSource options:nil error:&error];
        if (library1 == nil)
        {
            NSLog(@"Error: failed to create Metal library: %@", error);
        }

        ptMetalGraphics->tSolidVertexFunction = [library1 newFunctionWithName:@"vertex_main"];

        PL_FREE(pcFileData0);
        PL_FREE(pcFileData1);
    }

    //~~~~~~~~~~~~~~~~~~~~~~~~~~~~device memory allocators~~~~~~~~~~~~~~~~~~~~~~~~~

    // local dedicated
    static plDeviceAllocatorData tLocalDedicatedData = {0};
    tLocalDedicatedData.ptDevice = &ptGraphics->tDevice;
    ptGraphics->tDevice.tLocalDedicatedAllocator.allocate = pl_allocate_dedicated;
    ptGraphics->tDevice.tLocalDedicatedAllocator.free = pl_free_dedicated;
    ptGraphics->tDevice.tLocalDedicatedAllocator.blocks = pl_get_allocator_blocks;
    ptGraphics->tDevice.tLocalDedicatedAllocator.ranges = pl_get_allocator_ranges;
    ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst = (struct plDeviceMemoryAllocatorO*)&tLocalDedicatedData;

    // local buddy
    static plDeviceAllocatorData tLocalBuddyData = {0};
    for(uint32_t i = 0; i < PL_DEVICE_LOCAL_LEVELS; i++)
        tLocalBuddyData.auFreeList[i] = UINT32_MAX;
    tLocalBuddyData.ptDevice = &ptGraphics->tDevice;
    ptGraphics->tDevice.tLocalBuddyAllocator.allocate = pl_allocate_buddy;
    ptGraphics->tDevice.tLocalBuddyAllocator.free = pl_free_buddy;
    ptGraphics->tDevice.tLocalBuddyAllocator.blocks = pl_get_allocator_blocks;
    ptGraphics->tDevice.tLocalBuddyAllocator.ranges = pl_get_allocator_ranges;
    ptGraphics->tDevice.tLocalBuddyAllocator.ptInst = (struct plDeviceMemoryAllocatorO*)&tLocalBuddyData;

    // staging uncached
    static plDeviceAllocatorData tStagingUncachedData = {0};
    tStagingUncachedData.ptDevice = &ptGraphics->tDevice;
    ptGraphics->tDevice.tStagingUnCachedAllocator.allocate = pl_allocate_staging_uncached;
    ptGraphics->tDevice.tStagingUnCachedAllocator.free = pl_free_staging_uncached;
    ptGraphics->tDevice.tStagingUnCachedAllocator.blocks = pl_get_allocator_blocks;
    ptGraphics->tDevice.tStagingUnCachedAllocator.ranges = pl_get_allocator_ranges;
    ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst = (struct plDeviceMemoryAllocatorO*)&tStagingUncachedData;

    // staging cached
    static plDeviceAllocatorData tStagingCachedData = {0};
    tStagingCachedData.ptDevice = &ptGraphics->tDevice;
    ptGraphics->tDevice.tStagingCachedAllocator.allocate = pl_allocate_staging_uncached;
    ptGraphics->tDevice.tStagingCachedAllocator.free = pl_free_staging_uncached;
    ptGraphics->tDevice.tStagingCachedAllocator.blocks = pl_get_allocator_blocks;
    ptGraphics->tDevice.tStagingCachedAllocator.ranges = pl_get_allocator_ranges;
    ptGraphics->tDevice.tStagingCachedAllocator.ptInst = (struct plDeviceMemoryAllocatorO*)&tStagingCachedData;

    ptMetalGraphics->tStagingEvent = [ptMetalDevice->tDevice newSharedEvent];
    dispatch_queue_t tQueue = dispatch_queue_create("com.example.apple-samplecode.MyQueue", NULL);
    ptMetalGraphics->ptSharedEventListener = [[MTLSharedEventListener alloc] initWithDispatchQueue:tQueue];

    pl_sb_resize(ptGraphics->sbtGarbage, ptGraphics->uFramesInFlight);
    for(uint32_t i = 0; i < ptGraphics->uFramesInFlight; i++)
    {
        plFrameContext tFrame = {
            .tFrameBoundarySemaphore = dispatch_semaphore_create(1)
        };
        pl_sb_resize(tFrame.sbtDynamicBuffers, 1);
        static char atNameBuffer[PL_MAX_NAME_LENGTH] = {0};
        pl_sprintf(atNameBuffer, "D-BUF-F%d-0", (int)i);
        tFrame.sbtDynamicBuffers[0].tMemory = ptGraphics->tDevice.tStagingUnCachedAllocator.allocate(ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst, 0, PL_DEVICE_ALLOCATION_BLOCK_SIZE, 0,atNameBuffer);
        tFrame.sbtDynamicBuffers[0].tBuffer = [(id<MTLHeap>)tFrame.sbtDynamicBuffers[0].tMemory.uHandle newBufferWithLength:PL_DEVICE_ALLOCATION_BLOCK_SIZE options:MTLResourceStorageModeShared offset:0];
        tFrame.sbtDynamicBuffers[0].tBuffer.label = [NSString stringWithUTF8String:"dynamic"];
        
        plMetalBuffer tArgumentBuffer = {
                .tBuffer = [ptMetalDevice->tDevice newBufferWithLength:PL_DEVICE_ALLOCATION_BLOCK_SIZE options:0]
            };
        pl_sb_push(tFrame.sbtArgumentBuffers, tArgumentBuffer);
        pl_sb_push(ptMetalGraphics->sbFrames, tFrame);
    }

    ptMetalGraphics->tStagingMemory = ptGraphics->tDevice.tStagingUnCachedAllocator.allocate(ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst, 0, PL_DEVICE_ALLOCATION_BLOCK_SIZE, 0, "staging");
    ptMetalGraphics->tStagingBuffer = [(id<MTLHeap>)ptMetalGraphics->tStagingMemory.uHandle newBufferWithLength:PL_DEVICE_ALLOCATION_BLOCK_SIZE options:MTLResourceStorageModeShared offset:0];
    ptMetalGraphics->tStagingBuffer.label = [NSString stringWithUTF8String:"staging"];

    // color & depth
    const plTextureDesc tDepthTextureDesc = {
        .tDimensions = {ptIOCtx->afMainViewportSize[0], ptIOCtx->afMainViewportSize[1], 1},
        .tFormat = PL_FORMAT_D32_FLOAT,
        .uLayers = 1,
        .uMips = 1,
        .tType = PL_TEXTURE_TYPE_2D,
        .tUsage = PL_TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT | PL_TEXTURE_USAGE_TRANSIENT_ATTACHMENT,
        .tSamples = ptGraphics->tSwapchain.tMsaaSamples
    };
    ptGraphics->tSwapchain.tDepthTexture = pl_create_texture(&ptGraphics->tDevice, tDepthTextureDesc, 0, NULL, "Swapchain depth");

    const plTextureDesc tColorTextureDesc = {
        .tDimensions = {ptIOCtx->afMainViewportSize[0], ptIOCtx->afMainViewportSize[1], 1},
        .tFormat = PL_FORMAT_B8G8R8A8_UNORM,
        .uLayers = 1,
        .uMips = 1,
        .tType = PL_TEXTURE_TYPE_2D,
        .tUsage = PL_TEXTURE_USAGE_COLOR_ATTACHMENT | PL_TEXTURE_USAGE_SAMPLED,
        .tSamples = ptGraphics->tSwapchain.tMsaaSamples
    };
    ptGraphics->tSwapchain.tColorTexture = pl_create_texture(&ptGraphics->tDevice, tColorTextureDesc, 0, NULL, "Swapchain color");

    plSampler tSampler = {
        .tFilter = PL_FILTER_NEAREST,
        .fMinMip = 0.0f,
        .fMaxMip = 64.0f,
        .tVerticalWrap = PL_WRAP_MODE_CLAMP,
        .tHorizontalWrap = PL_WRAP_MODE_CLAMP
    };

    plTextureViewDesc tColorTextureViewDesc = {
        .tFormat     = tColorTextureDesc.tFormat,
        .uBaseLayer  = 0,
        .uBaseMip    = 0,
        .uLayerCount = 1
    };
    ptGraphics->tSwapchain.tColorTextureView = pl_create_texture_view(&ptGraphics->tDevice, &tColorTextureViewDesc, &tSampler, ptGraphics->tSwapchain.tColorTexture, "Swapchain color view");

    plTextureViewDesc tDepthTextureViewDesc = {
        .tFormat     = tDepthTextureDesc.tFormat,
        .uBaseLayer  = 0,
        .uBaseMip    = 0,
        .uLayerCount = 1
    };
    ptGraphics->tSwapchain.tDepthTextureView = pl_create_texture_view(&ptGraphics->tDevice, &tDepthTextureViewDesc, &tSampler, ptGraphics->tSwapchain.tDepthTexture, "Swapchain depth view");

    for(uint32_t i = 0; i < 64; i++)
        ptMetalGraphics->atPassFences[i] = [ptMetalDevice->tDevice newFence];
}

static void
pl_setup_ui(plGraphics* ptGraphics, plRenderPassHandle tPass)
{
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    pl_initialize_metal(ptMetalDevice->tDevice);
}

static void
pl_resize(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    plIO* ptIOCtx = pl_get_io();

    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    // recreate depth texture

    pl_queue_texture_for_deletion(&ptGraphics->tDevice, ptGraphics->tSwapchain.tColorTexture);
    pl_queue_texture_for_deletion(&ptGraphics->tDevice, ptGraphics->tSwapchain.tDepthTexture);
    pl_queue_texture_view_for_deletion(&ptGraphics->tDevice, ptGraphics->tSwapchain.tColorTextureView);
    pl_queue_texture_view_for_deletion(&ptGraphics->tDevice, ptGraphics->tSwapchain.tDepthTextureView);

    // color & depth
    const plTextureDesc tDepthTextureDesc = {
        .tDimensions = {ptIOCtx->afMainViewportSize[0], ptIOCtx->afMainViewportSize[1], 1},
        .tFormat = PL_FORMAT_D32_FLOAT,
        .uLayers = 1,
        .uMips = 1,
        .tType = PL_TEXTURE_TYPE_2D,
        .tUsage = PL_TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT | PL_TEXTURE_USAGE_TRANSIENT_ATTACHMENT,
        .tSamples = ptGraphics->tSwapchain.tMsaaSamples
    };
    ptGraphics->tSwapchain.tDepthTexture = pl_create_texture(&ptGraphics->tDevice, tDepthTextureDesc, 0, NULL, "Swapchain depth");

    const plTextureDesc tColorTextureDesc = {
        .tDimensions = {ptIOCtx->afMainViewportSize[0], ptIOCtx->afMainViewportSize[1], 1},
        .tFormat = PL_FORMAT_B8G8R8A8_UNORM,
        .uLayers = 1,
        .uMips = 1,
        .tType = PL_TEXTURE_TYPE_2D,
        .tUsage = PL_TEXTURE_USAGE_COLOR_ATTACHMENT | PL_TEXTURE_USAGE_SAMPLED,
        .tSamples = ptGraphics->tSwapchain.tMsaaSamples
    };
    ptGraphics->tSwapchain.tColorTexture = pl_create_texture(&ptGraphics->tDevice, tColorTextureDesc, 0, NULL, "Swapchain color");

    plSampler tSampler = {
        .tFilter = PL_FILTER_NEAREST,
        .fMinMip = 0.0f,
        .fMaxMip = 64.0f,
        .tVerticalWrap = PL_WRAP_MODE_CLAMP,
        .tHorizontalWrap = PL_WRAP_MODE_CLAMP
    };

    plTextureViewDesc tColorTextureViewDesc = {
        .tFormat     = tColorTextureDesc.tFormat,
        .uBaseLayer  = 0,
        .uBaseMip    = 0,
        .uLayerCount = 1
    };
    ptGraphics->tSwapchain.tColorTextureView = pl_create_texture_view(&ptGraphics->tDevice, &tColorTextureViewDesc, &tSampler, ptGraphics->tSwapchain.tColorTexture, "Swapchain color view");

    plTextureViewDesc tDepthTextureViewDesc = {
        .tFormat     = tDepthTextureDesc.tFormat,
        .uBaseLayer  = 0,
        .uBaseMip    = 0,
        .uLayerCount = 1
    };
    ptGraphics->tSwapchain.tDepthTextureView = pl_create_texture_view(&ptGraphics->tDevice, &tDepthTextureViewDesc, &tSampler, ptGraphics->tSwapchain.tDepthTexture, "Swapchain depth view");

    pl_end_profile_sample();
}

static bool
pl_begin_frame(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;
    ptMetalGraphics->uCurrentPassFenceIndex = 0;

    // Wait until the inflight command buffer has completed its work
    ptGraphics->tSwapchain.uCurrentImageIndex = ptGraphics->uCurrentFrameIndex;
    plFrameContext* ptFrame = pl__get_frame_resources(ptGraphics);
    ptFrame->uCurrentArgumentBuffer = 0;
    dispatch_semaphore_wait(ptFrame->tFrameBoundarySemaphore, DISPATCH_TIME_FOREVER);

    pl__garbage_collect(ptGraphics);
    
    plIO* ptIOCtx = pl_get_io();
    ptMetalGraphics->pMetalLayer = ptIOCtx->pBackendPlatformData;
    
    // get next drawable
    ptMetalGraphics->tCurrentDrawable = [ptMetalGraphics->pMetalLayer nextDrawable];

    if(!ptMetalGraphics->tCurrentDrawable)
    {
        pl_end_profile_sample();
        return false;
    }

    ptMetalGraphics->tCurrentCommandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];

    // reset 3d drawlists
    for(uint32_t i = 0u; i < pl_sb_size(ptGraphics->sbt3DDrawlists); i++)
    {
        plDrawList3D* drawlist = ptGraphics->sbt3DDrawlists[i];

        pl_sb_reset(drawlist->sbtSolidVertexBuffer);
        pl_sb_reset(drawlist->sbtLineVertexBuffer);
        pl_sb_reset(drawlist->sbtSolidIndexBuffer);    
        pl_sb_reset(drawlist->sbtLineIndexBuffer);    
    }

    pl_end_profile_sample();
    return true;
}

static bool
pl_end_gfx_frame(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;

    [ptMetalGraphics->tCurrentCommandBuffer presentDrawable:ptMetalGraphics->tCurrentDrawable];

    plFrameContext* ptFrame = pl__get_frame_resources(ptGraphics);
    ptFrame->uCurrentBufferIndex = UINT32_MAX;

    dispatch_semaphore_t semaphore = ptFrame->tFrameBoundarySemaphore;
    [ptMetalGraphics->tCurrentCommandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        // GPU work is complete
        // Signal the semaphore to start the CPU work
        dispatch_semaphore_signal(semaphore);
    }];

    [ptMetalGraphics->tCurrentCommandBuffer commit];

    ptGraphics->uCurrentFrameIndex = (ptGraphics->uCurrentFrameIndex + 1) % ptGraphics->uFramesInFlight;

    pl_end_profile_sample();
    return true;
}

static void
pl_begin_recording(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    pl_end_profile_sample();
}

static void
pl_end_recording(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    pl_end_profile_sample();
}

static void
pl_start_transfers(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    pl_end_profile_sample();
}

static void
pl_end_transfers(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    pl_end_profile_sample();
}

static void
pl_begin_main_pass(plGraphics* ptGraphics, plRenderPassHandle tPass)
{
    pl_begin_profile_sample(__FUNCTION__);
    plRenderPass* ptRenderPass = &ptGraphics->sbtRenderPassesCold[tPass.uIndex];
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plMetalRenderPass* ptMetalRenderPass = &ptMetalGraphics->sbtRenderPassesHot[tPass.uIndex];

    const plRenderPassAttachments* ptAttachment = &ptMetalRenderPass->sbtFrameBuffers[ptGraphics->tSwapchain.uCurrentImageIndex];

    const uint32_t uColorIndex = ptGraphics->sbtTextureViewsCold[ptAttachment->atViewAttachments[0].uIndex].tTexture.uIndex;
    const uint32_t uDepthIndex = ptGraphics->sbtTextureViewsCold[ptAttachment->atViewAttachments[1].uIndex].tTexture.uIndex;
    ptMetalRenderPass->ptRenderPassDescriptor.depthAttachment.texture = ptMetalGraphics->sbtTexturesHot[uDepthIndex].tTexture;
    ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[0].texture = ptMetalGraphics->sbtTexturesHot[uColorIndex].tTexture;
    ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[0].resolveTexture = ptMetalGraphics->tCurrentDrawable.texture;
    ptMetalGraphics->tCurrentRenderEncoder = [ptMetalGraphics->tCurrentCommandBuffer renderCommandEncoderWithDescriptor:ptMetalRenderPass->ptRenderPassDescriptor];

    for(uint32_t i = 0; i < ptMetalGraphics->uCurrentPassFenceIndex; i++)
        [ptMetalGraphics->tCurrentRenderEncoder waitForFence:ptMetalGraphics->atPassFences[i] beforeStages:MTLRenderStageFragment];

    pl_new_draw_frame_metal(ptMetalRenderPass->ptRenderPassDescriptor);
    pl_end_profile_sample();
}

static void
pl_end_main_pass(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    [ptMetalGraphics->tCurrentRenderEncoder endEncoding];
    pl_end_profile_sample();
}

static void
pl_begin_pass(plGraphics* ptGraphics, plRenderPassHandle tPass)
{
    pl_begin_profile_sample(__FUNCTION__);
    plRenderPass* ptRenderPass = &ptGraphics->sbtRenderPassesCold[tPass.uIndex];
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plMetalRenderPass* ptMetalRenderPass = &ptMetalGraphics->sbtRenderPassesHot[tPass.uIndex];

    const plRenderPassAttachments* ptAttachment = &ptMetalRenderPass->sbtFrameBuffers[ptGraphics->uCurrentFrameIndex];
    
    const uint32_t uColorIndex = ptGraphics->sbtTextureViewsCold[ptAttachment->atViewAttachments[0].uIndex].tTexture.uIndex;
    const uint32_t uDepthIndex = ptGraphics->sbtTextureViewsCold[ptAttachment->atViewAttachments[1].uIndex].tTexture.uIndex;
    ptMetalRenderPass->ptRenderPassDescriptor.depthAttachment.texture = ptMetalGraphics->sbtTexturesHot[uDepthIndex].tTexture;
    ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[0].texture = ptMetalGraphics->sbtTexturesHot[uColorIndex].tTexture;
    ptMetalGraphics->tCurrentRenderEncoder = [ptMetalGraphics->tCurrentCommandBuffer renderCommandEncoderWithDescriptor:ptMetalRenderPass->ptRenderPassDescriptor];

    pl_end_profile_sample();
}

static void
pl_end_pass(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    [ptMetalGraphics->tCurrentRenderEncoder updateFence:ptMetalGraphics->atPassFences[ptMetalGraphics->uCurrentPassFenceIndex++] afterStages:MTLRenderStageFragment];
    [ptMetalGraphics->tCurrentRenderEncoder endEncoding];
    pl_end_profile_sample();
}

static void
pl_dispatch(plGraphics* ptGraphics, uint32_t uDispatchCount, plDispatch* atDispatches)
{
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;
    id<MTLDevice> tDevice = ptMetalDevice->tDevice;

    id<MTLCommandBuffer> tCommandBuffer = [ptMetalGraphics->tCmdQueue commandBufferWithUnretainedReferences];
    tCommandBuffer.label = @"Compute command buffer";

    // Start a compute pass.
    id<MTLComputeCommandEncoder> tComputeEncoder = [tCommandBuffer computeCommandEncoder];

    for(uint32_t i = 0; i < uDispatchCount; i++)
    {
        const plDispatch* ptDispatch = &atDispatches[i];
        plMetalComputeShader* ptComputeShader = &ptMetalGraphics->sbtComputeShadersHot[ptDispatch->uShaderVariant];
        plMetalBindGroup* ptBindGroup = &ptMetalGraphics->sbtBindGroupsHot[ptDispatch->uBindGroup0];
        [tComputeEncoder setComputePipelineState:ptComputeShader->tPipelineState];

        for(uint32_t k = 0; k < ptBindGroup->tLayout.uBufferCount; k++)
        {
            const plBufferHandle tBufferHandle = ptBindGroup->tLayout.aBuffers[k].tBuffer;
            [tComputeEncoder useHeap:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tHeap];
            [tComputeEncoder useResource:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tBuffer usage:MTLResourceUsageRead | MTLResourceUsageWrite]; 
        }

        [tComputeEncoder setBuffer:ptBindGroup->tShaderArgumentBuffer
            offset:0
            atIndex:0];

        MTLSize tGridSize = MTLSizeMake(ptDispatch->uGroupCountX, ptDispatch->uGroupCountY, ptDispatch->uGroupCountZ);
        MTLSize tThreadsPerGroup = MTLSizeMake(ptDispatch->uThreadPerGroupX, ptDispatch->uThreadPerGroupY, ptDispatch->uThreadPerGroupZ);
        [tComputeEncoder dispatchThreadgroups:tGridSize threadsPerThreadgroup:tThreadsPerGroup];
    }

    // End the compute pass.
    [tComputeEncoder endEncoding];

    // Execute the command.
    [tCommandBuffer commit];

    [tCommandBuffer waitUntilCompleted];
}

static void
pl_draw_areas(plGraphics* ptGraphics, uint32_t uAreaCount, plDrawArea* atAreas)
{
    pl_begin_profile_sample(__FUNCTION__);
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;
    id<MTLDevice> tDevice = ptMetalDevice->tDevice;
    plFrameContext* ptFrame = pl__get_frame_resources(ptGraphics);

    for(uint32_t i = 0; i < uAreaCount; i++)
    {
        plDrawArea* ptArea = &atAreas[i];
        plDrawStream* ptStream = ptArea->ptDrawStream;

        MTLScissorRect tScissorRect = {
            .x      = (NSUInteger)(ptArea->tScissor.iOffsetX),
            .y      = (NSUInteger)(ptArea->tScissor.iOffsetY),
            .width  = (NSUInteger)(ptArea->tScissor.uWidth),
            .height = (NSUInteger)(ptArea->tScissor.uHeight)
        };
        [ptMetalGraphics->tCurrentRenderEncoder setScissorRect:tScissorRect];

        MTLViewport tViewport = {
            .originX = ptArea->tViewport.fX,
            .originY = ptArea->tViewport.fY,
            .width   = ptArea->tViewport.fWidth,
            .height  = ptArea->tViewport.fHeight
        };
        [ptMetalGraphics->tCurrentRenderEncoder setViewport:tViewport];

        const uint32_t uTokens = pl_sb_size(ptStream->sbtStream);
        uint32_t uCurrentStreamIndex = 0;
        uint32_t uTriangleCount = 0;
        uint32_t uIndexBuffer = 0;
        uint32_t uIndexBufferOffset = 0;
        uint32_t uVertexBufferOffset = 0;
        uint32_t uDynamicBufferOffset = 0;

        while(uCurrentStreamIndex < uTokens)
        {
            const uint32_t uDirtyMask = ptStream->sbtStream[uCurrentStreamIndex];
            uCurrentStreamIndex++;

            if(uDirtyMask & PL_DRAW_STREAM_BIT_SHADER)
            {
                plMetalShader* ptMetalShader = &ptMetalGraphics->sbtShadersHot[ptStream->sbtStream[uCurrentStreamIndex]];
                [ptMetalGraphics->tCurrentRenderEncoder setCullMode:ptMetalShader->tCullMode];
                [ptMetalGraphics->tCurrentRenderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
                [ptMetalGraphics->tCurrentRenderEncoder setDepthStencilState:ptMetalShader->tDepthStencilState];
                [ptMetalGraphics->tCurrentRenderEncoder setRenderPipelineState:ptMetalShader->tRenderPipelineState];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_DYNAMIC_OFFSET)
            {
                uDynamicBufferOffset = ptStream->sbtStream[uCurrentStreamIndex];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_DYNAMIC_BUFFER)
            {

                [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:ptFrame->sbtDynamicBuffers[ptStream->sbtStream[uCurrentStreamIndex]].tBuffer
                    offset:0
                    atIndex:4];

                [ptMetalGraphics->tCurrentRenderEncoder setFragmentBuffer:ptFrame->sbtDynamicBuffers[ptStream->sbtStream[uCurrentStreamIndex]].tBuffer
                    offset:0
                    atIndex:4];

                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_DYNAMIC_OFFSET)
            {
                [ptMetalGraphics->tCurrentRenderEncoder setVertexBufferOffset:uDynamicBufferOffset atIndex:4];
                [ptMetalGraphics->tCurrentRenderEncoder setFragmentBufferOffset:uDynamicBufferOffset atIndex:4];
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_BINDGROUP_2)
            {
                plMetalBindGroup* ptMetalBindGroup = &ptMetalGraphics->sbtBindGroupsHot[ptStream->sbtStream[uCurrentStreamIndex]];

                for(uint32_t k = 0; k < ptMetalBindGroup->tLayout.uBufferCount; k++)
                {
                    const plBufferHandle tBufferHandle = ptMetalBindGroup->tLayout.aBuffers[k].tBuffer;
                    [ptMetalGraphics->tCurrentRenderEncoder useHeap:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tHeap stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aBuffers[k].tStages)];
                    [ptMetalGraphics->tCurrentRenderEncoder useResource:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tBuffer
                        usage:MTLResourceUsageRead
                        stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aBuffers[k].tStages)]; 
                }

                for(uint32_t k = 0; k < ptMetalBindGroup->tLayout.uTextureCount; k++)
                {
                    const plTextureHandle tTextureHandle = ptGraphics->sbtTextureViewsCold[ptMetalBindGroup->tLayout.aTextures[k].tTextureView.uIndex].tTexture;
                    id<MTLHeap> tHeap = ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex].tHeap;
                    [ptMetalGraphics->tCurrentRenderEncoder useHeap:tHeap stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aTextures[k].tStages)];
                    [ptMetalGraphics->tCurrentRenderEncoder useResource:ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex].tTexture
                        usage:MTLResourceUsageRead
                        stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aTextures[k].tStages)]; 
                }

                [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:ptMetalBindGroup->tShaderArgumentBuffer
                    offset:ptMetalBindGroup->uOffset
                    atIndex:3];

                [ptMetalGraphics->tCurrentRenderEncoder setFragmentBuffer:ptMetalBindGroup->tShaderArgumentBuffer
                    offset:ptMetalBindGroup->uOffset
                    atIndex:3];
                uCurrentStreamIndex++;
            }
     
            if(uDirtyMask & PL_DRAW_STREAM_BIT_BINDGROUP_1)
            {
                plMetalBindGroup* ptMetalBindGroup = &ptMetalGraphics->sbtBindGroupsHot[ptStream->sbtStream[uCurrentStreamIndex]];

                for(uint32_t k = 0; k < ptMetalBindGroup->tLayout.uBufferCount; k++)
                {
                    const plBufferHandle tBufferHandle = ptMetalBindGroup->tLayout.aBuffers[k].tBuffer;
                    [ptMetalGraphics->tCurrentRenderEncoder useHeap:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tHeap stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aBuffers[k].tStages)];
                    [ptMetalGraphics->tCurrentRenderEncoder useResource:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tBuffer
                        usage:MTLResourceUsageRead
                        stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aBuffers[k].tStages)]; 
                }

                for(uint32_t k = 0; k < ptMetalBindGroup->tLayout.uTextureCount; k++)
                {
                    const plTextureHandle tTextureHandle = ptGraphics->sbtTextureViewsCold[ptMetalBindGroup->tLayout.aTextures[k].tTextureView.uIndex].tTexture;
                    id<MTLHeap> tHeap = ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex].tHeap;
                    [ptMetalGraphics->tCurrentRenderEncoder useHeap:tHeap stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aTextures[k].tStages)];
                    [ptMetalGraphics->tCurrentRenderEncoder useResource:ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex].tTexture
                        usage:MTLResourceUsageRead
                        stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aTextures[k].tStages)];  
                }

                [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:ptMetalBindGroup->tShaderArgumentBuffer
                    offset:ptMetalBindGroup->uOffset
                    atIndex:2];

                [ptMetalGraphics->tCurrentRenderEncoder setFragmentBuffer:ptMetalBindGroup->tShaderArgumentBuffer
                    offset:ptMetalBindGroup->uOffset
                    atIndex:2];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_BINDGROUP_0)
            {
                plMetalBindGroup* ptMetalBindGroup = &ptMetalGraphics->sbtBindGroupsHot[ptStream->sbtStream[uCurrentStreamIndex]];

                for(uint32_t k = 0; k < ptMetalBindGroup->tLayout.uBufferCount; k++)
                {
                    const plBufferHandle tBufferHandle = ptMetalBindGroup->tLayout.aBuffers[k].tBuffer;
                    [ptMetalGraphics->tCurrentRenderEncoder useHeap:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tHeap stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aBuffers[k].tStages)];
                    [ptMetalGraphics->tCurrentRenderEncoder useResource:ptMetalGraphics->sbtBuffersHot[tBufferHandle.uIndex].tBuffer
                        usage:MTLResourceUsageRead
                        stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aBuffers[k].tStages)]; 
                }


                for(uint32_t k = 0; k < ptMetalBindGroup->tLayout.uTextureCount; k++)
                {
                    
                    const plTextureHandle tTextureHandle = ptGraphics->sbtTextureViewsCold[ptMetalBindGroup->tLayout.aTextures[k].tTextureView.uIndex].tTexture;
                    id<MTLHeap> tHeap = ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex].tHeap;
                    [ptMetalGraphics->tCurrentRenderEncoder useHeap:tHeap stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aTextures[k].tStages)];
                    [ptMetalGraphics->tCurrentRenderEncoder useResource:ptMetalGraphics->sbtTexturesHot[tTextureHandle.uIndex].tTexture
                        usage:MTLResourceUsageRead
                        stages:pl__metal_stage_flags(ptMetalBindGroup->tLayout.aTextures[k].tStages)];  
                }

                [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:ptMetalBindGroup->tShaderArgumentBuffer
                    offset:ptMetalBindGroup->uOffset
                    atIndex:1];

                [ptMetalGraphics->tCurrentRenderEncoder setFragmentBuffer:ptMetalBindGroup->tShaderArgumentBuffer
                    offset:ptMetalBindGroup->uOffset
                    atIndex:1];

                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_INDEX_OFFSET)
            {
                uIndexBufferOffset = ptStream->sbtStream[uCurrentStreamIndex];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_VERTEX_OFFSET)
            {
                uVertexBufferOffset = ptStream->sbtStream[uCurrentStreamIndex];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_INDEX_BUFFER)
            {
                [ptMetalGraphics->tCurrentRenderEncoder useHeap:ptMetalGraphics->sbtBuffersHot[ptStream->sbtStream[uCurrentStreamIndex]].tHeap stages:MTLRenderStageVertex];
                uIndexBuffer = ptStream->sbtStream[uCurrentStreamIndex];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_VERTEX_BUFFER)
            {
                [ptMetalGraphics->tCurrentRenderEncoder useHeap:ptMetalGraphics->sbtBuffersHot[ptStream->sbtStream[uCurrentStreamIndex]].tHeap stages:MTLRenderStageVertex];
                [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:ptMetalGraphics->sbtBuffersHot[ptStream->sbtStream[uCurrentStreamIndex]].tBuffer
                    offset:0
                    atIndex:0];
                uCurrentStreamIndex++;
            }
            if(uDirtyMask & PL_DRAW_STREAM_BIT_TRIANGLES)
            {
                uTriangleCount = ptStream->sbtStream[uCurrentStreamIndex];
                uCurrentStreamIndex++;
            }

            [ptMetalGraphics->tCurrentRenderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle 
                indexCount:uTriangleCount * 3
                indexType:MTLIndexTypeUInt32
                indexBuffer:ptMetalGraphics->sbtBuffersHot[uIndexBuffer].tBuffer
                indexBufferOffset:uIndexBufferOffset * sizeof(uint32_t)
                instanceCount:1
                baseVertex:uVertexBufferOffset
                baseInstance:0
                ];
        }
    }
    pl_end_profile_sample();
}

static void
pl_cleanup(plGraphics* ptGraphics)
{
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;

    pl_cleanup_metal();

    for(uint32_t i = 0; i < pl_sb_size(ptMetalGraphics->sbtRenderPassesHot); i++)
    {
        pl_sb_free(ptMetalGraphics->sbtRenderPassesHot[i].sbtFrameBuffers);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptMetalGraphics->sbFrames); i++)
    {
        plFrameContext* ptFrame = &ptMetalGraphics->sbFrames[i];
        pl_sb_free(ptFrame->sbtDynamicBuffers);
        pl_sb_free(ptFrame->sbtArgumentBuffers);
    }

    pl_sb_free(ptMetalGraphics->sbFrames);
    pl_sb_free(ptMetalGraphics->sbtTexturesHot);
    pl_sb_free(ptMetalGraphics->sbtSamplersHot);
    pl_sb_free(ptMetalGraphics->sbtBindGroupsHot);
    pl_sb_free(ptMetalGraphics->sbtBuffersHot);
    pl_sb_free(ptMetalGraphics->sbtShadersHot);
    pl_sb_free(ptMetalGraphics->sbtPipelineEntries);
    pl_sb_free(ptMetalGraphics->sbFrames);
    pl_sb_free(ptMetalGraphics->sbtRenderPassesHot);
    pl_sb_free(ptMetalGraphics->sbtRenderPassLayoutsHot);
    pl_sb_free(ptMetalGraphics->sbtComputeShadersHot);
    pl__cleanup_common_graphics(ptGraphics);
}

static void
pl_draw_lists(plGraphics* ptGraphics, uint32_t uListCount, plDrawList* atLists, plRenderPassHandle tPass)
{
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;
    id<MTLDevice> tDevice = ptMetalDevice->tDevice;
    plMetalRenderPass* ptMetalRenderPass = &ptMetalGraphics->sbtRenderPassesHot[tPass.uIndex];

    plIO* ptIOCtx = pl_get_io();
    for(uint32_t i = 0; i < uListCount; i++)
    {
        pl_submit_metal_drawlist(&atLists[i], ptIOCtx->afMainViewportSize[0], ptIOCtx->afMainViewportSize[1], ptMetalGraphics->tCurrentRenderEncoder, ptMetalGraphics->tCurrentCommandBuffer, ptMetalRenderPass->ptRenderPassDescriptor);
    }
}

static void
pl__submit_3d_drawlist(plDrawList3D* ptDrawlist, float fWidth, float fHeight, const plMat4* ptMVP, pl3DDrawFlags tFlags, plRenderPassHandle tPass, uint32_t uMSAASampleCount)
{
    plGraphics* ptGfx = ptDrawlist->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGfx->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptGfx->tDevice._pInternalData;

    plMetalRenderPass* ptMetalRenderPass = &ptMetalGraphics->sbtRenderPassesHot[tPass.uIndex];
    plMetalPipelineEntry* ptPipelineEntry = pl__get_3d_pipelines(ptGfx, tFlags, ptMetalRenderPass->ptRenderPassDescriptor.colorAttachments[0].texture.sampleCount, ptMetalRenderPass->ptRenderPassDescriptor);

    const float fAspectRatio = fWidth / fHeight;

    const uint32_t uTotalIdxBufSzNeeded = sizeof(uint32_t) * (pl_sb_size(ptDrawlist->sbtSolidIndexBuffer) + pl_sb_size(ptDrawlist->sbtLineIndexBuffer));
    const uint32_t uSolidVtxBufSzNeeded = sizeof(plDrawVertex3DSolid) * pl_sb_size(ptDrawlist->sbtSolidVertexBuffer);
    const uint32_t uLineVtxBufSzNeeded = sizeof(plDrawVertex3DLine) * pl_sb_size(ptDrawlist->sbtLineVertexBuffer);

    plTrackedMetalBuffer* tIndexBuffer = pl__dequeue_reusable_buffer(ptGfx, uTotalIdxBufSzNeeded);
    plTrackedMetalBuffer* tVertexBuffer = pl__dequeue_reusable_buffer(ptGfx, uLineVtxBufSzNeeded + uSolidVtxBufSzNeeded);
    uint32_t uVertexOffset = 0;
    uint32_t uIndexOffset = 0;

    [ptMetalGraphics->tCurrentRenderEncoder setDepthStencilState:ptPipelineEntry->tDepthStencilState];
    [ptMetalGraphics->tCurrentRenderEncoder setCullMode:(tFlags & PL_PIPELINE_FLAG_FRONT_FACE_CW)];
    int iCullMode = MTLCullModeNone;
    if(tFlags & PL_PIPELINE_FLAG_CULL_FRONT) iCullMode = MTLCullModeFront;
    if(tFlags & PL_PIPELINE_FLAG_CULL_BACK) iCullMode |= MTLCullModeBack;
    [ptMetalGraphics->tCurrentRenderEncoder setCullMode:iCullMode];
    [ptMetalGraphics->tCurrentRenderEncoder setFrontFacingWinding:(tFlags & PL_PIPELINE_FLAG_FRONT_FACE_CW) ? MTLWindingClockwise : MTLWindingCounterClockwise];

    if(pl_sb_size(ptDrawlist->sbtSolidVertexBuffer) > 0)
    {
        memcpy(tVertexBuffer.buffer.contents, ptDrawlist->sbtSolidVertexBuffer, uSolidVtxBufSzNeeded);
        const uint32_t uIdxBufSzNeeded = sizeof(uint32_t) * pl_sb_size(ptDrawlist->sbtSolidIndexBuffer);
        memcpy(tIndexBuffer.buffer.contents, ptDrawlist->sbtSolidIndexBuffer, uIdxBufSzNeeded);

        [ptMetalGraphics->tCurrentRenderEncoder setVertexBytes:ptMVP length:sizeof(plMat4) atIndex:1 ];
        
        [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:tVertexBuffer.buffer offset:uVertexOffset atIndex:0];
        [ptMetalGraphics->tCurrentRenderEncoder setRenderPipelineState:ptPipelineEntry->tSolidRenderPipelineState];
        [ptMetalGraphics->tCurrentRenderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:pl_sb_size(ptDrawlist->sbtSolidIndexBuffer) indexType:MTLIndexTypeUInt32 indexBuffer:tIndexBuffer.buffer indexBufferOffset:uIndexOffset];

        uVertexOffset = uSolidVtxBufSzNeeded;
        uIndexOffset = uIdxBufSzNeeded;
    }

    if(pl_sb_size(ptDrawlist->sbtLineVertexBuffer) > 0)
    {
        memcpy(&((char*)tVertexBuffer.buffer.contents)[uVertexOffset], ptDrawlist->sbtLineVertexBuffer, uLineVtxBufSzNeeded);
        const uint32_t uIdxBufSzNeeded = sizeof(uint32_t) * pl_sb_size(ptDrawlist->sbtLineIndexBuffer);
        memcpy(&((char*)tIndexBuffer.buffer.contents)[uIndexOffset], ptDrawlist->sbtLineIndexBuffer, uIdxBufSzNeeded);

        struct UniformData {
            plMat4 tMvp;
            float  fAspect;
            float  padding[3];
        };

        struct UniformData b = {
            *ptMVP,
            fAspectRatio
        };

        [ptMetalGraphics->tCurrentRenderEncoder setVertexBytes:&b length:sizeof(struct UniformData) atIndex:1 ];
        [ptMetalGraphics->tCurrentRenderEncoder setVertexBuffer:tVertexBuffer.buffer offset:uVertexOffset atIndex:0];
        [ptMetalGraphics->tCurrentRenderEncoder setRenderPipelineState:ptPipelineEntry->tLineRenderPipelineState];
        [ptMetalGraphics->tCurrentRenderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:pl_sb_size(ptDrawlist->sbtLineIndexBuffer) indexType:MTLIndexTypeUInt32 indexBuffer:tIndexBuffer.buffer indexBufferOffset:uIndexOffset];
    }

    [ptMetalGraphics->tCurrentCommandBuffer addCompletedHandler:^(id<MTLCommandBuffer> tCmdBuffer)
    {
        dispatch_async(dispatch_get_main_queue(), ^{

            @synchronized(ptMetalGraphics->bufferCache)
            {
                [ptMetalGraphics->bufferCache addObject:tVertexBuffer];
                [ptMetalGraphics->bufferCache addObject:tIndexBuffer];
            }
        });
    }];
}

//-----------------------------------------------------------------------------
// [SECTION] internal api implementation
//-----------------------------------------------------------------------------

static MTLLoadAction
pl__metal_load_op(plLoadOp tOp)
{
    switch(tOp)
    {
        case PL_LOAD_OP_LOAD:      return MTLLoadActionLoad;
        case PL_LOAD_OP_CLEAR:     return MTLLoadActionClear;
        case PL_LOAD_OP_DONT_CARE: return MTLLoadActionDontCare;
    }

    PL_ASSERT(false && "Unsupported load op");
    return MTLLoadActionDontCare;
}

static MTLDataType
pl__metal_data_type(plDataType tType)
{
    switch(tType)
    {

        case PL_DATA_TYPE_BOOL:           return MTLDataTypeBool;
        case PL_DATA_TYPE_FLOAT:          return MTLDataTypeFloat;
        case PL_DATA_TYPE_UNSIGNED_BYTE:  return MTLDataTypeUChar;
        case PL_DATA_TYPE_BYTE:           return MTLDataTypeChar;
        case PL_DATA_TYPE_UNSIGNED_SHORT: return MTLDataTypeUShort;
        case PL_DATA_TYPE_SHORT:          return MTLDataTypeShort;
        case PL_DATA_TYPE_UNSIGNED_INT:   return MTLDataTypeUInt;
        case PL_DATA_TYPE_INT:            return MTLDataTypeInt;
        case PL_DATA_TYPE_UNSIGNED_LONG:  return MTLDataTypeULong;
        case PL_DATA_TYPE_LONG:           return MTLDataTypeLong;

        case PL_DATA_TYPE_BOOL2:           return MTLDataTypeBool2;
        case PL_DATA_TYPE_FLOAT2:          return MTLDataTypeFloat2;
        case PL_DATA_TYPE_UNSIGNED_BYTE2:  return MTLDataTypeUChar2;
        case PL_DATA_TYPE_BYTE2:           return MTLDataTypeChar2;
        case PL_DATA_TYPE_UNSIGNED_SHORT2: return MTLDataTypeUShort2;
        case PL_DATA_TYPE_SHORT2:          return MTLDataTypeShort2;
        case PL_DATA_TYPE_UNSIGNED_INT2:   return MTLDataTypeUInt2;
        case PL_DATA_TYPE_INT2:            return MTLDataTypeInt2;
        case PL_DATA_TYPE_UNSIGNED_LONG2:  return MTLDataTypeULong2;
        case PL_DATA_TYPE_LONG2:           return MTLDataTypeLong2;

        case PL_DATA_TYPE_BOOL3:           return MTLDataTypeBool3;
        case PL_DATA_TYPE_FLOAT3:          return MTLDataTypeFloat3;
        case PL_DATA_TYPE_UNSIGNED_BYTE3:  return MTLDataTypeUChar3;
        case PL_DATA_TYPE_BYTE3:           return MTLDataTypeChar3;
        case PL_DATA_TYPE_UNSIGNED_SHORT3: return MTLDataTypeUShort3;
        case PL_DATA_TYPE_SHORT3:          return MTLDataTypeShort3;
        case PL_DATA_TYPE_UNSIGNED_INT3:   return MTLDataTypeUInt3;
        case PL_DATA_TYPE_INT3:            return MTLDataTypeInt3;
        case PL_DATA_TYPE_UNSIGNED_LONG3:  return MTLDataTypeULong3;
        case PL_DATA_TYPE_LONG3:           return MTLDataTypeLong3;

        case PL_DATA_TYPE_BOOL4:           return MTLDataTypeBool4;
        case PL_DATA_TYPE_FLOAT4:          return MTLDataTypeFloat4;
        case PL_DATA_TYPE_UNSIGNED_BYTE4:  return MTLDataTypeUChar4;
        case PL_DATA_TYPE_BYTE4:           return MTLDataTypeChar4;
        case PL_DATA_TYPE_UNSIGNED_SHORT4: return MTLDataTypeUShort4;
        case PL_DATA_TYPE_SHORT4:          return MTLDataTypeShort4;
        case PL_DATA_TYPE_UNSIGNED_INT4:   return MTLDataTypeUInt4;
        case PL_DATA_TYPE_INT4:            return MTLDataTypeInt4;
        case PL_DATA_TYPE_UNSIGNED_LONG4:  return MTLDataTypeULong4;
        case PL_DATA_TYPE_LONG4:           return MTLDataTypeLong4;
    }

    PL_ASSERT(false && "Unsupported data type");
    return 0;
}

static MTLStoreAction
pl__metal_store_op(plStoreOp tOp)
{
    switch(tOp)
    {
        case PL_STORE_OP_STORE:               return MTLStoreActionStore;
        case PL_STORE_OP_MULTISAMPLE_RESOLVE: return MTLStoreActionMultisampleResolve;
        case PL_STORE_OP_DONT_CARE:           return MTLStoreActionDontCare;
        case PL_STORE_OP_NONE:                return MTLStoreActionUnknown;
    }

    PL_ASSERT(false && "Unsupported store op");
    return MTLStoreActionUnknown;
}

static MTLSamplerMinMagFilter
pl__metal_filter(plFilter tFilter)
{
    switch(tFilter)
    {
        case PL_FILTER_UNSPECIFIED:
        case PL_FILTER_NEAREST: return MTLSamplerMinMagFilterNearest;
        case PL_FILTER_LINEAR:  return MTLSamplerMinMagFilterLinear;
    }

    PL_ASSERT(false && "Unsupported filter mode");
    return MTLSamplerMinMagFilterLinear;
}

static MTLSamplerAddressMode
pl__metal_wrap(plWrapMode tWrap)
{
    switch(tWrap)
    {
        case PL_WRAP_MODE_UNSPECIFIED:
        case PL_WRAP_MODE_WRAP:   return MTLSamplerAddressModeMirrorRepeat;
        case PL_WRAP_MODE_CLAMP:  return MTLSamplerAddressModeClampToEdge;
        case PL_WRAP_MODE_MIRROR: return MTLSamplerAddressModeMirrorRepeat;
    }

    PL_ASSERT(false && "Unsupported wrap mode");
    return MTLSamplerAddressModeMirrorRepeat;
}

static MTLCompareFunction
pl__metal_compare(plCompareMode tCompare)
{
    switch(tCompare)
    {
        case PL_COMPARE_MODE_UNSPECIFIED:
        case PL_COMPARE_MODE_NEVER:            return MTLCompareFunctionNever;
        case PL_COMPARE_MODE_LESS:             return MTLCompareFunctionLess;
        case PL_COMPARE_MODE_EQUAL:            return MTLCompareFunctionEqual;
        case PL_COMPARE_MODE_LESS_OR_EQUAL:    return MTLCompareFunctionLessEqual;
        case PL_COMPARE_MODE_GREATER:          return MTLCompareFunctionGreater;
        case PL_COMPARE_MODE_NOT_EQUAL:        return MTLCompareFunctionNotEqual;
        case PL_COMPARE_MODE_GREATER_OR_EQUAL: return MTLCompareFunctionGreaterEqual;
        case PL_COMPARE_MODE_ALWAYS:           return MTLCompareFunctionAlways;
    }

    PL_ASSERT(false && "Unsupported compare mode");
    return MTLCompareFunctionNever;
}

static MTLPixelFormat
pl__metal_format(plFormat tFormat)
{
    switch(tFormat)
    {
        case PL_FORMAT_R32G32B32A32_FLOAT: return MTLPixelFormatRGBA32Float;
        case PL_FORMAT_R8G8B8A8_UNORM:     return MTLPixelFormatRGBA8Unorm;
        case PL_FORMAT_R32G32_FLOAT:       return MTLPixelFormatRG32Float;
        case PL_FORMAT_R8G8B8A8_SRGB:      return MTLPixelFormatRGBA8Unorm_sRGB;
        case PL_FORMAT_B8G8R8A8_SRGB:      return MTLPixelFormatBGRA8Unorm_sRGB;
        case PL_FORMAT_B8G8R8A8_UNORM:     return MTLPixelFormatBGRA8Unorm;
        case PL_FORMAT_D32_FLOAT:          return MTLPixelFormatDepth32Float;
        case PL_FORMAT_D32_FLOAT_S8_UINT:  return MTLPixelFormatDepth32Float_Stencil8;
        case PL_FORMAT_D24_UNORM_S8_UINT:  return MTLPixelFormatDepth24Unorm_Stencil8;
    }

    PL_ASSERT(false && "Unsupported format");
    return MTLPixelFormatInvalid;
}

static MTLCullMode
pl__metal_cull(plCullMode tCullMode)
{
    switch(tCullMode)
    {
        case PL_CULL_MODE_NONE:       return MTLCullModeNone;
        case PL_CULL_MODE_CULL_BACK:  return MTLCullModeBack;
        case PL_CULL_MODE_CULL_FRONT: return MTLCullModeFront;
    }
    PL_ASSERT(false && "Unsupported cull mode");
    return MTLCullModeNone;
};

static MTLRenderStages
pl__metal_stage_flags(plStageFlags tFlags)
{
    MTLRenderStages tResult = 0;

    if(tFlags & PL_STAGE_VERTEX)   tResult |= MTLRenderStageVertex;
    if(tFlags & PL_STAGE_PIXEL)    tResult |= MTLRenderStageFragment;
    // if(tFlags & PL_STAGE_COMPUTE)  tResult |= VK_SHADER_STAGE_COMPUTE_BIT; // not needed

    return tResult;
}

static plTrackedMetalBuffer*
pl__dequeue_reusable_buffer(plGraphics* ptGraphics, NSUInteger length)
{
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    double now = pl_get_io()->dTime;

    @synchronized(ptMetalGraphics->bufferCache)
    {
        // Purge old buffers that haven't been useful for a while
        if (now - ptMetalGraphics->lastBufferCachePurge > 1.0)
        {
            NSMutableArray* survivors = [NSMutableArray array];
            for (plTrackedMetalBuffer* candidate in ptMetalGraphics->bufferCache)
                if (candidate.lastReuseTime > ptMetalGraphics->lastBufferCachePurge)
                    [survivors addObject:candidate];
                else
                {
                    [candidate.buffer setPurgeableState:MTLPurgeableStateEmpty];
                    [candidate.buffer release];
                    [candidate release];
                }
            ptMetalGraphics->bufferCache = [survivors mutableCopy];
            ptMetalGraphics->lastBufferCachePurge = now;
        }

        // see if we have a buffer we can reuse
        plTrackedMetalBuffer* bestCandidate = nil;
        for (plTrackedMetalBuffer* candidate in ptMetalGraphics->bufferCache)
            if (candidate.buffer.length >= length && (bestCandidate == nil || bestCandidate.lastReuseTime > candidate.lastReuseTime))
                bestCandidate = candidate;

        if (bestCandidate != nil)
        {
            [ptMetalGraphics->bufferCache removeObject:bestCandidate];
            bestCandidate.lastReuseTime = now;
            return bestCandidate;
        }
    }

    // make a new buffer
    id<MTLBuffer> backing = [ptMetalDevice->tDevice newBufferWithLength:length options:MTLResourceStorageModeShared];
    backing.label = [NSString stringWithUTF8String:"3d drawing"];
    return [[plTrackedMetalBuffer alloc] initWithBuffer:backing];
}

static plMetalPipelineEntry*
pl__get_3d_pipelines(plGraphics* ptGraphics, pl3DDrawFlags tFlags, uint32_t uSampleCount, MTLRenderPassDescriptor* ptRenderPassDescriptor)
{
    plGraphicsMetal* ptMetalGraphics = (plGraphicsMetal*)ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = (plDeviceMetal*)ptGraphics->tDevice._pInternalData;

    for(uint32_t i = 0; i < pl_sb_size(ptMetalGraphics->sbtPipelineEntries); i++)
    {
        if(ptMetalGraphics->sbtPipelineEntries[i].tFlags == tFlags && ptMetalGraphics->sbtPipelineEntries[i].uSampleCount == uSampleCount)
            return &ptMetalGraphics->sbtPipelineEntries[i];
    }

    // pipeline not found, make new one

    plMetalPipelineEntry tPipelineEntry = {
        .tFlags = tFlags,
        .uSampleCount = uSampleCount
    };

    NSError* error = nil;

    // line rendering
    {
        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3; // position
        vertexDescriptor.attributes[0].bufferIndex = 0;

        vertexDescriptor.attributes[1].offset = sizeof(float) * 3;
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat3; // info
        vertexDescriptor.attributes[1].bufferIndex = 0;

        vertexDescriptor.attributes[2].offset = sizeof(float) * 6;
        vertexDescriptor.attributes[2].format = MTLVertexFormatFloat3; // other position
        vertexDescriptor.attributes[3].bufferIndex = 0;

        vertexDescriptor.attributes[3].offset = sizeof(float) * 9;
        vertexDescriptor.attributes[3].format = MTLVertexFormatUChar4; // color
        vertexDescriptor.attributes[3].bufferIndex = 0;

        vertexDescriptor.layouts[0].stepRate = 1;
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stride = sizeof(float) * 10;

        MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
        depthDescriptor.depthCompareFunction = (tFlags & PL_PIPELINE_FLAG_DEPTH_TEST) ? MTLCompareFunctionLessEqual : MTLCompareFunctionAlways;
        depthDescriptor.depthWriteEnabled = (tFlags & PL_PIPELINE_FLAG_DEPTH_WRITE) ? YES : NO;
        tPipelineEntry.tDepthStencilState = [ptMetalDevice->tDevice newDepthStencilStateWithDescriptor:depthDescriptor];

        MTLRenderPipelineDescriptor* pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDescriptor.vertexFunction = ptMetalGraphics->tLineVertexFunction;
        pipelineDescriptor.fragmentFunction = ptMetalGraphics->tFragmentFunction;
        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineDescriptor.rasterSampleCount = uSampleCount;

        pipelineDescriptor.colorAttachments[0].pixelFormat = ptRenderPassDescriptor.colorAttachments[0].texture.pixelFormat;
        pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        pipelineDescriptor.depthAttachmentPixelFormat = ptRenderPassDescriptor.depthAttachment.texture.pixelFormat;
        pipelineDescriptor.stencilAttachmentPixelFormat = ptRenderPassDescriptor.stencilAttachment.texture.pixelFormat;

        tPipelineEntry.tLineRenderPipelineState = [ptMetalDevice->tDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];

        if (error != nil)
            NSLog(@"Error: failed to create Metal pipeline state: %@", error);
    }

    // solid rendering
    {
        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3; // position
        vertexDescriptor.attributes[0].bufferIndex = 0;
        vertexDescriptor.attributes[1].offset = sizeof(float) * 3;
        vertexDescriptor.attributes[1].format = MTLVertexFormatUChar4; // color
        vertexDescriptor.attributes[1].bufferIndex = 0;
        vertexDescriptor.layouts[0].stepRate = 1;
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stride = sizeof(float) * 4;

        MTLRenderPipelineDescriptor* pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDescriptor.vertexFunction = ptMetalGraphics->tSolidVertexFunction;
        pipelineDescriptor.fragmentFunction = ptMetalGraphics->tFragmentFunction;
        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineDescriptor.rasterSampleCount = uSampleCount;
        pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        pipelineDescriptor.depthAttachmentPixelFormat = ptRenderPassDescriptor.depthAttachment.texture.pixelFormat;
        pipelineDescriptor.stencilAttachmentPixelFormat = ptRenderPassDescriptor.stencilAttachment.texture.pixelFormat;

        tPipelineEntry.tSolidRenderPipelineState = [ptMetalDevice->tDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
        if (error != nil)
            NSLog(@"Error: failed to create Metal pipeline state: %@", error);
    }

    pl_sb_push(ptMetalGraphics->sbtPipelineEntries, tPipelineEntry);
    return &ptMetalGraphics->sbtPipelineEntries[pl_sb_size(ptMetalGraphics->sbtPipelineEntries) - 1];
}

static void
pl__garbage_collect(plGraphics* ptGraphics)
{
    pl_begin_profile_sample(__FUNCTION__);
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal*   ptMetalDevice = ptGraphics->tDevice._pInternalData;
    plFrameContext* ptFrame = pl__get_frame_resources(ptGraphics);

    plFrameGarbage* ptGarbage = pl__get_frame_garbage(ptGraphics);


    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtRenderPasses); i++)
    {
        const uint32_t iResourceIndex = ptGarbage->sbtRenderPasses[i].uIndex;
        plMetalRenderPass* ptMetalResource = &ptMetalGraphics->sbtRenderPassesHot[iResourceIndex];
        [ptMetalResource->ptRenderPassDescriptor release];
        ptMetalResource->ptRenderPassDescriptor = nil;
        pl_sb_push(ptGraphics->sbtRenderPassFreeIndices, iResourceIndex);
        pl_sb_reset(ptMetalResource->sbtFrameBuffers);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtRenderPassLayouts); i++)
    {
        const uint32_t iResourceIndex = ptGarbage->sbtRenderPassLayouts[i].uIndex;
        plMetalRenderPassLayout* ptMetalResource = &ptMetalGraphics->sbtRenderPassLayoutsHot[iResourceIndex];
        pl_sb_push(ptGraphics->sbtRenderPassLayoutFreeIndices, iResourceIndex);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtShaders); i++)
    {
        const uint32_t iResourceIndex = ptGarbage->sbtShaders[i].uIndex;
        plShader* ptResource = &ptGraphics->sbtShadersCold[iResourceIndex];

        for(uint32_t j = 0; j < pl_sb_size(ptResource->_sbtVariantHandles); j++)
        {
            const uint32_t iVariantIndex = ptResource->_sbtVariantHandles[j].uIndex;
            plMetalShader* ptVariantMetalResource = &ptMetalGraphics->sbtShadersHot[iVariantIndex];
            [ptVariantMetalResource->tDepthStencilState release];
            [ptVariantMetalResource->tRenderPipelineState release];
            ptVariantMetalResource->tDepthStencilState = nil;
            ptVariantMetalResource->tRenderPipelineState = nil;
            if(ptVariantMetalResource->library)
            {
                [ptVariantMetalResource->library release];
                ptVariantMetalResource->library = nil;
            }
            pl_sb_push(ptGraphics->sbtShaderFreeIndices, iVariantIndex);
        }
        pl_sb_free(ptResource->_sbtVariantHandles);
        pl_hm_free(&ptResource->tVariantHashmap);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtComputeShaders); i++)
    {
        const uint32_t iResourceIndex = ptGarbage->sbtComputeShaders[i].uIndex;
        plComputeShader* ptResource = &ptGraphics->sbtComputeShadersCold[iResourceIndex];

        for(uint32_t j = 0; j < pl_sb_size(ptResource->_sbtVariantHandles); j++)
        {
            const uint32_t iVariantIndex = ptResource->_sbtVariantHandles[j].uIndex;
            plMetalComputeShader* ptVariantMetalResource = &ptMetalGraphics->sbtComputeShadersHot[iVariantIndex];
            [ptVariantMetalResource->tPipelineState release];
            ptVariantMetalResource->tPipelineState = nil;
            if(ptVariantMetalResource->library)
            {
                [ptVariantMetalResource->library release];
                ptVariantMetalResource->library = nil;
            }
            pl_sb_push(ptGraphics->sbtComputeShaderFreeIndices, iVariantIndex);
        }
        pl_sb_free(ptResource->_sbtVariantHandles);
        pl_hm_free(&ptResource->tVariantHashmap);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtBindGroups); i++)
    {
        const uint32_t iBindGroupIndex = ptGarbage->sbtBindGroups[i].uIndex;
        plMetalBindGroup* ptMetalResource = &ptMetalGraphics->sbtBindGroupsHot[iBindGroupIndex];
        [ptMetalResource->tShaderArgumentBuffer release];
        ptMetalResource->tShaderArgumentBuffer = nil;
        pl_sb_push(ptGraphics->sbtBindGroupFreeIndices, iBindGroupIndex);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtTextures); i++)
    {
        const uint32_t uTextureIndex = ptGarbage->sbtTextures[i].uIndex;
        plMetalTexture* ptMetalTexture = &ptMetalGraphics->sbtTexturesHot[uTextureIndex];
        [ptMetalTexture->tTexture release];
        ptMetalTexture->tTexture = nil;
        pl_sb_push(ptGraphics->sbtTextureFreeIndices, uTextureIndex);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtTextureViews); i++)
    {
        const uint32_t uTextureViewIndex = ptGarbage->sbtTextureViews[i].uIndex;
        plMetalSampler* ptMetalSampler = &ptMetalGraphics->sbtSamplersHot[uTextureViewIndex];
        [ptMetalSampler->tSampler release];
        ptMetalSampler->tSampler = nil;
        pl_sb_push(ptGraphics->sbtTextureViewFreeIndices, uTextureViewIndex);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtBuffers); i++)
    {
        const uint32_t iBufferIndex = ptGarbage->sbtBuffers[i].uIndex;
        [ptMetalGraphics->sbtBuffersHot[iBufferIndex].tBuffer release];
        ptMetalGraphics->sbtBuffersHot[iBufferIndex].tBuffer = nil;
        pl_sb_push(ptGraphics->sbtBufferFreeIndices, iBufferIndex);
    }

    for(uint32_t i = 0; i < pl_sb_size(ptGarbage->sbtMemory); i++)
    {
        if(ptGarbage->sbtMemory[i].ptInst == ptGraphics->tDevice.tLocalBuddyAllocator.ptInst)
            ptGraphics->tDevice.tLocalBuddyAllocator.free(ptGraphics->tDevice.tLocalBuddyAllocator.ptInst, &ptGarbage->sbtMemory[i]);
        else if(ptGarbage->sbtMemory[i].ptInst == ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst)
            ptGraphics->tDevice.tLocalDedicatedAllocator.free(ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst, &ptGarbage->sbtMemory[i]);
        else if(ptGarbage->sbtMemory[i].ptInst == ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst)
            ptGraphics->tDevice.tStagingUnCachedAllocator.free(ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst, &ptGarbage->sbtMemory[i]);
        else if(ptGarbage->sbtMemory[i].ptInst == ptGraphics->tDevice.tStagingCachedAllocator.ptInst)
            ptGraphics->tDevice.tStagingCachedAllocator.free(ptGraphics->tDevice.tStagingCachedAllocator.ptInst, &ptGarbage->sbtMemory[i]);
    }

    plDeviceAllocatorData* ptUnCachedAllocatorData = (plDeviceAllocatorData*)ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst;

    plIO* ptIO = pl_get_io();
    for(uint32_t i = 0; i < pl_sb_size(ptUnCachedAllocatorData->sbtNodes); i++)
    {
        plDeviceAllocationRange* ptNode = &ptUnCachedAllocatorData->sbtNodes[i];
        plDeviceAllocationBlock* ptBlock = &ptUnCachedAllocatorData->sbtBlocks[ptNode->ulBlockIndex];

        if(ptBlock->ulAddress == 0)
        {
            continue;
        }
        if(ptNode->ulUsedSize == 0 && ptIO->dTime - ptBlock->dLastTimeUsed > 1.0)
        {
            ptGraphics->szHostMemoryInUse -= ptBlock->ulSize;
            id<MTLHeap> tMetalHeap = (id<MTLHeap>)ptBlock->ulAddress;
            [tMetalHeap release];
            tMetalHeap = nil;

            ptBlock->ulAddress = 0;
            pl_sb_push(ptUnCachedAllocatorData->sbtFreeBlockIndices, ptNode->ulBlockIndex);
        }
        else if(ptNode->ulUsedSize != 0)
            ptBlock->dLastTimeUsed = ptIO->dTime;
    }

    pl_sb_reset(ptGarbage->sbtTextures);
    pl_sb_reset(ptGarbage->sbtTextureViews);
    pl_sb_reset(ptGarbage->sbtShaders);
    pl_sb_reset(ptGarbage->sbtComputeShaders);
    pl_sb_reset(ptGarbage->sbtRenderPasses);
    pl_sb_reset(ptGarbage->sbtRenderPassLayouts);
    pl_sb_reset(ptGarbage->sbtMemory);
    pl_sb_reset(ptGarbage->sbtBuffers);
    pl_sb_reset(ptGarbage->sbtBindGroups);
    pl_end_profile_sample();
}

//-----------------------------------------------------------------------------
// [SECTION] device memory allocators
//-----------------------------------------------------------------------------

static plDeviceMemoryAllocation
pl_allocate_dedicated(struct plDeviceMemoryAllocatorO* ptInst, uint32_t uTypeFilter, uint64_t ulSize, uint64_t ulAlignment, const char* pcName)
{
    plDeviceAllocatorData* ptData = (plDeviceAllocatorData*)ptInst;
    plDeviceMetal* ptMetalDevice =ptData->ptDevice->_pInternalData;

    plDeviceAllocationBlock tBlock = {
        .ulAddress = 0,
        .ulSize    = ulSize
    };

    MTLHeapDescriptor* ptHeapDescriptor = [MTLHeapDescriptor new];
    ptHeapDescriptor.storageMode = uTypeFilter;
    ptHeapDescriptor.size        = tBlock.ulSize;
    ptHeapDescriptor.type        = MTLHeapTypePlacement;
    ptHeapDescriptor.hazardTrackingMode = MTLHazardTrackingModeUntracked;

    tBlock.ulAddress = (uint64_t)[ptMetalDevice->tDevice newHeapWithDescriptor:ptHeapDescriptor];
    ptData->ptDevice->ptGraphics->szLocalMemoryInUse += tBlock.ulSize;
    
    plDeviceMemoryAllocation tAllocation = {
        .pHostMapped = NULL,
        .uHandle     = tBlock.ulAddress,
        .ulOffset    = 0,
        .ulSize      = ulSize,
        .ptInst      = ptInst
    };

    uint32_t uBlockIndex = pl_sb_size(ptData->sbtBlocks);
    if(pl_sb_size(ptData->sbtFreeBlockIndices) > 0)
        uBlockIndex = pl_sb_pop(ptData->sbtFreeBlockIndices);
    else
        pl_sb_add(ptData->sbtBlocks);

    plDeviceAllocationRange tRange = {
        .ulOffset     = 0,
        .ulTotalSize  = ulSize,
        .ulUsedSize   = ulSize,
        .ulBlockIndex = uBlockIndex
    };
    pl_sprintf(tRange.acName, "%s", pcName);

    pl_sb_push(ptData->sbtNodes, tRange);
    ptData->sbtBlocks[uBlockIndex] = tBlock;
    [ptHeapDescriptor release];
    return tAllocation;
}

static void
pl_free_dedicated(struct plDeviceMemoryAllocatorO* ptInst, plDeviceMemoryAllocation* ptAllocation)
{
    plDeviceAllocatorData* ptData = (plDeviceAllocatorData*)ptInst;

    uint32_t uBlockIndex = 0;
    uint32_t uNodeIndex = 0;
    for(uint32_t i = 0; i < pl_sb_size(ptData->sbtNodes); i++)
    {
        plDeviceAllocationRange* ptNode = &ptData->sbtNodes[i];
        plDeviceAllocationBlock* ptBlock = &ptData->sbtBlocks[ptNode->ulBlockIndex];

        if(ptBlock->ulAddress == ptAllocation->uHandle)
        {
            uNodeIndex = i;
            uBlockIndex = (uint32_t)ptNode->ulBlockIndex;
            ptData->ptDevice->ptGraphics->szLocalMemoryInUse -= ptBlock->ulSize;
            ptBlock->ulSize = 0;
            break;
        }
    }
    pl_sb_del_swap(ptData->sbtNodes, uNodeIndex);
    pl_sb_push(ptData->sbtFreeBlockIndices, uBlockIndex);

    id<MTLHeap> tHeap = (id<MTLHeap>)ptAllocation->uHandle;
    [tHeap setPurgeableState:MTLPurgeableStateEmpty];
    [tHeap release];
    tHeap = nil;

    ptAllocation->pHostMapped  = NULL;
    ptAllocation->uHandle      = 0;
    ptAllocation->ulOffset     = 0;
    ptAllocation->ulSize       = 0;
}

static plDeviceMemoryAllocation
pl_allocate_buddy(struct plDeviceMemoryAllocatorO* ptInst, uint32_t uTypeFilter, uint64_t ulSize, uint64_t ulAlignment, const char* pcName)
{
    plDeviceAllocatorData* ptData = (plDeviceAllocatorData*)ptInst;
    plDeviceMetal* ptMetalDevice =ptData->ptDevice->_pInternalData;

    plDeviceMemoryAllocation tAllocation = pl__allocate_buddy(ptInst, uTypeFilter, ulSize, ulAlignment, pcName, 0);
    
    if(tAllocation.uHandle == 0)
    {
        plDeviceAllocationBlock* ptBlock = &pl_sb_top(ptData->sbtBlocks);
        MTLHeapDescriptor* ptHeapDescriptor = [MTLHeapDescriptor new];
        ptHeapDescriptor.storageMode = uTypeFilter;
        ptHeapDescriptor.size        = PL_DEVICE_BUDDY_BLOCK_SIZE;
        ptHeapDescriptor.type        = MTLHeapTypePlacement;
        ptHeapDescriptor.hazardTrackingMode = MTLHazardTrackingModeUntracked;
        ptBlock->ulAddress = (uint64_t)[ptMetalDevice->tDevice newHeapWithDescriptor:ptHeapDescriptor];
        tAllocation.uHandle = (uint64_t)ptBlock->ulAddress;
        ptData->ptDevice->ptGraphics->szLocalMemoryInUse += ptBlock->ulSize;
    }

    return tAllocation;
}

static plDeviceMemoryAllocation
pl_allocate_staging_uncached(struct plDeviceMemoryAllocatorO* ptInst, uint32_t uTypeFilter, uint64_t ulSize, uint64_t ulAlignment, const char* pcName)
{
    plDeviceAllocatorData* ptData = (plDeviceAllocatorData*)ptInst;
    plDeviceMetal* ptMetalDevice =ptData->ptDevice->_pInternalData;

    plDeviceMemoryAllocation tAllocation = {
        .pHostMapped = NULL,
        .uHandle     = 0,
        .ulOffset    = 0,
        .ulSize      = ulSize,
        .ptInst      = ptInst
    };

    // check for existing block
    for(uint32_t i = 0; i < pl_sb_size(ptData->sbtNodes); i++)
    {
        plDeviceAllocationRange* ptNode = &ptData->sbtNodes[i];
        plDeviceAllocationBlock* ptBlock = &ptData->sbtBlocks[ptNode->ulBlockIndex];
        if(ptNode->ulUsedSize == 0 && ptNode->ulTotalSize >= ulSize && ptBlock->ulAddress != 0)
        {
            ptNode->ulUsedSize = ulSize;
            pl_sprintf(ptNode->acName, "%s", pcName);
            tAllocation.pHostMapped = ptBlock->pHostMapped;
            tAllocation.uHandle = ptBlock->ulAddress;
            tAllocation.ulOffset = 0;
            tAllocation.ulSize = ptBlock->ulSize;
            return tAllocation;
        }
    }

    uint32_t uIndex = UINT32_MAX;
    if(pl_sb_size(ptData->sbtFreeBlockIndices) > 0)
    {
        uIndex = pl_sb_pop(ptData->sbtFreeBlockIndices);
    }
    else
    {
        uIndex = pl_sb_size(ptData->sbtBlocks);
        pl_sb_add(ptData->sbtNodes);
        pl_sb_add(ptData->sbtBlocks);
    }

    plDeviceAllocationBlock tBlock = {
        .ulAddress = 0,
        .ulSize    = pl_maxu((uint32_t)ulSize, PL_DEVICE_ALLOCATION_BLOCK_SIZE)
    };

    plDeviceAllocationRange tRange = {
        .ulOffset     = 0,
        .ulUsedSize   = ulSize,
        .ulTotalSize  = tBlock.ulSize,
        .ulBlockIndex = uIndex
    };
    pl_sprintf(tRange.acName, "%s", pcName);

    MTLHeapDescriptor* ptHeapDescriptor = [MTLHeapDescriptor new];
    ptHeapDescriptor.storageMode = MTLStorageModeShared;
    ptHeapDescriptor.size = tBlock.ulSize;
    ptHeapDescriptor.type = MTLHeapTypePlacement;
    ptData->ptDevice->ptGraphics->szHostMemoryInUse += tBlock.ulSize;

    tBlock.ulAddress = (uint64_t)[ptMetalDevice->tDevice newHeapWithDescriptor:ptHeapDescriptor];
    tAllocation.uHandle = tBlock.ulAddress;

    ptData->sbtNodes[uIndex] = tRange;
    ptData->sbtBlocks[uIndex] = tBlock;
    return tAllocation;
}

static void
pl_free_staging_uncached(struct plDeviceMemoryAllocatorO* ptInst, plDeviceMemoryAllocation* ptAllocation)
{
    plDeviceAllocatorData* ptData = (plDeviceAllocatorData*)ptInst;

    for(uint32_t i = 0; i < pl_sb_size(ptData->sbtBlocks); i++)
    {
        plDeviceAllocationRange* ptRange = &ptData->sbtNodes[i];
        plDeviceAllocationBlock* ptBlock = &ptData->sbtBlocks[ptRange->ulBlockIndex];

        // find block
        if(ptBlock->ulAddress == ptAllocation->uHandle)
        {
            ptRange->ulUsedSize = 0;
            memset(ptRange->acName, 0, PL_MAX_NAME_LENGTH);
            strncpy(ptRange->acName, "not used", PL_MAX_NAME_LENGTH);
            break;
        }
    }
}

static void
pl_destroy_buffer(plDevice* ptDevice, plBufferHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;

    ptGraphics->sbtBufferGenerations[tHandle.uIndex]++;
    pl_sb_push(ptGraphics->sbtBufferFreeIndices, tHandle.uIndex);

    [ptMetalGraphics->sbtBuffersHot[tHandle.uIndex].tBuffer release];
    ptMetalGraphics->sbtBuffersHot[tHandle.uIndex].tBuffer = nil;

    plBuffer* ptBuffer = &ptGraphics->sbtBuffersCold[tHandle.uIndex];

    if(ptBuffer->tMemoryAllocation.ptInst == ptGraphics->tDevice.tLocalBuddyAllocator.ptInst)
        ptGraphics->tDevice.tLocalBuddyAllocator.free(ptGraphics->tDevice.tLocalBuddyAllocator.ptInst, &ptBuffer->tMemoryAllocation);
    else if(ptBuffer->tMemoryAllocation.ptInst == ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst)
        ptGraphics->tDevice.tLocalDedicatedAllocator.free(ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst, &ptBuffer->tMemoryAllocation);
    else if(ptBuffer->tMemoryAllocation.ptInst == ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst)
        ptGraphics->tDevice.tStagingUnCachedAllocator.free(ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst, &ptBuffer->tMemoryAllocation);
    else if(ptBuffer->tMemoryAllocation.ptInst == ptGraphics->tDevice.tStagingCachedAllocator.ptInst)
        ptGraphics->tDevice.tStagingCachedAllocator.free(ptGraphics->tDevice.tStagingCachedAllocator.ptInst, &ptBuffer->tMemoryAllocation);
}

static void
pl_destroy_texture(plDevice* ptDevice, plTextureHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;

    pl_sb_push(ptGraphics->sbtTextureFreeIndices, tHandle.uIndex);
    ptGraphics->sbtTextureGenerations[tHandle.uIndex]++;

    plMetalTexture* ptMetalTexture = &ptMetalGraphics->sbtTexturesHot[tHandle.uIndex];
    [ptMetalTexture->tTexture release];
    ptMetalTexture->tTexture = nil;

    plTexture* ptTexture = &ptGraphics->sbtTexturesCold[tHandle.uIndex];

    if(ptTexture->tMemoryAllocation.ptInst == ptGraphics->tDevice.tLocalBuddyAllocator.ptInst)
        ptGraphics->tDevice.tLocalBuddyAllocator.free(ptGraphics->tDevice.tLocalBuddyAllocator.ptInst, &ptTexture->tMemoryAllocation);
    else if(ptTexture->tMemoryAllocation.ptInst == ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst)
        ptGraphics->tDevice.tLocalDedicatedAllocator.free(ptGraphics->tDevice.tLocalDedicatedAllocator.ptInst, &ptTexture->tMemoryAllocation);
    else if(ptTexture->tMemoryAllocation.ptInst == ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst)
        ptGraphics->tDevice.tStagingUnCachedAllocator.free(ptGraphics->tDevice.tStagingUnCachedAllocator.ptInst, &ptTexture->tMemoryAllocation);
    else if(ptTexture->tMemoryAllocation.ptInst == ptGraphics->tDevice.tStagingCachedAllocator.ptInst)
        ptGraphics->tDevice.tStagingCachedAllocator.free(ptGraphics->tDevice.tStagingCachedAllocator.ptInst, &ptTexture->tMemoryAllocation);
}

static void
pl_destroy_texture_view(plDevice* ptDevice, plTextureViewHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;

    ptGraphics->sbtTextureViewGenerations[tHandle.uIndex]++;
    pl_sb_push(ptGraphics->sbtTextureViewFreeIndices, tHandle.uIndex);

    plMetalSampler* ptMetalSampler = &ptMetalGraphics->sbtSamplersHot[tHandle.uIndex];
    [ptMetalSampler->tSampler release];
    ptMetalSampler->tSampler = nil;
}

static void
pl_destroy_bind_group(plDevice* ptDevice, plBindGroupHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;
    
    ptGraphics->sbtBindGroupGenerations[tHandle.uIndex]++;
    pl_sb_push(ptGraphics->sbtBindGroupFreeIndices, tHandle.uIndex);

    plMetalBindGroup* ptMetalResource = &ptMetalGraphics->sbtBindGroupsHot[tHandle.uIndex];
    [ptMetalResource->tShaderArgumentBuffer release];
    ptMetalResource->tShaderArgumentBuffer = nil;
}

static void
pl_destroy_render_pass(plDevice* ptDevice, plRenderPassHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;
    
    ptGraphics->sbtRenderPassGenerations[tHandle.uIndex]++;
    pl_sb_push(ptGraphics->sbtRenderPassFreeIndices, tHandle.uIndex);

    plMetalRenderPass* ptMetalResource = &ptMetalGraphics->sbtRenderPassesHot[tHandle.uIndex];
    [ptMetalResource->ptRenderPassDescriptor release];
    ptMetalResource->ptRenderPassDescriptor = nil;
}

static void
pl_destroy_render_pass_layout(plDevice* ptDevice, plRenderPassLayoutHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;
    
    ptGraphics->sbtRenderPassLayoutGenerations[tHandle.uIndex]++;
    pl_sb_push(ptGraphics->sbtRenderPassLayoutFreeIndices, tHandle.uIndex);
}

static void
pl_destroy_shader(plDevice* ptDevice, plShaderHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;
    ptGraphics->sbtShaderGenerations[tHandle.uIndex]++;

    plShader* ptResource = &ptGraphics->sbtShadersCold[tHandle.uIndex];

    for(uint32_t j = 0; j < pl_sb_size(ptResource->_sbtVariantHandles); j++)
    {
        const uint32_t iVariantIndex = ptResource->_sbtVariantHandles[j].uIndex;
        plMetalShader* ptVariantMetalResource = &ptMetalGraphics->sbtShadersHot[iVariantIndex];
        [ptVariantMetalResource->tDepthStencilState release];
        [ptVariantMetalResource->tRenderPipelineState release];
        ptVariantMetalResource->tDepthStencilState = nil;
        ptVariantMetalResource->tRenderPipelineState = nil;
        pl_sb_push(ptGraphics->sbtShaderFreeIndices, iVariantIndex);
    }
    pl_sb_free(ptResource->_sbtVariantHandles);
    pl_hm_free(&ptResource->tVariantHashmap);
}

static void
pl_destroy_compute_shader(plDevice* ptDevice, plComputeShaderHandle tHandle)
{
    plGraphics* ptGraphics = ptDevice->ptGraphics;
    plGraphicsMetal* ptMetalGraphics = ptGraphics->_pInternalData;
    plDeviceMetal* ptMetalDevice = ptDevice->_pInternalData;
    ptGraphics->sbtComputeShaderGenerations[tHandle.uIndex]++;

    plComputeShader* ptResource = &ptGraphics->sbtComputeShadersCold[tHandle.uIndex];

    for(uint32_t j = 0; j < pl_sb_size(ptResource->_sbtVariantHandles); j++)
    {
        const uint32_t iVariantIndex = ptResource->_sbtVariantHandles[j].uIndex;
        plMetalComputeShader* ptVariantMetalResource = &ptMetalGraphics->sbtComputeShadersHot[iVariantIndex];
        [ptVariantMetalResource->tPipelineState release];
        ptVariantMetalResource->tPipelineState = nil;
        pl_sb_push(ptGraphics->sbtComputeShaderFreeIndices, iVariantIndex);
    }
    pl_sb_free(ptResource->_sbtVariantHandles);
    pl_hm_free(&ptResource->tVariantHashmap);
}

//-----------------------------------------------------------------------------
// [SECTION] extension loading
//-----------------------------------------------------------------------------

static const plGraphicsI*
pl_load_graphics_api(void)
{
    static const plGraphicsI tApi = {
        .initialize                       = pl_initialize_graphics,
        .resize                           = pl_resize,
        .setup_ui                         = pl_setup_ui,
        .begin_frame                      = pl_begin_frame,
        .end_frame                        = pl_end_gfx_frame,
        .begin_recording                  = pl_begin_recording,
        .end_recording                    = pl_end_recording,
        .start_transfers                  = pl_start_transfers,
        .end_transfers                    = pl_end_transfers,
        .begin_main_pass                  = pl_begin_main_pass,
        .end_main_pass                    = pl_end_main_pass,
        .begin_pass                       = pl_begin_pass,
        .end_pass                         = pl_end_pass,
        .dispatch                         = pl_dispatch,
        .draw_areas                       = pl_draw_areas,
        .draw_lists                       = pl_draw_lists,
        .cleanup                          = pl_cleanup,
        .create_font_atlas                = pl_create_metal_font_texture,
        .destroy_font_atlas               = pl_cleanup_metal_font_texture,
        .add_3d_triangle_filled           = pl__add_3d_triangle_filled,
        .add_3d_line                      = pl__add_3d_line,
        .add_3d_point                     = pl__add_3d_point,
        .add_3d_transform                 = pl__add_3d_transform,
        .add_3d_frustum                   = pl__add_3d_frustum,
        .add_3d_centered_box              = pl__add_3d_centered_box,
        .add_3d_bezier_quad               = pl__add_3d_bezier_quad,
        .add_3d_bezier_cubic              = pl__add_3d_bezier_cubic,
        .register_3d_drawlist             = pl__register_3d_drawlist,
        .submit_3d_drawlist               = pl__submit_3d_drawlist,
        .get_ui_texture_handle            = pl_get_ui_texture_handle,
    };
    return &tApi;
}

static const plDeviceI*
pl_load_device_api(void)
{
    static const plDeviceI tApi = {
        .create_buffer                          = pl_create_buffer,
        .create_shader                          = pl_create_shader,
        .create_compute_shader                  = pl_create_compute_shader,
        .create_render_pass_layout              = pl_create_render_pass_layout,
        .create_render_pass                     = pl_create_render_pass,
        .create_texture                         = pl_create_texture,
        .create_texture_view                    = pl_create_texture_view,
        .create_bind_group                      = pl_create_bind_group,
        .get_temporary_bind_group               = pl_get_temporary_bind_group,
        .update_bind_group                      = pl_update_bind_group,
        .update_texture                         = pl_update_texture,
        .transfer_image_to_buffer               = pl_transfer_image_to_buffer,
        .allocate_dynamic_data                  = pl_allocate_dynamic_data,
        .queue_buffer_for_deletion              = pl_queue_buffer_for_deletion,
        .queue_texture_for_deletion             = pl_queue_texture_for_deletion,
        .queue_texture_view_for_deletion        = pl_queue_texture_view_for_deletion,
        .queue_bind_group_for_deletion          = pl_queue_bind_group_for_deletion,
        .queue_shader_for_deletion              = pl_queue_shader_for_deletion,
        .queue_compute_shader_for_deletion      = pl_queue_compute_shader_for_deletion,
        .queue_render_pass_for_deletion         = pl_queue_render_pass_for_deletion,
        .queue_render_pass_layout_for_deletion  = pl_queue_render_pass_layout_for_deletion,
        .destroy_texture_view                   = pl_queue_texture_view_for_deletion,
        .destroy_bind_group                     = pl_destroy_bind_group,
        .destroy_buffer                         = pl_destroy_buffer,
        .destroy_texture                        = pl_destroy_texture,
        .destroy_shader                         = pl_destroy_shader,
        .destroy_compute_shader                 = pl_destroy_compute_shader,
        .destroy_render_pass                    = pl_destroy_render_pass,
        .destroy_render_pass_layout             = pl_destroy_render_pass_layout,
        .update_render_pass_attachments         = pl_update_render_pass_attachments,
        .get_buffer                             = pl__get_buffer,
        .get_texture                            = pl__get_texture,
        .get_texture_view                       = pl__get_texture_view,
        .get_bind_group                         = pl__get_bind_group,
        .get_shader                             = pl__get_shader,
        .get_compute_shader_variant             = pl_get_compute_shader_variant,
        .get_shader_variant                     = pl_get_shader_variant,
        .copy_buffer_to_texture                 = pl_copy_buffer_to_texture
    };
    return &tApi;
}

PL_EXPORT void
pl_load_graphics_ext(plApiRegistryApiI* ptApiRegistry, bool bReload)
{
    const plDataRegistryApiI* ptDataRegistry = ptApiRegistry->first(PL_API_DATA_REGISTRY);
    pl_set_memory_context(ptDataRegistry->get_data(PL_CONTEXT_MEMORY));
    pl_set_context(ptDataRegistry->get_data("ui"));
    pl_set_profile_context(ptDataRegistry->get_data("profile"));
    gptFile = ptApiRegistry->first(PL_API_FILE);
    if(bReload)
    {
        ptApiRegistry->replace(ptApiRegistry->first(PL_API_GRAPHICS), pl_load_graphics_api());
        ptApiRegistry->replace(ptApiRegistry->first(PL_API_DEVICE), pl_load_device_api());
        ptApiRegistry->replace(ptApiRegistry->first(PL_API_DRAW_STREAM), pl_load_drawstream_api());
    }
    else
    {
        ptApiRegistry->add(PL_API_GRAPHICS, pl_load_graphics_api());
        ptApiRegistry->add(PL_API_DEVICE, pl_load_device_api());
        ptApiRegistry->add(PL_API_DRAW_STREAM, pl_load_drawstream_api());
    }
}

PL_EXPORT void
pl_unload_graphics_ext(plApiRegistryApiI* ptApiRegistry)
{

}

//-----------------------------------------------------------------------------
// [SECTION] unity build
//-----------------------------------------------------------------------------

#include "pl_ui_metal.m"