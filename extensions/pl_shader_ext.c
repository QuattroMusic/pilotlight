/*
   pl_shader_ext.c
*/

/*
Index of this file:
// [SECTION] includes
// [SECTION] global data & APIs
// [SECTION] implementation
// [SECTION] script loading
*/

//-----------------------------------------------------------------------------
// [SECTION] includes
//-----------------------------------------------------------------------------

#include "pilotlight.h"
#include "pl_os.h"
#include "pl_ds.h"

// libs
#include "pl_string.h"
#include "pl_memory.h"

// extensions
#include "pl_shader_ext.h"
#include "pl_graphics_ext.h"

// external
#ifndef PL_OFFLINE_SHADERS_ONLY
#include "shaderc/shaderc.h"

#ifdef PL_METAL_BACKEND
#include "spirv_cross/spirv_cross_c.h"
#endif

#endif

//-----------------------------------------------------------------------------
// [SECTION] global data & APIs
//-----------------------------------------------------------------------------

#ifndef PL_OFFLINE_SHADERS_ONLY
#ifdef PL_METAL_BACKEND
static spvc_context tSpirvCtx;
#endif
#endif

// data
static plTempAllocator tTempAllocator = {0};
static plTempAllocator tTempAllocator2 = {0};
static uint8_t**       sbptShaderBytecodeCache = NULL;
static plShaderOptions gtDefaultShaderOptions = {0};
static bool            gbInitialized = false;

// apis
static const plFileI* gptFile = NULL;

//-----------------------------------------------------------------------------
// [SECTION] implementation
//-----------------------------------------------------------------------------

#ifndef PL_OFFLINE_SHADERS_ONLY

static shaderc_include_result*
pl_shaderc_include_resolve_fn(void* pUserData, const char* pcRequestedSource, int iType, const char* pcRequestingSource, size_t szIncludeDepth)
{
    plShaderOptions* ptOptions = pUserData;
    const char** apcIncludeDirectories = ptOptions ? ptOptions->apcIncludeDirectories : gtDefaultShaderOptions.apcIncludeDirectories;
    const uint32_t uIncludeDirectoriesCount = ptOptions ? ptOptions->uIncludeDirectoriesCount : gtDefaultShaderOptions.uIncludeDirectoriesCount;

    shaderc_include_result* ptResult = pl_temp_allocator_alloc(&tTempAllocator, sizeof(shaderc_include_result));
    ptResult->user_data = ptOptions;
    ptResult->source_name = pcRequestedSource;
    ptResult->source_name_length = strlen(pcRequestedSource);

    bool bFound = false;
    for(uint32_t i = 0; i < uIncludeDirectoriesCount; i++)
    {
        char* pcFullSourcePath = pl_temp_allocator_sprintf(&tTempAllocator, "%s%s", apcIncludeDirectories[i], pcRequestedSource);

        if(gptFile->exists(pcFullSourcePath))
        {
            size_t szShaderSize = 0;
            gptFile->binary_read(pcFullSourcePath, &szShaderSize, NULL);
            uint8_t* puVertexShaderCode = pl_temp_allocator_alloc(&tTempAllocator, szShaderSize);
            gptFile->binary_read(pcFullSourcePath, &szShaderSize, puVertexShaderCode);
            

            ptResult->content = (const char*)puVertexShaderCode;
            ptResult->content_length = szShaderSize;
            bFound = true;
            break;
        }
    }

    return bFound ? ptResult : NULL;

}

static void
pl_shaderc_include_result_release_fn(void* pUserData, shaderc_include_result* ptIncludeResult)
{
    pl_temp_allocator_reset(&tTempAllocator);
}

static void
pl_spvc_error_callback(void* pUserData, const char* pcError)
{
    printf("SPIR-V Cross Error: %s\n", pcError);
}

#endif

static void
pl_initialize_shader_ext(const plShaderOptions* ptShaderOptions)
{

    if(gbInitialized)
        return;
    gbInitialized = true;

    gtDefaultShaderOptions.apcIncludeDirectories[0] = "./";
    gtDefaultShaderOptions.uIncludeDirectoriesCount = 1;

    if(ptShaderOptions)
    {
        for(uint32_t i = 0; i < ptShaderOptions->uIncludeDirectoriesCount; i++)
        {
            gtDefaultShaderOptions.apcIncludeDirectories[i + 1] = ptShaderOptions->apcIncludeDirectories[i];
        }
        gtDefaultShaderOptions.uIncludeDirectoriesCount = ptShaderOptions->uIncludeDirectoriesCount + 1;
    }
    
    #ifndef PL_OFFLINE_SHADERS_ONLY
    #ifdef PL_METAL_BACKEND
    spvc_context_create(&tSpirvCtx);
    spvc_context_set_error_callback(tSpirvCtx, pl_spvc_error_callback, NULL);
    #endif
    #endif
}

