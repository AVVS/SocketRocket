//
//   Copyright 2012 Square Inc.
//
//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.
//


#import "SRWebSocket.h"

#import <unicode/utf8.h>
#import <Endian.h>
#import <CommonCrypto/CommonDigest.h>
#import "base64.h"
#import "NSData+SRB64Additions.h"
#include <execinfo.h>

typedef enum  {
    SROpCodeTextFrame = 0x1,
    SROpCodeBinaryFrame = 0x2,
    //3-7Reserved 
    SROpCodeConnectionClose = 0x8,
    SROpCodePing = 0x9,
    SROpCodePong = 0xA,
    //B-F reserved
} SROpCode;

typedef enum {
    SRStatusCodeNormal = 1000,
    SRStatusCodeGoingAway = 1001,
    SRStatusCodeProtocolError = 1002,
    SRStatusCodeUnhandledType = 1003,
    // 1004 reserved
    SRStatusNoStatusReceived = 1005,
    // 1004-1006 reserved
    SRStatusCodeInvalidUTF8 = 1007,
    SRStatusCodePolicyViolated = 1008,
    SRStatusCodeMessageTooBig = 1009,
} SRStatusCode;

typedef struct {
    BOOL fin;
//  BOOL rsv1;
//  BOOL rsv2;
//  BOOL rsv3;
    uint8_t opcode;
    BOOL masked;
    uint64_t payload_length;
} frame_header;


static inline dispatch_queue_t log_queue() {

    static dispatch_queue_t queue = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("fast log queue", DISPATCH_QUEUE_SERIAL);
    });
    
    return queue;
}

//#define SR_ENABLE_LOG

static inline void SRFastLog(NSString *format, ...)  {
#ifdef SR_ENABLE_LOG
    __block va_list arg_list;
    va_start (arg_list, format);
    
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arg_list];
    
    va_end(arg_list);
    
    NSLog(@"[SR] %@", formattedString);
#endif
}

static NSString *const SRWebSocketAppendToSecKeyString = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static inline int32_t validate_dispatch_data_partial_string(NSData *data) {
    
    const void * contents = [data bytes];
    long size = [data length];
    
    const uint8_t *str = (const uint8_t *)contents;

    
    UChar32 codepoint = 1;
    int32_t offset = 0;
    int32_t lastOffset = 0;
    while(offset < size && codepoint > 0)  {
        lastOffset = offset;
        U8_NEXT(str, offset, size, codepoint);
    }
    
    if (codepoint == -1) {
        // Check to see if the last byte is valid or whether it was just continuing
        if (!U8_IS_LEAD(str[lastOffset]) || U8_COUNT_TRAIL_BYTES(str[lastOffset]) + lastOffset < (int32_t)size) {
            
            size = -1;
        } else {
            uint8_t leadByte = str[lastOffset];
            U8_MASK_LEAD_BYTE(leadByte, U8_COUNT_TRAIL_BYTES(leadByte));

            for (int i = lastOffset + 1; i < offset; i++) {
                
                if (U8_IS_SINGLE(str[i]) || U8_IS_LEAD(str[i]) || !U8_IS_TRAIL(str[i])) {
                    size = -1;
                }
            }
                 
            if (size != -1) {
                size = lastOffset;
            }
        }
    }

    if (size != -1 && ![[NSString alloc] initWithBytesNoCopy:(char *)[data bytes] length:size encoding:NSUTF8StringEncoding freeWhenDone:NO]) {
        size = -1;
    }
    
    return size;
}


