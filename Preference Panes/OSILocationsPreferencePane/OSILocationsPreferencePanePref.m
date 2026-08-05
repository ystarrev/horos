#import "HorosSheetPresenter.h"
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
 OsiriX project.
 
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

#import "OSILocationsPreferencePanePref.h"
#import "N2Debug.h"
#import "url.h"
#import "HorosSwiftInterop.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

//#import "DDKeychain.h"

/************ Transfer Syntaxes *******************
	@"Explicit Little Endian"
	@"JPEG 2000 Lossless"
	@"JPEG 2000 Lossy 10:1"
	@"JPEG 2000 Lossy 20:1"
	@"JPEG 2000 Lossy 50:1"
	@"JPEG Lossless"
	@"JPEG High Quality (9)"	
	@"JPEG Medium High Quality (8)"	
	@"JPEG Medium Quality (7)"
	@"Implicit"
	@"RLE"
*************************************************/

@implementation OSILocationsPreferencePanePref

@synthesize testingNodes;

@synthesize TLSEnabled, TLSAuthenticated, TLSUseDHParameterFileURL;
@synthesize TLSDHParameterFileURL;
@synthesize TLSSupportedCipherSuite;
@synthesize TLSCertificateVerification;
@synthesize TLSAuthenticationCertificate;

- (id) initWithBundle:(NSBundle *)bundle
{
	if( self = [super init])
	{
		NSNib *nib = [[[NSNib alloc] initWithNibNamed: @"OSILocationsPreferencePanePref" bundle: nil] autorelease];
		[nib instantiateWithOwner:self topLevelObjects:&_tlos];
		
        [TLSSettings retain];
        
		[self setMainView: [mainWindow contentView]];
		[self mainViewDidLoad];
	}
	
	return self;
}


- (void) checkUniqueAETitle
{
	NSArray *serverList = [dicomNodes arrangedObjects];
	
	for( int x = 0; x < [serverList count]; x++)
	{
		int value = [[[serverList objectAtIndex: x] valueForKey:@"Port"] intValue];
		if( value < 1) value = 1;
		if( value > 131072) value = 131072;
		[[serverList objectAtIndex: x] setValue: [NSNumber numberWithInt: value] forKey: @"Port"];		
		[[serverList objectAtIndex: x] setValue: [[serverList objectAtIndex: x] valueForKey:@"AETitle"] forKey:@"AETitle"];
		
        if( [[serverList objectAtIndex: x] valueForKey:@"Activated"] == nil)
            [[serverList objectAtIndex: x] setValue: [NSNumber numberWithBool: YES] forKey: @"Activated"];
        
		NSString *currentAETitle = [[serverList objectAtIndex: x] valueForKey: @"AETitle"];
		
		for( int i = 0; i < [serverList count]; i++)
		{
			if( i != x)
			{
				if( [currentAETitle isEqualToString: [[serverList objectAtIndex: i] valueForKey: @"AETitle"]])
				{
					if ([[NSUserDefaults standardUserDefaults] boolForKey: @"HideSameAETitleAlert"] == NO)
					{
						NSAlert* alert = [[NSAlert new] autorelease];
						[alert setMessageText: NSLocalizedString(@"Same AETitle", 0L)];
						[alert setInformativeText:  [NSString stringWithFormat: NSLocalizedString(@"This AETitle is not unique: %@. AETitles should be unique, otherwise Q&R (C-Move SCP/SCU) can fail.", 0L), currentAETitle]];
						[alert setShowsSuppressionButton:YES ];
						[alert addButtonWithTitle: NSLocalizedString(@"OK", nil)];
						
						[alert runModal];
						
						if ([[alert suppressionButton] state] == NSControlStateValueOn)
							[[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"HideSameAETitleAlert"];
						
						i = [serverList count];
						x = [serverList count];
					}
				}
			}
		}
    }    
        // Check for unique description
    for( int x = 0; x < [serverList count]; x++)
    {
        NSString *description = [[serverList objectAtIndex: x] valueForKey: @"Description"];
        
        for( int i = 0; i < [serverList count]; i++)
		{
			if( i != x)
			{
                if( [description isEqualToString: [[serverList objectAtIndex: i] valueForKey: @"Description"]])
				{
                    if ([[NSUserDefaults standardUserDefaults] boolForKey: @"HideSameNameAlert"] == NO)
                    {
                        NSAlert* alert = [[NSAlert new] autorelease];
                        [alert setMessageText: NSLocalizedString(@"Same name", 0L)];
                        [alert setInformativeText:  [NSString stringWithFormat: NSLocalizedString(@"This server name is not unique: %@. Server names should be unique, otherwise autorouting rules can fail.", 0L), description]];
                        [alert setShowsSuppressionButton:YES ];
                        [alert addButtonWithTitle: NSLocalizedString(@"OK", nil)];
                        
                        [alert runModal];
                        
                        if ([[alert suppressionButton] state] == NSControlStateValueOn)
                            [[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"HideSameNameAlert"];
                        
                        i = [serverList count];
                        x = [serverList count];
                    }
                }
            }
        }
	}
}

- (int) echoAddress: (NSString*) address port:(int) port AET:(NSString*) aet
{
	NSTask* theTask = [[[NSTask alloc]init]autorelease];
	
	[theTask setExecutableURL:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingString:@"/echoscu"]]];

	[theTask setEnvironment:[NSDictionary dictionaryWithObject:[[[NSBundle mainBundle] resourcePath] stringByAppendingString:@"/dicom.dic"] forKey:@"DCMDICTPATH"]];
	[theTask setExecutableURL:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingString:@"/echoscu"]]];

	NSArray *args = [NSArray arrayWithObjects: address, [NSString stringWithFormat:@"%d", port], @"-aet", [[NSUserDefaults standardUserDefaults] stringForKey: @"AETITLE"], @"-aec", aet, @"-to", [[NSUserDefaults standardUserDefaults] stringForKey:@"DICOMTimeout"], @"-ta", [[NSUserDefaults standardUserDefaults] stringForKey:@"DICOMTimeout"], @"-td", [[NSUserDefaults standardUserDefaults] stringForKey:@"DICOMTimeout"], @"-d", nil];
	
	NSLog( @"%@", [args description]);
	
	[theTask setArguments:args];
	HorosLaunchTaskOrRaise(theTask);
	[theTask waitUntilExit];
	
	return [theTask terminationStatus];
}

