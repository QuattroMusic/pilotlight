/*
    pl_exe.c
      - common definitions needed by platform backends
      - should be included near the end of a platform backend file
*/

/*
Index of this file:
// [SECTION] includes
// [SECTION] defines
// [SECTION] internal structs
// [SECTION] enums
// [SECTION] internal api
// [SECTION] global data
// [SECTION] internal api implementation
// [SECTION] public api implementation
// [SECTION] unity build
*/

//-----------------------------------------------------------------------------
// [SECTION] includes
//-----------------------------------------------------------------------------

#include <float.h>   // FLT_MAX
#include <stdbool.h> // bool
#include <string.h>  // strcmp
#include "pl.h"
#include "pl_json.h"
#include "pl_ds.h"
#include "pl_memory.h"
#include "pl_os.h"
#include "pl_string.h"
#define PL_MATH_INCLUDE_FUNCTIONS
#include "pl_math.h"

//-----------------------------------------------------------------------------
// [SECTION] defines
//-----------------------------------------------------------------------------

#define PL_VEC2_LENGTH_SQR(vec) (((vec).x * (vec).x) + ((vec).y * (vec).y))

//-----------------------------------------------------------------------------
// [SECTION] internal structs
//-----------------------------------------------------------------------------

typedef struct _plExtension
{
    char pcLibName[128];
    char pcLibPath[128];
    char pcTransName[128];
    char pcLoadFunc[128];
    char pcUnloadFunc[128];

    void (*pl_load)   (const plApiRegistryI* ptApiRegistry, bool bReload);
    void (*pl_unload) (const plApiRegistryI* ptApiRegistry);
} plExtension;

typedef struct _plApiEntry
{
    const char*          pcName;
    const void*          pInterface;
    ptApiUpdateCallback* sbSubscribers;
    void**               sbUserData;
} plApiEntry;

typedef struct _plDataRegistryData
{
    plDataObject** sbtDataObjects;
    plDataObject** sbtDataObjectsDeletionQueue;
    plDataID*      sbtFreeDataIDs;
    plDataObject*  aptObjects[1024];
} plDataRegistryData;

typedef union _plDataObjectProperty
{
    const char* pcValue;
    void*       pValue;
} plDataObjectProperty;

typedef struct _plDataObject
{
    plDataID              tId;
    uint32_t              uReferenceCount;
    plDataObjectProperty  atDefaultProperties[2];
    uint32_t              uPropertyCount;
    plDataObjectProperty* ptProperties;
} plDataObject;

typedef struct _plInputEvent
{
    plInputEventType   tType;
    plInputEventSource tSource;

    union
    {
        struct // mouse pos event
        {
            float fPosX;
            float fPosY;
        };

        struct // mouse wheel event
        {
            float fWheelX;
            float fWheelY;
        };
        
        struct // mouse button event
        {
            int  iButton;
            bool bMouseDown;
        };

        struct // key event
        {
            plKey tKey;
            bool  bKeyDown;
        };

        struct // text event
        {
            uint32_t uChar;
        };
        
    };

} plInputEvent;

//-----------------------------------------------------------------------------
// [SECTION] enums
//-----------------------------------------------------------------------------

typedef enum
{
    PL_INPUT_EVENT_TYPE_NONE = 0,
    PL_INPUT_EVENT_TYPE_MOUSE_POS,
    PL_INPUT_EVENT_TYPE_MOUSE_WHEEL,
    PL_INPUT_EVENT_TYPE_MOUSE_BUTTON,
    PL_INPUT_EVENT_TYPE_KEY,
    PL_INPUT_EVENT_TYPE_TEXT,
    
    PL_INPUT_EVENT_TYPE_COUNT
} _plInputEventType;

typedef enum
{
    PL_INPUT_EVENT_SOURCE_NONE = 0,
    PL_INPUT_EVENT_SOURCE_MOUSE,
    PL_INPUT_EVENT_SOURCE_KEYBOARD,
    
    PL_INPUT_EVENT_SOURCE_COUNT
} _plInputEventSource;

//-----------------------------------------------------------------------------
// [SECTION] internal api
//-----------------------------------------------------------------------------

// data registry functions
void  pl__set_data(const char* pcName, void* pData);
void* pl__get_data(const char* pcName);

// new data registry functions

void                pl__garbage_collect(void);
plDataID            pl__create_object(void);
plDataID            pl__get_object_by_name(const char* pcName);
const plDataObject* pl__read      (plDataID);
void                pl__end_read  (const plDataObject* ptReader);
const char*         pl__get_string(const plDataObject*, uint32_t uProperty);
void*               pl__get_buffer(const plDataObject*, uint32_t uProperty);
plDataObject*       pl__write     (plDataID);
void                pl__set_string(plDataObject*, uint32_t, const char*);
void                pl__set_buffer(plDataObject*, uint32_t, void*);
void                pl__commit    (plDataObject*);

// api registry functions
static const void* pl__add_api        (const char* pcName, const void* pInterface);
static       void  pl__remove_api     (const void* pInterface);
static const void* pl__first_api      (const char* pcName);
static const void* pl__next_api       (const void* pPrev);
static       void  pl__replace_api    (const void* pOldInterface, const void* pNewInterface);
static       void  pl__subscribe_api  (const void* pOldInterface, ptApiUpdateCallback ptCallback, void* pUserData);

// extension registry functions
static bool pl__load_extension             (const char* pcName, const char* pcLoadFunc, const char* pcUnloadFunc, bool bReloadable);
static bool pl__unload_extension           (const char* pcName);
static void pl__unload_all_extensions      (void);
static void pl__handle_extension_reloads   (void);

// extension registry helper functions
static void pl__create_extension(const char* pcName, const char* pcLoadFunc, const char* pcUnloadFunc, plExtension* ptExtensionOut);

// IO helper functions
static void          pl__update_events(void);
static void          pl__update_mouse_inputs(void);
static void          pl__update_keyboard_inputs(void);
static int           pl__calc_typematic_repeat_amount(float fT0, float fT1, float fRepeatDelay, float fRepeatRate);
static plInputEvent* pl__get_last_event(plInputEventType tType, int iButtonOrKey);

static const plApiRegistryI*
pl__load_api_registry(void)
{
    static const plApiRegistryI tApiRegistry = {
        .add         = pl__add_api,
        .remove      = pl__remove_api,
        .first       = pl__first_api,
        .next        = pl__next_api,
        .replace     = pl__replace_api,
        .subscribe   = pl__subscribe_api
    };

    return &tApiRegistry;
}

//-----------------------------------------------------------------------------
// [SECTION] global data
//-----------------------------------------------------------------------------

