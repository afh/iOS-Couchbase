//
//  EmptyAppDelegate.m
//  Couchbase Empty App
//
//  Created by Jens Alfke on 7/8/11.
//  Copyright 2011 CouchBase, Inc. All rights reserved.
//

#import "EmptyAppDelegate.h"

@implementation EmptyAppDelegate

@synthesize window = _window;
@synthesize serverURL = _serverURL;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Override point for customization after application launch.
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window makeKeyAndVisible];
    
    // Initialize CouchDB:
    CouchbaseEmbeddedServer* cb = [[CouchbaseEmbeddedServer alloc] init];
    cb.delegate = self;
    NSAssert([cb start], @"Couchbase couldn't start! Error = %@", cb.error);
    return YES;
}

// This is for testing only! In a real app you would not want to send URL requests synchronously.
- (void)send: (NSString*)method toPath: (NSString*)relativePath {
    NSLog(@"%@ %@", method, relativePath);
    NSURL* url = [NSURL URLWithString: relativePath relativeToURL: self.serverURL];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url];
    request.HTTPMethod = method;
    NSURLResponse* response = nil;
    NSError* error = nil;
    
    NSData* body = [NSURLConnection sendSynchronousRequest: request
                                         returningResponse: &response
                                                     error: &error];
    NSAssert(body != nil && response != nil,
             @"Request to <%@> failed: %@", url.absoluteString, error);
    int statusCode = ((NSHTTPURLResponse*)response).statusCode;
    NSAssert(statusCode < 300,
             @"Request to <%@> failed: HTTP error %i", url.absoluteString, statusCode);
    
    NSString* responseStr = [[NSString alloc] initWithData: body encoding: NSUTF8StringEncoding];
    NSLog(@"Response (%d):\n%@", statusCode, responseStr);
    [responseStr release];
}

- (void)couchbaseDidStart:(NSURL *)serverURL {
    NSAssert(serverURL != nil, @"Couchbase failed to initialize");
	NSLog(@"CouchDB is Ready, go!");
    self.serverURL = serverURL;
    
    [self send: @"GET" toPath: @"/"];
    
    NSLog(@"Everything works!");
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // In its current early state of development, Mobile Couchbase doesn't yet work properly when
    // returning to the foreground. To work around this, quit instead of backgrounding:
    exit(1);
}

@end
