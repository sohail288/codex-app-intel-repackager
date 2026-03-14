#include <node_api.h>

#import <Cocoa/Cocoa.h>
#import "Sparkle.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum LogLevel {
  kLogTrace = 1,
  kLogDebug = 2,
  kLogInfo = 3,
  kLogWarning = 4,
  kLogError = 5,
};

struct LogMessagePayload {
  int level;
  char *message;
};

struct BoolPayload {
  bool value;
};

struct ModuleState {
  napi_env env = nullptr;
  napi_threadsafe_function log_sink = nullptr;
  napi_threadsafe_function update_ready_sink = nullptr;
};

ModuleState g_state;

void ReleaseThreadsafeFunction(napi_threadsafe_function *tsfn) {
  if (*tsfn != nullptr) {
    napi_release_threadsafe_function(*tsfn, napi_tsfn_abort);
    *tsfn = nullptr;
  }
}

void CallLogSinkJs(napi_env env, napi_value js_cb, void *, void *data) {
  LogMessagePayload *payload = static_cast<LogMessagePayload *>(data);
  if (env != nullptr && js_cb != nullptr) {
    napi_value undefined;
    napi_value argv[2];
    napi_get_undefined(env, &undefined);
    napi_create_int32(env, payload->level, &argv[0]);
    napi_create_string_utf8(env, payload->message, NAPI_AUTO_LENGTH, &argv[1]);
    napi_call_function(env, undefined, js_cb, 2, argv, nullptr);
  }
  free(payload->message);
  delete payload;
}

void CallUpdateReadySinkJs(napi_env env, napi_value js_cb, void *, void *data) {
  BoolPayload *payload = static_cast<BoolPayload *>(data);
  if (env != nullptr && js_cb != nullptr) {
    napi_value undefined;
    napi_value argv[1];
    napi_get_undefined(env, &undefined);
    napi_get_boolean(env, payload->value, &argv[0]);
    napi_call_function(env, undefined, js_cb, 1, argv, nullptr);
  }
  delete payload;
}

void EmitLog(int level, NSString *message) {
  if (g_state.log_sink == nullptr) {
    return;
  }

  const char *utf8 = message != nil ? [message UTF8String] : "";
  LogMessagePayload *payload = new LogMessagePayload();
  payload->level = level;
  payload->message = strdup(utf8 != nullptr ? utf8 : "");
  if (payload->message == nullptr) {
    delete payload;
    return;
  }

  napi_call_threadsafe_function(g_state.log_sink, payload, napi_tsfn_nonblocking);
}

void EmitLogf(int level, NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  EmitLog(level, message);
}

void EmitUpdateReady(bool ready) {
  if (g_state.update_ready_sink == nullptr) {
    return;
  }

  BoolPayload *payload = new BoolPayload();
  payload->value = ready;
  napi_call_threadsafe_function(g_state.update_ready_sink, payload, napi_tsfn_nonblocking);
}

napi_value ThrowTypeError(napi_env env, const char *message) {
  napi_throw_type_error(env, nullptr, message);
  return nullptr;
}

void EnsureMainThread(void (^block)(void)) {
  if ([NSThread isMainThread]) {
    block();
    return;
  }

  dispatch_sync(dispatch_get_main_queue(), block);
}

class SparkleBridge;
SparkleBridge *GetBridge();

@interface SparkleBridgeImpl : NSObject <SPUUpdaterDelegate, SPUStandardUserDriverDelegate>

@property(nonatomic, copy) NSString *feedURL;
@property(nonatomic, strong) SPUStandardUpdaterController *controller;
@property(nonatomic, copy) void (^immediateInstallBlock)(void);
@property(nonatomic, assign) BOOL hasDiscoveredUpdate;
@property(nonatomic, assign) BOOL hasDownloadedOrInstallingUpdate;
@property(nonatomic, assign) BOOL lastEmittedUpdateReady;

- (instancetype)initWithFeedURL:(NSString *)feedURL;
- (void)start;
- (void)checkForUpdates;
- (void)checkForUpdatesInBackground;
- (void)installUpdatesIfAvailable;
- (void)resetImmediateInstallBlock;
- (void)emitCurrentUpdateState;

@end

class SparkleBridge {
 public:
  SparkleBridge() = default;

