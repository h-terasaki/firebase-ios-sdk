/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Remote/FSTRemoteStore.h"

#include <cinttypes>
#include <memory>
#include <unordered_map>
#include <utility>

#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Core/FSTTransaction.h"
#import "Firestore/Source/Local/FSTLocalStore.h"
#import "Firestore/Source/Local/FSTQueryData.h"
#import "Firestore/Source/Model/FSTDocument.h"
#import "Firestore/Source/Model/FSTMutation.h"
#import "Firestore/Source/Model/FSTMutationBatch.h"
#import "Firestore/Source/Remote/FSTStream.h"

#include "Firestore/core/src/firebase/firestore/auth/user.h"
#include "Firestore/core/src/firebase/firestore/model/document_key.h"
#include "Firestore/core/src/firebase/firestore/model/mutation_batch.h"
#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/remote/online_state_tracker.h"
#include "Firestore/core/src/firebase/firestore/remote/remote_event.h"
#include "Firestore/core/src/firebase/firestore/remote/stream.h"
#include "Firestore/core/src/firebase/firestore/util/error_apple.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/status.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"
#include "absl/memory/memory.h"

namespace util = firebase::firestore::util;
using firebase::firestore::auth::User;
using firebase::firestore::model::BatchId;
using firebase::firestore::model::kBatchIdUnknown;
using firebase::firestore::model::DocumentKey;
using firebase::firestore::model::DocumentKeySet;
using firebase::firestore::model::OnlineState;
using firebase::firestore::model::SnapshotVersion;
using firebase::firestore::model::DocumentKeySet;
using firebase::firestore::model::TargetId;
using firebase::firestore::remote::Datastore;
using firebase::firestore::remote::WatchStream;
using firebase::firestore::remote::WriteStream;
using firebase::firestore::remote::DocumentWatchChange;
using firebase::firestore::remote::ExistenceFilterWatchChange;
using firebase::firestore::remote::OnlineStateTracker;
using firebase::firestore::remote::RemoteEvent;
using firebase::firestore::remote::TargetChange;
using firebase::firestore::remote::WatchChange;
using firebase::firestore::remote::WatchChangeAggregator;
using firebase::firestore::remote::WatchTargetChange;
using firebase::firestore::remote::WatchTargetChangeState;
using util::AsyncQueue;
using util::Status;

NS_ASSUME_NONNULL_BEGIN

/**
 * The maximum number of pending writes to allow.
 * TODO(bjornick): Negotiate this value with the backend.
 */
static const int kMaxPendingWrites = 10;

#pragma mark - FSTRemoteStore

@interface FSTRemoteStore () <FSTWatchStreamDelegate, FSTWriteStreamDelegate>

/**
 * The local store, used to fill the write pipeline with outbound mutations and resolve existence
 * filter mismatches. Immutable after initialization.
 */
@property(nonatomic, strong, readonly) FSTLocalStore *localStore;

#pragma mark Watch Stream

/**
 * A list of up to kMaxPendingWrites writes that we have fetched from the LocalStore via
 * fillWritePipeline and have or will send to the write stream.
 *
 * Whenever writePipeline is not empty, the RemoteStore will attempt to start or restart the write
 * stream. When the stream is established, the writes in the pipeline will be sent in order.
 *
 * Writes remain in writePipeline until they are acknowledged by the backend and thus will
 * automatically be re-sent if the stream is interrupted / restarted before they're acknowledged.
 *
 * Write responses from the backend are linked to their originating request purely based on
 * order, and so we can just remove writes from the front of the writePipeline as we receive
 * responses.
 */
@property(nonatomic, strong, readonly) NSMutableArray<FSTMutationBatch *> *writePipeline;
@end