@interface NSData (SRWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;

@end


@interface NSString (SRWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;

@end


static NSString *newSHA1String(const char *bytes, size_t length) {
    uint8_t md[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(bytes, length, md);
    
    size_t buffer_size = ((sizeof(md) * 3 + 2) / 2);
    
    char *buffer =  (char *)malloc(buffer_size);
    
    int len = b64_ntop(md, CC_SHA1_DIGEST_LENGTH, buffer, buffer_size);
    if (len == -1) {
        free(buffer);
        return nil;
    } else{
        return [[NSString alloc] initWithBytesNoCopy:buffer length:len encoding:NSASCIIStringEncoding freeWhenDone:YES];
    }
}

@implementation NSData (SRWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;
{
    return newSHA1String(self.bytes, self.length);
}

@end


@implementation NSString (SRWebSocket)

- (NSString *)stringBySHA1ThenBase64Encoding;
{
    return newSHA1String(self.UTF8String, self.length);
}

@end

NSString *const SRWebSocketErrorDomain = @"SRWebSocketErrorDomain";

// Returns number of bytes consumed. returning 0 means you didn't match.
// Sends bytes to callback handler;
typedef size_t (^stream_scanner)(NSData *collected_data);

typedef void (^data_callback)(SRWebSocket *webSocket,  NSData *data);

@interface SRIOConsumer : NSObject {
    stream_scanner _scanner;
    data_callback _handler;
    size_t _bytesNeeded;
    BOOL _readToCurrentFrame;
    BOOL _unmaskBytes;
}

- (id)initWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;

@property (nonatomic, copy, readonly) stream_scanner consumer;
@property (nonatomic, copy, readonly) data_callback handler;
@property (nonatomic, assign) size_t bytesNeeded;
@property (nonatomic, assign, readonly) BOOL readToCurrentFrame;
@property (nonatomic, assign, readonly) BOOL unmaskBytes;

@end


@interface SRMessage : NSObject
@property (nonatomic,retain) id data;
@property (nonatomic,retain) id userData;
@property (nonatomic,retain) NSData* framedData;
@property (nonatomic,assign) NSInteger writeOffset;
@property (nonatomic,copy) SRWebSocketCompletionBlock completionBlock;

- (void)sendInStream:(NSOutputStream*)outputStream error:(NSError**)error;
- (BOOL)isSentCompletely;

@end

@implementation SRMessage
@synthesize data = _data;
@synthesize userData = _userData;
@synthesize framedData = _framedData;
@synthesize writeOffset = _writeOffset;
@synthesize completionBlock = _completionBlock;

- (void)dealloc{
    [_data release];
    [_framedData release];
    [_completionBlock release];
    [_userData release];
    [super dealloc];
}

- (id)init{
    self = [super init];
    _writeOffset = 0;
    return self;
}

- (void)sendInStream:(NSOutputStream*)outputStream error:(NSError**)error{
    NSUInteger bytesWritten = [outputStream write:_framedData.bytes + _writeOffset maxLength:_framedData.length - _writeOffset];
    if (bytesWritten == -1) {
        *error = [NSError errorWithDomain:@"org.lolrus.SocketRocket" code:2145 userInfo:[NSDictionary dictionaryWithObject:@"Error writing to stream" forKey:NSLocalizedDescriptionKey]];
    }
    else{
        _writeOffset += bytesWritten;
    }
}

- (BOOL)isSentCompletely{
    return (_writeOffset == _framedData.length);
}

@end



@interface SRWebSocket ()  <NSStreamDelegate>

- (void)_writeMessage:(SRMessage *)message;
- (void)_closeWithProtocolError:(NSString *)message;
- (void)_failWithError:(NSError *)error;

- (void)_disconnect;

- (void)_readFrameNew;
- (void)_readFrameContinue;

- (void)_pumpScanner;

- (void)_pumpWriting;

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;

- (void)_sendFrameWithOpcode:(SROpCode)opcode data:(id)data  userData:userData completionBlock:(void(^)(SRWebSocket* socket, id data, id userData))completionBlock;

- (BOOL)_checkHandshake:(CFHTTPMessageRef)httpMessage;
- (void)_SR_commonInit;

- (void)_connectToHost:(NSString *)host port:(NSInteger)port;

@property (nonatomic) SRReadyState readyState;

@end


@implementation SRWebSocket {
    NSInteger _webSocketVersion;
    dispatch_queue_t _callbackQueue;
    dispatch_queue_t _workQueue;
    NSMutableArray *_consumers;

    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;
   
    NSMutableData *_readBuffer;
    NSInteger _readBufferOffset;
 
    /*
    NSMutableData *_outputBuffer;
    NSInteger _outputBufferOffset;
     */
    NSMutableArray* _outputMessageQueue;

    uint8_t _currentFrameOpcode;
    size_t _currentFrameCount;
    size_t _readOpCount;
    uint32_t _currentStringScanPosition;
    NSMutableData *_currentFrameData;
    
    NSString *_closeReason;
    
    NSString *_secKey;
    
    uint8_t _currentReadMaskKey[4];
    size_t _currentReadMaskOffset;

    BOOL _consumerStopped;
    
    BOOL _closeWhenFinishedWriting;
    BOOL _failed;

    BOOL _secure;
    NSURLRequest *_urlRequest;

    __attribute__((NSObject)) CFHTTPMessageRef _receivedHTTPHeaders;
    
    BOOL _sentClose;
    BOOL _didFail;
    int _closeCode;
}

@synthesize delegate = _delegate;
@synthesize url = _url;
@synthesize readyState = _readyState;

static __strong NSData *CRLFCRLF;

+ (void)initialize;
{
    CRLFCRLF = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
}

- (id)initWithURLRequest:(NSURLRequest *)request;
{
    self = [super init];
    if (self) {
        
        assert(request.URL);
        _url = request.URL;
        NSString *scheme = [_url scheme];
        
        assert([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]);
        _urlRequest = request;
        
        if ([scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]) {
            _secure = YES;
        }
        
        [self _SR_commonInit];
    }
    
    return self;
}

- (void)_SR_commonInit;
{
    _readyState = SR_CONNECTING;

    _consumerStopped = YES;
    
    _webSocketVersion = 13;
    
    _workQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    
    _callbackQueue = dispatch_get_main_queue();
    dispatch_retain(_callbackQueue);
    
    _readBuffer = [[NSMutableData alloc] init];
    
    /*
    _outputBuffer = [[NSMutableData alloc] init];
     */
    _outputMessageQueue = [[NSMutableArray alloc]init];
    
    _currentFrameData = [[NSMutableData alloc] init];

    _consumers = [[NSMutableArray alloc] init];
    
    // default handlers
}

- (void)dealloc
{
    if(_inputStream && _inputStream.streamStatus == NSStreamEventOpenCompleted){
        [_inputStream close];
        [_inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        _inputStream.delegate = nil;
    }
    [_inputStream release];
    
    if(_outputStream && _outputStream.streamStatus == NSStreamEventOpenCompleted){
        [_outputStream close];
        [_outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        _outputStream.delegate = nil;
    }
    [_outputStream release];
    [_outputMessageQueue release];
    [_currentFrameData release];
    [_consumers release];
    [_readBuffer release];
    
    dispatch_release(_callbackQueue);
    dispatch_release(_workQueue);
    
    [super dealloc];
}

#ifndef NDEBUG

- (void)setReadyState:(SRReadyState)aReadyState;
{
    [self willChangeValueForKey:@"readyState"];
    assert(aReadyState > _readyState);
    _readyState = aReadyState;
    [self didChangeValueForKey:@"readyState"];
}

#endif

- (void)open;
{
    assert(_url);
    NSAssert(_readyState == SR_CONNECTING && _inputStream == nil && _outputStream == nil, @"Cannot call open a connection more than once");

    NSInteger port = _url.port.integerValue;
    if (port == 0) {
        if (!_secure) {
            port = 80;
        } else {
            port = 443;
        }
    }

    [self _connectToHost:_url.host port:port];
}



- (BOOL)_checkHandshake:(CFHTTPMessageRef)httpMessage;
{
    NSString *acceptHeader = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(httpMessage, CFSTR("Sec-WebSocket-Accept")));

    if (acceptHeader == nil) {
        return NO;
    }
    
    NSString *concattedString = [_secKey stringByAppendingString:SRWebSocketAppendToSecKeyString];
    NSString *expectedAccept = [concattedString stringBySHA1ThenBase64Encoding];
    
    return [acceptHeader isEqualToString:expectedAccept];
}

- (void)_HTTPHeadersDidFinish;
{
    NSInteger responseCode = CFHTTPMessageGetResponseStatusCode(_receivedHTTPHeaders);
    
    if (responseCode >= 400) {
        SRFastLog(@"Request failed with response code %d", responseCode);
        [self _failWithError:[NSError errorWithDomain:@"org.lolrus.SocketRocket" code:2132 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"received bad response code from server %d", responseCode] forKey:NSLocalizedDescriptionKey]]];
        return;

    }
    
    if(![self _checkHandshake:_receivedHTTPHeaders]) {
        [self _failWithError:[NSError errorWithDomain:SRWebSocketErrorDomain code:2133 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Invalid Sec-WebSocket-Accept response"] forKey:NSLocalizedDescriptionKey]]];
        return;
    }
    
    self.readyState = SR_OPEN;
    
    if (!_didFail) {
        [self _readFrameNew];
    }

    __block SRWebSocket* bself = self;
    dispatch_async(_callbackQueue, ^{
        if ([bself.delegate respondsToSelector:@selector(webSocketDidOpen:)]) {
            [bself.delegate webSocketDidOpen:bself];
        }
    });
}


- (void)_readHTTPHeader;
{
    if (_receivedHTTPHeaders == NULL) {
        _receivedHTTPHeaders = CFHTTPMessageCreateEmpty(NULL, NO);
    }
                        
    [self _readUntilHeaderCompleteWithCallback:^(SRWebSocket *socket,  NSData *data) {
        CFHTTPMessageAppendBytes(socket->_receivedHTTPHeaders, (const UInt8 *)data.bytes, data.length);
        
        if (CFHTTPMessageIsHeaderComplete(socket->_receivedHTTPHeaders)) {
            SRFastLog(@"Finished reading headers %@", CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(socket->_receivedHTTPHeaders)));
            [socket _HTTPHeadersDidFinish];
        } else {
            [socket _readHTTPHeader];
        }
    }];
}

- (void)didConnect
{
    SRFastLog(@"Connected");
    CFHTTPMessageRef request = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
    
    // Set host first so it defaults
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Host"), (__bridge CFStringRef)(_url.port ? [NSString stringWithFormat:@"%@:%@", _url.host, _url.port] : _url.host));
    
    [_urlRequest.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        CFHTTPMessageSetHeaderFieldValue(request, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
    }];
    
    
    NSMutableData *keyBytes = [[NSMutableData alloc] initWithLength:16];
    SecRandomCopyBytes(kSecRandomDefault, keyBytes.length, keyBytes.mutableBytes);
    _secKey = [keyBytes SR_stringByBase64Encoding];
    assert([_secKey length] == 24);
    
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Upgrade"), CFSTR("websocket"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Connection"), CFSTR("Upgrade"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Key"), (__bridge CFStringRef)_secKey);
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Version"), (__bridge CFStringRef)[NSString stringWithFormat:@"%d", _webSocketVersion]);
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Origin"), (__bridge CFStringRef)_url.absoluteString);
    
    NSData *messageData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(request));
    
    CFRelease(request);
    
    SRMessage* message = [[[SRMessage alloc]init]autorelease];
    message.data = messageData;
    message.framedData = messageData;
    message.completionBlock = nil;

    [self _writeMessage:message];
    [self _readHTTPHeader];
}

- (void)_connectToHost:(NSString *)host port:(NSInteger)port;
{    
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &readStream, &writeStream);
    
    _outputStream = CFBridgingRelease(writeStream);
    _inputStream = CFBridgingRelease(readStream);
    
    if (_secure) {
        [_outputStream setProperty:(__bridge id)kCFStreamSocketSecurityLevelNegotiatedSSL forKey:(__bridge id)kCFStreamPropertySocketSecurityLevel];
        #if DEBUG
        NSLog(@"SocketRocket: In debug mode.  Allowing connection to any root cert");
        [_outputStream setProperty:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] 
                                                               forKey:(__bridge id)kCFStreamSSLAllowsAnyRoot]
                            forKey:(__bridge id)kCFStreamPropertySSLSettings];
        #endif
    }
    
    _inputStream.delegate = self;
    _outputStream.delegate = self;
    
    // TODO schedule in a better run loop
    [_outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
    
    [_outputStream open];
    [_inputStream open];
}

- (void)close;
{
    [self closeWithCode:-1 reason:nil];
}

- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason;
{
    assert(code);
    if (self.readyState == SR_CLOSING || self.readyState == SR_CLOSED) {
        return;
    }
    
    BOOL wasConnecting = self.readyState == SR_CONNECTING;

    self.readyState = SR_CLOSING;

    SRFastLog(@"Closing with code %d reason %@", code, reason);
    
    __block SRWebSocket* bself = self;
    dispatch_async(_workQueue, ^{
        if (wasConnecting) {
            [bself _disconnect];
            return;
        }

        size_t maxMsgSize = [reason maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *mutablePayload = [[NSMutableData alloc] initWithLength:sizeof(uint16_t) + maxMsgSize];
        NSData *payload = mutablePayload;
        
        ((uint16_t *)mutablePayload.mutableBytes)[0] = EndianU16_BtoN(code);
        
        if (reason) {
            NSRange remainingRange = {0};
            
            NSUInteger usedLength = 0;
            
            BOOL success = [reason getBytes:(char *)mutablePayload.mutableBytes + sizeof(uint16_t) maxLength:payload.length - sizeof(uint16_t) usedLength:&usedLength encoding:NSUTF8StringEncoding options:NSStringEncodingConversionExternalRepresentation range:NSMakeRange(0, reason.length) remainingRange:&remainingRange];
            
            assert(success);
            assert(remainingRange.length == 0);

            if (usedLength != maxMsgSize) {
                payload = [payload subdataWithRange:NSMakeRange(0, usedLength + sizeof(uint16_t))];
            }
        }
        
        
        [bself _sendFrameWithOpcode:SROpCodeConnectionClose data:payload userData:nil completionBlock:nil];
    });
}

- (void)_closeWithProtocolError:(NSString *)message;
{
    __block SRWebSocket* bself = self;
    // Need to shunt this on the _callbackQueue first to see if they received any messages 
    dispatch_async(_callbackQueue, ^{
        [bself closeWithCode:SRStatusCodeProtocolError reason:message];
        dispatch_async(_workQueue, ^{
            [bself _disconnect];
        });
    });
}

- (void)_failWithError:(NSError *)error;
{
    __block SRWebSocket* bself = self;
    //dispatching here is dangerous as the socket should be deallocated asap to clear dispatch queues !
    //dispatch_async(_workQueue, ^{
        if (bself.readyState != SR_CLOSED) {
            bself->_failed = YES;
            
            if ([bself.delegate respondsToSelector:@selector(webSocket:didFailWithError:)]) {
                [bself.delegate webSocket:bself didFailWithError:error];
            }

            bself.readyState = SR_CLOSED;

            SRFastLog(@"Failing with error %@", error.localizedDescription);
            
            [bself _disconnect]; //here we explicitly retain the socket to let time to disconnect before beiing deallocated avoiding multi-threading issues.!
        }
    //});
}

- (void)_writeMessage:(SRMessage*)message
{    
    assert(dispatch_get_current_queue() == _workQueue);

    if (_closeWhenFinishedWriting) {
            return;
    }
    
    @synchronized(_outputMessageQueue){
        [_outputMessageQueue addObject:message];
    }
    
//    [_outputBuffer appendData:data];
    [self _pumpWriting];
}

- (void)send:(id)data userData:(id)userData completionBlock:(void(^)(SRWebSocket* socket, id data, id userData))completionBlock;
{
    __block SRWebSocket* bself = self;
    NSAssert(self.readyState == SR_OPEN, @"Invalid State: Cannot call send: until connection is open");
    // TODO: maybe not copy this for performance
    data = [data copy];
    dispatch_async(_workQueue, ^{
        if ([data isKindOfClass:[NSString class]]) {
            [bself _sendFrameWithOpcode:SROpCodeTextFrame data:[(NSString *)data dataUsingEncoding:NSUTF8StringEncoding] userData:userData completionBlock:completionBlock];
        } else if ([data isKindOfClass:[NSData class]]) {
            [bself _sendFrameWithOpcode:SROpCodeBinaryFrame data:data userData:userData completionBlock:completionBlock];
        } else if (data == nil) {
            [bself _sendFrameWithOpcode:SROpCodeTextFrame data:data userData:userData completionBlock:completionBlock];
        } else {
            assert(NO);
        }
    });
}

- (void)handlePing:(NSData *)pingData;
{
    __block SRWebSocket* bself = self;
    // Need to pingpong this off _callbackQueue first to make sure messages happen in order
    dispatch_async(_callbackQueue, ^{
        dispatch_async(_workQueue, ^{
            [bself _sendFrameWithOpcode:SROpCodePong data:pingData userData:nil  completionBlock:nil];
        });
    });
}

- (void)handlePong;
{
    // NOOP
}

- (void)_handleMessage:(id)message
{
    __block SRWebSocket* bself = self;
    dispatch_async(_callbackQueue, ^{
        [bself.delegate webSocket:bself didReceiveMessage:message];
    });
}


static inline BOOL closeCodeIsValid(int closeCode) {
    if (closeCode < 1000) {
        return NO;
    }
    
    if (closeCode >= 1000 && closeCode <= 1011) {
        if (closeCode == 1004 ||
            closeCode == 1005 ||
            closeCode == 1006) {
            return NO;
        }
        return YES;
    }
    
    if (closeCode >= 3000 && closeCode <= 3999) {
        return YES;
    }
    
    if (closeCode >= 4000 && closeCode <= 4999) {
        return YES;
    }

    return NO;
}

//  Note from RFC:
//
//  If there is a body, the first two
//  bytes of the body MUST be a 2-byte unsigned integer (in network byte
//  order) representing a status code with value /code/ defined in
//  Section 7.4.  Following the 2-byte integer the body MAY contain UTF-8
//  encoded data with value /reason/, the interpretation of which is not
//  defined by this specification.

- (void)handleCloseWithData:(NSData *)data;
{
    size_t dataSize = data.length;
    __block uint16_t closeCode = 0;
    
    SRFastLog(@"Received close frame");
    
    if (dataSize == 1) {
        // TODO handle error
        [self _closeWithProtocolError:@"Payload for close must be larger than 2 bytes"];
        return;
    } else if (dataSize >= 2) {
        [data getBytes:&closeCode length:sizeof(closeCode)];
        _closeCode = EndianU16_BtoN(closeCode);
        if (!closeCodeIsValid(_closeCode)) {
            [self _closeWithProtocolError:[NSString stringWithFormat:@"Cannot have close code of %d", _closeCode]];
            return;
        }
        if (dataSize > 2) {
            _closeReason = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, dataSize - 2)] encoding:NSUTF8StringEncoding];
            if (!_closeReason) {
                [self _closeWithProtocolError:@"Close reason MUST be valid UTF-8"];
                return;
            }
        }
    } else {
        _closeCode = SRStatusNoStatusReceived;
    }
    
    assert(dispatch_get_current_queue() == _workQueue);
    
    if (self.readyState == SR_OPEN) {
        [self closeWithCode:1000 reason:nil];
    }
    
    __block SRWebSocket* bself = self;
    dispatch_async(_workQueue, ^{
        [bself _disconnect];
    });
}

