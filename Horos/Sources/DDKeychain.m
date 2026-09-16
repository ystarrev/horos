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

#import "DDKeychain.h"
#import "DICOMTLS.h"
#include <stdio.h>

static NSMutableDictionary *lockedFiles = nil;
static NSRecursiveLock *lockFile = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/*
 * Function: SSLSecPolicyCopy
 * Purpose:
 *   Returns a copy of the SSL policy.
 */
static OSStatus SSLSecPolicyCopy(SecPolicyRef *ret_policy)
{
	SecPolicyRef policy;
	SecPolicySearchRef policy_search;
	OSStatus status;
	
	*ret_policy = NULL;
	status = SecPolicySearchCreate(CSSM_CERT_X_509v3, &CSSMOID_APPLE_TP_SSL, NULL, &policy_search);
	//status = SecPolicySearchCreate(CSSM_CERT_X_509v3, &CSSMOID_APPLE_X509_BASIC, NULL, &policy_search);
    if (status == errSecSuccess) {
        status = SecPolicySearchCopyNext(policy_search, &policy);
        
        if (status == errSecSuccess)
            *ret_policy = policy;
	
        CFRelease(policy_search);
    }
    
	return (status);
}


@implementation DDKeychain

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Creates (if necessary) and returns a temporary directory for the application.
 *
 * A general temporary directory is provided for each user by the OS.
 * This prevents conflicts between the same application running on multiple user accounts.
 * We take this a step further by putting everything inside another subfolder, identified by our application name.