// data registry
plHashMap*         gptHashmap = NULL;
plDataRegistryData gtDataRegistryData = {0};
plMutex*           gptDataMutex = NULL;

// api registry
plApiEntry* gsbApiEntries = NULL;

// extension registry
plExtension*      gsbtExtensions  = NULL;
plSharedLibrary** gsbptLibs        = NULL;
uint32_t*         gsbtHotLibs     = NULL;

// IO
plIO gtIO = {
    .fHeadlessUpdateRate      = 30.0f,
    .fMouseDoubleClickTime    = 0.3f,
    .fMouseDoubleClickMaxDist = 6.0f,
    .fMouseDragThreshold      = 6.0f,
    .fKeyRepeatDelay          = 0.275f,
    .fKeyRepeatRate           = 0.050f,
    .afMainFramebufferScale   = {1.0f, 1.0f},
    .tCurrentCursor           = PL_MOUSE_CURSOR_ARROW,
    .tNextCursor              = PL_MOUSE_CURSOR_ARROW,
    .afMainViewportSize       = {500.0f, 500.0f},
    .bViewportSizeChanged     = true,
    .bRunning                 = true,
};

// memory tracking
size_t             gszActiveAllocations = 0;
size_t             gszAllocationCount   = 0;
size_t             gszAllocationFrees   = 0;
size_t             gszMemoryUsage       = 0;
plAllocationEntry* gsbtAllocations      = NULL;
plHashMap*         gptMemoryHashMap     = NULL;

//-----------------------------------------------------------------------------
// [SECTION] internal api implementation
//-----------------------------------------------------------------------------

void
pl_set_data(const char* pcName, void* pData)
{
    plDataID tData = {
        .ulData = pl_hm_lookup_str(gptHashmap, pcName)
    };

    if(tData.ulData == UINT64_MAX)
    {
        tData = pl_create_object();
    }
    plDataObject* ptWriter = pl_write(tData);
    pl_set_string(ptWriter, 0, pcName);
    pl_set_buffer(ptWriter, 1, pData);
    pl_commit(ptWriter);
}

void*
pl_get_data(const char* pcName)
{
    plDataID tData = pl_get_object_by_name(pcName);
    if(tData.ulData == UINT64_MAX)
        return NULL;
    const plDataObject* ptReader = pl_read(tData);
    void* pData = pl_get_buffer(ptReader, 1);
    pl_end_read(ptReader);
    return pData;
}

void
pl_garbage_collect(void)
{
    pl_lock_mutex(gptDataMutex);
    uint32_t uQueueSize = pl_sb_size(gtDataRegistryData.sbtDataObjectsDeletionQueue);
    for(uint32_t i = 0; i < uQueueSize; i++)
    {
        if(gtDataRegistryData.sbtDataObjectsDeletionQueue[i]->uReferenceCount == 0)
        {
            pl_sb_push(gtDataRegistryData.sbtDataObjects, gtDataRegistryData.sbtDataObjectsDeletionQueue[i]);
            pl_sb_del_swap(gtDataRegistryData.sbtDataObjectsDeletionQueue, i);
            i--;
            uQueueSize--;
        }
    }
    pl_unlock_mutex(gptDataMutex);
}

plDataID
pl_create_object(void)
{
    plDataID tId = {.ulData = UINT64_MAX};

    pl_lock_mutex(gptDataMutex);
    if(pl_sb_size(gtDataRegistryData.sbtFreeDataIDs) > 0)
    {
        tId = pl_sb_pop(gtDataRegistryData.sbtFreeDataIDs);
    }
    else
    {
        PL_ASSERT(false);
    }

    plDataObject* ptObject = NULL;
    if(pl_sb_size(gtDataRegistryData.sbtDataObjects) > 0)
    {
        ptObject = pl_sb_pop(gtDataRegistryData.sbtDataObjects);
    }
    else
    {
        ptObject = PL_ALLOC(sizeof(plDataObject));
        memset(ptObject, 0, sizeof(plDataObject));
    }
    pl__unlock_mutex(gptDataMutex);
    ptObject->tId = tId;

    ptObject->uPropertyCount = 2;
    ptObject->ptProperties = ptObject->atDefaultProperties;
    ptObject->atDefaultProperties[0].pcValue = NULL;
    ptObject->atDefaultProperties[1].pValue = NULL;

    gtDataRegistryData.aptObjects[tId.uIndex] = ptObject;

    return tId;
}

plDataID
pl__get_object_by_name(const char* pcName)
{
    plDataID tID = {
        .ulData = pl_hm_lookup_str(&gtHashMap, pcName)
    };
    return tID;
}

const plDataObject*
pl__read(plDataID tId)
{
    gtDataRegistryData.aptObjects[tId.uIndex]->uReferenceCount++;
    return gtDataRegistryData.aptObjects[tId.uIndex];
}

void
pl__end_read(const plDataObject* ptReader)
{
    gtDataRegistryData.aptObjects[ptReader->tId.uIndex]->uReferenceCount--;
}

const char*
pl__get_string(const plDataObject* ptReader, uint32_t uProperty)
{
    return ptReader->ptProperties[uProperty].pcValue;
}

void*
pl__get_buffer(const plDataObject* ptReader, uint32_t uProperty)
{
    return ptReader->ptProperties[uProperty].pValue;
}

plDataObject*
pl__write(plDataID tId)
{
    const plDataObject* ptOriginalObject = gtDataRegistryData.aptObjects[tId.uIndex];

    pl__lock_mutex(gptDataMutex);
    plDataObject* ptObject = NULL;
    if(pl_sb_size(gtDataRegistryData.sbtDataObjects) > 0)
    {
        ptObject = pl_sb_pop(gtDataRegistryData.sbtDataObjects);
    }
    else
    {
        ptObject = PL_ALLOC(sizeof(plDataObject));
        memset(ptObject, 0, sizeof(plDataObject));
    }
    pl__unlock_mutex(gptDataMutex);

    memcpy(ptObject, ptOriginalObject, sizeof(plDataObject));
    ptObject->uReferenceCount = 0;
    ptObject->ptProperties = ptObject->atDefaultProperties;

    return ptObject;
}

void
pl_set_string(plDataObject* ptWriter, uint32_t uProperty, const char* pcValue)
{
    ptWriter->ptProperties[uProperty].pcValue = pcValue;
    if(uProperty == 0)
    {
        if(pl_hm_has_key_str(gptHashmap, pcValue))
        {
            pl_hm_remove_str(gptHashmap, pcValue);
        }
        else
        {
            pl_hm_insert_str(gptHashmap, pcValue, ptWriter->tId.ulData);
        }
    }
}