@implementation FSTRemoteStore {
  OnlineStateTracker _onlineStateTracker;

  std::unique_ptr<WatchChangeAggregator> _watchChangeAggregator;

  /** The client-side proxy for interacting with the backend. */
  std::shared_ptr<Datastore> _datastore;
  /**
   * A mapping of watched targets that the client cares about tracking and the
   * user has explicitly called a 'listen' for this target.
   *
   * These targets may or may not have been sent to or acknowledged by the
   * server. On re-establishing the listen stream, these targets should be sent
   * to the server. The targets removed with unlistens are removed eagerly
   * without waiting for confirmation from the listen stream. */
  std::unordered_map<TargetId, FSTQueryData *> _listenTargets;

  std::shared_ptr<WatchStream> _watchStream;
  std::shared_ptr<WriteStream> _writeStream;
  /**
   * Set to YES by 'enableNetwork:' and NO by 'disableNetworkInternal:' and
   * indicates the user-preferred network state.
   */
  BOOL _isNetworkEnabled;
}

- (instancetype)initWithLocalStore:(FSTLocalStore *)localStore
                         datastore:(std::shared_ptr<Datastore>)datastore
                       workerQueue:(AsyncQueue *)queue
                onlineStateHandler:(std::function<void(OnlineState)>)onlineStateHandler {
  if (self = [super init]) {
    _localStore = localStore;
    _datastore = std::move(datastore);

    _writePipeline = [NSMutableArray array];
    _onlineStateTracker = OnlineStateTracker{queue, std::move(onlineStateHandler)};

    _datastore->Start();
    // Create streams (but note they're not started yet)
    _watchStream = _datastore->CreateWatchStream(self);
    _writeStream = _datastore->CreateWriteStream(self);

    _isNetworkEnabled = NO;
  }
  return self;
}

- (void)start {
  // For now, all setup is handled by enableNetwork(). We might expand on this in the future.
  [self enableNetwork];
}

#pragma mark Online/Offline state

- (BOOL)canUseNetwork {
  // PORTING NOTE: This method exists mostly because web also has to take into
  // account primary vs. secondary state.
  return _isNetworkEnabled;
}

- (void)enableNetwork {
  _isNetworkEnabled = YES;

  if ([self canUseNetwork]) {
    // Load any saved stream token from persistent storage
    _writeStream->SetLastStreamToken([self.localStore lastStreamToken]);

    if ([self shouldStartWatchStream]) {
      [self startWatchStream];
    } else {
      _onlineStateTracker.UpdateState(OnlineState::Unknown);
    }

    // This will start the write stream if necessary.
    [self fillWritePipeline];
  }
}

- (void)disableNetwork {
  _isNetworkEnabled = NO;
  [self disableNetworkInternal];

  // Set the OnlineState to Offline so get()s return from cache, etc.
  _onlineStateTracker.UpdateState(OnlineState::Offline);
}

/** Disables the network, setting the OnlineState to the specified targetOnlineState. */
- (void)disableNetworkInternal {
  _watchStream->Stop();
  _writeStream->Stop();

  if (self.writePipeline.count > 0) {
    LOG_DEBUG("Stopping write stream with %s pending writes",
              (unsigned long)self.writePipeline.count);
    [self.writePipeline removeAllObjects];
  }

  [self cleanUpWatchStreamState];
}

#pragma mark Shutdown

- (void)shutdown {
  LOG_DEBUG("FSTRemoteStore %s shutting down", (__bridge void *)self);
  _isNetworkEnabled = NO;
  [self disableNetworkInternal];
  // Set the OnlineState to Unknown (rather than Offline) to avoid potentially triggering
  // spurious listener events with cached data, etc.
  _onlineStateTracker.UpdateState(OnlineState::Unknown);
  _datastore->Shutdown();
}

- (void)credentialDidChange {
  if ([self canUseNetwork]) {
    // Tear down and re-create our network streams. This will ensure we get a fresh auth token
    // for the new user and re-fill the write pipeline with new mutations from the LocalStore
    // (since mutations are per-user).
    LOG_DEBUG("FSTRemoteStore %s restarting streams for new credential", (__bridge void *)self);
    _isNetworkEnabled = NO;
    [self disableNetworkInternal];
    _onlineStateTracker.UpdateState(OnlineState::Unknown);
    [self enableNetwork];
  }
}

