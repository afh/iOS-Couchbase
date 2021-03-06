//
//  Couchbase.m
//  Couchbase Mobile
//
//  Created by J Chris Anderson on 3/2/11.
//  Copyright 2011 Couchbase, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

#import "CouchbaseEmbeddedServer.h"

#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>

// Erlang entry point
void erl_start(int, char**);


static const NSTimeInterval kWaitTimeout = 10.0;    // How long to wait for CouchDB to start


@interface CouchbaseEmbeddedServer ()
@property (readwrite, retain) NSURL* serverURL;
@property (readwrite, retain) NSError* error;
- (BOOL)createDir:(NSString*)dirName;
- (BOOL)installFileNamed:(NSString*)name fromDir:(NSString*)fromDir toDir:(NSString*)toDir;
- (BOOL)deleteFile:(NSString*)filename fromDir: (NSString*)fromDir;
- (BOOL)launchErlang;
@end


@implementation CouchbaseEmbeddedServer


+ (CouchbaseEmbeddedServer*) startCouchbase: (id<CouchbaseDelegate>)delegate {
    static CouchbaseEmbeddedServer* sCouchbase;
    NSAssert(!sCouchbase, @"+startCouchbase has already been called");

    sCouchbase = [[self alloc] init];
    sCouchbase.delegate = delegate;
    if (![sCouchbase start]) {
        [sCouchbase release];
        sCouchbase = nil;
    }
    return sCouchbase;
}


- (id) initWithBundlePath: (NSString*)bundlePath {
    NSParameterAssert(bundlePath);
    self = [super init];
    if (self) {
        _bundlePath = [bundlePath copy];
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask,
                                                             YES);
        _documentsDirectory = [[paths objectAtIndex:0] copy];
    }
    return self;
}


- (id)init {
    NSString* bundlePath = [[NSBundle mainBundle] pathForResource:@"CouchbaseResources" ofType:nil];
    NSAssert(bundlePath, @"Couldn't find CouchbaseResources bundle in app's Resources directory");
    return [self initWithBundlePath: bundlePath];
}


- (void)dealloc {
    [_documentsDirectory release];
    [_bundlePath release];
    [_serverURL release];
    [_error release];
    [super dealloc];
}


@synthesize delegate = _delegate, serverURL = _serverURL, error = _error;


- (NSString*) logDirectory {
    return [_documentsDirectory stringByAppendingPathComponent:@"log"];
}

- (NSString*) databaseDirectory {
    return [_documentsDirectory stringByAppendingPathComponent:@"couchdb"];
}


- (BOOL) installDefaultDatabase: (NSString*)databasePath {
    NSString* dbDir = self.databaseDirectory;
    return [self createDir: dbDir] &&
            [self installFileNamed: databasePath fromDir:nil toDir: dbDir];
}


#pragma mark STARTING COUCHDB:

- (BOOL)start
{
    if (_erlangThread)
        return YES;

    _timeStarted = CFAbsoluteTimeGetCurrent();
	NSLog(@"Couchbase: Starting CouchDB, using runtime files at: %@ (built %s, %s)",
          _bundlePath, __DATE__, __TIME__);

    if(![self createDir: self.logDirectory]
           || ![self createDir: self.databaseDirectory]
           || ![self installFileNamed:@"icouch.ini" fromDir:_bundlePath
                                toDir:_documentsDirectory]
           || ![self installFileNamed:@"erlang/emonk_mapred.js" fromDir:_bundlePath
                                toDir:_documentsDirectory]
           || ![self installFileNamed:@"erlang/emonk_app.js" fromDir:_bundlePath
                                toDir:_documentsDirectory]
           || ![self deleteFile:@"couch.uri" fromDir:_documentsDirectory])
    {
        return NO;
    }

	[[NSFileManager defaultManager] changeCurrentDirectoryPath: _documentsDirectory];    //FIX: Seems bad to do...

    if (![self launchErlang])
        return NO;

    [self performSelectorInBackground: @selector(waitForStart) withObject: nil];
    return YES;
}


