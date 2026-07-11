/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import "N2ManagedDatabase.h"
#import <AppKit/AppKit.h>
#import "NSMutableDictionary+N2.h"
#import "N2Debug.h"
#import "NSFileManager+N2.h"
#import "NSException+N2.h"
#import "DCMTKQueryNode.h"
//#import "DicomDatabase.h" // for debug purposes, REMOVE

static int gTotalN2ManagedObjectContext = 0;

static void N2ManagedDatabaseAppendErrorDetails(NSMutableArray *details, NSError *error, NSUInteger depth)
{
    if (![error isKindOfClass:[NSError class]] || depth > 4)
        return;

    NSString *description = error.localizedDescription.length ? error.localizedDescription : error.description;
    if (description.length)
        [details addObject:[NSString stringWithFormat:@"%@ %ld: %@", error.domain, (long)error.code, description]];

    if (error.localizedFailureReason.length)
        [details addObject:[NSString stringWithFormat:@"%@: %@", NSLocalizedString(@"Reason", nil), error.localizedFailureReason]];

    if (error.localizedRecoverySuggestion.length)
        [details addObject:[NSString stringWithFormat:@"%@: %@", NSLocalizedString(@"Suggestion", nil), error.localizedRecoverySuggestion]];

    NSString *filePath = [error.userInfo objectForKey:NSFilePathErrorKey];
    if (filePath.length)
        [details addObject:[NSString stringWithFormat:@"%@: %@", NSLocalizedString(@"File", nil), filePath]];

    id underlyingError = [error.userInfo objectForKey:NSUnderlyingErrorKey];
    if ([underlyingError isKindOfClass:[NSError class]])
        N2ManagedDatabaseAppendErrorDetails(details, underlyingError, depth + 1);
    else if ([underlyingError isKindOfClass:[NSArray class]]) {
        for (NSError *nestedError in (NSArray *)underlyingError)
            N2ManagedDatabaseAppendErrorDetails(details, nestedError, depth + 1);
    }
}

static NSString *N2ManagedDatabaseStorageErrorDetails(NSError *error)
{
    NSMutableArray *details = [NSMutableArray array];
    N2ManagedDatabaseAppendErrorDetails(details, error, 0);
    return details.count ? [details componentsJoinedByString:@"\r"] : NSLocalizedString(@"No detailed error was provided by the persistent store.", nil);
}

static NSString *N2ManagedDatabaseBackupPathForSQLFile(NSString *sqlFilePath)
{
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";

    NSString *basePath = [NSString stringWithFormat:@"%@.failed-open-%@", sqlFilePath, [formatter stringFromDate:[NSDate date]]];
    for (NSUInteger index = 0; index < 1000; ++index) {
        NSString *candidate = index ? [NSString stringWithFormat:@"%@-%lu", basePath, (unsigned long)index] : basePath;
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate])
            return candidate;
    }

    return [NSString stringWithFormat:@"%@-%u", basePath, arc4random()];
}

static NSString *N2ManagedDatabaseMoveSQLIndexAside(NSString *sqlFilePath, NSError **error)
{
    NSString *backupPath = N2ManagedDatabaseBackupPathForSQLFile(sqlFilePath);
    if (![NSFileManager.defaultManager moveItemAtPath:sqlFilePath toPath:backupPath error:error])
        return nil;

    for (NSString *suffix in @[@"-journal", @"-shm", @"-wal"]) {
        NSString *sidecarPath = [sqlFilePath stringByAppendingString:suffix];
        if (![NSFileManager.defaultManager fileExistsAtPath:sidecarPath])
            continue;

        NSError *sidecarError = nil;
        if (![NSFileManager.defaultManager moveItemAtPath:sidecarPath toPath:[backupPath stringByAppendingString:suffix] error:&sidecarError])
            NSLog(@"Warning: could not move database sidecar %@ aside: %@", sidecarPath, sidecarError);
    }

    return backupPath;
}

@interface N2ManagedDatabase ()

@property(readwrite,retain) NSString* sqlFilePath;
@property(readwrite,retain) id mainDatabase;
- (id)_objectWithIDOnContextQueue:(id)objectID;
- (void)_mergeChangesFromContextDidSaveNotificationOnMainThread:(NSDictionary *)payload;

@end