  void Init(NSString *feed_url) {
    EnsureMainThread(^{
      NSString *trimmed = [feed_url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (trimmed.length == 0) {
        EmitLog(kLogWarning, @"Sparkle init skipped because the feed URL is empty.");
        return;
      }

      if (bridge_ == nil) {
        bridge_ = [[SparkleBridgeImpl alloc] initWithFeedURL:trimmed];
        [bridge_ start];
        return;
      }

      bridge_.feedURL = trimmed;
      EmitLogf(kLogInfo, @"Sparkle feed updated: %@", trimmed);
    });
  }

  void CheckForUpdates() {
    EnsureMainThread(^{
      if (bridge_ == nil) {
        EmitLog(kLogWarning, @"CheckForUpdates called before Sparkle init.");
        return;
      }
      EmitLog(kLogInfo, @"CheckForUpdates called.");
      [bridge_ checkForUpdates];
    });
  }

  void CheckForUpdatesInBackground() {
    EnsureMainThread(^{
      if (bridge_ == nil) {
        EmitLog(kLogWarning, @"CheckForUpdatesInBackground called before Sparkle init.");
        return;
      }
      [bridge_ checkForUpdatesInBackground];
    });
  }

  void InstallUpdatesIfAvailable() {
    EnsureMainThread(^{
      if (bridge_ == nil) {
        EmitLog(kLogWarning, @"installUpdatesIfAvailable called before Sparkle init.");
        return;
      }
      [bridge_ installUpdatesIfAvailable];
    });
  }

 private:
  SparkleBridgeImpl *bridge_ = nil;
};

SparkleBridge &BridgeSingleton() {
  static SparkleBridge bridge;
  return bridge;
}

@implementation SparkleBridgeImpl

- (instancetype)initWithFeedURL:(NSString *)feedURL {
  self = [super init];
  if (self != nil) {
    _feedURL = [feedURL copy];
    _hasDiscoveredUpdate = NO;
    _hasDownloadedOrInstallingUpdate = NO;
    _lastEmittedUpdateReady = NO;
  }
  return self;
}

- (void)start {
  self.controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:self userDriverDelegate:self];

  NSError *error = nil;
  if (![self.controller.updater startUpdater:&error]) {
    EmitLogf(kLogError, @"Sparkle failed to start: %@", error.localizedDescription ?: @"unknown error");
    return;
  }

  EmitLog(kLogInfo, @"Sparkle controller started.");
}

- (void)checkForUpdates {
  [self.controller checkForUpdates:nil];
}

- (void)checkForUpdatesInBackground {
  [self.controller.updater checkForUpdatesInBackground];
}

- (void)installUpdatesIfAvailable {
  if (self.immediateInstallBlock != nil) {
    EmitLog(kLogInfo, @"Installing previously downloaded update immediately.");
    self.immediateInstallBlock();
    return;
  }

  if (self.hasDiscoveredUpdate || self.hasDownloadedOrInstallingUpdate) {
    EmitLog(kLogInfo, @"Focusing Sparkle update UI.");
    [self.controller checkForUpdates:nil];
    return;
  }

  EmitLog(kLogInfo, @"No pending Sparkle update; falling back to manual check.");
  [self.controller checkForUpdates:nil];
}

- (void)resetImmediateInstallBlock {
  self.immediateInstallBlock = nil;
}

- (void)emitCurrentUpdateState {
  BOOL nextValue = self.hasDiscoveredUpdate || self.hasDownloadedOrInstallingUpdate;
  if (nextValue == self.lastEmittedUpdateReady) {
    return;
  }

  self.lastEmittedUpdateReady = nextValue;
  EmitUpdateReady(nextValue);
}

- (nullable NSString *)feedURLStringForUpdater:(SPUUpdater *)updater {
  return self.feedURL;
}

- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater {
  return NO;
}

- (BOOL)supportsGentleScheduledUpdateReminders {
  return YES;
}

- (BOOL)standardUserDriverShouldHandleShowingScheduledUpdate:(SUAppcastItem *)update andInImmediateFocus:(BOOL)immediateFocus {
  return NO;
}

- (void)standardUserDriverWillHandleShowingUpdate:(BOOL)handleShowingUpdate forUpdate:(SUAppcastItem *)update state:(SPUUserUpdateState *)state {
  if (handleShowingUpdate || state.userInitiated) {
    EmitLogf(kLogInfo, @"Showing Sparkle update UI for %@.", update.displayVersionString ?: update.versionString);
    return;
  }

  self.hasDiscoveredUpdate = YES;
  [self emitCurrentUpdateState];
  EmitLogf(kLogInfo, @"Update available for manual install: %@ (%@)", update.displayVersionString ?: @"unknown", update.versionString ?: @"unknown");
}