#pragma mark LAUNCHING ERLANG:

typedef struct {
    char couchDBDirPath[1024];
    char documentsDirPath[1024];
} ErlangThreadParams;


// Body of the pthread that runs Erlang (and CouchDB)
static void* couchdb_erlang_thread(void* data) {
    ErlangThreadParams* params = data;

	char erl_root[1024];
    sprintf(erl_root, "%s/erlang", params->couchDBDirPath);
    
    // Set some environment variables for Erlang:
    {
        char erl_bin[1024];
        char erl_inetrc[1024];
        sprintf(erl_bin, "%s/erts-5.7.5/bin", erl_root);
        sprintf(erl_inetrc, "%s/erl_inetrc", erl_root);

        setenv("ROOTDIR", erl_root, 1);
        setenv("BINDIR", erl_bin, 1);
        setenv("ERL_INETRC", erl_inetrc, 1);
    }

	char inipath[1024];
	char inipath2[1024];
	sprintf(inipath, "%s/default.ini", params->couchDBDirPath);
	sprintf(inipath2, "%s/icouch.ini", params->documentsDirPath);

    free(params);  // balances malloc call that created the pointer

	char* erlang_args[10] = {"beam", "--", "-noinput",
		"-eval", "application:start(couch).",
		"-root", erl_root, "-couch_ini",
		inipath, inipath2};
	erl_start(10, erlang_args);     // This never returns (unless Erlang exits)
	return NULL;
}


- (BOOL)launchErlang {
    NSLog(@"Couchbase: Starting server thread...");

    ErlangThreadParams* params = malloc(sizeof(ErlangThreadParams));
    strlcpy(params->couchDBDirPath, [_bundlePath fileSystemRepresentation],
            sizeof(params->couchDBDirPath));
    strlcpy(params->documentsDirPath, [_documentsDirectory fileSystemRepresentation],
            sizeof(params->documentsDirPath));

	pthread_attr_t erlThreadAttr;
	assert(!pthread_attr_init(&erlThreadAttr));
	assert(!pthread_attr_setdetachstate(&erlThreadAttr, PTHREAD_CREATE_DETACHED));

	int err = pthread_create(&_erlangThread, &erlThreadAttr, &couchdb_erlang_thread, params);
    if (err) {
        NSLog(@"Couchbase: Error starting Erlang pthread: %i", err);
        self.error = [NSError errorWithDomain: NSPOSIXErrorDomain code: err userInfo: nil];
        return NO;
    }
    return YES;
}


#pragma mark WAITING FOR COUCHDB TO START:

- (BOOL)shouldKeepWaiting {
    if (CFAbsoluteTimeGetCurrent() - _timeStarted < kWaitTimeout)
        return YES;
    NSLog(@"Couchbase: Warning: Timeout waiting for CouchDB to start; giving up");
    return NO;
}


- (BOOL)canConnectToPort:(int) port {
	struct sockaddr_in addr = {sizeof(struct sockaddr_in), AF_INET, htons(port), {0}};
	int sockfd = socket(AF_INET,SOCK_STREAM, 0);
	int result = connect(sockfd,(struct sockaddr*) &addr, sizeof(addr));
    close(sockfd);
	return result == 0;
}