#pragma mark Watch Stream

- (void)startWatchStream {
  HARD_ASSERT([self shouldStartWatchStream],
              "startWatchStream: called when shouldStartWatchStream: is false.");
  _watchChangeAggregator = absl::make_unique<WatchChangeAggregator>(self);
  _watchStream->Start();

  _onlineStateTracker.HandleWatchStreamStart();
}

- (void)listenToTargetWithQueryData:(FSTQueryData *)queryData {
  TargetId targetKey = queryData.targetID;
  HARD_ASSERT(_listenTargets.find(targetKey) == _listenTargets.end(),
              "listenToQuery called with duplicate target id: %s", targetKey);

  _listenTargets[targetKey] = queryData;

  if ([self shouldStartWatchStream]) {
    [self startWatchStream];
  } else if (_watchStream->IsOpen()) {
    [self sendWatchRequestWithQueryData:queryData];
  }
}

- (void)sendWatchRequestWithQueryData:(FSTQueryData *)queryData {
  _watchChangeAggregator->RecordPendingTargetRequest(queryData.targetID);
  _watchStream->WatchQuery(queryData);
}

- (void)stopListeningToTargetID:(TargetId)targetID {
  size_t num_erased = _listenTargets.erase(targetID);
  HARD_ASSERT(num_erased == 1, "stopListeningToTargetID: target not currently watched: %s",
              targetID);

  if (_watchStream->IsOpen()) {
    [self sendUnwatchRequestForTargetID:targetID];
  }
  if (_listenTargets.empty()) {
    if (_watchStream->IsOpen()) {
      _watchStream->MarkIdle();
    } else if ([self canUseNetwork]) {
      // Revert to OnlineState::Unknown if the watch stream is not open and we have no listeners,
      // since without any listens to send we cannot confirm if the stream is healthy and upgrade
      // to OnlineState::Online.
      _onlineStateTracker.UpdateState(OnlineState::Unknown);
    }
  }
}

- (void)sendUnwatchRequestForTargetID:(TargetId)targetID {
  _watchChangeAggregator->RecordPendingTargetRequest(targetID);
  _watchStream->UnwatchTargetId(targetID);
}

/**
 * Returns YES if the network is enabled, the watch stream has not yet been started and there are
 * active watch targets.
 */
- (BOOL)shouldStartWatchStream {
  return [self canUseNetwork] && !_watchStream->IsStarted() && !_listenTargets.empty();
}

- (void)cleanUpWatchStreamState {
  _watchChangeAggregator.reset();
}

- (void)watchStreamDidOpen {
  // Restore any existing watches.
  for (const auto &kv : _listenTargets) {
    [self sendWatchRequestWithQueryData:kv.second];
  }
}

- (void)watchStreamDidChange:(const WatchChange &)change
             snapshotVersion:(const SnapshotVersion &)snapshotVersion {
  // Mark the connection as Online because we got a message from the server.
  _onlineStateTracker.UpdateState(OnlineState::Online);

  if (change.type() == WatchChange::Type::TargetChange) {
    const WatchTargetChange &watchTargetChange = static_cast<const WatchTargetChange &>(change);
    if (watchTargetChange.state() == WatchTargetChangeState::Removed &&
        !watchTargetChange.cause().ok()) {
      // There was an error on a target, don't wait for a consistent snapshot to raise events
      return [self processTargetErrorForWatchChange:watchTargetChange];
    } else {
      _watchChangeAggregator->HandleTargetChange(watchTargetChange);
    }
  } else if (change.type() == WatchChange::Type::Document) {
    _watchChangeAggregator->HandleDocumentChange(static_cast<const DocumentWatchChange &>(change));
  } else {
    HARD_ASSERT(change.type() == WatchChange::Type::ExistenceFilter,
                "Expected watchChange to be an instance of ExistenceFilterWatchChange");
    _watchChangeAggregator->HandleExistenceFilter(
        static_cast<const ExistenceFilterWatchChange &>(change));
  }

  if (snapshotVersion != SnapshotVersion::None() &&
      snapshotVersion >= [self.localStore lastRemoteSnapshotVersion]) {
    // We have received a target change with a global snapshot if the snapshot version is not
    // equal to SnapshotVersion.None().
    [self raiseWatchSnapshotWithSnapshotVersion:snapshotVersion];
  }
}