static void
pl_write_to_disk(const char* pcShader, const plShaderModule* ptModule)
{
    gptFile->binary_write(pcShader, (uint32_t)ptModule->szCodeSize, ptModule->puCode);
}

static plShaderModule
pl_read_from_disk(const char* pcShader, const char* pcEntryFunc)
{
    plShaderModule tModule = {0};
    if(pcShader && gptFile->exists(pcShader))
    {
        gptFile->binary_read(pcShader, &tModule.szCodeSize, NULL);
        tModule.puCode = PL_ALLOC(tModule.szCodeSize);
        memset(tModule.puCode, 0, tModule.szCodeSize);
        gptFile->binary_read(pcShader, &tModule.szCodeSize, tModule.puCode);
        pl_sb_push(sbptShaderBytecodeCache, tModule.puCode);
        tModule.pcEntryFunc = pcEntryFunc;
    }
    return tModule;
}

static plShaderModule
pl_compile_glsl(const char* pcShader, const char* pcEntryFunc, plShaderOptions* ptOptions)
{

    plShaderModule tModule = {0};

    #ifndef PL_OFFLINE_SHADERS_ONLY
    shaderc_compiler_t tCompiler = shaderc_compiler_initialize();
    shaderc_compile_options_t tOptions = shaderc_compile_options_initialize();
    shaderc_compile_options_set_include_callbacks(tOptions, pl_shaderc_include_resolve_fn, pl_shaderc_include_result_release_fn, ptOptions);

    if(ptOptions == NULL)
        ptOptions = &gtDefaultShaderOptions;
        
    switch(ptOptions->tOptimizationLevel)
    {

        case PL_SHADER_OPTIMIZATION_SIZE:
            shaderc_compile_options_set_optimization_level(tOptions, shaderc_optimization_level_size);
            break;
        case PL_SHADER_OPTIMIZATION_PERFORMANCE:
            shaderc_compile_options_set_optimization_level(tOptions, shaderc_optimization_level_performance);
            break;
        
        case PL_SHADER_OPTIMIZATION_NONE:
        default:
            shaderc_compile_options_set_optimization_level(tOptions, shaderc_optimization_level_zero);
            break;
    }

    if(ptOptions->tFlags & PL_SHADER_FLAGS_INCLUDE_DEBUG)
        shaderc_compile_options_set_generate_debug_info(tOptions);

    for(uint32_t i = 0; i < ptOptions->uMacroDefinitionCount; i++)
    {
        shaderc_compile_options_add_macro_definition(tOptions,
            ptOptions->ptMacroDefinitions[i].pcName,
            ptOptions->ptMacroDefinitions[i].szNameLength,
            ptOptions->ptMacroDefinitions[i].pcValue,
            ptOptions->ptMacroDefinitions[i].szValueLength);
    }

    // shaderc_compile_options_set_forced_version_profile(tOptions, 450, shaderc_profile_core);

    size_t szShaderSize = 0;
    gptFile->binary_read(pcShader, &szShaderSize, NULL);
    uint8_t* puShaderCode = PL_ALLOC(szShaderSize);
    memset(puShaderCode, 0, szShaderSize);
    gptFile->binary_read(pcShader, &szShaderSize, puShaderCode);
    pl_sb_push(sbptShaderBytecodeCache, puShaderCode);

    char acExtension[64] = {0};
    pl_str_get_file_extension(pcShader, acExtension);

    shaderc_shader_kind tShaderKind = 0;
    if(acExtension[0] == 'c')
        tShaderKind = shaderc_glsl_compute_shader;
    else if(acExtension[0] == 'f')
        tShaderKind = shaderc_glsl_fragment_shader;
    else if(acExtension[0] == 'v')
        tShaderKind = shaderc_glsl_vertex_shader;
    else
    {
        PL_ASSERT("unknown glsl shader type");
    }

    shaderc_compilation_result_t tresult = shaderc_compile_into_spv(
        tCompiler,
        (const char*)puShaderCode,
        szShaderSize,
        tShaderKind,
        pcShader,
        pcEntryFunc,
        tOptions);

    size_t uNumErrors = shaderc_result_get_num_errors(tresult);
    if(uNumErrors)
    {
        printf("%s\n", shaderc_result_get_error_message(tresult));
        tModule.szCodeSize = 0;
        tModule.puCode = NULL;
        tModule.pcEntryFunc = NULL;
        PL_ASSERT(false);
    }
    else
    {
        tModule.szCodeSize = shaderc_result_get_length(tresult);
        tModule.puCode = (uint8_t*)shaderc_result_get_bytes(tresult);
        tModule.pcEntryFunc = pcEntryFunc;
    }

    #ifdef PL_METAL_BACKEND
    if(tShaderKind == shaderc_glsl_vertex_shader)
    {
        spvc_parsed_ir ir = NULL;
        spvc_context_parse_spirv(tSpirvCtx, (const SpvId*)tModule.puCode, tModule.szCodeSize / sizeof(SpvId) , &ir);

        spvc_compiler tMslCompiler;
        spvc_context_create_compiler(tSpirvCtx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &tMslCompiler);

        spvc_compiler_options tOptions;
        spvc_compiler_create_compiler_options(tMslCompiler, &tOptions);

        spvc_compiler_options_set_uint(tOptions, SPVC_COMPILER_OPTION_MSL_VERSION, 30000);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, true);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, true);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, true);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_FORCE_ACTIVE_ARGUMENT_BUFFER_RESOURCES, true);

        spvc_compiler_rename_entry_point(tMslCompiler, tModule.pcEntryFunc, "vertex_main", SpvExecutionModelVertex);

        const spvc_reflected_resource *list = NULL;
        spvc_resources resources = NULL;
        size_t count = 0;
        spvc_compiler_create_shader_resources(tMslCompiler, &resources);
        spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, &list, &count);

        for (size_t i = 0; i < count; i++)
        {
            if(pl_str_contains(list[i].name, "PL_DYNAMIC_DATA"))
            {
                spvc_compiler_msl_add_inline_uniform_block(tMslCompiler, spvc_compiler_get_decoration(tMslCompiler, list[i].id, SpvDecorationDescriptorSet), 0);
                break;
            }
        }

        spvc_compiler_install_compiler_options(tMslCompiler, tOptions);
        spvc_compiler_compile(tMslCompiler, (const char**)&tModule.puCode);
    }
    else if(tShaderKind == shaderc_glsl_fragment_shader)
    {
        spvc_parsed_ir ir = NULL;
        spvc_context_parse_spirv(tSpirvCtx, (const SpvId*)tModule.puCode, tModule.szCodeSize / sizeof(SpvId) , &ir);

        spvc_compiler tMslCompiler;
        spvc_context_create_compiler(tSpirvCtx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &tMslCompiler);

        spvc_compiler_options tOptions;
        spvc_compiler_create_compiler_options(tMslCompiler, &tOptions);

        spvc_compiler_options_set_uint(tOptions, SPVC_COMPILER_OPTION_MSL_VERSION, 30000);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, true);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, true);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_FORCE_ACTIVE_ARGUMENT_BUFFER_RESOURCES, true);

        spvc_compiler_rename_entry_point(tMslCompiler, tModule.pcEntryFunc, "fragment_main", SpvExecutionModelFragment);

        const spvc_reflected_resource *list = NULL;
        spvc_resources resources = NULL;
        size_t count = 0;
        spvc_compiler_create_shader_resources(tMslCompiler, &resources);
        spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, &list, &count);

        for (size_t i = 0; i < count; i++)
        {
            if(pl_str_contains(list[i].name, "PL_DYNAMIC_DATA"))
            {
                spvc_compiler_msl_add_inline_uniform_block(tMslCompiler, spvc_compiler_get_decoration(tMslCompiler, list[i].id, SpvDecorationDescriptorSet), 0);
                break;
            }
        }

        spvc_compiler_install_compiler_options(tMslCompiler, tOptions);
        spvc_compiler_compile(tMslCompiler, (const char**)&tModule.puCode);
    }
    else if(tShaderKind == shaderc_glsl_compute_shader)
    {
        spvc_parsed_ir ir = NULL;
        spvc_context_parse_spirv(tSpirvCtx, (const SpvId*)tModule.puCode, tModule.szCodeSize / sizeof(SpvId) , &ir);

        spvc_compiler tMslCompiler;
        spvc_context_create_compiler(tSpirvCtx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &tMslCompiler);

        spvc_compiler_options tOptions;
        spvc_compiler_create_compiler_options(tMslCompiler, &tOptions);

        spvc_compiler_options_set_uint(tOptions, SPVC_COMPILER_OPTION_MSL_VERSION, 30000);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, true);
        spvc_compiler_options_set_bool(tOptions, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, true);

        spvc_compiler_rename_entry_point(tMslCompiler, tModule.pcEntryFunc, "kernel_main", SpvExecutionModelGLCompute);

        const spvc_reflected_resource *list = NULL;
        spvc_resources resources = NULL;
        size_t count = 0;
        spvc_compiler_create_shader_resources(tMslCompiler, &resources);
        spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, &list, &count);

        for (size_t i = 0; i < count; i++)
        {
            if(pl_str_contains(list[i].name, "PL_DYNAMIC_DATA"))
            {
                spvc_compiler_msl_add_inline_uniform_block(tMslCompiler, spvc_compiler_get_decoration(tMslCompiler, list[i].id, SpvDecorationDescriptorSet), 0);
                break;
            }
        }

        spvc_compiler_install_compiler_options(tMslCompiler, tOptions);
        spvc_compiler_compile(tMslCompiler, (const char**)&tModule.puCode);
    }
    #endif
    #endif
    return tModule;
}