void
pl_set_buffer(plDataObject* ptWriter, uint32_t uProperty, void* pData)
{
    ptWriter->ptProperties[uProperty].pValue = pData;
}

void
pl_commit(plDataObject* ptWriter)
{
    plDataObject* ptOriginalObject = gtDataRegistryData.aptObjects[ptWriter->tId.uIndex];
    pl_lock_mutex(gptDataMutex);
    pl_sb_push(gtDataRegistryData.sbtDataObjectsDeletionQueue, ptOriginalObject);
    pl_unlock_mutex(gptDataMutex);
    gtDataRegistryData.aptObjects[ptWriter->tId.uIndex] = ptWriter;
}

const void*
pl_add_api(const char* pcName, const void* pInterface)
{
    plApiEntry tNewApiEntry = {
        .pcName = pcName,
        .pInterface = pInterface
    };
    pl_sb_push(gsbApiEntries, tNewApiEntry);
    return pInterface;
}

static void
pl__remove_api(const void* pInterface)
{
    for(uint32_t i = 0; i < pl_sb_size(gsbApiEntries); i++)
    {
        if(gsbApiEntries[i].pInterface == pInterface)
        {
            pl_sb_free(gsbApiEntries[i].sbSubscribers);
            pl_sb_del_swap(gsbApiEntries, i);
            break;
        }
    }
}

static void
pl__replace_api(const void* pOldInterface, const void* pNewInterface)
{
    for(uint32_t i = 0; i < pl_sb_size(gsbApiEntries); i++)
    {
        if(gsbApiEntries[i].pInterface == pOldInterface)
        {
            gsbApiEntries[i].pInterface = pNewInterface;

            for(uint32_t j = 0; j < pl_sb_size(gsbApiEntries[i].sbSubscribers); j++)
            {
                gsbApiEntries[i].sbSubscribers[j](pNewInterface, pOldInterface, gsbApiEntries[i].sbUserData[j]);
            }
            pl_sb_reset(gsbApiEntries[i].sbSubscribers);
            break;
        }
    }
}

static void
pl__subscribe_api(const void* pInterface, ptApiUpdateCallback ptCallback, void* pUserData)
{
    for(uint32_t i = 0; i < pl_sb_size(gsbApiEntries); i++)
    {
        if(gsbApiEntries[i].pInterface == pInterface)
        {
            pl_sb_push(gsbApiEntries[i].sbSubscribers, ptCallback);
            pl_sb_push(gsbApiEntries[i].sbUserData, pUserData);
            break;
        }
    }
}

static const void*
pl__first_api(const char* pcName)
{
    for(uint32_t i = 0; i < pl_sb_size(gsbApiEntries); i++)
    {
        if(strcmp(pcName, gsbApiEntries[i].pcName) == 0)
        {
            return gsbApiEntries[i].pInterface;
        }
    }

    return NULL;
}

static const void*
pl__next_api(const void* pPrev)
{
    const char* pcName = "";
    for(uint32_t i = 0; i < pl_sb_size(gsbApiEntries); i++)
    {
        if(strcmp(pcName, gsbApiEntries[i].pcName) == 0)
        {
            return gsbApiEntries[i].pInterface;
        }

        if(gsbApiEntries[i].pInterface == pPrev)
        {
            pcName = gsbApiEntries[i].pcName;
        }
    }

    return NULL;
}

static void
pl__create_extension(const char* pcName, const char* pcLoadFunc, const char* pcUnloadFunc, plExtension* ptExtensionOut)
{

    #ifdef _WIN32
        pl_sprintf(ptExtensionOut->pcLibPath, "./%s.dll", pcName);
    #elif defined(__APPLE__)
        pl_sprintf(ptExtensionOut->pcLibPath, "./%s.dylib", pcName);
    #else
        pl_sprintf(ptExtensionOut->pcLibPath, "./%s.so", pcName);
    #endif
    strcpy(ptExtensionOut->pcLibName, pcName);
    strcpy(ptExtensionOut->pcLoadFunc, pcLoadFunc);
    strcpy(ptExtensionOut->pcUnloadFunc, pcUnloadFunc);
    pl_sprintf(ptExtensionOut->pcTransName, "./%s_", pcName); 
}

static bool
pl__load_extension(const char* pcName, const char* pcLoadFunc, const char* pcUnloadFunc, bool bReloadable)
{

    // check if extension is already loaded
    const uint32_t uCurrentExtensionCount = pl_sb_size(gsbtExtensions);
    for(uint32_t i = 0; i < uCurrentExtensionCount; i++)
    {
        if(strcmp(pcName, gsbtExtensions[i].pcLibName) == 0)
        {
            return true;
        }
    }

    if(pcLoadFunc == NULL)
        pcLoadFunc = "pl_load_ext";

    if(pcUnloadFunc == NULL)
        pcUnloadFunc = "pl_unload_ext";

    const plApiRegistryI* ptApiRegistry = pl__load_api_registry();

    plExtension tExtension = {0};
    pl__create_extension(pcName, pcLoadFunc, pcUnloadFunc, &tExtension);

    plSharedLibrary* ptLibrary = NULL;

    const plLibraryI* ptLibraryApi = ptApiRegistry->first(PL_API_LIBRARY);

    if(ptLibraryApi->load(tExtension.pcLibPath, tExtension.pcTransName, "./lock.tmp", &ptLibrary))
    {
        #ifdef _WIN32
            tExtension.pl_load   = (void (__cdecl *)(const plApiRegistryI*, bool))  ptLibraryApi->load_function(ptLibrary, tExtension.pcLoadFunc);
            tExtension.pl_unload = (void (__cdecl *)(const plApiRegistryI*))        ptLibraryApi->load_function(ptLibrary, tExtension.pcUnloadFunc);
        #else // linux & apple
            tExtension.pl_load   = (void (__attribute__(()) *)(const plApiRegistryI*, bool)) ptLibraryApi->load_function(ptLibrary, tExtension.pcLoadFunc);
            tExtension.pl_unload = (void (__attribute__(()) *)(const plApiRegistryI*))       ptLibraryApi->load_function(ptLibrary, tExtension.pcUnloadFunc);
        #endif

        PL_ASSERT(tExtension.pl_load);
        PL_ASSERT(tExtension.pl_unload);
        pl_sb_push(gsbptLibs, ptLibrary);
        if(bReloadable)
            pl_sb_push(gsbtHotLibs, pl_sb_size(gsbptLibs) - 1);
        tExtension.pl_load(ptApiRegistry, false);
        pl_sb_push(gsbtExtensions, tExtension);
    }
    else
    {
        // printf("Extension: %s not loaded\n", tExtension.pcLibPath);
        return false;
    }
    return true;
}

