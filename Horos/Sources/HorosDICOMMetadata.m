#import "HorosDICOMMetadata.h"

static NSString *HorosMetadataNodeName(NSString *name)
{
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"];
    NSString *result = [[(name ?: @"Unknown") componentsSeparatedByCharactersInSet:allowed.invertedSet]
                        componentsJoinedByString:@"_"];
    if (result.length == 0)
        return @"Unknown";
    if ([[NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"] characterIsMember:[result characterAtIndex:0]])
        result = [@"Tag_" stringByAppendingString:result];
    return result;
}

NSXMLElement *HorosDICOMMetadataAttribute(NSString *tag, NSString *name, NSString *vr, NSArray<NSString *> *values)
{
    NSArray *parts = [tag.lowercaseString componentsSeparatedByString:@","];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    if (parts.count != 2 || [parts[0] length] != 4 || [parts[1] length] != 4 ||
        [parts[0] rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound ||
        [parts[1] rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound)
        return nil;

    NSXMLElement *node = [NSXMLElement elementWithName:HorosMetadataNodeName(name)];
    [node addAttribute:[NSXMLNode attributeWithName:@"group" stringValue:parts[0]]];
    [node addAttribute:[NSXMLNode attributeWithName:@"element" stringValue:parts[1]]];
    [node addAttribute:[NSXMLNode attributeWithName:@"attributeTag" stringValue:tag.lowercaseString]];
    [node addAttribute:[NSXMLNode attributeWithName:@"vr" stringValue:vr ?: @"UN"]];
    for (NSString *value in values)
    {
        NSXMLElement *child = [NSXMLElement elementWithName:@"value" stringValue:value];
        [child addAttribute:[NSXMLNode attributeWithName:@"number" stringValue:
                             [NSString stringWithFormat:@"%lu", (unsigned long)node.childCount]]];
        [node addChild:child];
    }
    return node;
}

static BOOL HorosAppendMetadataNodes(NSXMLElement *source, NSXMLElement *target, NSUInteger depth)
{
    // Each DICOM nesting level contributes both a sequence and an item node.
    if (depth > 256)
        return NO;
    for (NSXMLNode *child in source.children)
    {
        if (child.kind != NSXMLElementKind)
            continue;
        NSXMLElement *element = (NSXMLElement *)child;
        if ([element.name isEqualToString:@"item"])
        {
            NSXMLElement *item = [NSXMLElement elementWithName:@"item"];
            if (!HorosAppendMetadataNodes(element, item, depth + 1))
                return NO;
            [target addChild:item];
            continue;
        }
        NSString *tag = [[element attributeForName:@"tag"] stringValue];
        NSString *vr = [[element attributeForName:@"vr"] stringValue];
        BOOL sequence = [element.name isEqualToString:@"sequence"] && [vr isEqualToString:@"SQ"];
        BOOL binary = [element attributeForName:@"binary"] != nil ||
                      ([element.name isEqualToString:@"sequence"] && !sequence);
        BOOL unloaded = [[[element attributeForName:@"loaded"] stringValue] isEqualToString:@"no"];
        NSArray *values = nil;
        if (!sequence)
        {
            if (binary || unloaded)
                values = @[[NSString stringWithFormat:@"[%@ data not displayed]", binary ? @"Binary" : @"Unloaded"]];
            else
            {
                NSString *value = element.stringValue ?: @"";
                // ST/LT/UT/UR may contain literal backslashes; only split actual VM.
                BOOL multiple = [[[element attributeForName:@"vm"] stringValue] integerValue] > 1;
                values = multiple ? [value componentsSeparatedByString:@"\\"] : @[value];
            }
        }
        NSXMLElement *node = HorosDICOMMetadataAttribute(tag,
            [[element attributeForName:@"name"] stringValue], vr, values);
        if (node == nil)
            return NO;
        if (binary || unloaded || sequence)
            [node addAttribute:[NSXMLNode attributeWithName:@"readOnly" stringValue:@"true"]];
        for (NSString *key in @[@"len", @"vm"])
        {
            NSString *value = [[element attributeForName:key] stringValue];
            if (value != nil)
                [node addAttribute:[NSXMLNode attributeWithName:key stringValue:value]];
        }
        if (sequence && !HorosAppendMetadataNodes(element, node, depth + 1))
            return NO;
        [target addChild:node];
    }
    return YES;
}

NSXMLDocument *HorosDICOMMetadataDocument(NSString *xml, NSError **error)
{
    if (error != NULL)
        *error = nil;
    NSXMLDocument *source = xml ? [[[NSXMLDocument alloc] initWithXMLString:xml
        options:NSXMLNodeLoadExternalEntitiesNever error:error] autorelease] : nil;
    if (source == nil)
        return nil;

    NSXMLElement *root = [NSXMLElement elementWithName:@"DICOMObject"];
    BOOL valid = source.DTD == nil;
    if (valid && [source.rootElement.name isEqualToString:@"file-format"])
    {
        for (NSXMLNode *section in source.rootElement.children)
            if (section.kind == NSXMLElementKind)
                valid = valid && ([@[@"meta-header", @"data-set"] containsObject:section.name]) &&
                    HorosAppendMetadataNodes((NSXMLElement *)section, root, 0);
    }
    else if (valid && [source.rootElement.name isEqualToString:@"data-set"])
        valid = HorosAppendMetadataNodes(source.rootElement, root, 0);
    else
        valid = NO;

    if (!valid)
    {
        if (error != NULL)
            *error = [NSError errorWithDomain:@"HorosDICOMMetadata" code:1 userInfo:
                      @{NSLocalizedDescriptionKey: @"The DICOM metadata tree could not be read."}];
        return nil;
    }
    return [[[NSXMLDocument alloc] initWithRootElement:root] autorelease];
}

static void HorosAppendMetadataText(NSXMLElement *node, NSString *prefix, NSMutableString *text)
{
    NSString *tag = [[node attributeForName:@"attributeTag"] stringValue];
    NSString *path = prefix;
    if (tag != nil)
    {
        path = [prefix stringByAppendingFormat:@"(%@)", tag];
        NSMutableArray *values = [NSMutableArray array];
        for (NSXMLNode *child in node.children)
            if ([child.name isEqualToString:@"value"])
                [values addObject:child.stringValue ?: @""];
        [text appendFormat:@"%@\t%@\t%@\t%@\n", path,
            [[node attributeForName:@"vr"] stringValue] ?: @"", node.name,
            [values componentsJoinedByString:@"\\"]];
    }
    NSUInteger index = 0;
    for (NSXMLNode *child in node.children)
    {
        if (child.kind == NSXMLElementKind && ![child.name isEqualToString:@"value"])
        {
            NSString *childPrefix = [child.name isEqualToString:@"item"] ?
                [path stringByAppendingFormat:@"[%lu].", (unsigned long)index++] : path;
            HorosAppendMetadataText((NSXMLElement *)child, childPrefix, text);
        }
    }
}

NSString *HorosDICOMMetadataText(NSXMLDocument *document)
{
    NSMutableString *text = [NSMutableString string];
    HorosAppendMetadataText(document.rootElement, @"", text);
    return text;
}