static plShaderModule
pl_load_glsl(const char* pcShader, const char* pcEntryFunc, const char* pcFile, plShaderOptions* ptOptions)
{
    if(ptOptions == NULL)
        ptOptions = &gtDefaultShaderOptions;

    const char* pcCacheFile = pcFile;
    if(pcCacheFile == NULL)
    {
        // char acTempBuffer[1024] = {0};
        const char* pcFileNameOnly = pl_str_get_file_name(pcShader, NULL);
        #ifdef PL_METAL_BACKEND
        pcCacheFile = pl_temp_allocator_sprintf(&tTempAllocator2, "%s.metal", pcFileNameOnly);
        #else
        pcCacheFile = pl_temp_allocator_sprintf(&tTempAllocator2, "%s.spv", pcFileNameOnly);
        #endif
    }

    plShaderModule tModule = {0};

    // unless overriden, try to load precompiled shader
    if(!(ptOptions->tFlags & PL_SHADER_FLAGS_ALWAYS_COMPILE))
        tModule = pl_read_from_disk(pcCacheFile, pcEntryFunc);

    // no precompiled shader available, compile it ourselves
    if(tModule.szCodeSize == 0)
    {
        tModule = pl_compile_glsl(pcShader, pcEntryFunc, ptOptions);
        if(!(ptOptions->tFlags & PL_SHADER_FLAGS_NEVER_CACHE) && tModule.szCodeSize > 0)
            pl_write_to_disk(pcCacheFile, &tModule);
    }
    pl_temp_allocator_reset(&tTempAllocator2);
    return tModule;
}