static bool
pl__unload_extension(const char* pcName)
{
    const plApiRegistryI* ptApiRegistry = pl__load_api_registry();

    for(uint32_t i = 0; i < pl_sb_size(gsbtExtensions); i++)
    {
        if(strcmp(pcName, gsbtExtensions[i].pcLibName) == 0)
        {
            gsbtExtensions[i].pl_unload(ptApiRegistry);
            PL_FREE(gsbptLibs[i]);
            gsbptLibs[i] = NULL;
            pl_sb_del_swap(gsbtExtensions, i);
            pl_sb_del_swap(gsbptLibs, i);
            pl_sb_del_swap(gsbtHotLibs, i);
            return true;
        }
    }

    return false;
}

static void
pl__unload_all_extensions(void)
{
    const plApiRegistryI* ptApiRegistry = pl__load_api_registry();

    for(uint32_t i = 0; i < pl_sb_size(gsbtExtensions); i++)
    {
        if(gsbtExtensions[i].pl_unload)
            gsbtExtensions[i].pl_unload(ptApiRegistry);
    }
}

static void
pl__handle_extension_reloads(void)
{
    const plApiRegistryI* ptApiRegistry = pl__load_api_registry();

    for(uint32_t i = 0; i < pl_sb_size(gsbtHotLibs); i++)
    {
        if(pl__has_library_changed(gsbptLibs[gsbtHotLibs[i]]))
        {
            plSharedLibrary* ptLibrary = gsbptLibs[gsbtHotLibs[i]];
            plExtension* ptExtension = &gsbtExtensions[gsbtHotLibs[i]];
            // ptExtension->pl_unload(ptApiRegistry);
            pl__reload_library(ptLibrary); 
            #ifdef _WIN32
                ptExtension->pl_load   = (void (__cdecl *)(const plApiRegistryI*, bool)) pl__load_library_function(ptLibrary, ptExtension->pcLoadFunc);
                ptExtension->pl_unload = (void (__cdecl *)(const plApiRegistryI*))       pl__load_library_function(ptLibrary, ptExtension->pcUnloadFunc);
            #else // linux & apple
                ptExtension->pl_load   = (void (__attribute__(()) *)(const plApiRegistryI*, bool)) pl__load_library_function(ptLibrary, ptExtension->pcLoadFunc);
                ptExtension->pl_unload = (void (__attribute__(()) *)(const plApiRegistryI*))       pl__load_library_function(ptLibrary, ptExtension->pcUnloadFunc);
            #endif
            PL_ASSERT(ptExtension->pl_load);
            // PL_ASSERT(ptExtension->pl_unload);
            ptExtension->pl_load(ptApiRegistry, true);
        }
            
    }
}

plKeyData*
pl_get_key_data(plKey tKey)
{
    if(tKey & PL_KEY_MOD_MASK_)
    {
        if     (tKey == PL_KEY_MOD_CTRL)  tKey = PL_KEY_RESERVED_MOD_CTRL;
        else if(tKey == PL_KEY_MOD_SHIFT) tKey = PL_KEY_RESERVED_MOD_SHIFT;
        else if(tKey == PL_KEY_MOD_ALT)   tKey = PL_KEY_RESERVED_MOD_ALT;
        else if(tKey == PL_KEY_MOD_SUPER) tKey = PL_RESERVED_KEY_MOD_SUPER;
        else if(tKey == PL_KEY_MOD_SHORTCUT) tKey = (gtIO.bConfigMacOSXBehaviors ? PL_RESERVED_KEY_MOD_SUPER : PL_KEY_RESERVED_MOD_CTRL);
    }
    assert(tKey > PL_KEY_NONE && tKey < PL_KEY_COUNT && "Key not valid");
    return &gtIO._tKeyData[tKey];
}

void
pl_add_key_event(plKey tKey, bool bDown)
{
    // check for duplicate
    const plInputEvent* ptLastEvent = pl__get_last_event(PL_INPUT_EVENT_TYPE_KEY, (int)tKey);
    if(ptLastEvent && ptLastEvent->bKeyDown == bDown)
        return;

    const plInputEvent tEvent = {
        .tType    = PL_INPUT_EVENT_TYPE_KEY,
        .tSource  = PL_INPUT_EVENT_SOURCE_KEYBOARD,
        .tKey     = tKey,
        .bKeyDown = bDown
    };
    pl_sb_push(gtIO._sbtInputEvents, tEvent);
}

void
pl_add_text_event(uint32_t uChar)
{
    const plInputEvent tEvent = {
        .tType    = PL_INPUT_EVENT_TYPE_TEXT,
        .tSource  = PL_INPUT_EVENT_SOURCE_KEYBOARD,
        .uChar     = uChar
    };
    pl_sb_push(gtIO._sbtInputEvents, tEvent);
}

void
pl_add_text_event_utf16(uint16_t uChar)
{
    if (uChar == 0 && gtIO._tInputQueueSurrogate == 0)
        return;

    if ((uChar & 0xFC00) == 0xD800) // High surrogate, must save
    {
        if (gtIO._tInputQueueSurrogate != 0)
            pl_add_text_event(0xFFFD);
        gtIO._tInputQueueSurrogate = uChar;
        return;
    }

    plUiWChar cp = uChar;
    if (gtIO._tInputQueueSurrogate != 0)
    {
        if ((uChar & 0xFC00) != 0xDC00) // Invalid low surrogate
        {
            pl_add_text_event(0xFFFD);
        }
        else
        {
            cp = 0xFFFD; // Codepoint will not fit in ImWchar
        }

        gtIO._tInputQueueSurrogate = 0;
    }
    pl_add_text_event((uint32_t)cp);
}

void
pl_add_text_events_utf8(const char* pcText)
{
    while(*pcText != 0)
    {
        uint32_t uChar = 0;
        pcText += pl_text_char_from_utf8(&uChar, pcText, NULL);
        pl_add_text_event(uChar);
    }
}

void
pl_add_mouse_pos_event(float fX, float fY)
{

    // check for duplicate
    const plInputEvent* ptLastEvent = pl__get_last_event(PL_INPUT_EVENT_TYPE_MOUSE_POS, (int)(fX + fY));
    if(ptLastEvent && ptLastEvent->fPosX == fX && ptLastEvent->fPosY == fY)
        return;

    const plInputEvent tEvent = {
        .tType    = PL_INPUT_EVENT_TYPE_MOUSE_POS,
        .tSource  = PL_INPUT_EVENT_SOURCE_MOUSE,
        .fPosX    = fX,
        .fPosY    = fY
    };
    pl_sb_push(gtIO._sbtInputEvents, tEvent);
}