- (void)standardUserDriverDidReceiveUserAttentionForUpdate:(SUAppcastItem *)update {
  EmitLogf(kLogDebug, @"User viewed update %@.", update.versionString ?: @"unknown");
}

- (void)standardUserDriverWillFinishUpdateSession {
  if (!self.hasDownloadedOrInstallingUpdate) {
    self.hasDiscoveredUpdate = NO;
    [self emitCurrentUpdateState];
  }
}

- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
  self.hasDiscoveredUpdate = YES;
  [self emitCurrentUpdateState];
  EmitLogf(kLogInfo, @"Valid update found: %@ (%@)", item.displayVersionString ?: @"unknown", item.versionString ?: @"unknown");
}

- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater {
  self.hasDiscoveredUpdate = NO;
  if (!self.hasDownloadedOrInstallingUpdate) {
    [self emitCurrentUpdateState];
  }
  EmitLog(kLogDebug, @"No update found.");
}

- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error {
  self.hasDiscoveredUpdate = NO;
  if (!self.hasDownloadedOrInstallingUpdate) {
    [self emitCurrentUpdateState];
  }
  EmitLogf(kLogDebug, @"No update found: %@", error.localizedDescription ?: @"unknown error");
}

- (void)updater:(SPUUpdater *)updater didDownloadUpdate:(SUAppcastItem *)item {
  self.hasDiscoveredUpdate = NO;
  self.hasDownloadedOrInstallingUpdate = YES;
  [self emitCurrentUpdateState];
  EmitLogf(kLogInfo, @"Update downloaded: %@ (%@)", item.displayVersionString ?: @"unknown", item.versionString ?: @"unknown");
}

- (void)updater:(SPUUpdater *)updater didExtractUpdate:(SUAppcastItem *)item {
  self.hasDownloadedOrInstallingUpdate = YES;
  [self emitCurrentUpdateState];
  EmitLogf(kLogInfo, @"Update extracted: %@ (%@)", item.displayVersionString ?: @"unknown", item.versionString ?: @"unknown");
}

- (void)updater:(SPUUpdater *)updater failedToDownloadUpdate:(SUAppcastItem *)item error:(NSError *)error {
  self.hasDiscoveredUpdate = NO;
  self.hasDownloadedOrInstallingUpdate = NO;
  [self resetImmediateInstallBlock];
  [self emitCurrentUpdateState];
  EmitLogf(kLogError, @"Update failed to download: %@", error.localizedDescription ?: @"unknown error");
}

- (void)userDidCancelDownload:(SPUUpdater *)updater {
  self.hasDownloadedOrInstallingUpdate = NO;
  [self resetImmediateInstallBlock];
  [self emitCurrentUpdateState];
  EmitLog(kLogWarning, @"User canceled update download.");
}

- (void)updater:(SPUUpdater *)updater userDidMakeChoice:(SPUUserUpdateChoice)choice forUpdate:(SUAppcastItem *)updateItem state:(SPUUserUpdateState *)state {
  if (choice == SPUUserUpdateChoiceSkip) {
    self.hasDiscoveredUpdate = NO;
    if (state.stage == SPUUserUpdateStageNotDownloaded) {
      [self emitCurrentUpdateState];
    }
    EmitLogf(kLogInfo, @"User skipped update %@.", updateItem.versionString ?: @"unknown");
    return;
  }

  if (choice == SPUUserUpdateChoiceDismiss && state.stage == SPUUserUpdateStageNotDownloaded) {
    self.hasDiscoveredUpdate = NO;
    [self emitCurrentUpdateState];
    EmitLogf(kLogInfo, @"User dismissed update %@.", updateItem.versionString ?: @"unknown");
  }
}

- (BOOL)updater:(SPUUpdater *)updater willInstallUpdateOnQuit:(SUAppcastItem *)item immediateInstallationBlock:(void (^)(void))immediateInstallHandler {
  self.hasDiscoveredUpdate = NO;
  self.hasDownloadedOrInstallingUpdate = YES;
  self.immediateInstallBlock = [immediateInstallHandler copy];
  [self emitCurrentUpdateState];
  EmitLogf(kLogInfo, @"Update ready to install on quit: %@ (%@)", item.displayVersionString ?: @"unknown", item.versionString ?: @"unknown");
  return YES;
}

- (void)updater:(SPUUpdater *)updater willInstallUpdate:(SUAppcastItem *)item {
  self.hasDownloadedOrInstallingUpdate = YES;
  [self emitCurrentUpdateState];
  EmitLogf(kLogInfo, @"Installing update %@.", item.versionString ?: @"unknown");
}

- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
  if (!self.hasDownloadedOrInstallingUpdate) {
    self.hasDiscoveredUpdate = NO;
    [self emitCurrentUpdateState];
  }
  EmitLogf(kLogWarning, @"Update aborted with error: %@", error.localizedDescription ?: @"unknown error");
}

- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)updateCheck error:(NSError *)error {
  if (error != nil) {
    EmitLogf(kLogDebug, @"Sparkle cycle finished with error: %@", error.localizedDescription ?: @"unknown error");
  } else {
    EmitLog(kLogDebug, @"Sparkle cycle finished.");
  }
}

- (void)updater:(SPUUpdater *)updater willScheduleUpdateCheckAfterDelay:(NSTimeInterval)delay {
  EmitLogf(kLogDebug, @"Sparkle scheduled next update check after %.0f seconds.", delay);
}

@end

SparkleBridge *GetBridge() {
  return &BridgeSingleton();
}

napi_value SetFunctionSink(napi_env env, napi_value arg, napi_threadsafe_function *target, const char *resource_name,
                           napi_threadsafe_function_call_js call_js, const char *error_message) {
  napi_valuetype value_type;
  napi_typeof(env, arg, &value_type);

  if (value_type == napi_null || value_type == napi_undefined) {
    ReleaseThreadsafeFunction(target);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
  }

  if (value_type != napi_function) {
    return ThrowTypeError(env, error_message);
  }

  ReleaseThreadsafeFunction(target);

  napi_value resource;
  napi_create_string_utf8(env, resource_name, NAPI_AUTO_LENGTH, &resource);
  napi_status status = napi_create_threadsafe_function(
      env,
      arg,
      nullptr,
      resource,
      0,
      1,
      nullptr,
      nullptr,
      nullptr,
      call_js,
      target);

  if (status != napi_ok) {
    napi_throw_error(env, nullptr, "Failed to create threadsafe function");
    return nullptr;
  }

  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value SetLogSink(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 1) {
    return ThrowTypeError(env, "Sparkle setLogSink requires a function (or null)");
  }

  return SetFunctionSink(env, argv[0], &g_state.log_sink, "sparkleLogSink", CallLogSinkJs,
                         "Sparkle setLogSink requires a function (or null)");
}

napi_value SetUpdateReadySink(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 1) {
    return ThrowTypeError(env, "Sparkle setUpdateReadySink requires a function (or null)");
  }

  return SetFunctionSink(env, argv[0], &g_state.update_ready_sink, "sparkleUpdateReadySink",
                         CallUpdateReadySinkJs, "Sparkle setUpdateReadySink requires a function (or null)");
}

napi_value InitSparkle(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 1) {
    return ThrowTypeError(env, "Sparkle init requires a feed URL");
  }

  size_t length = 0;
  napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length);
  char *buffer = static_cast<char *>(malloc(length + 1));
  if (buffer == nullptr) {
    napi_throw_error(env, nullptr, "Failed to allocate feed URL buffer");
    return nullptr;
  }

  napi_get_value_string_utf8(env, argv[0], buffer, length + 1, &length);
  NSString *feed_url = [[NSString alloc] initWithUTF8String:buffer];
  free(buffer);

  GetBridge()->Init(feed_url);

  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value CheckForUpdates(napi_env env, napi_callback_info info) {
  GetBridge()->CheckForUpdates();
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value CheckForUpdatesInBackground(napi_env env, napi_callback_info info) {
  GetBridge()->CheckForUpdatesInBackground();
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value InstallUpdatesIfAvailable(napi_env env, napi_callback_info info) {
  GetBridge()->InstallUpdatesIfAvailable();
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

void Cleanup(void *) {
  ReleaseThreadsafeFunction(&g_state.log_sink);
  ReleaseThreadsafeFunction(&g_state.update_ready_sink);
}

napi_value InitModule(napi_env env, napi_value exports) {
  g_state.env = env;
  napi_add_env_cleanup_hook(env, Cleanup, nullptr);

  napi_property_descriptor descriptors[] = {
      {"setLogSink", nullptr, SetLogSink, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setUpdateReadySink", nullptr, SetUpdateReadySink, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"init", nullptr, InitSparkle, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"checkForUpdates", nullptr, CheckForUpdates, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"checkForUpdatesInBackground", nullptr, CheckForUpdatesInBackground, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"installUpdatesIfAvailable", nullptr, InstallUpdatesIfAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
  };

  napi_define_properties(env, exports, sizeof(descriptors) / sizeof(*descriptors), descriptors);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, InitModule)