#define N2PersistentStoreCoordinator NSPersistentStoreCoordinator // for debug purposes, disable this #define and enable the commented N2PersistentStoreCoordinator implementation

@implementation N2ManagedObjectContext

@synthesize database = _database;

- (id)initWithDatabase:(N2ManagedDatabase *)db concurrencyType:(NSManagedObjectContextConcurrencyType)ct
{
    if (!(self = [super initWithConcurrencyType:ct]))
        return nil;
    
    _database = db;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(N2ManagedDatabaseDealloced:) name:@"N2ManagedDatabaseDealloced" object:db];
    
#ifndef NDEBUG
    gTotalN2ManagedObjectContext++;
    
    if( gTotalN2ManagedObjectContext > 10)
        NSLog( @"-- gTotalN2ManagedObjectContext = %d", gTotalN2ManagedObjectContext);
#endif
    
    return self;
}

-(void)N2ManagedDatabaseDealloced:(NSNotification*) n
{
    if( n.object != _database)
        N2LogStackTrace( @"******* N2ManagedDatabaseDealloced");
    [NSNotificationCenter.defaultCenter removeObserver:self name:@"N2ManagedDatabaseDealloced" object:n.object];
    _database = nil;
}

-(void)dealloc {
#ifndef NDEBUG
    gTotalN2ManagedObjectContext--;
#endif
    
    [NSNotificationCenter.defaultCenter removeObserver:self];

    _database = nil;
	
    [super dealloc]; //test if db is deallocated
}

@end


@implementation N2ManagedDatabase
@synthesize sqlFilePath = _sqlFilePath;
@synthesize managedObjectContext = _managedObjectContext;
@synthesize mainDatabase = _mainDatabase;

-(BOOL)isMainDatabase {
    return (_mainDatabase == nil);
}

-(NSManagedObjectContext*)managedObjectContext {
	return _managedObjectContext;
}

-(void)setManagedObjectContext:(NSManagedObjectContext*)managedObjectContext {
	if (managedObjectContext != _managedObjectContext) {
        [self willChangeValueForKey:@"managedObjectContext"];
        
        [_managedObjectContext autorelease];
		_managedObjectContext = [managedObjectContext retain];
        
        [self didChangeValueForKey:@"managedObjectContext"];
    }
}

+(NSString*)modelName {
	[NSException raise:NSGenericException format:@"[class modelName] must be defined"];
	return NULL;
}

-(BOOL) deleteSQLFileIfOpeningFailed
{
    return NO;
}

-(NSManagedObjectModel*)managedObjectModel {
	[NSException raise:NSGenericException format:@"[%@ managedObjectModel] must be defined", self.className];
	return NULL;
}

/*-(NSMutableDictionary*)persistentStoreCoordinatorsDictionary {
	static NSMutableDictionary* dict = NULL;
	if (!dict)
		dict = [[NSMutableDictionary alloc] initWithCapacity:4];
	return dict;
}*/

- (void) renewManagedObjectContext
{
    self.managedObjectContext = self.isMainDatabase
        ? [self contextAtPath:self.sqlFilePath concurrencyType:NSMainQueueConcurrencyType]
        : [self.mainDatabase contextAtPath:self.sqlFilePath];
}

- (Class)NSManagedObjectContextClass {
    return N2ManagedObjectContext.class;
}

- (NSManagedObjectContext *)contextAtPath:(NSString *)sqlFilePath {
    BOOL createsPrimaryContext = self.isMainDatabase && self.managedObjectContext == nil;
    NSManagedObjectContextConcurrencyType concurrencyType = createsPrimaryContext ? NSMainQueueConcurrencyType : NSPrivateQueueConcurrencyType;
    return [self contextAtPath:sqlFilePath concurrencyType:concurrencyType];
}