void
pl_add_mouse_button_event(int iButton, bool bDown)
{

    // check for duplicate
    const plInputEvent* ptLastEvent = pl__get_last_event(PL_INPUT_EVENT_TYPE_MOUSE_BUTTON, iButton);
    if(ptLastEvent && ptLastEvent->bMouseDown == bDown)
        return;

    const plInputEvent tEvent = {
        .tType      = PL_INPUT_EVENT_TYPE_MOUSE_BUTTON,
        .tSource    = PL_INPUT_EVENT_SOURCE_MOUSE,
        .iButton    = iButton,
        .bMouseDown = bDown
    };
    pl_sb_push(gtIO._sbtInputEvents, tEvent);
}

void
pl_add_mouse_wheel_event(float fX, float fY)
{

    const plInputEvent tEvent = {
        .tType   = PL_INPUT_EVENT_TYPE_MOUSE_WHEEL,
        .tSource = PL_INPUT_EVENT_SOURCE_MOUSE,
        .fWheelX = fX,
        .fWheelY = fY
    };
    pl_sb_push(gtIO._sbtInputEvents, tEvent);
}

void
pl_clear_input_characters(void)
{
    pl_sb_reset(gtIO._sbInputQueueCharacters);
}

bool
pl_is_key_down(plKey tKey)
{
    const plKeyData* ptData = pl_get_key_data(tKey);
    return ptData->bDown;
}

int
pl_get_key_pressed_amount(plKey tKey, float fRepeatDelay, float fRate)
{
    const plKeyData* ptData = pl_get_key_data(tKey);
    if (!ptData->bDown) // In theory this should already be encoded as (DownDuration < 0.0f), but testing this facilitates eating mechanism (until we finish work on input ownership)
        return 0;
    const float fT = ptData->fDownDuration;
    return pl__calc_typematic_repeat_amount(fT - gtIO.fDeltaTime, fT, fRepeatDelay, fRate);
}

bool
pl_is_key_pressed(plKey tKey, bool bRepeat)
{
    const plKeyData* ptData = pl_get_key_data(tKey);
    if (!ptData->bDown) // In theory this should already be encoded as (DownDuration < 0.0f), but testing this facilitates eating mechanism (until we finish work on input ownership)
        return false;
    const float fT = ptData->fDownDuration;
    if (fT < 0.0f)
        return false;

    bool bPressed = (fT == 0.0f);
    if (!bPressed && bRepeat)
    {
        const float fRepeatDelay = gtIO.fKeyRepeatDelay;
        const float fRepeatRate = gtIO.fKeyRepeatRate;
        bPressed = (fT > fRepeatDelay) && pl_get_key_pressed_amount(tKey, fRepeatDelay, fRepeatRate) > 0;
    }

    if (!bPressed)
        return false;
    return true;
}

bool
pl_is_key_released(plKey tKey)
{
    const plKeyData* ptData = pl_get_key_data(tKey);
    if (ptData->fDownDurationPrev < 0.0f || ptData->bDown)
        return false;
    return true;
}

bool
pl_is_mouse_down(plMouseButton tButton)
{
    return gtIO._abMouseDown[tButton];
}

bool
pl_is_mouse_clicked(plMouseButton tButton, bool bRepeat)
{
    if(!gtIO._abMouseDown[tButton])
        return false;
    const float fT = gtIO._afMouseDownDuration[tButton];
    if(fT == 0.0f)
        return true;
    if(bRepeat && fT > gtIO.fKeyRepeatDelay)
        return pl__calc_typematic_repeat_amount(fT - gtIO.fDeltaTime, fT, gtIO.fKeyRepeatDelay, gtIO.fKeyRepeatRate) > 0;
    return false;
}

bool
pl_is_mouse_released(plMouseButton tButton)
{
    return gtIO._abMouseReleased[tButton];
}

bool
pl_is_mouse_double_clicked(plMouseButton tButton)
{
    return gtIO._auMouseClickedCount[tButton] == 2;
}

bool
pl_is_mouse_dragging(plMouseButton tButton, float fThreshold)
{
    if(!gtIO._abMouseDown[tButton])
        return false;
    if(fThreshold < 0.0f)
        fThreshold = gtIO.fMouseDragThreshold;
    return gtIO._afMouseDragMaxDistSqr[tButton] >= fThreshold * fThreshold;
}

bool
pl_is_mouse_hovering_rect(plVec2 minVec, plVec2 maxVec)
{
    const plVec2 tMousePos = gtIO._tMousePos;
    return ( tMousePos.x >= minVec.x && tMousePos.y >= minVec.y && tMousePos.x <= maxVec.x && tMousePos.y <= maxVec.y);
}

void
pl_reset_mouse_drag_delta(plMouseButton tButton)
{
    gtIO._atMouseClickedPos[tButton] = gtIO._tMousePos;
}

plVec2
pl_get_mouse_pos(void)
{
    return gtIO._tMousePos;
}

float
pl_get_mouse_wheel(void)
{
    return gtIO._fMouseWheel;
}

bool
pl_is_mouse_pos_valid(plVec2 tPos)
{
    return tPos.x > -FLT_MAX && tPos.y > -FLT_MAX;
}

void
pl_set_mouse_cursor(plMouseCursor tCursor)
{
    gtIO.tNextCursor = tCursor;
    gtIO.bCursorChanged = true;
}

plVec2
pl_get_mouse_drag_delta(plMouseButton tButton, float fThreshold)
{
    if(fThreshold < 0.0f)
        fThreshold = gtIO.fMouseDragThreshold;
    if(gtIO._abMouseDown[tButton] || gtIO._abMouseReleased[tButton])
    {
        if(gtIO._afMouseDragMaxDistSqr[tButton] >= fThreshold * fThreshold)
        {
            if(pl_is_mouse_pos_valid(gtIO._tMousePos) && pl_is_mouse_pos_valid(gtIO._atMouseClickedPos[tButton]))
                return pl_sub_vec2(gtIO._tLastValidMousePos, gtIO._atMouseClickedPos[tButton]);
        }
    }
    
    return pl_create_vec2(0.0f, 0.0f);
}

plIO*
pl_get_io(void)
{
    return &gtIO;
}