- (void)watchStreamWasInterruptedWithError:(const Status &)error {
  if (error.ok()) {
    // Graceful stop (due to Stop() or idle timeout). Make sure that's desirable.
    HARD_ASSERT(![self shouldStartWatchStream],
                "Watch stream was stopped gracefully while still needed.");
  }

  [self cleanUpWatchStreamState];

  // If we still need the watch stream, retry the connection.
  if ([self shouldStartWatchStream]) {
    _onlineStateTracker.HandleWatchStreamFailure(error);

    [self startWatchStream];
  } else {
    // We don't need to restart the watch stream because there are no active targets. The online
    // state is set to unknown because there is no active attempt at establishing a connection.
    _onlineStateTracker.UpdateState(OnlineState::Unknown);
  }
}

/**
 * Takes a batch of changes from the Datastore, repackages them as a `RemoteEvent`, and passes that
 * on to the SyncEngine.
 */
- (void)raiseWatchSnapshotWithSnapshotVersion:(const SnapshotVersion &)snapshotVersion {
  HARD_ASSERT(snapshotVersion != SnapshotVersion::None(),
              "Can't raise event for unknown SnapshotVersion");

  RemoteEvent remoteEvent = _watchChangeAggregator->CreateRemoteEvent(snapshotVersion);

  // Update in-memory resume tokens. `FSTLocalStore` will update the persistent view of these when
  // applying the completed `RemoteEvent`.
  for (const auto &entry : remoteEvent.target_changes()) {
    const TargetChange &target_change = entry.second;
    NSData *resumeToken = target_change.resume_token();
    if (resumeToken.length > 0) {
      TargetId targetID = entry.first;
      auto found = _listenTargets.find(targetID);
      FSTQueryData *queryData = found != _listenTargets.end() ? found->second : nil;
      // A watched target might have been removed already.
      if (queryData) {
        _listenTargets[targetID] =
            [queryData queryDataByReplacingSnapshotVersion:snapshotVersion
                                               resumeToken:resumeToken
                                            sequenceNumber:queryData.sequenceNumber];
      }
    }
  }

  // Re-establish listens for the targets that have been invalidated by existence filter
  // mismatches.
  for (TargetId targetID : remoteEvent.target_mismatches()) {
    auto found = _listenTargets.find(targetID);
    if (found == _listenTargets.end()) {
      // A watched target might have been removed already.
      continue;
    }
    FSTQueryData *queryData = found->second;

    // Clear the resume token for the query, since we're in a known mismatch state.
    queryData = [[FSTQueryData alloc] initWithQuery:queryData.query
                                           targetID:targetID
                               listenSequenceNumber:queryData.sequenceNumber
                                            purpose:queryData.purpose];
    _listenTargets[targetID] = queryData;

    // Cause a hard reset by unwatching and rewatching immediately, but deliberately don't send a
    // resume token so that we get a full update.
    [self sendUnwatchRequestForTargetID:targetID];

    // Mark the query we send as being on behalf of an existence filter mismatch, but don't
    // actually retain that in _listenTargets. This ensures that we flag the first re-listen this
    // way without impacting future listens of this target (that might happen e.g. on reconnect).
    FSTQueryData *requestQueryData =
        [[FSTQueryData alloc] initWithQuery:queryData.query
                                   targetID:targetID
                       listenSequenceNumber:queryData.sequenceNumber
                                    purpose:FSTQueryPurposeExistenceFilterMismatch];
    [self sendWatchRequestWithQueryData:requestQueryData];
  }

  // Finally handle remote event
  [self.syncEngine applyRemoteEvent:remoteEvent];
}