- (NSManagedObjectContext *)contextAtPath:(NSString *)sqlFilePath concurrencyType:(NSManagedObjectContextConcurrencyType)concurrencyType {
	sqlFilePath = sqlFilePath.stringByExpandingTildeInPath;

    if( sqlFilePath.length == 0)
        return nil;

    N2ManagedObjectContext *moc = [[[self.NSManagedObjectContextClass alloc] initWithDatabase:self concurrencyType:concurrencyType] autorelease];
    moc.name = concurrencyType == NSMainQueueConcurrencyType ? @"Horos main database context" : @"Horos worker database context";
    //	NSLog(@"---------- NEW %@ at %@", moc, sqlFilePath);
	moc.undoManager = nil;
	
    //	NSMutableDictionary* persistentStoreCoordinatorsDictionary = self.persistentStoreCoordinatorsDictionary;
	
    @try {
        @synchronized (self) {
    //        if (self.managedObjectContext.hasChanges)
    //            [self save];
            
            if ([sqlFilePath isEqualToString:self.sqlFilePath] && [NSFileManager.defaultManager fileExistsAtPath:sqlFilePath]) {
                NSManagedObjectContext *primaryContext = self.managedObjectContext;
                __block NSPersistentStoreCoordinator *coordinator = nil;
                N2PerformManagedObjectContextBlockAndWait(primaryContext, ^{
                    coordinator = [primaryContext.persistentStoreCoordinator retain];
                });
                moc.persistentStoreCoordinator = coordinator;
                [coordinator release];
            }
            
            if (!moc.persistentStoreCoordinator) {
                //			moc.persistentStoreCoordinator = [persistentStoreCoordinatorsDictionary objectForKey:sqlFilePath];
                
                BOOL isNewFile = ![NSFileManager.defaultManager fileExistsAtPath:sqlFilePath];
                if (isNewFile)
                {
                    [[NSFileManager defaultManager] confirmDirectoryAtPath:[sqlFilePath stringByDeletingLastPathComponent]];
                    moc.persistentStoreCoordinator = nil;
                }
                
                if (!moc.persistentStoreCoordinator)
                {
                    NSManagedObjectModel *models = self.managedObjectModel;
                    
                    NSPersistentStoreCoordinator* persistentStoreCoordinator = moc.persistentStoreCoordinator = [[[N2PersistentStoreCoordinator alloc] initWithManagedObjectModel: models] autorelease];
                    
                    //[persistentStoreCoordinatorsDictionary setObject:persistentStoreCoordinator forKey:sqlFilePath];
                    
                    NSPersistentStore* pStore = nil;
                    int i = 0;
                    do { // try 2 times
                        ++i;
                        
                        NSError* err = nil;
                        NSDictionary* options = @{ NSInferMappingModelAutomaticallyOption: @NO,
                                                   NSMigratePersistentStoresAutomaticallyOption: @NO,
                                                   NSSQLitePragmasOption: @{ @"journal_mode": @"delete" } };
                        NSURL* url = [NSURL fileURLWithPath:sqlFilePath];
                        @try {
                            pStore = [persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:options error:&err];

                        } @catch (...) {
                        }
                        
                        if (!pStore && i == 1)
                        {
                            NSLog(@"Error: [N2ManagedDatabase contextAtPath:] %@", [err description]);
                            BOOL shouldResetSQLIndex = NO;
                            if ([NSThread isMainThread]) {
                                NSString *message = [NSString stringWithFormat:
                                    NSLocalizedString(@"Horos could not open the database SQL index file.\r\rThis can happen when the database volume is not mounted, macOS has not granted this copy of Horos access to the folder, the file is locked, or the SQL index is damaged.\r\rDatabase SQL index:\r%@\r\rDetails:\r%@\r\rIf this is not the database location you expected, do not reset this index. Continue, then select the correct database location.\r\rContinuing leaves this file untouched. Resetting the SQL index moves the old index aside and asks Horos to rebuild it.", nil),
                                    sqlFilePath,
                                    N2ManagedDatabaseStorageErrorDetails(err)];
                                NSInteger result = NSRunCriticalAlertPanel(
                                    [NSString stringWithFormat:NSLocalizedString(@"%@ Storage Error", nil), [self className]],
                                    @"%@",
                                    NSLocalizedString(@"Continue", nil),
                                    NSLocalizedString(@"Reveal in Finder", nil),
                                    self.deleteSQLFileIfOpeningFailed ? NSLocalizedString(@"Reset SQL Index...", nil) : nil,
                                    message);
                                
                                if (result == NSAlertAlternateReturn) {
                                    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:sqlFilePath]]];
                                } else if (result == NSAlertOtherReturn && self.deleteSQLFileIfOpeningFailed) {
                                    NSInteger confirmation = NSRunCriticalAlertPanel(
                                        [NSString stringWithFormat:NSLocalizedString(@"Reset %@ SQL Index?", nil), [self className]],
                                        @"%@\r\r%@",
                                        NSLocalizedString(@"Cancel", nil),
                                        NSLocalizedString(@"Reset SQL Index", nil),
                                        nil,
                                        NSLocalizedString(@"Only reset the SQL index if this is the database Horos should rebuild. If Horos is opening an unexpected folder, cancel and choose the correct database instead.\r\rHoros will move the existing SQL index to a backup file beside it, then try to create a new one. DICOM image files are not intentionally deleted, but database-only metadata may be missing until the old index is restored.", nil),
                                        sqlFilePath);
                                    
                                    shouldResetSQLIndex = confirmation == NSAlertAlternateReturn;
                                }
                            }
                            
                            // error = [NSError osirixErrorWithCode:0 underlyingError:error localizedDescriptionFormat:NSLocalizedString(@"Store Configuration Failure: %@", nil), error.localizedDescription? error.localizedDescription : NSLocalizedString(@"Unknown Error", nil)];
                            
                            // Move the old file aside for the Database.sql model ONLY (don't do this for the WebUser db), and only after explicit user confirmation.
                            if (shouldResetSQLIndex) {
                                NSError *moveError = nil;
                                NSString *backupPath = N2ManagedDatabaseMoveSQLIndexAside(sqlFilePath, &moveError);
                                if (backupPath) {
                                    NSLog(@"Moved SQL index %@ to %@ before rebuilding.", sqlFilePath, backupPath);
                                    i = 0;
                                } else if ([NSThread isMainThread]) {
                                    NSRunCriticalAlertPanel(
                                        [NSString stringWithFormat:NSLocalizedString(@"%@ Storage Error", nil), [self className]],
                                        @"%@\r\r%@\r\r%@",
                                        NSLocalizedString(@"Continue", nil),
                                        nil,
                                        nil,
                                        NSLocalizedString(@"Horos could not move the SQL index aside, so it has not been reset.", nil),
                                        sqlFilePath,
                                        N2ManagedDatabaseStorageErrorDetails(moveError));
                                }
                            }
                        }
                    } while (!pStore && i < 2);
                    
                }
                
                if (isNewFile) {
                    [moc performBlockAndWait:^{
                        [moc save:NULL];
                    }];
//                    NSLog(@"New database file created at %@", sqlFilePath);
                }
                
            } else if (concurrencyType == NSPrivateQueueConcurrencyType) {
                if (self.mainDatabase)
                    N2LogStackTrace(@"****************************: creating independent context from already independent database");
                
                // Our main DicomDatabase context will listen to changes from the independentContext.
                // Warning: the independentContext will not receive main DicomDatabase changes unless a caller explicitly merges them.
                [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mergeChangesFromContextDidSaveNotification:) name:NSManagedObjectContextDidSaveNotification object:moc];
            }
            
        }
    }
    @catch (NSException *exception) {
        moc = nil;
    }
    
    return moc;
}