static void
pl__update_events(void)
{
    const uint32_t uEventCount = pl_sb_size(gtIO._sbtInputEvents);
    for(uint32_t i = 0; i < uEventCount; i++)
    {
        plInputEvent* ptEvent = &gtIO._sbtInputEvents[i];

        switch(ptEvent->tType)
        {
            case PL_INPUT_EVENT_TYPE_MOUSE_POS:
            {
                // PL_UI_DEBUG_LOG_IO("[%Iu] IO Mouse Pos (%0.0f, %0.0f)", gptCtx->frameCount, ptEvent->fPosX, ptEvent->fPosY);

                if(ptEvent->fPosX != -FLT_MAX && ptEvent->fPosY != -FLT_MAX)
                {
                    gtIO._tMousePos.x = ptEvent->fPosX;
                    gtIO._tMousePos.y = ptEvent->fPosY;
                }
                break;
            }

            case PL_INPUT_EVENT_TYPE_MOUSE_WHEEL:
            {
                // PL_UI_DEBUG_LOG_IO("[%Iu] IO Mouse Wheel (%0.0f, %0.0f)", gptCtx->frameCount, ptEvent->fWheelX, ptEvent->fWheelY);
                gtIO._fMouseWheelH += ptEvent->fWheelX;
                gtIO._fMouseWheel += ptEvent->fWheelY;
                break;
            }

            case PL_INPUT_EVENT_TYPE_MOUSE_BUTTON:
            {
                // PL_UI_DEBUG_LOG_IO(ptEvent->bMouseDown ? "[%Iu] IO Mouse Button %i down" : "[%Iu] IO Mouse Button %i up", gptCtx->frameCount, ptEvent->iButton);
                assert(ptEvent->iButton >= 0 && ptEvent->iButton < PL_MOUSE_BUTTON_COUNT);
                gtIO._abMouseDown[ptEvent->iButton] = ptEvent->bMouseDown;
                break;
            }

            case PL_INPUT_EVENT_TYPE_KEY:
            {
                // if(ptEvent->tKey < PL_KEY_COUNT)
                //     PL_UI_DEBUG_LOG_IO(ptEvent->bKeyDown ? "[%Iu] IO Key %i down" : "[%Iu] IO Key %i up", gptCtx->frameCount, ptEvent->tKey);
                plKey tKey = ptEvent->tKey;
                assert(tKey != PL_KEY_NONE);
                plKeyData* ptKeyData = pl_get_key_data(tKey);
                ptKeyData->bDown = ptEvent->bKeyDown;
                break;
            }

            case PL_INPUT_EVENT_TYPE_TEXT:
            {
                // PL_UI_DEBUG_LOG_IO("[%Iu] IO Text (U+%08u)", gptCtx->frameCount, (uint32_t)ptEvent->uChar);
                plUiWChar uChar = (plUiWChar)ptEvent->uChar;
                pl_sb_push(gtIO._sbInputQueueCharacters, uChar);
                break;
            }

            default:
            {
                assert(false && "unknown input event type");
                break;
            }
        }
    }
    pl_sb_reset(gtIO._sbtInputEvents)
}

static void
pl__update_keyboard_inputs(void)
{
    gtIO.tKeyMods = 0;
    if (pl_is_key_down(PL_KEY_LEFT_CTRL)  || pl_is_key_down(PL_KEY_RIGHT_CTRL))     { gtIO.tKeyMods |= PL_KEY_MOD_CTRL; }
    if (pl_is_key_down(PL_KEY_LEFT_SHIFT) || pl_is_key_down(PL_KEY_RIGHT_SHIFT))    { gtIO.tKeyMods |= PL_KEY_MOD_SHIFT; }
    if (pl_is_key_down(PL_KEY_LEFT_ALT)   || pl_is_key_down(PL_KEY_RIGHT_ALT))      { gtIO.tKeyMods |= PL_KEY_MOD_ALT; }
    if (pl_is_key_down(PL_KEY_LEFT_SUPER) || pl_is_key_down(PL_KEY_RIGHT_SUPER))    { gtIO.tKeyMods |= PL_KEY_MOD_SUPER; }

    gtIO.bKeyCtrl  = (gtIO.tKeyMods & PL_KEY_MOD_CTRL) != 0;
    gtIO.bKeyShift = (gtIO.tKeyMods & PL_KEY_MOD_SHIFT) != 0;
    gtIO.bKeyAlt   = (gtIO.tKeyMods & PL_KEY_MOD_ALT) != 0;
    gtIO.bKeySuper = (gtIO.tKeyMods & PL_KEY_MOD_SUPER) != 0;

    // Update keys
    for (uint32_t i = 0; i < PL_KEY_COUNT; i++)
    {
        plKeyData* ptKeyData = &gtIO._tKeyData[i];
        ptKeyData->fDownDurationPrev = ptKeyData->fDownDuration;
        ptKeyData->fDownDuration = ptKeyData->bDown ? (ptKeyData->fDownDuration < 0.0f ? 0.0f : ptKeyData->fDownDuration + gtIO.fDeltaTime) : -1.0f;
    }
}