/** Process a target error and passes the error along to SyncEngine. */
- (void)processTargetErrorForWatchChange:(const WatchTargetChange &)change {
  HARD_ASSERT(!change.cause().ok(), "Handling target error without a cause");
  // Ignore targets that have been removed already.
  for (TargetId targetID : change.target_ids()) {
    auto found = _listenTargets.find(targetID);
    if (found != _listenTargets.end()) {
      _listenTargets.erase(found);
      _watchChangeAggregator->RemoveTarget(targetID);
      [self.syncEngine rejectListenWithTargetID:targetID error:util::MakeNSError(change.cause())];
    }
  }
}

- (DocumentKeySet)remoteKeysForTarget:(TargetId)targetID {
  return [self.syncEngine remoteKeysForTarget:targetID];
}

- (nullable FSTQueryData *)queryDataForTarget:(TargetId)targetID {
  auto found = _listenTargets.find(targetID);
  return found != _listenTargets.end() ? found->second : nil;
}

#pragma mark Write Stream

/**
 * Returns YES if the network is enabled, the write stream has not yet been started and there are
 * pending writes.
 */
- (BOOL)shouldStartWriteStream {
  return [self canUseNetwork] && !_writeStream->IsStarted() && self.writePipeline.count > 0;
}

- (void)startWriteStream {
  HARD_ASSERT([self shouldStartWriteStream],
              "startWriteStream: called when shouldStartWriteStream: is false.");
  _writeStream->Start();
}

/**
 * Attempts to fill our write pipeline with writes from the LocalStore.
 *
 * Called internally to bootstrap or refill the write pipeline and by SyncEngine whenever there
 * are new mutations to process.
 *
 * Starts the write stream if necessary.
 */
- (void)fillWritePipeline {
  BatchId lastBatchIDRetrieved =
      self.writePipeline.count == 0 ? kBatchIdUnknown : self.writePipeline.lastObject.batchID;
  while ([self canAddToWritePipeline]) {
    FSTMutationBatch *batch = [self.localStore nextMutationBatchAfterBatchID:lastBatchIDRetrieved];
    if (!batch) {
      if (self.writePipeline.count == 0) {
        _writeStream->MarkIdle();
      }
      break;
    }
    [self addBatchToWritePipeline:batch];
    lastBatchIDRetrieved = batch.batchID;
  }

  if ([self shouldStartWriteStream]) {
    [self startWriteStream];
  }
}

/**
 * Returns YES if we can add to the write pipeline (i.e. it is not full and the network is enabled).
 */
- (BOOL)canAddToWritePipeline {
  return [self canUseNetwork] && self.writePipeline.count < kMaxPendingWrites;
}

/**
 * Queues additional writes to be sent to the write stream, sending them immediately if the write
 * stream is established.
 */
- (void)addBatchToWritePipeline:(FSTMutationBatch *)batch {
  HARD_ASSERT([self canAddToWritePipeline], "addBatchToWritePipeline called when pipeline is full");

  [self.writePipeline addObject:batch];

  if (_writeStream->IsOpen() && _writeStream->handshake_complete()) {
    _writeStream->WriteMutations(batch.mutations);
  }
}

- (void)writeStreamDidOpen {
  _writeStream->WriteHandshake();
}

/**
 * Handles a successful handshake response from the server, which is our cue to send any pending
 * writes.
 */
- (void)writeStreamDidCompleteHandshake {
  // Record the stream token.
  [self.localStore setLastStreamToken:_writeStream->GetLastStreamToken()];

  // Send the write pipeline now that the stream is established.
  for (FSTMutationBatch *write in self.writePipeline) {
    _writeStream->WriteMutations(write.mutations);
  }
}