+ (BOOL) echoServer:(NSDictionary*)serverParameters
{
    @try
    {
        NSString *address = [serverParameters objectForKey:@"Address"];
        NSNumber *port = [serverParameters objectForKey:@"Port"];
        NSString *aet = [serverParameters objectForKey:@"AETitle"];
        
        NSTask* theTask = [[[NSTask alloc] init] autorelease];
        
        [theTask setExecutableURL:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/echoscu"]]];
        
        [theTask setEnvironment:[NSDictionary dictionaryWithObject:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/dicom.dic"] forKey:@"DCMDICTPATH"]];
        [theTask setExecutableURL:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/echoscu"]]];
            
        NSMutableArray *args = [NSMutableArray array];
        [args addObject:address];
        [args addObject:[NSString stringWithFormat:@"%d", [port intValue]]];
        [args addObject:@"-aet"]; // set my calling AE title
        [args addObject:[[NSUserDefaults standardUserDefaults] stringForKey: @"AETITLE"]];
        [args addObject:@"-aec"]; // set called AE title of peer
        [args addObject:aet];
        [args addObject:@"-to"]; // timeout for connection requests
        [args addObject:[[NSUserDefaults standardUserDefaults] stringForKey:@"DICOMTimeout"]];
        [args addObject:@"-ta"]; // timeout for ACSE messages
        [args addObject:[[NSUserDefaults standardUserDefaults] stringForKey:@"DICOMTimeout"]];
        [args addObject:@"-td"]; // timeout for DIMSE messages
        [args addObject:[[NSUserDefaults standardUserDefaults] stringForKey:@"DICOMTimeout"]];
        
        [DDKeychain lockTmpFiles];
        
        if([[serverParameters objectForKey:@"TLSEnabled"] boolValue])
        {
            // TLS support. Options listed here http://support.dcmtk.org/docs/echoscu.html
            
            if([[serverParameters objectForKey:@"TLSAuthenticated"] boolValue])
            {
                [args addObject:@"--enable-tls"]; // use authenticated secure TLS connection

                [DICOMTLS generateCertificateAndKeyForServerAddress:address port: [port intValue] AETitle:aet]; // export certificate/key from the Keychain to the disk
                [args addObject:[DICOMTLS keyPathForServerAddress:address port:[port intValue] AETitle:aet]]; // [p]rivate key file
                [args addObject:[DICOMTLS certificatePathForServerAddress:address port:[port intValue] AETitle:aet]]; // [c]ertificate file: string
                
                [args addObject:@"--use-passwd"];
                [args addObject: [DICOMTLS TLS_PRIVATE_KEY_PASSWORD]];
            }
            else
                [args addObject:@"--anonymous-tls"]; // use secure TLS connection without certificate
            
            // key and certificate file format options:
            [args addObject:@"--pem-keys"];
            
            //ciphersuite options:
            for (NSDictionary *suite in [serverParameters objectForKey:@"TLSCipherSuites"])
            {
                if ([[suite objectForKey:@"Supported"] boolValue])
                {
                    [args addObject:@"--cipher"]; // add ciphersuite to list of negotiated suites
                    [args addObject:[suite objectForKey:@"Cipher"]];
                }
            }

            if([[serverParameters objectForKey:@"TLSUseDHParameterFileURL"] boolValue])
            {
                [args addObject:@"--dhparam"]; // read DH parameters for DH/DSS ciphersuites
                [args addObject:[serverParameters objectForKey:@"TLSDHParameterFileURL"]];
            }

            // peer authentication options:
            TLSCertificateVerificationType verification = [[serverParameters objectForKey:@"TLSCertificateVerification"] intValue];
            if(verification==RequirePeerCertificate)
                [args addObject:@"--require-peer-cert"]; //verify peer certificate, fail if absent (default)
            else if(verification==VerifyPeerCertificate)
                [args addObject:@"--verify-peer-cert"]; //verify peer certificate if present
            else //IgnorePeerCertificate
                [args addObject:@"--ignore-peer-cert"]; //don't verify peer certificate	
            
            // certification authority options:
            if(verification==RequirePeerCertificate || verification==VerifyPeerCertificate)
            {
                [DDKeychain KeychainAccessExportTrustedCertificatesToDirectory:TLS_TRUSTED_CERTIFICATES_DIR];
                NSArray *trustedCertificates = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:TLS_TRUSTED_CERTIFICATES_DIR error:nil];
            
                //[args addObject:@"--add-cert-dir"]; // add certificates in d to list of certificates  .... needs to use OpenSSL & rename files (see http://forum.dicom-cd.de/viewtopic.php?p=3237&sid=bd17bd76876a8fd9e7fdf841b90cf639 )
                for (NSString *cert in trustedCertificates)
                {
                    [args addObject:@"--add-cert-file"];
                    [args addObject:[TLS_TRUSTED_CERTIFICATES_DIR stringByAppendingPathComponent:cert]];
                }
            }
            
            // Seed DCMTK TLS with app-generated entropy.
            [DDKeychain generatePseudoRandomFileToPath:TLS_SEED_FILE];
            [args addObject:@"--seed"]; // seed random generator with contents of f
            [args addObject:TLS_SEED_FILE];		
        }
            
        [theTask setArguments:args];
        HorosLaunchTaskOrRaise(theTask);
        [theTask waitUntilExit];

        [DDKeychain unlockTmpFiles];
        
        if( [theTask terminationStatus] == 0) return YES;
        else return NO;
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    
    return NO;
}

- (void) enableControls: (BOOL) val
{
//	[[NSUserDefaults standardUserDefaults] setBool: val forKey: @"preferencesModificationsEnabled"];
//	[[NSUserDefaults standardUserDefaults] setBool: [[NSUserDefaults standardUserDefaults] boolForKey:@"syncDICOMNodes"] forKey: @"syncDICOMNodes"];
}

- (void) mainViewDidLoad
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	stringEncoding = [[defaults stringForKey:@"STRINGENCODING"] retain];
	int tag = 0;
	 if( [stringEncoding isEqualToString: @"ISO_IR 192"])	//UTF8
		tag = 0;
	else if ( [stringEncoding isEqualToString: @"ISO_IR 100"])
		tag = 1;
	else if( [stringEncoding isEqualToString: @"ISO_IR 101"])
		tag =  2;
	else if( [stringEncoding isEqualToString: @"ISO_IR 109"])	
		tag =  3;
	else if( [stringEncoding isEqualToString: @"ISO_IR 110"])
		tag =  4;
	else if( [stringEncoding isEqualToString: @"ISO_IR 127"])	
		tag =  5 ;
	else if( [stringEncoding isEqualToString: @"ISO_IR 144"])		
		tag =  6;
	else if( [stringEncoding isEqualToString: @"ISO_IR 126"])	
		tag =  7;
	else if( [stringEncoding isEqualToString: @"ISO_IR 138"])		
		tag =  8 ;
	else if( [stringEncoding isEqualToString: @"GB18030"])	
		tag =  9;
	else if( [stringEncoding isEqualToString: @"ISO 2022 IR 149"])
		tag =  10;
	else if( [stringEncoding isEqualToString: @"ISO 2022 IR 13"])	
		tag =  11;
	else if( [stringEncoding isEqualToString: @"ISO_IR 13"])	
		tag =  12 ;
	else if( [stringEncoding isEqualToString: @"ISO 2022 IR 87"])	
		tag =  13 ;
	else if( [stringEncoding isEqualToString: @"ISO_IR 1166"])
		tag =  14 ;
	else
	{
		[[NSUserDefaults standardUserDefaults] setObject: @"ISO_IR 100" forKey:@"STRINGENCODING"];
		tag = 1;
	}
	
	[characterSetPopup selectItemAtIndex:-1];
	[characterSetPopup selectItemAtIndex:tag];
	
	for( int i = 0 ; i < [[dicomNodes arrangedObjects] count]; i++)
	{
		NSMutableDictionary *aServer = [[dicomNodes arrangedObjects] objectAtIndex: i];
		if( [aServer valueForKey:@"Send"] == 0L)
			[aServer setValue:[NSNumber numberWithBool:YES] forKey:@"Send"];
	}
}

- (void) willSelect
{
    [self checkUniqueAETitle];
	[self resetTest];
}

- (void) willUnselect
{
	[[[self mainView] window] makeFirstResponder: nil];
}

- (void)dealloc
{
	NSLog(@"dealloc OSILocationsPreferencePanePref");
	
	[stringEncoding release];
	
	[TLSDHParameterFileURL release];
	[TLSSupportedCipherSuite release];
    [TLSAuthenticationCertificate release];
    
    [TLSSettings release];
    
    [_tlos release]; _tlos = nil;
	
	[super dealloc];
}

- (IBAction) newServer:(id)sender
{
    NSMutableDictionary *aServer = [NSMutableDictionary dictionary];
    [aServer setObject:@"127.0.0.1" forKey:@"Address"];
    [aServer setObject:@"PACS" forKey:@"AETitle"];
    [aServer setObject:@"11112" forKey:@"Port"];
	[aServer setObject:[NSNumber numberWithBool:YES] forKey:@"QR"];
	[aServer setObject:[NSNumber numberWithBool:YES] forKey:@"Send"];
    [aServer setObject:@"Description" forKey:@"Description"];
	[aServer setObject:[NSNumber numberWithInt:0] forKey:@"TransferSyntax"];
	[aServer setObject: [NSNumber numberWithInt: 0] forKey: @"retrieveMode"]; // CMove
	
	[aServer setObject:[NSNumber numberWithBool:NO] forKey:@"TLSEnabled"];
	[aServer setObject:[NSNumber numberWithBool:NO] forKey:@"TLSAuthenticated"];
	
	[dicomNodes addObject:aServer];
	
	[[dicomNodes tableView] scrollRowToVisible: [[dicomNodes tableView] selectedRow]];
	
	[self resetTest];
}

- (IBAction) osirixNewServer:(id)sender
{
    NSMutableDictionary *aServer = [NSMutableDictionary dictionary];
    [aServer setObject:@"osirix.hcuge.ch" forKey:@"Address"];
    [aServer setObject:@"OsiriX PACS Server" forKey:@"Description"];
    
    [osiriXServers addObject: aServer];
	
	[[osiriXServers tableView] scrollRowToVisible: [[osiriXServers tableView] selectedRow]];
	
	[[[self mainView] window] makeKeyAndOrderFront: self];
}

- (IBAction) cancel:(id)sender
{
	[NSApp abortModal];
}

- (IBAction) ok:(id)sender
{
	[NSApp stopModal];
}


- (void) resetTest
{
	for( int i = 0 ; i < [[dicomNodes arrangedObjects] count]; i++)
	{
		NSMutableDictionary *aServer = [[dicomNodes arrangedObjects] objectAtIndex: i];
		[aServer removeObjectForKey: @"test"];
	}
}

- (IBAction) OsiriXDBsaveAs:(id) sender;
{
	NSSavePanel		*sPanel		= [NSSavePanel savePanel];

	sPanel.allowedContentTypes = @[UTTypePropertyList];
    sPanel.nameFieldStringValue = NSLocalizedString(@"OsiriXDB.plist", nil);
	
    [sPanel beginWithCompletionHandler:^(NSInteger result) {
	        if (result != NSModalResponseOK)
            return;
        
        [[osiriXServers arrangedObjects] writeToURL:sPanel.URL atomically: YES];
    }];
}

- (IBAction) refreshNodesOsiriXDB: (id) sender
{
	if( [[NSUserDefaults standardUserDefaults] boolForKey:@"syncOsiriXDB"])
	{
		NSURL *url = [NSURL URLWithString: [[NSUserDefaults standardUserDefaults] valueForKey:@"syncOsiriXDBURL"]];
		
		if( url)
		{
			NSArray	*r = [NSArray arrayWithContentsOfURL: url];
			
			if( r)
			{
				[osiriXServers removeObjects: [osiriXServers arrangedObjects]];
				[osiriXServers addObjects: r];
			}
				else [HorosAlertPresenter runWithTitle:NSLocalizedString(@"URL Invalid", nil)
				                                    message:NSLocalizedString(@"Cannot download data from this URL.", nil)
				                                      style:NSAlertStyleInformational
				                                firstButton:NSLocalizedString(@"OK", nil)
				                               secondButton:nil
				                                thirdButton:nil];
			}
			else [HorosAlertPresenter runWithTitle:NSLocalizedString(@"URL Invalid", nil)
			                                message:NSLocalizedString(@"This URL is invalid. Check syntax.", nil)
			                                  style:NSAlertStyleInformational
			                            firstButton:NSLocalizedString(@"OK", nil)
			                           secondButton:nil
			                            thirdButton:nil];
	}
}

- (IBAction) OsiriXDBloadFrom:(id) sender;
{
	NSOpenPanel		*sPanel		= [NSOpenPanel openPanel];
	
	[self resetTest];
	
	sPanel.allowedContentTypes = @[UTTypePropertyList];
    
    [sPanel beginWithCompletionHandler:^(NSInteger result) {
	        if (result != NSModalResponseOK)
            return;
        
		NSArray	*r = [NSArray arrayWithContentsOfURL:sPanel.URL];
		
		if( r)
		{
				if ([HorosAlertPresenter runWithTitle:NSLocalizedString(@"Load locations", nil)
				                                      message:NSLocalizedString(@"Should I add or replace this locations list? If you choose 'replace', the current list will be deleted.", nil)
				                                        style:NSAlertStyleInformational
				                                  firstButton:NSLocalizedString(@"Add", nil)
				                                 secondButton:NSLocalizedString(@"Replace", nil)
				                                  thirdButton:nil] == NSAlertFirstButtonReturn)
			{
				
			}
			else [osiriXServers removeObjects: [osiriXServers arrangedObjects]];
			
			[osiriXServers addObjects: r];
			
			int i, x;
			
			for( i = 0; i < [[osiriXServers arrangedObjects] count]; i++)
			{
				NSDictionary	*server = [[osiriXServers arrangedObjects] objectAtIndex: i];
				
				for( x = 0; x < [[osiriXServers arrangedObjects] count]; x++)
				{
					NSDictionary	*c = [[osiriXServers arrangedObjects] objectAtIndex: x];
					
					if( c != server)
					{
						if( [[server valueForKey:@"Address"] isEqualToString: [c valueForKey:@"Address"]] &&
							[[server valueForKey:@"Description"] isEqualToString: [c valueForKey:@"Description"]])
							{
								[osiriXServers removeObjectAtArrangedObjectIndex: i];
								i--;
								x = [[osiriXServers arrangedObjects] count];
							}
					}
				}
			}
		}
    }];
}


- (IBAction) saveAs:(id) sender;
{
	NSSavePanel		*sPanel		= [NSSavePanel savePanel];

	sPanel.allowedContentTypes = @[UTTypePropertyList];
	
	[self resetTest];
	
    sPanel.nameFieldStringValue = NSLocalizedString(@"DICOMNodes.plist", nil);
    
    [sPanel beginWithCompletionHandler:^(NSInteger result) {
	        if (result != NSModalResponseOK)
            return;
        
        [[dicomNodes arrangedObjects] writeToURL:sPanel.URL atomically: YES];
    }];
}

- (IBAction) refreshNodesListURL: (id) sender
{
	if( [[NSUserDefaults standardUserDefaults] boolForKey:@"syncDICOMNodes"])
	{
		NSURL *url = [NSURL URLWithString: [[NSUserDefaults standardUserDefaults] valueForKey:@"syncDICOMNodesURL"]];
		
		if( url)
		{
			NSArray	*r = [NSArray arrayWithContentsOfURL: url];
			
			if( r)
			{
				[dicomNodes removeObjects: [dicomNodes arrangedObjects]];
				[dicomNodes addObjects: r];
			}
				else [HorosAlertPresenter runWithTitle:NSLocalizedString(@"URL Invalid", nil)
				                                    message:NSLocalizedString(@"Cannot download data from this URL.", nil)
				                                      style:NSAlertStyleInformational
				                                firstButton:NSLocalizedString(@"OK", nil)
				                               secondButton:nil
				                                thirdButton:nil];
			}
			else [HorosAlertPresenter runWithTitle:NSLocalizedString(@"URL Invalid", nil)
			                                message:NSLocalizedString(@"This URL is invalid. Check syntax.", nil)
			                                  style:NSAlertStyleInformational
			                            firstButton:NSLocalizedString(@"OK", nil)
			                           secondButton:nil
			                            thirdButton:nil];
	}
}

- (IBAction) loadFrom:(id) sender;
{
	NSOpenPanel		*sPanel		= [NSOpenPanel openPanel];
	
	[self resetTest];
	
	sPanel.allowedContentTypes = @[UTTypePropertyList];
	
    [sPanel beginWithCompletionHandler:^(NSInteger result) {
	        if (result != NSModalResponseOK) {
            [self resetTest];
            return;
        }
        
		NSArray	*r = [NSArray arrayWithContentsOfURL:sPanel.URL];
		
		if( r)
		{
				if ([HorosAlertPresenter runWithTitle:NSLocalizedString(@"Load locations", nil)
				                                      message:NSLocalizedString(@"Should I add or replace this locations list? If you choose 'replace', the current list will be deleted.", nil)
				                                        style:NSAlertStyleInformational
				                                  firstButton:NSLocalizedString(@"Add", nil)
				                                 secondButton:NSLocalizedString(@"Replace", nil)
				                                  thirdButton:nil] == NSAlertFirstButtonReturn)
			{
				
			}
			else [dicomNodes removeObjects: [dicomNodes arrangedObjects]];
			
			[dicomNodes addObjects: r];
			
			int i, x;
			
			for( i = 0; i < [[dicomNodes arrangedObjects] count]; i++)
			{
				NSDictionary	*server = [[dicomNodes arrangedObjects] objectAtIndex: i];
				
				for( x = 0; x < [[dicomNodes arrangedObjects] count]; x++)
				{
					NSDictionary	*c = [[dicomNodes arrangedObjects] objectAtIndex: x];
					
					if( c != server)
					{
						if( [[server valueForKey:@"AETitle"] isEqualToString: [c valueForKey:@"AETitle"]] &&
							[[server valueForKey:@"Address"] isEqualToString: [c valueForKey:@"Address"]] &&
							[[server valueForKey:@"Port"] intValue] == [[c valueForKey:@"Port"] intValue])
							{
								[dicomNodes removeObjectAtArrangedObjectIndex: i];
								i--;
								x = [[dicomNodes arrangedObjects] count];
							}
					}
				}
			}
		}
        
        [self resetTest];
    }];
}

- (void) testThread:(NSArray*) serverList
{
    @autoreleasepool
    {
        self.testingNodes = YES;
        
        for( NSMutableDictionary *aServer in [NSArray arrayWithArray: serverList])
        {
            int status;
            
            if( [[aServer objectForKey: @"Activated"] boolValue] && [OSILocationsPreferencePanePref echoServer:aServer])
                status = 0;
            else
                status = -1;
            
            [aServer setObject:[NSNumber numberWithInt: status] forKey:@"test"];
            
            [[dicomNodes tableView] performSelectorOnMainThread: @selector( display) withObject:nil waitUntilDone:NO];
        }
        
        self.testingNodes = NO;
    }
}

- (IBAction) test:(id) sender
{
    if( self.testingNodes)
        return;
    
    for( NSMutableDictionary *server in [dicomNodes arrangedObjects])
        [server setObject: @0 forKey:@"test"];
    
    [[dicomNodes tableView] display];
    
    [NSThread detachNewThreadSelector: @selector( testThread:) toTarget: self withObject: [dicomNodes arrangedObjects]];
}

- (IBAction) activateAllNone:(id) sender
{
	for( NSMutableDictionary *aServer in [dicomNodes arrangedObjects])
    {
        [aServer setObject: [NSNumber numberWithBool: [sender tag]] forKey: @"Activated"];
    }
    [[NSUserDefaults standardUserDefaults] setObject:[dicomNodes arrangedObjects] forKey:@"SERVERS"];
}


- (IBAction) setStringEncoding:(id)sender
{
	NSString *encoding;

	switch ([[sender selectedItem] tag]){
		case 0: encoding = @"ISO_IR 192";
			break;
		case 1: encoding = @"ISO_IR 100";
			break;
		case 2: encoding = @"ISO_IR 101";
			break;
		case 3: encoding = @"ISO_IR 109";
			break;
		case 4: encoding = @"ISO_IR 110";
			break;
		case 5: encoding = @"ISO_IR 127";
			break;
		case 6: encoding = @"ISO_IR 144";
			break;
		case 7: encoding = @"ISO_IR 126";
			break;
		case 8: encoding = @"ISO_IR 138";
			break;
		case 9: encoding = @"GB18030";
			break;
		case 10: encoding = @"ISO 2022 IR 149";
			break;
		case 11: encoding = @"ISO 2022 IR 13";
			break;
		case 12: encoding = @"ISO_IR 13";
			break;
		case 13: encoding = @"ISO 2022 IR 87";
			break;
		case 14: encoding = @"ISO_IR 1166";
			break;
		default: encoding = @"ISO_IR 100";
			break;
	}
	[[NSUserDefaults standardUserDefaults] setObject:encoding forKey:@"STRINGENCODING"];
	[stringEncoding release];
	stringEncoding = [encoding retain];
}

- (IBAction) addPath:(id) sender
{
	NSOpenPanel		*oPanel		= [NSOpenPanel openPanel];

    [oPanel setCanChooseFiles:YES];
    [oPanel setCanChooseDirectories:YES];

	    UTType *sqlType = [UTType typeWithFilenameExtension:@"sql"];
	    if (sqlType)
	        oPanel.allowedContentTypes = @[sqlType];
    
    [oPanel beginWithCompletionHandler:^(NSInteger result) {
	        if (result != NSModalResponseOK)
            return;
        
		NSString	*location = oPanel.URL.path;
		
		if( [[location lastPathComponent] isEqualToString:@"Horos Data"])
		{
			location = [location stringByDeletingLastPathComponent];
		}

		if( [[location lastPathComponent] isEqualToString:@"DATABASE"] && [[[location stringByDeletingLastPathComponent] lastPathComponent] isEqualToString:@"Horos Data"])
		{
			location = [[location stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
		}
		
		BOOL isDirectory;
		
		if( [[NSFileManager defaultManager] fileExistsAtPath: location isDirectory: &isDirectory])
		{
			NSDictionary	*dict = nil;
			
			if( isDirectory)
			{
				dict = [NSDictionary dictionaryWithObjectsAndKeys: location, @"Path", [[location lastPathComponent] stringByAppendingString: NSLocalizedString( @" DB", @"DB = DataBase")], @"Description", nil];
				
				[localPaths addObject: dict];
			
				[[localPaths tableView] scrollRowToVisible: [[localPaths tableView] selectedRow]];
			}
		}

        [[[self mainView] window] makeKeyAndOrderFront: self];
    }];
}

#pragma mark DICOM TLS Support

- (IBAction) editTLS: (id) sender
{	
	NSMutableDictionary *aServer = [[dicomNodes arrangedObjects] objectAtIndex:[[dicomNodes tableView] selectedRow]];
	
	self.TLSEnabled = [[aServer valueForKey:@"TLSEnabled"] boolValue];
	self.TLSAuthenticated = [[aServer valueForKey:@"TLSAuthenticated"] boolValue];

	[self getTLSCertificate];
	
	NSArray *selectedCipherSuites = [aServer valueForKey:@"TLSCipherSuites"];

	if ([selectedCipherSuites count])
		self.TLSSupportedCipherSuite = selectedCipherSuites;
	else
		self.TLSSupportedCipherSuite = [DICOMTLS defaultCipherSuites];

	self.TLSUseDHParameterFileURL = [[aServer valueForKey:@"TLSUseDHParameterFileURL"] boolValue];
	NSString *dhParameterFileURL = [aServer valueForKey:@"TLSDHParameterFileURL"];
	if(!dhParameterFileURL)
		dhParameterFileURL = NSHomeDirectory();
	self.TLSDHParameterFileURL = [NSURL fileURLWithPath:dhParameterFileURL];
	
	if([aServer valueForKey:@"TLSCertificateVerification"])
		self.TLSCertificateVerification = [[aServer valueForKey:@"TLSCertificateVerification"] intValue];
	else
		self.TLSCertificateVerification = IgnorePeerCertificate;
		
	[[[self mainView] window] beginSheet:TLSSettings completionHandler:nil];
	
	int result = [NSApp runModalForWindow: TLSSettings];
	[TLSSettings makeFirstResponder: nil];
	
	HorosEndSheet(TLSSettings);
	[TLSSettings orderOut: self];
	
	if( result == NSModalResponseStop)
	{
		[aServer setObject:[NSNumber numberWithBool:self.TLSEnabled] forKey:@"TLSEnabled"];
		
		if (self.TLSEnabled)
		{
			[aServer setObject:[NSNumber numberWithBool: self.TLSAuthenticated] forKey:@"TLSAuthenticated"];
						
			[aServer setObject:self.TLSSupportedCipherSuite forKey:@"TLSCipherSuites"];
			
			[aServer setObject:[NSNumber numberWithBool:self.TLSUseDHParameterFileURL] forKey:@"TLSUseDHParameterFileURL"];
			[aServer setObject:[self.TLSDHParameterFileURL path] forKey:@"TLSDHParameterFileURL"];
			
			[aServer setObject:[NSNumber numberWithInt:self.TLSCertificateVerification] forKey:@"TLSCertificateVerification"];
		}

		[[NSUserDefaults standardUserDefaults] setObject:[dicomNodes arrangedObjects] forKey:@"SERVERS"];
	}
}

- (IBAction)chooseTLSCertificate:(id)sender
{
	NSArray *certificates = [DDKeychain KeychainAccessCertificatesList];
	
	if([certificates count])
	{
		[[SFChooseIdentityPanel sharedChooseIdentityPanel] setAlternateButtonTitle:NSLocalizedString(@"Cancel", @"Cancel")];
		NSInteger clickedButton = [[SFChooseIdentityPanel sharedChooseIdentityPanel] runModalForIdentities:certificates message:NSLocalizedString(@"Choose a certificate from the following list.", nil)];
		
		if(clickedButton == NSModalResponseOK)
		{
			SecIdentityRef identity = [[SFChooseIdentityPanel sharedChooseIdentityPanel] identity];
			if(identity)
			{
				[DDKeychain KeychainAccessSetPreferredIdentity:identity forName:[self DICOMTLSUniqueLabelForSelectedServer] keyUse:CSSM_KEYUSE_ANY];
				[self getTLSCertificate];
			}
		}
		else if(clickedButton == NSModalResponseCancel)
			return;
	}
	else
	{
		NSInteger clickedButton = [HorosAlertPresenter runWithTitle:NSLocalizedString(@"No Valid Certificate", nil)
		                                                     message:NSLocalizedString(@"Your Keychain does not contain any valid certificate.", nil)
		                                                       style:NSAlertStyleCritical
		                                                 firstButton:NSLocalizedString(@"Help", nil)
		                                                secondButton:NSLocalizedString(@"Cancel", nil)
		                                                 thirdButton:nil];
		
		if(clickedButton == NSAlertFirstButtonReturn)
		{
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:URL_HOROS_DOC_SECURITY]];
		}
		
		return;
	}
}

- (IBAction)viewTLSCertificate:(id)sender;
{
	NSString *label = [self DICOMTLSUniqueLabelForSelectedServer];
	[DDKeychain openCertificatePanelForLabel:label];
}

- (void)getTLSCertificate;
{	
	NSString *label = [self DICOMTLSUniqueLabelForSelectedServer];
	NSString *name = [DDKeychain certificateNameForLabel:label];
	NSImage *icon = [DDKeychain certificateIconForLabel:label];
	
	if(!name)
	{
		name = NSLocalizedString(@"No certificate selected.", nil);	
		[TLSCertificateButton setHidden:YES];
		[TLSChooseCertificateButton setTitle:NSLocalizedString(@"Choose", nil)];
	}
	else
	{
		[TLSCertificateButton setHidden:NO];
		[TLSCertificateButton setImage:icon];
		[TLSChooseCertificateButton setTitle:NSLocalizedString(@"Change", nil)];
	}

	self.TLSAuthenticationCertificate = name;
}

- (NSString*)DICOMTLSUniqueLabelForSelectedServer;
{
	NSMutableDictionary *aServer = [[dicomNodes arrangedObjects] objectAtIndex:[[dicomNodes tableView] selectedRow]];
	return [DICOMTLS uniqueLabelForServerAddress:[aServer valueForKey:@"Address"] port:[NSString stringWithFormat:@"%d",[[aServer valueForKey:@"Port"] intValue]] AETitle:[aServer valueForKey:@"AETitle"]];
}

- (IBAction)selectAllSuites:(id)sender;
{
	for( NSMutableDictionary *suite in self.TLSSupportedCipherSuite)
		[suite setObject: [NSNumber numberWithBool: YES] forKey: @"Supported"];
}

- (IBAction)deselectAllSuites:(id)sender;
{
	for( NSMutableDictionary *suite in self.TLSSupportedCipherSuite)
		[suite setObject: [NSNumber numberWithBool: NO] forKey: @"Supported"];
}

@end