static void
pl__update_mouse_inputs(void)
{
    if(pl_is_mouse_pos_valid(gtIO._tMousePos))
    {
        gtIO._tMousePos.x = floorf(gtIO._tMousePos.x);
        gtIO._tMousePos.y = floorf(gtIO._tMousePos.y);
        gtIO._tLastValidMousePos = gtIO._tMousePos;
    }

    // only calculate data if the current & previous mouse position are valid
    if(pl_is_mouse_pos_valid(gtIO._tMousePos) && pl_is_mouse_pos_valid(gtIO._tMousePosPrev))
        gtIO._tMouseDelta = pl_sub_vec2(gtIO._tMousePos, gtIO._tMousePosPrev);
    else
    {
        gtIO._tMouseDelta.x = 0.0f;
        gtIO._tMouseDelta.y = 0.0f;
    }
    gtIO._tMousePosPrev = gtIO._tMousePos;

    for(uint32_t i = 0; i < PL_MOUSE_BUTTON_COUNT; i++)
    {
        gtIO._abMouseClicked[i] = gtIO._abMouseDown[i] && gtIO._afMouseDownDuration[i] < 0.0f;
        gtIO._auMouseClickedCount[i] = 0;
        gtIO._abMouseReleased[i] = !gtIO._abMouseDown[i] && gtIO._afMouseDownDuration[i] >= 0.0f;
        gtIO._afMouseDownDurationPrev[i] = gtIO._afMouseDownDuration[i];
        gtIO._afMouseDownDuration[i] = gtIO._abMouseDown[i] ? (gtIO._afMouseDownDuration[i] < 0.0f ? 0.0f : gtIO._afMouseDownDuration[i] + gtIO.fDeltaTime) : -1.0f;

        if(gtIO._abMouseClicked[i])
        {

            bool bIsRepeatedClick = false;
            if((float)(gtIO.dTime - gtIO._adMouseClickedTime[i]) < gtIO.fMouseDoubleClickTime)
            {
                plVec2 tDeltaFromClickPos = pl_create_vec2(0.0f, 0.0f);
                if(pl_is_mouse_pos_valid(gtIO._tMousePos))
                    tDeltaFromClickPos = pl_sub_vec2(gtIO._tMousePos, gtIO._atMouseClickedPos[i]);

                if(PL_VEC2_LENGTH_SQR(tDeltaFromClickPos) < gtIO.fMouseDoubleClickMaxDist * gtIO.fMouseDoubleClickMaxDist)
                    bIsRepeatedClick = true;
            }

            if(bIsRepeatedClick)
                gtIO._auMouseClickedLastCount[i]++;
            else
                gtIO._auMouseClickedLastCount[i] = 1;

            gtIO._adMouseClickedTime[i] = gtIO.dTime;
            gtIO._atMouseClickedPos[i] = gtIO._tMousePos;
            gtIO._afMouseDragMaxDistSqr[i] = 0.0f;
            gtIO._auMouseClickedCount[i] = gtIO._auMouseClickedLastCount[i];
        }
        else if(gtIO._abMouseDown[i])
        {
            const plVec2 tClickPos = pl_sub_vec2(gtIO._tLastValidMousePos, gtIO._atMouseClickedPos[i]);
            float fDeltaSqrClickPos = PL_VEC2_LENGTH_SQR(tClickPos);
            gtIO._afMouseDragMaxDistSqr[i] = pl_max(fDeltaSqrClickPos, gtIO._afMouseDragMaxDistSqr[i]);
        }
    }
}

static int
pl__calc_typematic_repeat_amount(float fT0, float fT1, float fRepeatDelay, float fRepeatRate)
{
    if(fT1 == 0.0f)
        return 1;
    if(fT0 >= fT1)
        return 0;
    if(fRepeatRate <= 0.0f)
        return (fT0 < fRepeatDelay) && (fT1 >= fRepeatDelay);
    
    const int iCountT0 = (fT0 < fRepeatDelay) ? -1 : (int)((fT0 - fRepeatDelay) / fRepeatRate);
    const int iCountT1 = (fT1 < fRepeatDelay) ? -1 : (int)((fT1 - fRepeatDelay) / fRepeatRate);
    const int iCount = iCountT1 - iCountT0;
    return iCount;
}

static plInputEvent*
pl__get_last_event(plInputEventType tType, int iButtonOrKey)
{
    const uint32_t uEventCount = pl_sb_size(gtIO._sbtInputEvents);
    for(uint32_t i = 0; i < uEventCount; i++)
    {
        plInputEvent* ptEvent = &gtIO._sbtInputEvents[uEventCount - i - 1];
        if(ptEvent->tType != tType)
            continue;
        if(tType == PL_INPUT_EVENT_TYPE_KEY && (int)ptEvent->tKey != iButtonOrKey)
            continue;
        else if(tType == PL_INPUT_EVENT_TYPE_MOUSE_BUTTON && ptEvent->iButton != iButtonOrKey)
            continue;
        else if(tType == PL_INPUT_EVENT_TYPE_MOUSE_POS && (int)(ptEvent->fPosX + ptEvent->fPosY) != iButtonOrKey)
            continue;
        return ptEvent;
    }
    return NULL;
}

void
pl_new_frame(void)
{

    // update IO structure
    gtIO.dTime += (double)gtIO.fDeltaTime;
    gtIO.ulFrameCount++;
    gtIO.bViewportSizeChanged = false;

    // calculate frame rate
    gtIO._fFrameRateSecPerFrameAccum += gtIO.fDeltaTime - gtIO._afFrameRateSecPerFrame[gtIO._iFrameRateSecPerFrameIdx];
    gtIO._afFrameRateSecPerFrame[gtIO._iFrameRateSecPerFrameIdx] = gtIO.fDeltaTime;
    gtIO._iFrameRateSecPerFrameIdx = (gtIO._iFrameRateSecPerFrameIdx + 1) % 120;
    gtIO._iFrameRateSecPerFrameCount = pl_max(gtIO._iFrameRateSecPerFrameCount, 120);
    gtIO.fFrameRate = FLT_MAX;
    if(gtIO._fFrameRateSecPerFrameAccum > 0)
        gtIO.fFrameRate = ((float) gtIO._iFrameRateSecPerFrameCount) / gtIO._fFrameRateSecPerFrameAccum;

    // handle events
    pl__update_events();
    pl__update_keyboard_inputs();
    pl__update_mouse_inputs();
}

size_t
pl_get_memory_usage(void)
{
    return gszMemoryUsage;
}

size_t
pl_get_allocation_count(void)
{
    return gszActiveAllocations;
}

size_t
pl_get_free_count(void)
{
    return gszAllocationFrees;
}

plAllocationEntry*
pl_get_allocations(size_t* pszCount)
{
    *pszCount = pl_sb_size(gsbtAllocations);
    return gsbtAllocations;
}

void
pl_check_for_leaks(void)
{
    // check for unfreed memory
    uint32_t uMemoryLeakCount = 0;
    for(uint32_t i = 0; i < pl_sb_size(gsbtAllocations); i++)
    {
        if(gsbtAllocations[i].pAddress != NULL)
        {
            printf("Unfreed memory from line %i in file '%s'.\n", gsbtAllocations[i].iLine, gsbtAllocations[i].pcFile);
            uMemoryLeakCount++;
        }
    }
        
    PL_ASSERT(uMemoryLeakCount == gszActiveAllocations);
    if(uMemoryLeakCount > 0)
        printf("%u unfreed allocations.\n", uMemoryLeakCount);
}

