#ifdef SHOULD_COMPILE_LOOKIN_SERVER 

//
//  LookinServer.m
//  LookinServer
//
//  Created by Li Kai on 2018/8/5.
//  https://lookin.work
//

#import "LKS_ConnectionManager.h"
#import "Lookin_PTChannel.h"
#import "LKS_RequestHandler.h"
#import "LookinConnectionResponseAttachment.h"
#import "LKS_ExportManager.h"
#import "LookinServerDefines.h"
#import "LKS_TraceManager.h"
#import "LKS_MultiplatformAdapter.h"

NSString *const LKS_ConnectionDidEndNotificationName = @"LKS_ConnectionDidEndNotificationName";

@interface LKS_ConnectionManager () <Lookin_PTChannelDelegate>

@property(nonatomic, strong) Lookin_PTChannel *listeningChannel;
@property(nonatomic, strong) NSMutableSet<Lookin_PTChannel *> *connectedChannels;

@property(nonatomic, strong) LKS_RequestHandler *requestHandler;

@end

@implementation LKS_ConnectionManager

+ (instancetype)sharedInstance {
    static LKS_ConnectionManager *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[LKS_ConnectionManager alloc] init];
    });
    return sharedInstance;
}

+ (void)load {
    // 触发 init 方法
    [LKS_ConnectionManager sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        NSLog(@"LookinServer - Will launch. Framework version: %@", LOOKIN_SERVER_READABLE_VERSION);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleApplicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWillResignActiveNotification) name:UIApplicationWillResignActiveNotification object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleLocalInspect:) name:@"Lookin_2D" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleLocalInspect:) name:@"Lookin_3D" object:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"Lookin_Export" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [[LKS_ExportManager sharedInstance] exportAndShare];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"Lookin_RelationSearch" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [[LKS_TraceManager sharedInstance] addSearchTarger:note.object];
        }];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleGetLookinInfo:) name:@"GetLookinInfo" object:nil];
        
        self.connectedChannels = [NSMutableSet set];
        self.requestHandler = [LKS_RequestHandler new];
    }
    return self;
}

- (void)_handleWillResignActiveNotification {
    self.applicationIsActive = NO;
}

- (void)_handleApplicationDidBecomeActive {
    self.applicationIsActive = YES;
    [self searchPortToListenIfNoConnection];
}

- (void)searchPortToListenIfNoConnection {
    if ([self.listeningChannel isListening]) {
        NSLog(@"LookinServer - Abort to search ports. Already has listening channel.");
        return;
    }
    NSLog(@"LookinServer - Searching port to listen...");
    [self.listeningChannel close];
    self.listeningChannel = nil;
    
    if ([self isiOSAppOnMac]) {
        [self _tryToListenOnPortFrom:LookinSimulatorIPv4PortNumberStart to:LookinSimulatorIPv4PortNumberEnd current:LookinSimulatorIPv4PortNumberStart];
    } else {
        [self _tryToListenOnPortFrom:LookinUSBDeviceIPv4PortNumberStart to:LookinUSBDeviceIPv4PortNumberEnd current:LookinUSBDeviceIPv4PortNumberStart];
    }
}

- (BOOL)isiOSAppOnMac {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    if (@available(iOS 14.0, *)) {
        // isiOSAppOnMac 这个 API 看似在 iOS 14.0 上可用，但其实在 iOS 14 beta 上是不存在的、有 unrecognized selector 问题，因此这里要用 respondsToSelector 做一下保护
        NSProcessInfo *info = [NSProcessInfo processInfo];
        if ([info respondsToSelector:@selector(isiOSAppOnMac)] && [info isiOSAppOnMac]) {
            return YES;
        } else if ([info respondsToSelector:@selector(isMacCatalystApp)] && [info isMacCatalystApp]) {
            return YES;
        } else {
            return NO;
        }
    } else if (@available(iOS 13.0, tvOS 13.0, *)) {
        return [NSProcessInfo processInfo].isMacCatalystApp;
    }
    return NO;
#endif
}

- (void)_tryToListenOnPortFrom:(int)fromPort to:(int)toPort current:(int)currentPort  {
    Lookin_PTChannel *channel = [Lookin_PTChannel channelWithDelegate:self];
    channel.targetPort = currentPort;
    [channel listenOnPort:currentPort IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
        if (error) {
            if (error.code == 48) {
                // 该地址已被占用
            } else {
                // 未知失败
            }
            
            if (currentPort < toPort) {
                // 尝试下一个端口
                NSLog(@"LookinServer - 127.0.0.1:%d is unavailable(%@). Will try anothor address ...", currentPort, error);
                [self _tryToListenOnPortFrom:fromPort to:toPort current:(currentPort + 1)];
            } else {
                // 所有端口都尝试完毕，全部失败
                NSLog(@"LookinServer - 127.0.0.1:%d is unavailable(%@).", currentPort, error);
                NSLog(@"LookinServer - Connect failed in the end.");
            }
            
        } else {
            // 成功
            NSLog(@"LookinServer - Connected successfully on 127.0.0.1:%d", currentPort);
            self.listeningChannel = channel;
        }
    }];
}

