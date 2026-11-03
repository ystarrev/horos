// Private transport shared with Horos. A volume is never sent on a plain TCP socket.
#ifndef HVR_PSK_TRANSPORT_H
#define HVR_PSK_TRANSPORT_H

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>
#include <stdlib.h>
#include <string.h>

static inline dispatch_data_t HVRDispatchCopy(const void *bytes, size_t length)
{
  void *copy = malloc(length);
  if (!copy) return nil;
  memcpy(copy, bytes, length);
  return dispatch_data_create(copy, length, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                              DISPATCH_DATA_DESTRUCTOR_FREE);
}

static inline nw_parameters_t HVRPSKParameters(NSData *key)
{
  if (key.length != 32) return nil;
  return nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
    sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
    sec_protocol_options_set_min_tls_protocol_version(options, tls_protocol_version_TLSv12);
    sec_protocol_options_set_max_tls_protocol_version(options, tls_protocol_version_TLSv12);
    // Certificate-free TLS is permitted only with this authenticated PSK cipher suite.
    sec_protocol_options_set_peer_authentication_required(options, false);
    sec_protocol_options_append_tls_ciphersuite(options, (tls_ciphersuite_t)TLS_PSK_WITH_AES_256_GCM_SHA384);
    dispatch_data_t secret = HVRDispatchCopy(key.bytes, key.length);
    static const char identity[] = "horos-volume-v3";
    dispatch_data_t name = HVRDispatchCopy(identity, sizeof(identity) - 1);
    if (secret && name) sec_protocol_options_add_pre_shared_key(options, secret, name);
#if !__has_feature(objc_arc)
    if (secret) dispatch_release(secret);
    if (name) dispatch_release(name);
    sec_release(options);
#endif
  }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
}

static inline BOOL HVRWaitForReady(nw_connection_t connection, NSTimeInterval seconds)
{
  dispatch_semaphore_t ready = dispatch_semaphore_create(0);
  __block BOOL connected = NO;
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
    (void)error;
    if (state == nw_connection_state_ready || state == nw_connection_state_failed ||
        state == nw_connection_state_cancelled)
    {
      connected = state == nw_connection_state_ready;
      dispatch_semaphore_signal(ready);
    }
  });
  nw_connection_start(connection);
  if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) != 0)
  {
    nw_connection_cancel(connection);
    return NO;
  }
  if (!connected) return NO;
  nw_protocol_definition_t definition = nw_protocol_copy_tls_definition();
  nw_protocol_metadata_t metadata = nw_connection_copy_protocol_metadata(connection, definition);
  sec_protocol_metadata_t security = metadata ? nw_tls_copy_sec_protocol_metadata(metadata) : nil;
  BOOL authenticated = security &&
    sec_protocol_metadata_get_negotiated_tls_protocol_version(security) == tls_protocol_version_TLSv12 &&
    sec_protocol_metadata_get_negotiated_tls_ciphersuite(security) == (tls_ciphersuite_t)TLS_PSK_WITH_AES_256_GCM_SHA384;
#if !__has_feature(objc_arc)
  if (security) sec_release(security);
  if (metadata) nw_release(metadata);
  nw_release(definition);
#endif
  if (!authenticated) nw_connection_cancel(connection);
  return authenticated;
}

static inline BOOL HVRRead(nw_connection_t connection, void *bytes, size_t length)
{
  uint8_t *cursor = (uint8_t *)bytes;
  while (length)
  {
    uint32_t wanted = (uint32_t)MIN(length, (size_t)(256 * 1024));
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block size_t received = 0;
    nw_connection_receive(connection, 1, wanted,
      ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context; (void)complete;
        if (!error && content)
        {
          dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
                                            const void *buffer, size_t size) {
            (void)region; (void)offset;
            memcpy(cursor + received, buffer, size);
            received += size;
            return true;
          });
        }
        dispatch_semaphore_signal(done);
      });
    BOOL timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0;
    if (timedOut)
    {
      nw_connection_cancel(connection);
      dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    }
    if (timedOut || !received) return NO;
    cursor += received;
    length -= received;
  }
  return YES;
}

static inline BOOL HVRWrite(nw_connection_t connection, const void *bytes, size_t length, BOOL final)
{
  dispatch_data_t content = HVRDispatchCopy(bytes, length);
  if (!content) return NO;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block BOOL sent = NO;
  nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, final,
    ^(nw_error_t error) {
      sent = error == nil;
      dispatch_semaphore_signal(done);
    });
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
  {
    nw_connection_cancel(connection);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    sent = NO;
  }
#if !__has_feature(objc_arc)
  dispatch_release(content);
#endif
  return sent;
}

#endif