void*
pl_realloc(void* pBuffer, size_t szSize, const char* pcFile, int iLine)
{

    static plMutex* gptMutex = NULL;

    if(gptMutex == NULL)
    {
        pl_create_mutex(&gptMutex);
    }

    pl_lock_mutex(gptMutex);

    void* pNewBuffer = NULL;

    if(szSize > 0)
    {
        
        gszActiveAllocations++;
        gszMemoryUsage += szSize;
        pNewBuffer = malloc(szSize);
        memset(pNewBuffer, 0, szSize);

        const uint64_t ulHash = pl_hm_hash(&pNewBuffer, sizeof(void*), 1);

        
        uint64_t ulFreeIndex = pl_hm_get_free_index(gptMemoryHashMap);
        if(ulFreeIndex == UINT64_MAX)
        {
            pl_sb_push(gsbtAllocations, (plAllocationEntry){0});
            ulFreeIndex = pl_sb_size(gsbtAllocations) - 1;
        }
        pl_hm_insert(gptMemoryHashMap, ulHash, ulFreeIndex);
        
        gsbtAllocations[ulFreeIndex].iLine = iLine;
        gsbtAllocations[ulFreeIndex].pcFile = pcFile;
        gsbtAllocations[ulFreeIndex].pAddress = pNewBuffer;
        gsbtAllocations[ulFreeIndex].szSize = szSize;
        gszAllocationCount++;
        
    }

    if(pBuffer) // free
    {
        const uint64_t ulHash = pl_hm_hash(&pBuffer, sizeof(void*), 1);
        const bool bDataExists = pl_hm_has_key(gptMemoryHashMap, ulHash);

        if(bDataExists)
        {
            
            const uint64_t ulIndex = pl_hm_lookup(gptMemoryHashMap, ulHash);

            if(pNewBuffer)
            {
                memcpy(pNewBuffer, pBuffer, gsbtAllocations[ulIndex].szSize);
            }
            gsbtAllocations[ulIndex].pAddress = NULL;
            gszMemoryUsage -= gsbtAllocations[ulIndex].szSize;
            gsbtAllocations[ulIndex].szSize = 0;
            pl_hm_remove(gptMemoryHashMap, ulHash);
            gszAllocationFrees++;
            gszActiveAllocations--;
        }
        else
        {
            PL_ASSERT(false);
        }
        free(pBuffer);
    }

    pl_unlock_mutex(gptMutex);
    return pNewBuffer;
}

//-----------------------------------------------------------------------------
// [SECTION] public api implementation
//-----------------------------------------------------------------------------

const plApiRegistryI*
pl_load_core_apis(void)
{

    const plApiRegistryI* ptApiRegistry = pl__load_api_registry();
    pl__create_mutex(&gptDataMutex);

    pl_sb_resize(gtDataRegistryData.sbtFreeDataIDs, 1024);
    for(uint32_t i = 0; i < 1024; i++)
    {
        gtDataRegistryData.sbtFreeDataIDs[i].uIndex = i;
    }

    static const plIOI tIOApi = {
        .new_frame               = pl_new_frame,
        .get_io                  = pl_get_io,
        .is_key_down             = pl_is_key_down,
        .is_key_pressed          = pl_is_key_pressed,
        .is_key_released         = pl_is_key_released,
        .get_key_pressed_amount  = pl_get_key_pressed_amount,
        .is_mouse_down           = pl_is_mouse_down,
        .is_mouse_clicked        = pl_is_mouse_clicked,
        .is_mouse_released       = pl_is_mouse_released,
        .is_mouse_double_clicked = pl_is_mouse_double_clicked,
        .is_mouse_dragging       = pl_is_mouse_dragging,
        .is_mouse_hovering_rect  = pl_is_mouse_hovering_rect,
        .reset_mouse_drag_delta  = pl_reset_mouse_drag_delta,
        .get_mouse_drag_delta    = pl_get_mouse_drag_delta,
        .get_mouse_pos           = pl_get_mouse_pos,
        .get_mouse_wheel         = pl_get_mouse_wheel,
        .is_mouse_pos_valid      = pl_is_mouse_pos_valid,
        .set_mouse_cursor        = pl_set_mouse_cursor,
        .get_key_data            = pl_get_key_data,
        .add_key_event           = pl_add_key_event,
        .add_text_event          = pl_add_text_event,
        .add_text_event_utf16    = pl_add_text_event_utf16,
        .add_text_events_utf8    = pl_add_text_events_utf8,
        .add_mouse_pos_event     = pl_add_mouse_pos_event,
        .add_mouse_button_event  = pl_add_mouse_button_event,
        .add_mouse_wheel_event   = pl_add_mouse_wheel_event,
        .clear_input_characters  = pl_clear_input_characters,
    };

    static const plDataRegistryI tDataRegistryApi = {
        .set_data           = pl__set_data,
        .get_data           = pl__get_data,
        .garbage_collect    = pl__garbage_collect,
        .create_object      = pl__create_object,
        .get_object_by_name = pl__get_object_by_name,
        .read               = pl__read,
        .end_read           = pl__end_read,
        .get_string         = pl__get_string,
        .get_buffer         = pl__get_buffer,
        .write              = pl__write,
        .set_string         = pl__set_string,
        .set_buffer         = pl__set_buffer,
        .commit             = pl__commit
    };

    static const plExtensionRegistryI tExtensionRegistryApi = {
        .load       = pl__load_extension,
        .unload     = pl__unload_extension,
        .unload_all = pl__unload_all_extensions,
        .reload     = pl__handle_extension_reloads
    };

    // apis more likely to not be stored, should be first (api registry is not sorted)
    ptApiRegistry->add(PL_API_IO, &tIOApi);
    ptApiRegistry->add(PL_API_DATA_REGISTRY, &tDataRegistryApi);
    ptApiRegistry->add(PL_API_EXTENSION_REGISTRY, &tExtensionRegistryApi);

    return ptApiRegistry;
}

void
pl_unload_core_apis(void)
{
    const uint32_t uApiCount = pl_sb_size(gsbApiEntries);
    for(uint32_t i = 0; i < uApiCount; i++)
    {
        pl_sb_free(gsbApiEntries[i].sbSubscribers);
        pl_sb_free(gsbApiEntries[i].sbUserData);
    }

    pl_sb_free(gsbtExtensions);
    pl_sb_free(gsbptLibs);
    pl_sb_free(gsbtHotLibs);
    pl_sb_free(gsbApiEntries);
    pl_hm_free(&gtHashMap);
}

//-----------------------------------------------------------------------------
// [SECTION] unity build
//-----------------------------------------------------------------------------

#ifdef PL_USE_STB_SPRINTF
    #define STB_SPRINTF_IMPLEMENTATION
    #include "stb_sprintf.h"
    #undef STB_SPRINTF_IMPLEMENTATION
#endif

#define PL_MEMORY_IMPLEMENTATION
#include "pl_memory.h"
#undef PL_MEMORY_IMPLEMENTATION

#define PL_STRING_IMPLEMENTATION
#include "pl_string.h"
#undef PL_STRING_IMPLEMENTATION

void*
pl_realloc(void* pBuffer, size_t szSize, const char* pcFile, int iLine)
{
    return realloc(pBuffer, szSize);
}