- (void)_disconnect;
{
    assert(dispatch_get_current_queue() == _workQueue);
    SRFastLog(@"Trying to disconnect");
    _closeWhenFinishedWriting = YES;
    [self _pumpWriting];
}

- (void)_handleFrameWithData:(NSData *)frameData opCode:(NSInteger)opcode;
{                
    // Check that the current data is valid UTF8
    
    BOOL isControlFrame = (opcode == SROpCodePing || opcode == SROpCodePong || opcode == SROpCodeConnectionClose);
    if (!isControlFrame) {
        [self _readFrameNew];
    } else {
        __block SRWebSocket* bself = self;
        dispatch_async(_workQueue, ^{
            [bself _readFrameContinue];
        });
    }
    
    __block SRWebSocket* bself = self;
    switch (opcode) {
        case SROpCodeTextFrame: {
            NSString *str = [[NSString alloc] initWithData:frameData encoding:NSUTF8StringEncoding];
            if (str == nil && frameData) {
                [self closeWithCode:SRStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                dispatch_async(_workQueue, ^{
                    [bself _disconnect];
                });

                return;
            }
            [self _handleMessage:str];
            break;
        }
        case SROpCodeBinaryFrame:
            [self _handleMessage:[frameData copy]];
            break;
        case SROpCodeConnectionClose:
            [self handleCloseWithData:frameData];
            break;
        case SROpCodePing:
            [self handlePing:frameData];
            break;
        case SROpCodePong:
            [self handlePong];
            break;
        default:
            [self _closeWithProtocolError:[NSString stringWithFormat:@"Unknown opcode %d", opcode]];
            // TODO: Handle invalid opcode
            break;
    }
}

- (void)_handleFrameHeader:(frame_header)frame_header curData:(NSData *)curData;
{
    assert(frame_header.opcode != 0);
    
    if (self.readyState != SR_OPEN) {
        return;
    }
    
    
    BOOL isControlFrame = (frame_header.opcode == SROpCodePing || frame_header.opcode == SROpCodePong || frame_header.opcode == SROpCodeConnectionClose);
    
    if (isControlFrame && !frame_header.fin) {
        [self _closeWithProtocolError:@"Fragmented control frames not allowed"];
        return;
    }
    
    if (isControlFrame && frame_header.payload_length >= 126) {
        [self _closeWithProtocolError:@"Control frames cannot have payloads larger than 126 bytes"];
        return;
    }
    
    if (!isControlFrame) {
        _currentFrameOpcode = frame_header.opcode;
        _currentFrameCount += 1;
    }
    
    if (frame_header.payload_length == 0) {
        if (isControlFrame) {
            [self _handleFrameWithData:curData opCode:frame_header.opcode];
        } else {
            if (frame_header.fin) {
                [self _handleFrameWithData:_currentFrameData opCode:frame_header.opcode];
            } else {
                // TODO add assert that opcode is not a control;
                [self _readFrameContinue];
            }
        }
    } else {
        [self _addConsumerWithDataLength:frame_header.payload_length callback:^(SRWebSocket *socket, NSData *newData) {
            if (isControlFrame) {
                [socket _handleFrameWithData:newData opCode:frame_header.opcode];
            } else {
                if (frame_header.fin) {
                    [socket _handleFrameWithData:socket->_currentFrameData opCode:frame_header.opcode];
                } else {
                    // TODO add assert that opcode is not a control;
                    [socket _readFrameContinue];
                }
                
            }
        } readToCurrentFrame:!isControlFrame unmaskBytes:frame_header.masked];
    }
}

/* From RFC:

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-------+-+-------------+-------------------------------+
 |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
 |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
 |N|V|V|V|       |S|             |   (if payload len==126/127)   |
 | |1|2|3|       |K|             |                               |
 +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
 |     Extended payload length continued, if payload len == 127  |
 + - - - - - - - - - - - - - - - +-------------------------------+
 |                               |Masking-key, if MASK set to 1  |
 +-------------------------------+-------------------------------+
 | Masking-key (continued)       |          Payload Data         |
 +-------------------------------- - - - - - - - - - - - - - - - +
 :                     Payload Data continued ...                :
 + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
 |                     Payload Data continued ...                |
 +---------------------------------------------------------------+
 */

static const uint8_t SRFinMask          = 0x80;
static const uint8_t SROpCodeMask       = 0x0F;
static const uint8_t SRRsvMask          = 0x70;
static const uint8_t SRMaskMask         = 0x80;
static const uint8_t SRPayloadLenMask   = 0x7F;


- (void)_readFrameContinue;
{
    assert((_currentFrameCount == 0 && _currentFrameOpcode == 0) || (_currentFrameCount > 0 && _currentFrameOpcode > 0));

    [self _addConsumerWithDataLength:2 callback:^(SRWebSocket *socket, NSData *data) {
        __block frame_header header = {0};
        
        const uint8_t *headerBuffer = data.bytes;
        assert(data.length >= 2);
        
        if (headerBuffer[0] & SRRsvMask) {
            [socket _closeWithProtocolError:@"Server used RSV bits"];
            return;
        }
        
        uint8_t receivedOpcode = (SROpCodeMask & headerBuffer[0]);
        
        BOOL isControlFrame = (receivedOpcode == SROpCodePing || receivedOpcode == SROpCodePong || receivedOpcode == SROpCodeConnectionClose);
        
        if (!isControlFrame && receivedOpcode != 0 && socket->_currentFrameCount > 0) {
            [socket _closeWithProtocolError:@"all data frames after the initial data frame must have opcode 0"];
            return;
        }
        
        if (receivedOpcode == 0 && socket->_currentFrameCount == 0) {
            [socket _closeWithProtocolError:@"cannot continue a message"];
            return;
        }
        
        header.opcode = receivedOpcode == 0 ? socket->_currentFrameOpcode : receivedOpcode;
        
        header.fin = !!(SRFinMask & headerBuffer[0]);
        
        
        header.masked = !!(SRMaskMask & headerBuffer[1]);
        header.payload_length = SRPayloadLenMask & headerBuffer[1];
        
        headerBuffer = NULL;
        
        if (header.masked) {
            [socket _closeWithProtocolError:@"Client must receive unmasked data"];
        }
        
        size_t extra_bytes_needed = header.masked ? sizeof(socket->_currentReadMaskKey) : 0;
        
        if (header.payload_length == 126) {
            extra_bytes_needed += sizeof(uint16_t);
        } else if (header.payload_length == 127) {
            extra_bytes_needed += sizeof(uint64_t);
        }
        
        if (extra_bytes_needed == 0) {
            [socket _handleFrameHeader:header curData:socket->_currentFrameData];
        } else {
            [socket _addConsumerWithDataLength:extra_bytes_needed callback:^(SRWebSocket *socket, NSData *data) {
                size_t mapped_size = data.length;
                const void *mapped_buffer = data.bytes;
                size_t offset = 0;
                
                if (header.payload_length == 126) {
                    assert(mapped_size >= sizeof(uint16_t));
                    uint16_t newLen = EndianU16_BtoN(*(uint16_t *)(mapped_buffer));
                    header.payload_length = newLen;
                    offset += sizeof(uint16_t);
                } else if (header.payload_length == 127) {
                    assert(mapped_size >= sizeof(uint64_t));
                    header.payload_length = EndianU64_BtoN(*(uint64_t *)(mapped_buffer));
                    offset += sizeof(uint64_t);
                } else {
                    assert(header.payload_length < 126 && header.payload_length >= 0);
                }
                
                
                if (header.masked) {
                    assert(mapped_size >= sizeof(socket->_currentReadMaskOffset) + offset);
                    memcpy(socket->_currentReadMaskKey, ((uint8_t *)mapped_buffer) + offset, sizeof(socket->_currentReadMaskKey));
                }
                
                [socket _handleFrameHeader:header curData:socket->_currentFrameData];
            } readToCurrentFrame:NO unmaskBytes:NO];
        }
    } readToCurrentFrame:NO unmaskBytes:NO];
}

- (void)_readFrameNew;
{
    __block SRWebSocket* bself = self;
    dispatch_async(_workQueue, ^{
        [bself->_currentFrameData setLength:0];
        
        bself->_currentFrameOpcode = 0;
        bself->_currentFrameCount = 0;
        bself->_readOpCount = 0;
        bself->_currentStringScanPosition = 0;
        
        [bself _readFrameContinue];
    });
}

- (void)_pumpWriting;
{
    assert(dispatch_get_current_queue() == _workQueue);
    
    @synchronized(_outputMessageQueue){
        NSError* error = nil;
        while(_outputStream.hasSpaceAvailable && [_outputMessageQueue count] > 0 && !error){
            SRMessage* message = [_outputMessageQueue objectAtIndex:0];
            
            [message sendInStream:_outputStream error:&error];
            if(error){
                [self _failWithError:error];
            }else{
                if([message isSentCompletely]){
                    if(message.completionBlock){
                        message.completionBlock(self,message.data, message.userData);
                    }
                    [_outputMessageQueue removeObjectAtIndex:0];
                }
            }
        }
    }
    
    if (_closeWhenFinishedWriting && 
        (_inputStream.streamStatus != NSStreamStatusNotOpen &&
         _inputStream.streamStatus != NSStreamStatusClosed)){
            
            [_inputStream close];
            [_inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            _inputStream = nil;
        }
    
    if (_closeWhenFinishedWriting && 
        /*_outputBuffer.length - _outputBufferOffset == 0 && */
        (_outputStream.streamStatus != NSStreamStatusNotOpen &&
         _outputStream.streamStatus != NSStreamStatusClosed) &&
        !_sentClose) {
        _sentClose = YES;
        
        
        dispatch_release(_callbackQueue);
        dispatch_release(_workQueue);
        
        _callbackQueue = nil;
        _workQueue = nil;
        
        [_outputStream close];
        [_outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        _outputStream = nil;
        
        __block SRWebSocket* bself = self;
        if (!_failed) {
            if ([bself.delegate respondsToSelector:@selector(webSocket:didCloseWithCode:reason:wasClean:)]) {
                [bself.delegate webSocket:bself didCloseWithCode:_closeCode reason:_closeReason wasClean:YES];
            }
        }
    }
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
{
    [self _addConsumerWithScanner:consumer callback:callback dataLength:0];
}

- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{   
    assert(dataLength);
    
    __block SRWebSocket* bself = self;
    dispatch_async(_workQueue, ^{
        [bself->_consumers addObject:[[SRIOConsumer alloc] initWithScanner:nil handler:callback bytesNeeded:dataLength readToCurrentFrame:readToCurrentFrame unmaskBytes:unmaskBytes]];
        [bself _pumpScanner];
    });
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
{    
    __block SRWebSocket* bself = self;
    dispatch_async(_workQueue, ^{
        [bself->_consumers addObject:[[SRIOConsumer alloc] initWithScanner:consumer handler:callback bytesNeeded:dataLength readToCurrentFrame:NO unmaskBytes:NO]];
        [bself _pumpScanner];
    });
}

     
static const char CRLFCRLFBytes[] = {'\r', '\n', '\r', '\n'};

- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;
{
    [self _readUntilBytes:CRLFCRLFBytes length:sizeof(CRLFCRLFBytes) callback:dataHandler];
}

- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
{
    __block SRWebSocket* bself = self;
    // TODO optimize so this can continue from where we last searched
    stream_scanner consumer = ^size_t(NSData *data) {
        __block size_t found_size = 0;
        __block size_t match_count = 0;
        
        size_t size = data.length;
        const unsigned char *buffer = data.bytes;
        for (int i = 0; i < size; i++ ) {
            if (((const unsigned char *)buffer)[i] == ((const unsigned char *)bytes)[match_count]) {
                match_count += 1;
                if (match_count == length) {
                    found_size = i + 1;
                    break;
                }
            } else {
                match_count = 0;
            }
        }
        return found_size;
    };
    [bself _addConsumerWithScanner:consumer callback:dataHandler];
}

-(void)_pumpScanner;
{
    assert(dispatch_get_current_queue() == _workQueue);

    if (self.readyState >= SR_CLOSING) {
        return;
    }
    
    if (!_consumers.count) {
        return;
    }
    
    size_t curSize = _readBuffer.length - _readBufferOffset;
    if (!curSize) {
        return;
    }

    SRIOConsumer *consumer = [_consumers objectAtIndex:0];
    
    size_t bytesNeeded = consumer.bytesNeeded;
   
    size_t foundSize = 0;
    if (consumer.consumer) {
        NSData *tempView = [NSData dataWithBytesNoCopy:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset freeWhenDone:NO];  
        foundSize = consumer.consumer(tempView);
    } else {
        assert(consumer.bytesNeeded);
        if (curSize >= bytesNeeded) {
            foundSize = bytesNeeded;
        } else if (consumer.readToCurrentFrame) {
            foundSize = curSize;
        }
    }
    
    __block SRWebSocket* bself = self;
    
    NSData *slice = nil;
    if (consumer.readToCurrentFrame || foundSize) {
        NSRange sliceRange = NSMakeRange(_readBufferOffset, foundSize);
        slice = [_readBuffer subdataWithRange:sliceRange];
        
        _readBufferOffset += foundSize;

        if (_readBufferOffset > 4096 && _readBufferOffset > (_readBuffer.length >> 1)) {
            _readBuffer = [[NSMutableData alloc] initWithBytes:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset];            _readBufferOffset = 0;
        }
        
        if (consumer.unmaskBytes) {
            NSMutableData *mutableSlice = [slice mutableCopy];
           
            NSUInteger len = mutableSlice.length;
            uint8_t *bytes = mutableSlice.mutableBytes;

            for (int i = 0; i < len; i++) {
                bytes[i] = bytes[i] ^ _currentReadMaskKey[_currentReadMaskOffset % sizeof(_currentReadMaskKey)];
                _currentReadMaskOffset += 1;
            }
            
            slice = mutableSlice;
        }

        if (consumer.readToCurrentFrame) {
            [_currentFrameData appendData:slice];
            
            _readOpCount += 1;

            if (_currentFrameOpcode == SROpCodeTextFrame) {
                // Validate UTF8 stuff.
                size_t currentDataSize = _currentFrameData.length;
                if (_currentFrameOpcode == SROpCodeTextFrame && currentDataSize > 0) {
                    // TODO: Optimize the crap out of this.  Don't really have to copy all the data each time
                    
                    size_t scanSize = currentDataSize - _currentStringScanPosition;
                    
                    NSData *scan_data = [_currentFrameData subdataWithRange:NSMakeRange(_currentStringScanPosition, scanSize)];
                    int32_t valid_utf8_size = validate_dispatch_data_partial_string(scan_data);
                    
                    if (valid_utf8_size == -1) {
                        [bself closeWithCode:SRStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                        dispatch_async(_workQueue, ^{
                            [bself _disconnect];
                        });
                        return;
                    } else {
                        _currentStringScanPosition += valid_utf8_size;
                    }
                } 

            }
            
            consumer.bytesNeeded -= foundSize;
            
            if (consumer.bytesNeeded == 0) {
                consumer.handler(bself, nil);
                [_consumers removeObjectAtIndex:0];
            }
        } else if (foundSize) {
            consumer.handler(bself, slice);
            [_consumers removeObjectAtIndex:0];
        }
        
        dispatch_async(_workQueue, ^{
            [bself _pumpScanner];
        });
    }
}

//#define NOMASK

static const size_t SRFrameHeaderOverhead = 32;

- (void)_sendFrameWithOpcode:(SROpCode)opcode data:(id)data userData:userData completionBlock:(void(^)(SRWebSocket* socket, id data, id usedData))completionBlock
{
    assert(dispatch_get_current_queue() == _workQueue);
    
    NSAssert(data == nil || [data isKindOfClass:[NSData class]] || [data isKindOfClass:[NSString class]], @"Function expects nil, NSString or NSData");
    
    size_t payloadLength = [data isKindOfClass:[NSString class]] ? [(NSString *)data lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : [data length];
        
    NSMutableData *frame = [[NSMutableData alloc] initWithLength:payloadLength + SRFrameHeaderOverhead];
    if (!frame) {
        [self closeWithCode:SRStatusCodeMessageTooBig reason:@"Message too big"];
        return;
    }
    uint8_t *frame_buffer = (uint8_t *)[frame mutableBytes];
    
    // set fin
    frame_buffer[0] = SRFinMask | opcode;
    
    BOOL useMask = YES;
#ifdef NOMASK
    useMask = NO;
#endif
    
    if (useMask) {
    // set the mask and header
        frame_buffer[1] |= SRMaskMask;
    }
    
    size_t frame_buffer_size = 2;
    
    const uint8_t *unmasked_payload = NULL;
    if ([data isKindOfClass:[NSData class]]) {
        unmasked_payload = (uint8_t *)[data bytes];
    } else if ([data isKindOfClass:[NSString class]]) {
        unmasked_payload =  (const uint8_t *)[data UTF8String];
    } else {
        assert(NO);
    }
    
    if (payloadLength < 126) {
        frame_buffer[1] |= payloadLength;
    } else if (payloadLength <= UINT16_MAX) {
        frame_buffer[1] |= 126;
        *((uint16_t *)(frame_buffer + frame_buffer_size)) = EndianU16_BtoN((uint16_t)payloadLength);
        frame_buffer_size += sizeof(uint16_t);
    } else {
        frame_buffer[1] |= 127;
        *((uint64_t *)(frame_buffer + frame_buffer_size)) = EndianU64_BtoN((uint64_t)payloadLength);
        frame_buffer_size += sizeof(uint64_t);
    }
        
    if (!useMask) {
        for (int i = 0; i < payloadLength; i++) {
            frame_buffer[frame_buffer_size] = unmasked_payload[i];
            frame_buffer_size += 1;
        }
    } else {
        uint8_t *mask_key = frame_buffer + frame_buffer_size;
        SecRandomCopyBytes(kSecRandomDefault, sizeof(uint32_t), (uint8_t *)mask_key);
        frame_buffer_size += sizeof(uint32_t);
        
        // TODO: could probably optimize this with SIMD
        for (int i = 0; i < payloadLength; i++) {
            frame_buffer[frame_buffer_size] = unmasked_payload[i] ^ mask_key[i % sizeof(uint32_t)];
            frame_buffer_size += 1;
        }
    }

    assert(frame_buffer_size <= [frame length]);
    frame.length = frame_buffer_size;
    
    
    SRMessage* message = [[[SRMessage alloc]init]autorelease];
    message.data = data;
    message.framedData = frame;
    message.completionBlock = completionBlock;
    message.userData = userData;
    [self _writeMessage:message];
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode;
{
    /*__block */ SRWebSocket* bself = self; //lets finish !
    //    SRFastLog(@"%@ Got stream event %d", aStream, eventCode);
    dispatch_async(_workQueue, ^{
        switch (eventCode) {
            case NSStreamEventOpenCompleted: {
                SRFastLog(@"NSStreamEventOpenCompleted %@", aStream);
                if (bself.readyState >= SR_CLOSING) {
                    return;
                }
                
                assert(bself->_readBuffer);
                
                if (bself.readyState == SR_CONNECTING && aStream == bself->_inputStream) {
                    [bself didConnect];
                }
                [bself _pumpWriting];
                [bself _pumpScanner];
                break;
            }
                
            case NSStreamEventErrorOccurred: {
                SRFastLog(@"NSStreamEventErrorOccurred %@ %@", aStream, [[aStream streamError] copy]);
                /// TODO specify error better!
                
                [bself _failWithError:aStream.streamError];
                bself->_readBufferOffset = 0;
                [bself->_readBuffer setLength:0];
                
                break;
                
            }
                
            case NSStreamEventEndEncountered: {
                SRFastLog(@"NSStreamEventEndEncountered %@", aStream);
                if (aStream.streamError) {
                    [bself _failWithError:aStream.streamError];
                } else {
                    if (bself.readyState != SR_CLOSED) {
                        bself.readyState = SR_CLOSED;
                    }

                    if (!bself->_sentClose && !bself->_failed) {
                        bself->_sentClose = YES;
                        // If we get closed in this state it's probably not clean because we should be sending this when we send messages
                        dispatch_async(bself->_callbackQueue, ^{
                            if ([bself.delegate respondsToSelector:@selector(webSocket:didCloseWithCode:reason:wasClean:)]) {
                                [bself.delegate webSocket:bself didCloseWithCode:0 reason:@"Stream end encountered" wasClean:NO];
                            }
                        });
                    }
                }
                
                break;
            }
                
            case NSStreamEventHasBytesAvailable: {
                SRFastLog(@"NSStreamEventHasBytesAvailable %@", aStream);
                const int bufferSize = 2048;
                uint8_t buffer[bufferSize];
                
                while (bself->_inputStream.hasBytesAvailable) {
                    int bytes_read = [bself->_inputStream read:buffer maxLength:bufferSize];
                    
                    if (bytes_read > 0) {
                        [bself->_readBuffer appendBytes:buffer length:bytes_read];
                    } else if (bytes_read < 0) {
                        [bself _failWithError:bself->_inputStream.streamError];
                    }
                    
                    if (bytes_read != bufferSize) {
                        break;
                    }
                };
                [bself _pumpScanner];
                break;
            }
                
            case NSStreamEventHasSpaceAvailable: {
                SRFastLog(@"NSStreamEventHasSpaceAvailable %@", aStream);
                [bself _pumpWriting];
                break;
            }
                
            default:
                SRFastLog(@"(default)  %@", aStream);
                break;
        }
    });

}

/*

- (void)CheckForBlockCopy{
    void *frames[128];
    int len = backtrace(frames, 128);
    char **symbols = backtrace_symbols(frames, len);
    for (int i = 0; i < len; ++i) {
        NSString* string = [NSString stringWithUTF8String:symbols[i]];
        NSRange range = [string rangeOfString:@"__copy_helper_block_"];
        if(range.location != NSNotFound){
            NSAssert(NO,@"You are retaining an object in a block copy !\nPlease define a variable with __block %@* bYourVar = yourVar; outside the scope of the block and use bYourVar in your block instead of yourVar.",[self class]);
        }
    }
    free(symbols);
}


- (id)retain{
    [self CheckForBlockCopy];
    return [super retain];
}
*/

@end


@implementation SRIOConsumer

@synthesize bytesNeeded = _bytesNeeded;
@synthesize consumer = _scanner;
@synthesize handler = _handler;
@synthesize readToCurrentFrame = _readToCurrentFrame;
@synthesize unmaskBytes = _unmaskBytes;

- (id)initWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{
    self = [super init];
    if (self) {
        _scanner = [scanner copy];
        _handler = [handler copy];
        _bytesNeeded = bytesNeeded;
        _readToCurrentFrame = readToCurrentFrame;
        _unmaskBytes = unmaskBytes;
        assert(_scanner || _bytesNeeded);
    }
    return self;
}

@end