/** Handles a successful StreamingWriteResponse from the server that contains a mutation result. */
- (void)writeStreamDidReceiveResponseWithVersion:(const SnapshotVersion &)commitVersion
                                 mutationResults:(NSArray<FSTMutationResult *> *)results {
  // This is a response to a write containing mutations and should be correlated to the first
  // write in our write pipeline.
  NSMutableArray *writePipeline = self.writePipeline;
  FSTMutationBatch *batch = writePipeline[0];
  [writePipeline removeObjectAtIndex:0];

  FSTMutationBatchResult *batchResult =
      [FSTMutationBatchResult resultWithBatch:batch
                                commitVersion:commitVersion
                              mutationResults:results
                                  streamToken:_writeStream->GetLastStreamToken()];
  [self.syncEngine applySuccessfulWriteWithResult:batchResult];

  // It's possible that with the completion of this mutation another slot has freed up.
  [self fillWritePipeline];
}

/**
 * Handles the closing of the StreamingWrite RPC, either because of an error or because the RPC
 * has been terminated by the client or the server.
 */
- (void)writeStreamWasInterruptedWithError:(const Status &)error {
  if (error.ok()) {
    // Graceful stop (due to Stop() or idle timeout). Make sure that's desirable.
    HARD_ASSERT(![self shouldStartWriteStream],
                "Write stream was stopped gracefully while still needed.");
  }

  // If the write stream closed due to an error, invoke the error callbacks if there are pending
  // writes.
  if (!error.ok() && self.writePipeline.count > 0) {
    if (_writeStream->handshake_complete()) {
      // This error affects the actual writes.
      [self handleWriteError:error];
    } else {
      // If there was an error before the handshake finished, it's possible that the server is
      // unable to process the stream token we're sending. (Perhaps it's too old?)
      [self handleHandshakeError:error];
    }
  }

  // The write stream might have been started by refilling the write pipeline for failed writes
  if ([self shouldStartWriteStream]) {
    [self startWriteStream];
  }
}

- (void)handleHandshakeError:(const Status &)error {
  HARD_ASSERT(!error.ok(), "Handling write error with status OK.");
  // Reset the token if it's a permanent error, signaling the write stream is
  // no longer valid. Note that the handshake does not count as a write: see
  // comments on `Datastore::IsPermanentWriteError` for details.
  if (Datastore::IsPermanentError(error)) {
    NSString *token = [_writeStream->GetLastStreamToken() base64EncodedStringWithOptions:0];
    LOG_DEBUG("FSTRemoteStore %s error before completed handshake; resetting stream token %s: "
              "error code: '%s', details: '%s'",
              (__bridge void *)self, token, error.code(), error.error_message());
    _writeStream->SetLastStreamToken(nil);
    [self.localStore setLastStreamToken:nil];
  } else {
    // Some other error, don't reset stream token. Our stream logic will just retry with exponential
    // backoff.
  }
}

- (void)handleWriteError:(const Status &)error {
  HARD_ASSERT(!error.ok(), "Handling write error with status OK.");
  // Only handle permanent errors here. If it's transient, just let the retry logic kick in.
  if (!Datastore::IsPermanentWriteError(error)) {
    return;
  }

  // If this was a permanent error, the request itself was the problem so it's not going to
  // succeed if we resend it.
  FSTMutationBatch *batch = self.writePipeline[0];
  [self.writePipeline removeObjectAtIndex:0];

  // In this case it's also unlikely that the server itself is melting down--this was just a
  // bad request so inhibit backoff on the next restart.
  _writeStream->InhibitBackoff();

  [self.syncEngine rejectFailedWriteWithBatchID:batch.batchID error:util::MakeNSError(error)];

  // It's possible that with the completion of this mutation another slot has freed up.
  [self fillWritePipeline];
}

- (FSTTransaction *)transaction {
  return [FSTTransaction transactionWithDatastore:_datastore.get()];
}

@end

NS_ASSUME_NONNULL_END