- (void)dealloc {
    if (self.listeningChannel) {
        self.listeningChannel.delegate = nil;
        [self.listeningChannel close];
    }
    [self.connectedChannels enumerateObjectsUsingBlock:^(Lookin_PTChannel * _Nonnull obj, BOOL * _Nonnull stop) {
        obj.delegate = nil;
        [obj close];
    }];
    [self.connectedChannels removeAllObjects];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)respond:(LookinConnectionResponseAttachment *)data requestType:(uint32_t)requestType tag:(uint32_t)tag channel:(Lookin_PTChannel *)channel {
    data.appIsInBackground = !self.applicationIsActive;
    [self _sendData:data frameOfType:requestType tag:tag channel:channel];
}

- (void)pushData:(NSObject *)data type:(uint32_t)type {
    NSArray<Lookin_PTChannel *> *channels = self.connectedChannels.allObjects;
    [channels enumerateObjectsUsingBlock:^(Lookin_PTChannel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _sendData:data frameOfType:type tag:0 channel:obj];
    }];
}

- (void)_sendData:(NSObject *)data frameOfType:(uint32_t)frameOfType tag:(uint32_t)tag channel:(Lookin_PTChannel *)channel {
    if (!channel || ![self.connectedChannels containsObject:channel] || !channel.isConnected) {
        return;
    }

    NSData *archivedData = [NSKeyedArchiver archivedDataWithRootObject:data];
    dispatch_data_t payload = [archivedData createReferencingDispatchData];

    [channel sendFrameOfType:frameOfType tag:tag withPayload:payload callback:^(NSError *error) {
        if (error) {
        }
    }];
}

#pragma mark - Lookin_PTChannelDelegate

- (BOOL)ioFrameChannel:(Lookin_PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    if (![self.connectedChannels containsObject:channel]) {
        return NO;
    } else if ([self.requestHandler canHandleRequestType:type]) {
        return YES;
    } else {
        [channel close];
        return NO;
    }
}

- (void)ioFrameChannel:(Lookin_PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(Lookin_PTData*)payload {
    id object = nil;
    if (payload) {
        id unarchivedObject = [NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithContentsOfDispatchData:payload.dispatchData]];
        if ([unarchivedObject isKindOfClass:[LookinConnectionAttachment class]]) {
            LookinConnectionAttachment *attachment = (LookinConnectionAttachment *)unarchivedObject;
            object = attachment.data;
        } else {
            object = unarchivedObject;
        }
    }
    [self.requestHandler handleRequestType:type tag:tag object:object channel:channel];
}

/// 当 Client 端链接成功时，该方法会被调用，然后 channel 的状态会变成 connected
- (void)ioFrameChannel:(Lookin_PTChannel*)channel didAcceptConnection:(Lookin_PTChannel*)otherChannel fromAddress:(Lookin_PTAddress*)address {
    NSLog(@"LookinServer - channel:%@, acceptConnection:%@", channel.debugTag, otherChannel.debugTag);

    otherChannel.targetPort = address.port;
    [self.connectedChannels addObject:otherChannel];
}

/// 当连接过 Lookin 客户端，然后 Lookin 客户端又被关闭时，会走到这里
- (void)ioFrameChannel:(Lookin_PTChannel*)channel didEndWithError:(NSError*)error {
    if (self.listeningChannel == channel) {
        NSLog(@"LookinServer - listening channel%@ DidEndWithError:%@", channel.debugTag, error);
        self.listeningChannel = nil;
        [self searchPortToListenIfNoConnection];
        return;
    }

    if (![self.connectedChannels containsObject:channel]) {
        NSLog(@"LookinServer - Ignore channel%@ end.", channel.debugTag);
        return;
    }
    
    NSLog(@"LookinServer - channel%@ DidEndWithError:%@", channel.debugTag, error);
    [self.connectedChannels removeObject:channel];
    [self.requestHandler cancelRequestsForChannel:channel];
    channel.delegate = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:LKS_ConnectionDidEndNotificationName object:self userInfo:@{@"channel": channel}];
    [self searchPortToListenIfNoConnection];
}

#pragma mark - Handler

- (void)_handleLocalInspect:(NSNotification *)note {
    UIAlertController  *alertController = [UIAlertController  alertControllerWithTitle:@"Lookin" message:@"Failed to run local inspection. The feature has been removed. Please use the computer version of Lookin or consider SDKs like FLEX for similar functionality."  preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction  = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alertController addAction:okAction];
    UIWindow *keyWindow = [LKS_MultiplatformAdapter keyWindow];
    UIViewController *rootViewController = [keyWindow rootViewController];
    [rootViewController presentViewController:alertController animated:YES completion:nil];
    
    NSLog(@"LookinServer - Failed to run local inspection. The feature has been removed. Please use the computer version of Lookin or consider SDKs like FLEX for similar functionality.");
}

- (void)handleGetLookinInfo:(NSNotification *)note {
    NSDictionary* userInfo = note.userInfo;
    if (!userInfo) {
        return;
    }
    NSMutableDictionary* infoWrapper = userInfo[@"infos"];
    if (![infoWrapper isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"LookinServer - GetLookinInfo failed. Params invalid.");
        return;
    }
    infoWrapper[@"lookinServerVersion"] = LOOKIN_SERVER_READABLE_VERSION;
}

@end

/// 这个类使得用户可以通过 NSClassFromString(@"Lookin") 来判断 LookinServer 是否被编译进了项目里

@interface Lookin : NSObject

@end

@implementation Lookin

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