//-----------------------------------------------------------------------------
// [SECTION] script loading
//-----------------------------------------------------------------------------

static const plShaderI*
pl_load_shader_api(void)
{
    static const plShaderI tApi = {
        .initialize     = pl_initialize_shader_ext,
        .load_glsl      = pl_load_glsl,
        #ifdef PL_OFFLINE_SHADERS_ONLY
        .compile_glsl   = NULL,
        #else
        .compile_glsl   = pl_compile_glsl,
        #endif
        .write_to_disk  = pl_write_to_disk,
        .read_from_disk = pl_read_from_disk,
    };
    return &tApi;
}

PL_EXPORT void
pl_load_ext(plApiRegistryI* ptApiRegistry, bool bReload)
{
    const plDataRegistryI* ptDataRegistry = ptApiRegistry->first(PL_API_DATA_REGISTRY);
    pl_set_memory_context(ptDataRegistry->get_data(PL_CONTEXT_MEMORY));

    gptFile = ptApiRegistry->first(PL_API_FILE);

    if(bReload)
        ptApiRegistry->replace(ptApiRegistry->first(PL_API_SHADER), pl_load_shader_api());
    else
        ptApiRegistry->add(PL_API_SHADER, pl_load_shader_api());
}

PL_EXPORT void
pl_unload_ext(plApiRegistryI* ptApiRegistry)
{
    #ifndef PL_OFFLINE_SHADERS_ONLY
    #ifdef PL_METAL_BACKEND
    spvc_context_destroy(tSpirvCtx);
    #endif
    #endif
    for(uint32_t i = 0; i < pl_sb_size(sbptShaderBytecodeCache); i++)
    {
        PL_FREE(sbptShaderBytecodeCache[i]);
    }
    pl_sb_free(sbptShaderBytecodeCache);
}
