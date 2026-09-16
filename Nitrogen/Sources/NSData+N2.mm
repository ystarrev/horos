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

#import "NSData+N2.h"
#include <CommonCrypto/CommonDigest.h>

char hexchar2dec(char hex) {
	if (hex >= '0' && hex <= '9')
		return hex-'0';
	if (hex >= 'A' && hex <= 'F')
		return hex-'A'+10;
	if (hex >= 'a' && hex <= 'f')
		return hex-'a'+10;
	return -1;
}

char hex2char(const char* hex) {
	return (hexchar2dec(hex[0])<<4)+hexchar2dec(hex[1]);
}


@implementation NSData (N2)

+(NSData*)dataWithHex:(NSString*)hex {
	if (!hex) return NULL;
	return [[[NSData alloc] initWithHex:hex] autorelease];
}

-(NSData*)initWithHex:(NSString*)hex {
	NSUInteger length = [hex length]/2;
	char* buffer = (char*)malloc(length);
	const char* utf8 = [hex UTF8String];
	
	//#pragma omp parallel for
	for (int i = 0; i < (int)length; ++i)
		buffer[i] = hex2char(&utf8[i*2]);
	
	return [self initWithBytesNoCopy:buffer length:length];
}


-(NSString*)hex {
	NSMutableString* stringBuffer = [NSMutableString stringWithCapacity:([self length] * 2)];
	const unsigned char* dataBuffer = (unsigned char*)[self bytes];
	for (int i = 0; i < [self length]; ++i)
		[stringBuffer appendFormat:@"%02X", (unsigned int) dataBuffer[i]];
	return [[stringBuffer copy] autorelease];
}

-(NSData*)md5 {
    NSMutableData* hash = [NSMutableData dataWithLength:16];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // MD5 is retained here for stable legacy identifiers, not for security.
    CC_MD5(self.bytes, self.length, (unsigned char*)hash.mutableBytes);
#pragma clang diagnostic pop
    return hash;
} 


@end