-(void)mergeChangesFromContextDidSaveNotification:(NSNotification*)n {
    NSManagedObjectContext *sourceContext = n.object;
    if (self.managedObjectContext == sourceContext)
        return;

    NSPersistentStoreCoordinator *sourceCoordinator = [sourceContext.persistentStoreCoordinator retain];
    if (!sourceCoordinator)
        return;

    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
        n, @"notification",
        sourceCoordinator, @"coordinator",
        nil];
    [sourceCoordinator release];
    [self performSelectorOnMainThread:@selector(_mergeChangesFromContextDidSaveNotificationOnMainThread:)
                           withObject:payload
                        waitUntilDone:NO];
}

- (void)_mergeChangesFromContextDidSaveNotificationOnMainThread:(NSDictionary *)payload {
    NSNotification *notification = [payload objectForKey:@"notification"];
    NSPersistentStoreCoordinator *sourceCoordinator = [payload objectForKey:@"coordinator"];
    NSManagedObjectContext *targetContext = self.managedObjectContext;

    N2PerformManagedObjectContextBlockAndWait(targetContext, ^{
        if (targetContext.persistentStoreCoordinator != sourceCoordinator)
            return;

        @try {
            [targetContext mergeChangesFromContextDidSaveNotification:notification];
        } @catch (NSException* e) {
            N2LogExceptionWithStackTrace(e);
        }
    });
}