- (void)waitForStart
{
    // This method runs on a background thread!
	NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    // First wait for CouchDB to create the 'couch.uri' file (the 'uri_file' in default.ini):
    NSLog(@"Couchbase: Waiting to acquire CouchDB URL...");
	NSString *uriPath = [_documentsDirectory stringByAppendingPathComponent:@"couch.uri"];
    
    int port = 0;
    do {
        usleep(10000);
        // Read the URI out of the file:
        NSString *rawUriString = [NSString stringWithContentsOfFile:uriPath
                                                           encoding:NSASCIIStringEncoding
                                                              error:NULL];
        if (rawUriString) {
            NSArray *components = [rawUriString componentsSeparatedByString:@"\n"];
            NSString *uriString = [components objectAtIndex:0];
            if (uriString) {
                NSURL *url = [NSURL URLWithString:uriString];
                if (url)
                    port = url.port.intValue;  // Got the port!
            }
        }
    } while (port == 0 && [self shouldKeepWaiting]);
    
    if (port) {
        // Wait till the port accepts a connection:
        NSLog(@"Couchbase: Checking connection to CouchDB on port %i...", port);
        while (![self canConnectToPort:port]) {
            if (![self shouldKeepWaiting]) {
                // Timed out trying to contact the server!
                port = 0;
                break;
            }
            usleep(2500);
        }
    }

    // Done -- now notify the client on the main thread:
    [self performSelectorOnMainThread:@selector(finishedWaiting:)
                           withObject:[NSNumber numberWithInt: port]
                        waitUntilDone:NO];
	[pool drain];
}


- (void)finishedWaiting: (NSNumber*)portObj {
    // Runs on the main thread after waitForStart completes.
    UInt16 port = [portObj intValue];
    if (port) {
        NSURL* serverURL = [NSURL URLWithString: [NSString stringWithFormat:@"http://0.0.0.0:%i/",
                                                  port]];
        NSLog(@"Couchbase: CouchDB is up and running after %.3f sec at <%@>",
              (CFAbsoluteTimeGetCurrent() - _timeStarted), serverURL);
        self.serverURL = serverURL; // Will trigger KVO notification
    } else {
        NSLog(@"Couchbase: Error: Unable to read CouchDB URI file / connect to server");
        self.error = [NSError errorWithDomain: @"Couchbase" code: 1 userInfo: nil]; //TODO: Real error
    }
    
    [_delegate couchbaseDidStart:_serverURL];
}


#pragma mark UTILITIES:

- (BOOL)createDir:(NSString*)dirName {
	BOOL isDir=YES;
	NSFileManager *fm= [NSFileManager defaultManager];
	if(![fm fileExistsAtPath:dirName isDirectory:&isDir]) {
        NSError* createError = nil;
		if([fm createDirectoryAtPath:dirName withIntermediateDirectories:YES
                          attributes:nil error:&createError]) {
            NSLog(@"Couchbase: Created dir %@", dirName);
        } else {
			NSLog(@"Couchbase: Error creating dir '%@': %@", dirName, createError);
            self.error = createError;
            return NO;
        }
    } else if (!isDir) {
        NSLog(@"Couchbase: Error creating dir '%@': already exists as file", dirName);
        return NO;
    }
    return YES;
}

- (BOOL)installFileNamed:(NSString*)name fromDir:(NSString*)fromDir toDir:(NSString*)toDir {
	NSString *source = fromDir ? [fromDir stringByAppendingPathComponent: name] : name;
	NSString *target = [toDir stringByAppendingPathComponent: [name lastPathComponent]];

	NSFileManager *fm= [NSFileManager defaultManager];
    NSError* copyError = nil;
	if(![fm fileExistsAtPath: target]) {
        if ([fm copyItemAtPath: source toPath: target error: &copyError]) {
            NSLog(@"Couchbase: Installed %@ into %@", [name lastPathComponent], target);
        } else {
            NSLog(@"Couchbase: Error copying %@: %@", name, copyError);
            self.error = copyError;
            return NO;
        }
    }
    return YES;
}

- (BOOL)deleteFile:(NSString*)filename fromDir: (NSString*)fromDir {
    NSString* path = [fromDir stringByAppendingPathComponent: filename];
	NSFileManager *fm= [NSFileManager defaultManager];
	if([fm fileExistsAtPath:path]) {
        NSError* removeError = nil;
		if (![fm removeItemAtPath:path error:&removeError]) {
            NSLog(@"Couchbase: Error deleting %@: %@", path, removeError);
            self.error = removeError;
            return NO;
        }
	}
    return YES;
}

@end