**/
+ (NSString *)applicationTemporaryDirectory
{
	NSString *userTempDir = NSTemporaryDirectory();
	NSString *appTempDir = [userTempDir stringByAppendingPathComponent:@"Horos Keychain"];
	
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if([fileManager fileExistsAtPath:appTempDir] == NO)
	{
		[fileManager createDirectoryAtPath:appTempDir withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	
	return appTempDir;
}

/**
 * Simple utility class to convert a SecExternalFormat into a string suitable for printing/logging.
**/
+ (NSString *)stringForSecExternalFormat:(SecExternalFormat)extFormat
{
	switch(extFormat)
	{
		case kSecFormatUnknown              : return @"kSecFormatUnknown";
			
		/* Asymmetric Key Formats */
		case kSecFormatOpenSSL              : return @"kSecFormatOpenSSL";
		case kSecFormatSSH                  : return @"kSecFormatSSH - Not Supported";
		case kSecFormatBSAFE                : return @"kSecFormatBSAFE";
			
		/* Symmetric Key Formats */
		case kSecFormatRawKey               : return @"kSecFormatRawKey";
			
		/* Formats for wrapped symmetric and private keys */
		case kSecFormatWrappedPKCS8         : return @"kSecFormatWrappedPKCS8";
		case kSecFormatWrappedOpenSSL       : return @"kSecFormatWrappedOpenSSL";
		case kSecFormatWrappedSSH           : return @"kSecFormatWrappedSSH - Not Supported";
		case kSecFormatWrappedLSH           : return @"kSecFormatWrappedLSH - Not Supported";
			
		/* Formats for certificates */
		case kSecFormatX509Cert             : return @"kSecFormatX509Cert";
			
		/* Aggregate Types */
		case kSecFormatPEMSequence          : return @"kSecFormatPEMSequence";
		case kSecFormatPKCS7                : return @"kSecFormatPKCS7";
		case kSecFormatPKCS12               : return @"kSecFormatPKCS12";
		case kSecFormatNetscapeCertSequence : return @"kSecFormatNetscapeCertSequence";
			
		default                             : return @"Unknown";
	}
}

/**
 * Simple utility class to convert a SecExternalItemType into a string suitable for printing/logging.
**/
+ (NSString *)stringForSecExternalItemType:(SecExternalItemType)itemType
{
	switch(itemType)
	{
		case kSecItemTypeUnknown     : return @"kSecItemTypeUnknown";
			
		case kSecItemTypePrivateKey  : return @"kSecItemTypePrivateKey";
		case kSecItemTypePublicKey   : return @"kSecItemTypePublicKey";
		case kSecItemTypeSessionKey  : return @"kSecItemTypeSessionKey";
		case kSecItemTypeCertificate : return @"kSecItemTypeCertificate";
		case kSecItemTypeAggregate   : return @"kSecItemTypeAggregate";
		
		default                      : return @"Unknown";
	}
}

/**
 * Simple utility class to convert a SecKeychainAttrType into a string suitable for printing/logging.
**/
+ (NSString *)stringForSecKeychainAttrType:(SecKeychainAttrType)attrType
{
	switch(attrType)
	{
		case kSecCreationDateItemAttr       : return @"kSecCreationDateItemAttr";
		case kSecModDateItemAttr            : return @"kSecModDateItemAttr";
		case kSecDescriptionItemAttr        : return @"kSecDescriptionItemAttr";
		case kSecCommentItemAttr            : return @"kSecCommentItemAttr";
		case kSecCreatorItemAttr            : return @"kSecCreatorItemAttr";
		case kSecTypeItemAttr               : return @"kSecTypeItemAttr";
		case kSecScriptCodeItemAttr         : return @"kSecScriptCodeItemAttr";
		case kSecLabelItemAttr              : return @"kSecLabelItemAttr";
		case kSecInvisibleItemAttr          : return @"kSecInvisibleItemAttr";
		case kSecNegativeItemAttr           : return @"kSecNegativeItemAttr";
		case kSecCustomIconItemAttr         : return @"kSecCustomIconItemAttr";
		case kSecAccountItemAttr            : return @"kSecAccountItemAttr";
		case kSecServiceItemAttr            : return @"kSecServiceItemAttr";
		case kSecGenericItemAttr            : return @"kSecGenericItemAttr";
		case kSecSecurityDomainItemAttr     : return @"kSecSecurityDomainItemAttr";
		case kSecServerItemAttr             : return @"kSecServerItemAttr";
		case kSecAuthenticationTypeItemAttr : return @"kSecAuthenticationTypeItemAttr";
		case kSecPortItemAttr               : return @"kSecPortItemAttr";
		case kSecPathItemAttr               : return @"kSecPathItemAttr";
		case kSecVolumeItemAttr             : return @"kSecVolumeItemAttr";
		case kSecAddressItemAttr            : return @"kSecAddressItemAttr";
		case kSecSignatureItemAttr          : return @"kSecSignatureItemAttr";
		case kSecProtocolItemAttr           : return @"kSecProtocolItemAttr";
		case kSecCertificateType            : return @"kSecCertificateType";
		case kSecCertificateEncoding        : return @"kSecCertificateEncoding";
		case kSecCrlType                    : return @"kSecCrlType";
		case kSecCrlEncoding                : return @"kSecCrlEncoding";
		case kSecAlias                      : return @"kSecAlias";
		default                             : return @"Unknown";
	}
}

+ (NSString *)stringForError:(OSStatus)status;
{
	CFStringRef msg = SecCopyErrorMessageString(status, NULL);
	NSString *errorMsg = [NSString stringWithString:(NSString*)msg];
	CFRelease(msg);
	
	return errorMsg;
}

# pragma mark Keychain Access


+ (NSArray *)KeychainAccessCertificatesList {
    CFArrayRef searchList;
    SecKeychainCopySearchList (&searchList);
    
    CFTypeRef   arrayRef     = NULL;
    NSDictionary * dict = @{
                            (id) kSecClass: (id) kSecClassIdentity,
                            (id) kSecMatchLimit: (id) kSecMatchLimitAll,
                            (id) kSecReturnAttributes: (id) kCFBooleanTrue,
                            (id) kSecReturnRef: (id) kCFBooleanTrue,
                            };
    
    OSStatus err = SecItemCopyMatching((CFDictionaryRef) dict, &arrayRef);

    if (err != errSecSuccess) {
        if (err == errSecItemNotFound)
            return [NSArray array];
        NSLog(@"%@:%s: SecItemCopyMatching failed: %@", [[self class] description],
              __PRETTY_FUNCTION__, [DDKeychain stringForError:err]);
        return nil;
    }
    
    NSMutableArray * found = [NSMutableArray array];
    
    for(int i = 0; i < CFArrayGetCount(arrayRef); i++) {
        NSDictionary * attr = (__bridge NSDictionary *)(CFArrayGetValueAtIndex(arrayRef, i));
        /*NSString * label = (NSString *)[attr objectForKey:(id)kSecAttrLabel];*/
        
        if (YES)  {
            SecIdentityRef identityRef = (__bridge SecIdentityRef)([attr objectForKey:(id)kSecValueRef]);
            SecCertificateRef certRef;
            err = SecIdentityCopyCertificate(identityRef, &certRef);
            if (err != errSecSuccess) {
                NSLog(@"%@:%s: SecIdentityCopyCertificate failed: %@ (skipping %@)", [[self class] description],
                      __PRETTY_FUNCTION__, [DDKeychain stringForError:err], identityRef);
                goto skip;
            }

            NSDictionary * valRef = CFBridgingRelease(SecCertificateCopyValues(certRef, nil, nil));

#if 0
            SecKeychainRef keychainRef;
            err = SecKeychainItemCopyKeychain((SecKeychainItemRef)identityRef, &keychainRef);
            if (err != errSecSuccess) {
                NSLog(@"%@:%s: SecKeychainItemCopyKeychain failed: %@ (skipping %@)", [[self class] description],
                      __PRETTY_FUNCTION__, [DDKeychain stringForError:err], identityRef);
                goto skip;
            };
            
            char path[PATH_MAX];
            UInt32 len = sizeof(path);
            err = SecKeychainGetPath(keychainRef, &len, path);
            if (err != errSecSuccess) {
                NSLog(@"%@:%s: SecKeychainGetPath failed: %@ (skipping %@)", [[self class] description],
                      __PRETTY_FUNCTION__, [DDKeychain stringForError:err], identityRef);
                goto skip;
            };
            NSLog(@"%@: %s",[valRef objectForKey:(__bridge id)(kSecOIDCommonName)], path);
#endif
            
            // Skip certs which cannot be used. Page 29 of ITU-T Rec. X.509 (11/2008):
            //
            // KeyUsage  ::=  BIT STRING {
            //    digitalSignature  (0),
            //    contentCommitment (1),
            //    keyEncipherment   (2),
            //    dataEncipherment  (3),
            //    keyAgreement      (4),
            //    keyCertSign       (5),
            //    cRLSign           (6),
            //    encipherOnly      (7),
            //    decipherOnly      (8),
            //
            NSDictionary * keyUsage = [valRef objectForKey:(__bridge id)(kSecOIDKeyUsage)];
            NSInteger flag = keyUsage ? [[keyUsage objectForKey:@"value"] integerValue] : 0;
            
            CFBooleanRef invisible = (CFBooleanRef) [valRef objectForKey:(__bridge id)(kSecAttrIsInvisible)];
            
            // Value of 0 is implies any use - seems to be passed by apple if none is set.
            //
            if (invisible == kCFBooleanTrue)
                goto skip;
            
            if ((flag != 0)&& ((flag & 1) == 0))
                goto skip;
                
                [found addObject:(__bridge id)(identityRef)];
        skip:
            CFRelease(certRef);
        }
    };
    if (arrayRef)
        CFRelease(arrayRef);
    if (searchList)
        CFRelease(searchList);

    return found;
}

+ (void)KeychainAccessExportTrustedCertificatesToDirectory:(NSString*)directory;
{
	BOOL isDirectory, directoryExists;
	
	directoryExists = [[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory];
	if(directoryExists) return;
	if(!directoryExists)[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil];
		
	int domains[3] = {kSecTrustSettingsDomainUser, kSecTrustSettingsDomainAdmin, kSecTrustSettingsDomainSystem};
	
	CFArrayRef certArray = NULL;
	OSStatus status;
	CFIndex numCerts, dex;
	int i;
	for (i=0; i<3; i++)
	{
		status = SecTrustSettingsCopyCertificates(domains[i], &certArray);
		if(status) cssmPerror("SecTrustSettingsCopyCertificates", status);
		
		if( certArray)
		{
			numCerts = CFArrayGetCount(certArray);

			for(dex=0; dex<numCerts; dex++)
			{
				SecCertificateRef certRef = (SecCertificateRef)CFArrayGetValueAtIndex(certArray, dex);			
				CFDataRef certificateDataRef = NULL;
				status = SecKeychainItemExport(certRef, kSecFormatX509Cert, kSecItemPemArmour, NULL, &certificateDataRef);
				
				if(status==0)
				{
					NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d_%d.pem", i, (int) dex]];
					if(![[NSFileManager defaultManager] fileExistsAtPath:path])
						[(NSData*)certificateDataRef writeToFile:path atomically:YES];
				}
				else NSLog(@"SecKeychainItemExport : error : %@", [DDKeychain stringForError:status]);
				
			}
			
			CFRelease(certArray);
			certArray = NULL;
		}
	}
}

// Returns a reference to the preferred identity, or NULL if none was found.
// Call the CFRelease function to release this object when you are finished with it.
+ (SecIdentityRef)KeychainAccessPreferredIdentityForName:(NSString*)name keyUse:(int)keyUse;
{
	SecIdentityRef identity = NULL;
	OSStatus status = SecIdentityCopyPreference((CFStringRef)name, keyUse, NULL, &identity);
	if(status!=0) NSLog(@"KeychainAccessPreferredIdentityForName:%@ keyUse: error: %@", name, [DDKeychain stringForError:status]);
	return identity;
}

+ (void)KeychainAccessSetPreferredIdentity:(SecIdentityRef)identity forName:(NSString*)name keyUse:(int)keyUse;
{
	if(identity)
	{
		OSStatus status = SecIdentitySetPreference(identity, (CFStringRef)name, keyUse);
		if(status!=0) NSLog(@"KeychainAccessSetPreferredIdentity:forName:keyUse: error: %@", [DDKeychain stringForError:status]);
	}
}	

+ (NSString*)KeychainAccessCertificateCommonNameForIdentity:(SecIdentityRef)identity;
{
	NSString *name = nil;
	if(identity)
	{		
		SecCertificateRef certificateRef = NULL;
		SecIdentityCopyCertificate(identity, &certificateRef);
		if(certificateRef)
		{
			CFStringRef commonName = NULL;
			OSStatus status = SecCertificateCopyCommonName(certificateRef, &commonName);
			if(status==0)
			{
				name = [NSString stringWithString:(NSString*)commonName];
				CFRelease(commonName);
			}
			else NSLog(@"KeychainAccessCertificateCommonNameForIdentity: error: %@", [DDKeychain stringForError:status]);
			
			CFRelease(certificateRef);
		}		
	}	
	return name;
}

/*
 * The following method returns the correct icon for a certificate:
 *	- the blue icon for "Standard certificates"
 *	- the gold icon for "Self signed certificates"
 *
 *	The hypothese is : if the subject == the issuer then it is a Self signed certificate
 *	It _seems_ to work (Joris)
 */
+ (NSImage*)KeychainAccessCertificateIconForIdentity:(SecIdentityRef)identity;
{
	NSImage *icon = nil;
	
	if(identity)
	{	
		SecCertificateRef certificateRef = NULL;
		SecIdentityCopyCertificate(identity, &certificateRef);	
		if(certificateRef)
		{
			const CSSM_X509_NAME *subject, *issuer;
			SecCertificateGetSubject(certificateRef, &subject);
			SecCertificateGetIssuer(certificateRef, &issuer);
			
			BOOL equal = YES;
			if(subject->numberOfRDNs==issuer->numberOfRDNs)
			{
				int i, j;
				for (i=0; i<subject->numberOfRDNs; i++)
				{
					CSSM_X509_RDN issuerRDN = issuer->RelativeDistinguishedName[i];
					CSSM_X509_RDN subjectRDN = subject->RelativeDistinguishedName[i];
										
					if(issuerRDN.numberOfPairs==subjectRDN.numberOfPairs)
					{
						for (j=0; j<subjectRDN.numberOfPairs; j++)
						{
							CSSM_X509_TYPE_VALUE_PAIR issuerVP = issuerRDN.AttributeTypeAndValue[j];
							CSSM_X509_TYPE_VALUE_PAIR subjectVP = subjectRDN.AttributeTypeAndValue[j];

							NSData *issuerVPData = [NSData dataWithBytes:issuerVP.value.Data length:issuerVP.value.Length];
							NSData *subjectVPData = [NSData dataWithBytes:subjectVP.value.Data length:subjectVP.value.Length];
							
							if ([issuerVPData isEqualToData:subjectVPData])
								equal &= YES;
							else
							{
								equal = NO;
								break;
							}
						}
					}
					else
					{
						equal = NO;
						break;
					}
				}
			}
			else
				equal = NO;

			CFRelease(certificateRef);
			
			if(equal)
			{
				// Self signed certificate
				icon = [NSImage imageNamed:@"CertSmallRoot.tif"];
			}
			else 
			{
				// Standard certificate
				icon = [NSImage imageNamed:@"CertSmallStd.tif"];
			}
		}	
	}	
	return icon;
}

+ (NSArray*)KeychainAccessCertificateChainForIdentity:(SecIdentityRef)identity;
{
	OSStatus status;
    NSArray *returnedValue = nil;
    
	if(identity)
	{		
		SecCertificateRef certificateRef = NULL;
		SecIdentityCopyCertificate(identity, &certificateRef);
		
		if(certificateRef)
		{
			SecPolicyRef sslPolicy = NULL;		
			status = SSLSecPolicyCopy(&sslPolicy);
			
			if(status==0)
			{
				if(sslPolicy)
				{
					SecTrustRef trust = NULL;
					status = SecTrustCreateWithCertificates((CFArrayRef)[NSArray arrayWithObject:(id)certificateRef], sslPolicy, &trust);
					if(status==0)
					{
						SecTrustResultType result;
						status = SecTrustEvaluate(trust, &result);
						
						if(status==0)
						{
							CFArrayRef certChain;
							CSSM_TP_APPLE_EVIDENCE_INFO *statusChain;
							status = SecTrustGetResult(trust, &result, &certChain, &statusChain);
							if(status==0)
							{
								NSArray *certificatesChain = [NSArray arrayWithArray:(NSArray*)certChain];
								CFRelease(certChain);
								returnedValue = certificatesChain;
							}
							else NSLog(@"SecTrustGetResult : error : %@", [DDKeychain stringForError:status]);
						}
						else NSLog(@"SecTrustEvaluate : error : %@", [DDKeychain stringForError:status]);	
						
						CFRelease(trust);
					}
					else NSLog(@"SecTrustCreateWithCertificates : error : %@", [DDKeychain stringForError:status]);

					CFRelease(sslPolicy);
				}
			}
			else NSLog(@"SSLSecPolicyCopy : error : %@", [DDKeychain stringForError:status]);

			CFRelease(certificateRef);
		}
	}
	return returnedValue;
}

+ (void)KeychainAccessExportCertificateForIdentity:(SecIdentityRef)identity toPath:(NSString*)path;
{
	if([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
	
	SecCertificateRef certificate = NULL;
	OSStatus status = SecIdentityCopyCertificate(identity, &certificate);
	if(status==0)
	{
		CFDataRef certificateDataRef = NULL;
		status = SecKeychainItemExport(certificate, kSecFormatX509Cert, kSecItemPemArmour, NULL, &certificateDataRef);
		
		if(status==0)
		{
			[(NSData*)certificateDataRef writeToFile:path atomically:YES];
		}
		else NSLog(@"SecKeychainItemExport : error : %@", [DDKeychain stringForError:status]);
		
		CFRelease(certificate);	
	}
	else NSLog(@"SecIdentityCopyCertificate : error : %@", [DDKeychain stringForError:status]);	
}

+ (void)KeychainAccessExportPrivateKeyForIdentity:(SecIdentityRef)identity toPath:(NSString*)path cryptWithPassword:(NSString*)password;
{
	if([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
		
	SecKeyRef privateKey = NULL;
	OSStatus status = SecIdentityCopyPrivateKey(identity, &privateKey);
	if(status==0)
	{
		CFDataRef privateKeyDataRef = NULL;
		SecKeyImportExportParameters exportParameters = {.passphrase=(CFStringRef)password};
		
		status = SecKeychainItemExport(privateKey, kSecFormatPKCS12, 0, &exportParameters, &privateKeyDataRef);
		
		if(status==0)
		{
			[(NSData*)privateKeyDataRef writeToFile:[path stringByAppendingPathExtension:@"p12"] atomically:YES];
			
			// convert the private key file from PKCS#12 format to PEM format:
			// $ openssl pkcs12 -in key.p12 -out key.pem -passin pass:passwordIN -passout pass:passwordOUT
			
			NSArray *args = [NSArray arrayWithObjects:	@"pkcs12",
							 @"-in", [path stringByAppendingPathExtension:@"p12"],
							 @"-out", path,
							 @"-passin", [NSString stringWithFormat:@"pass:%@", password],
							 @"-passout", [NSString stringWithFormat:@"pass:%@", password], nil];
			
			NSTask *convertTask = [[[NSTask alloc] init] autorelease];
			[convertTask setLaunchPath:@"/usr/bin/openssl"];
			[convertTask setArguments:args];
			[convertTask launch];
			
            while( [convertTask isRunning])
                [NSThread sleepForTimeInterval: 0.1];
            
			[[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingPathExtension:@"p12"] error:NULL]; // remove the .p12 file
		}
		else NSLog(@"SecKeychainItemExport : error : %@", [DDKeychain stringForError:status]);
		
		CFRelease(privateKey);
	}
	else NSLog(@"SecIdentityCopyPrivateKey : error : %@", [DDKeychain stringForError:status]);			
}

+ (void)KeychainAccessOpenCertificatePanelForIdentity:(SecIdentityRef)identity;
{
	if(identity)
	{		
		SecCertificateRef certificateRef = NULL;
		SecIdentityCopyCertificate(identity, &certificateRef);
		if(certificateRef)
		{
			NSMutableArray *certificates = [NSMutableArray arrayWithObject:(id)certificateRef];
			NSArray *certificateChain = [DDKeychain KeychainAccessCertificateChainForIdentity:identity];
			[certificates addObjectsFromArray:certificateChain];
			
			[[SFCertificatePanel sharedCertificatePanel] runModalForCertificates:certificates showGroup:YES];		
			CFRelease(certificateRef);
		}
	}
}

#pragma mark-

// Returns a reference to the preferred identity for DICOM TLS, or NULL if none was found.
// Call the CFRelease function to release this object when you are finished with it.
+ (SecIdentityRef)identityForLabel:(NSString*)label;
{
	return [DDKeychain KeychainAccessPreferredIdentityForName:label keyUse:CSSM_KEYUSE_ANY];
}

+ (NSString*)certificateNameForLabel:(NSString*)label;
{
	SecIdentityRef identity = [DDKeychain identityForLabel:label];
	
	NSString *name = nil;
	if(identity)
	{
		name = [NSString stringWithString:[DDKeychain KeychainAccessCertificateCommonNameForIdentity:identity]];
		CFRelease(identity);
	}
	
	return name;
}

+ (NSImage*)certificateIconForLabel:(NSString*)label;
{
	SecIdentityRef identity = [DDKeychain identityForLabel:label];
	
	NSImage *icon = nil;
	if(identity)
	{
		icon = [DDKeychain KeychainAccessCertificateIconForIdentity:identity];
		CFRelease(identity);
	}
	
	return icon;
}

+ (void)openCertificatePanelForLabel:(NSString*)label;
{
	SecIdentityRef identity = [DDKeychain identityForLabel:label];
	if(identity)
	{
		[DDKeychain KeychainAccessOpenCertificatePanelForIdentity:identity];
		CFRelease(identity);
	}
}

#pragma mark Other Utilities

+ (void)generatePseudoRandomFileToPath:(NSString*)path;
{
	NSPoint mouseLocation = [NSEvent mouseLocation];
	NSTimeInterval time = [[NSDate date] timeIntervalSince1970];

	NSString *string = [NSString stringWithFormat:@"%f%f%lf", mouseLocation.x, mouseLocation.y, time];
	[string writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (void)lockFile:(NSString*)path;
{
	if(!lockedFiles) lockedFiles = [[NSMutableDictionary dictionary] retain];
	
	@synchronized( lockedFiles)
	{
		int n=0;
		
		if([[lockedFiles allKeys] containsObject:path])
		{
			n = [(NSNumber*)[lockedFiles objectForKey:path] intValue];
		}
		
		[lockedFiles setObject:[NSNumber numberWithInt:n+1] forKey:path];
		NSLog(@"lockFile: %d %@", n+1, path);
	}
}

+ (void)unlockFile:(NSString*)path;
{	
	@synchronized( lockedFiles)
	{
		int n=0;
		
		if(lockedFiles)
		{
			if([[lockedFiles allKeys] containsObject:path])
			{
				n = [(NSNumber*)[lockedFiles objectForKey:path] intValue];
				n--;
				[lockedFiles setObject:[NSNumber numberWithInt:n] forKey:path];
				NSLog(@"unlockFile: %d %@", n, path);
			}
		}
		
		if(n==0)
		{
			[lockedFiles removeObjectForKey:path];
			//[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
			//NSLog(@"removeItemAtPath: %@", path);
		}
	}
}

+ (void)lockTmpFiles;
{
	if(!lockFile) lockFile = [[NSRecursiveLock alloc] init];
	
	[lockFile lock];
}

+ (void)unlockTmpFiles;
{
	[lockFile unlock];
	//NSString *cmd = [NSString stringWithFormat:@"rm %@* %@*", TLS_PRIVATE_KEY_FILE, TLS_CERTIFICATE_FILE];
	//system([cmd cStringUsingEncoding:NSUTF8StringEncoding]);
}

#pragma clang diagnostic pop

@end