-(id)initWithPath:(NSString*)p {
	return [self initWithPath:p context:nil mainDatabase:nil];
}

-(id)initWithPath:(NSString*)p context:(NSManagedObjectContext*)c {
    return [self initWithPath:p context:c mainDatabase:nil];
}

-(id)initWithPath:(NSString*)p context:(NSManagedObjectContext*)c mainDatabase:(N2ManagedDatabase*)mainDbReference {
	self = [super init];
	
	self.sqlFilePath = p;
    self.mainDatabase = mainDbReference;
	
//#ifndef NDEBUG
//    if( [NSThread isMainThread] == NO && mainDbReference == nil)
//        NSLog( @"****** WARNING - Creating a MAIN database, NOT on the MAIN thread... Be aware that this managedObjectContext could be later used on the MAIN thread, unless you renewManagedObjectContext on the main thread.");
//#endif
    
	self.managedObjectContext = c? c : [self contextAtPath:p];
    
	return self;
}

-(void)dealloc {
    // this should fix dealloc cycles
    if (_isDeallocating)
        return;
    _isDeallocating = YES;
    
    [NSNotificationCenter.defaultCenter postNotificationName: @"N2ManagedDatabaseDealloced" object:self];
    
    [NSNotificationCenter.defaultCenter removeObserver:self];
    
    if ([NSFileManager.defaultManager fileExistsAtPath:[self.sqlFilePath stringByDeletingLastPathComponent]]) {
        __block BOOL hasChanges = NO;
        [self.managedObjectContext performBlockAndWait:^{
            hasChanges = self.managedObjectContext.hasChanges;
        }];
        if (hasChanges)
            [self save];
    }
    
    if (self.mainDatabase)
        [NSNotificationCenter.defaultCenter removeObserver:self.mainDatabase name:NSManagedObjectContextDidSaveNotification object:self];
    
    self.mainDatabase = nil;
	self.managedObjectContext = nil;
	self.sqlFilePath = nil;
    
	[super dealloc];
}

- (NSManagedObjectContext *)independentContext:(BOOL)independent {
    if (!independent)
        return self.managedObjectContext;
    
#ifndef NDEBUG
    if ([NSThread isMainThread])
        N2LogStackTrace(@"info: independent context not required on main thread");
#endif
    
	NSManagedObjectContext *ic = [self contextAtPath:self.sqlFilePath];
    
    return ic;
}

- (NSManagedObjectContext *)independentContext {
	return [self independentContext:YES];
}

- (id)independentDatabase {
	return [[[[self class] alloc] initWithPath:self.sqlFilePath context:[self independentContext] mainDatabase:self] autorelease];
}

-(id)objectWithID:(id)oid {
    __block id result = nil;
    [self.managedObjectContext performBlockAndWait:^{
        @try {
            result = [[self _objectWithIDOnContextQueue:oid] retain];
        } @catch (...) {
            result = nil;
        }
    }];
    return [result autorelease];
}

-(NSArray*)objectsWithIDs:(NSArray*)objectIDs {
    __block NSArray *result = nil;
    [self.managedObjectContext performBlockAndWait:^{
        NSMutableArray *objects = [NSMutableArray arrayWithCapacity:objectIDs.count];
        for (id objectID in objectIDs) {
            @try {
                id object = [self _objectWithIDOnContextQueue:objectID];
                if (object)
                    [objects addObject:object];
            } @catch (NSException* e) {
                // Ignore invalid IDs and continue with the remaining objects.
            }
        }
        result = [objects copy];
    }];
    return [result autorelease];
}

-(id)_objectWithIDOnContextQueue:(id)objectID {
    if ([objectID isKindOfClass:[NSManagedObjectID class]]) {
        // Already an object ID.
    } else if ([objectID isKindOfClass:[NSManagedObject class]]) {
        objectID = [objectID objectID];
    } else if ([objectID isKindOfClass:[DCMTKQueryNode class]]) {
        return objectID;
    } else if ([objectID isKindOfClass:[NSURL class]]) {
        objectID = [self.managedObjectContext.persistentStoreCoordinator managedObjectIDForURIRepresentation:objectID];
    } else if ([objectID isKindOfClass:[NSString class]]) {
        NSURL *URL = [NSURL URLWithString:objectID];
        objectID = [self.managedObjectContext.persistentStoreCoordinator managedObjectIDForURIRepresentation:URL];
    }

    return [self.managedObjectContext existingObjectWithID:objectID error:NULL];
}

-(NSEntityDescription*)entityForName:(NSString*)name {
	__block NSEntityDescription *result = nil;
    [self.managedObjectContext performBlockAndWait:^{
        result = [[NSEntityDescription entityForName:name inManagedObjectContext:self.managedObjectContext] retain];
    }];
    return [result autorelease];
}

-(NSEntityDescription*)_entity:(id*)entity {
    if ([*entity isKindOfClass:[NSString class]])
        *entity = [NSEntityDescription entityForName:*entity inManagedObjectContext:self.managedObjectContext];
    return *entity;
}

-(NSArray*)objectsForEntity:(id)e {
	return [self objectsForEntity:e predicate:nil error:NULL];
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p {
	return [self objectsForEntity:e predicate:p error:NULL];
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error {
    return [self objectsForEntity:e predicate:p error:error fetchLimit:0 sortDescriptors:nil];
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error fetchLimit:(NSUInteger)fetchLimit sortDescriptors:(NSArray*)sortDescriptors{
	__block NSArray *result = nil;
    __block NSError *blockError = nil;
    [self.managedObjectContext performBlockAndWait:^{
        id entity = e;
        [self _entity:&entity];

        NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
        request.entity = entity;
        request.predicate = p ? p : [NSPredicate predicateWithValue:YES];
        request.sortDescriptors = sortDescriptors;
        if (fetchLimit > 0)
            request.fetchLimit = fetchLimit;

        NSError *operationError = nil;
        @try {
            result = [[self.managedObjectContext executeFetchRequest:request error:&operationError] retain];
        } @catch (NSException *exception) {
            operationError = [NSError errorWithDomain:N2ErrorDomain
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Core Data fetch failed"}];
        }
        blockError = [operationError retain];
    }];

    if (error)
        *error = [blockError autorelease];
    else if (blockError) {
        N2LogError(blockError.description);
        [blockError release];
    }
    return [result autorelease];
}

-(NSUInteger)countObjectsForEntity:(id)e {
	return [self countObjectsForEntity:e predicate:nil error:NULL];
}

-(NSUInteger)countObjectsForEntity:(id)e predicate:(NSPredicate*)p {
	return [self countObjectsForEntity:e predicate:p error:NULL];
}

-(NSUInteger)countObjectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error {
	__block NSUInteger result = 0;
    __block NSError *blockError = nil;
    [self.managedObjectContext performBlockAndWait:^{
        id entity = e;
        [self _entity:&entity];

        NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
        request.entity = entity;
        request.predicate = p ? p : [NSPredicate predicateWithValue:YES];

        NSError *operationError = nil;
        @try {
            result = [self.managedObjectContext countForFetchRequest:request error:&operationError];
        } @catch (NSException *exception) {
            operationError = [NSError errorWithDomain:N2ErrorDomain
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Core Data count failed"}];
        }
        blockError = [operationError retain];
    }];

    if (error)
        *error = [blockError autorelease];
    else if (blockError) {
        N2LogError(blockError.description);
        [blockError release];
    }
	return result;
}

-(id)newObjectForEntity:(id)entity {
    __block id result = nil;
    [self.managedObjectContext performBlockAndWait:^{
        id resolvedEntity = entity;
        [self _entity:&resolvedEntity];
        result = [[NSEntityDescription insertNewObjectForEntityForName:[resolvedEntity name] inManagedObjectContext:self.managedObjectContext] retain];
    }];
    return [result autorelease];
}

-(BOOL)save {
    return [self save:NULL];
}

-(BOOL)save:(NSError**)error {
	__block BOOL saved = NO;
    __block NSError *blockError = nil;
    [self.managedObjectContext performBlockAndWait:^{
        NSError *operationError = nil;
        @try {
            saved = [self.managedObjectContext save:&operationError];
        } @catch(NSException *exception) {
            operationError = [NSError errorWithDomain:N2ErrorDomain
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Core Data save failed"}];
        }
        blockError = [operationError retain];
    }];

    if (error)
        *error = [blockError autorelease];
    else if (blockError) {
        N2LogError(blockError.description);
        [blockError release];
    }
	return saved;
}


@end
