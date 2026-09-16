"""Non-build export-resizer checks and synthetic native Core Image smoke tests.

Native checks exercise the framework pipeline, not the unbuilt Horos category.
No patient images or application preferences are accessed.
"""

import json
from pathlib import Path
import platform
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Nitrogen/Sources/NSImage+N2.mm").read_text()
RESIZE = SOURCE.split("- (NSImage*)imageByScalingProportionallyToSize:(NSSize)targetSize", 1)[1]


class ExportImageScalingTests(unittest.TestCase):
    def test_eager_bitmap_replaces_tiff_and_deferred_appkit_drawing(self):
        for old in ("TIFFRepresentation", "initWithData:", "drawingHandler:", "NSAutoreleasePool",
                    "mainScreen", "backingScaleFactor", "NSGraphicsContext", "[NSImage class]"):
            self.assertNotIn(old, RESIZE)
        self.assertIn("createCGImage:output fromRect:canvasRect", RESIZE)
        self.assertIn("format:kCIFormatRGBA8 colorSpace:colorSpace deferred:NO", RESIZE)
        self.assertIn("initWithCGImage:outputCGImage size:targetSize", RESIZE)

    def test_context_is_reused_but_filters_and_source_snapshots_are_per_request(self):
        context = SOURCE.split("static CIContext* N2ExportImageContext()", 1)[1].split("@implementation", 1)[0]
        self.assertIn("dispatch_once(&once", context)
        self.assertIn("kCIContextCacheIntermediates: @NO", context)
        self.assertIn("CIFilter<CILanczosScaleTransform>* filter = [CIFilter lanczosScaleTransformFilter]", RESIZE)
        lock = RESIZE.split("@synchronized(self)", 1)[1].split("if (!sourceCGImage)", 1)[0]
        self.assertIn("CGImageRetain([self CGImageForProposedRect:", lock)
        self.assertNotIn("filter", lock)
        self.assertNotIn("createCGImage:", lock)

    def test_geometry_uses_logical_aspect_and_actual_source_pixels(self):
        self.assertIn("std::ceil(targetSize.width)", RESIZE)
        self.assertIn("std::ceil(targetSize.height)", RESIZE)
        self.assertIn("std::min(pixelSize.width / imageSize.width, pixelSize.height / imageSize.height)", RESIZE)
        self.assertIn("contentSize.height / CGImageGetHeight(sourceCGImage)", RESIZE)
        self.assertIn("contentSize.width / CGImageGetWidth(sourceCGImage)", RESIZE)
        self.assertIn("float aspectRatio = scaleX / scaleY", RESIZE)
        self.assertIn("filter.scale = scale", RESIZE)
        self.assertIn("filter.aspectRatio = aspectRatio", RESIZE)
        self.assertIn("(pixelSize.width - contentSize.width) * 0.5", RESIZE)
        self.assertIn("(pixelSize.height - contentSize.height) * 0.5", RESIZE)
        self.assertNotIn("NSEqualSizes", RESIZE)

    def test_padding_alpha_profiles_and_resource_lifetimes_are_explicit(self):
        for token in ("imageByClampingToExtent", "imageByCroppingToRect:contentRect", "CIColor.clearColor",
                      "imageByCompositingOverImage:background", "CGColorSpaceGetModel(sourceColorSpace)",
                      "CGColorSpaceRetain(sourceColorSpace)", "CGColorSpaceCreateWithName(kCGColorSpaceSRGB)"):
            self.assertIn(token, RESIZE)
        for component in ("targetSize.width", "targetSize.height", "imageSize.width", "imageSize.height"):
            self.assertIn(f"!std::isfinite({component})", RESIZE)
            self.assertIn(f"{component} <= 0", RESIZE)
        self.assertIn("!std::isfinite(scale) || !std::isfinite(aspectRatio)", RESIZE)
        cleanup = RESIZE.split("@finally", 1)[1]
        for release in ("CGImageRelease(outputCGImage)", "CGImageRelease(sourceCGImage)", "CGColorSpaceRelease(colorSpace)"):
            self.assertIn(release, cleanup)
        self.assertIn("return [result autorelease]", cleanup)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires macOS SDK")
    def test_actual_objcpp_file_passes_sdk_syntax_check(self):
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        result = subprocess.run([
            "xcrun", "clang++", "-fsyntax-only", "-fblocks", "-fno-objc-arc", "-std=c++17",
            "-target", "arm64-apple-macos27.0", "-isysroot", sdk, "-Werror",
            str(ROOT / "Nitrogen/Sources/NSImage+N2.mm"),
        ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(platform.system() == "Darwin", "Requires native Core Image")
    def test_native_geometry_orientation_color_and_alpha_fixtures(self):
        result = subprocess.run(["osascript", "-l", "JavaScript", "-e", NATIVE_CHECK],
                                capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        if report.get("unavailable"):
            self.skipTest("Core Image could not create a context in this environment")
        self.assertEqual(len(report["cases"]), 8)
        for case in report["cases"]:
            with self.subTest(case=case["name"]):
                self.assertEqual(case["pixels"], case["expectedPixels"])
                self.assertEqual(case["logical"], case["target"])
                self.assertLess(case["maxColorError"], 0.035)
                self.assertEqual(case["paddingAlpha"], 0 if case["hasPadding"] else 1)


NATIVE_CHECK = r'''
ObjC.import("AppKit");
ObjC.import("CoreImage");
ObjC.import("CoreGraphics");
var options = $.NSMutableDictionary.alloc.init;
options.setObjectForKey($.NSNumber.numberWithBool(false), $.kCIContextCacheIntermediates);
var context = $.CIContext.contextWithOptions(options);

function rect(x, y, w, h) { return $.CGRectMake(x, y, w, h); }
function color(r, g, b, a) { return $.CIColor.colorWithRedGreenBlueAlpha(r, g, b, a); }
function solid(c, bounds) { return $.CIImage.imageWithColor(c).imageByCroppingToRect(bounds); }
function rgba(rep, x, y) {
    var c = rep.colorAtXY(Math.floor(x), Math.floor(y)).colorUsingColorSpace($.NSColorSpace.sRGBColorSpace);
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Number);
}
function check(row) {
    var name = row[0], w = row[1], h = row[2], lw = row[3], lh = row[4], tw = row[5], th = row[6];
    var colors = [color(1,0,0,1), color(0,1,0,row[7] ? 0.5 : 1), color(0,0,1,1), color(1,1,0,1)];
    var input = solid(colors[0], rect(0,0,w/2,h/2));
    input = solid(colors[1], rect(w/2,0,w/2,h/2)).imageByCompositingOverImage(input);
    input = solid(colors[2], rect(0,h/2,w/2,h/2)).imageByCompositingOverImage(input);
    input = solid(colors[3], rect(w/2,h/2,w/2,h/2)).imageByCompositingOverImage(input);
    var space = $.CGColorSpaceCreateWithName(row[8] ? $.kCGColorSpaceGenericGrayGamma2_2 : $.kCGColorSpaceSRGB);
    var sourceCG = context.createCGImageFromRectFormatColorSpaceDeferred(
        input, rect(0,0,w,h), row[8] ? $.kCIFormatL8 : $.kCIFormatRGBA8, space, false);
    var source = $.NSImage.alloc.initWithCGImageSize(sourceCG, $.NSMakeSize(lw, lh));
    var snapshot = source.CGImageForProposedRectContextHints(null, $(), $());
    var sourceRep = $.NSBitmapImageRep.alloc.initWithCGImage(snapshot);
    var pw = Math.ceil(tw), ph = Math.ceil(th), fit = Math.min(pw/lw, ph/lh);
    var cw = lw*fit, ch = lh*fit, sx = cw / Number($.CGImageGetWidth(snapshot)), sy = ch / Number($.CGImageGetHeight(snapshot));
    var f = $.CIFilter.lanczosScaleTransformFilter;
    f.inputImage = $.CIImage.imageWithCGImage(snapshot).imageByClampingToExtent;
    f.scale = sy;
    f.aspectRatio = sx/sy;
    var content = f.outputImage.imageByCroppingToRect(rect(0,0,cw,ch));
    var x = (pw-cw)*0.5, y = (ph-ch)*0.5;
    content = content.imageByApplyingTransform($.CGAffineTransformMakeTranslation(x,y));
    var output = content.imageByCompositingOverImage(solid($.CIColor.clearColor, rect(0,0,pw,ph)));
    var sourceSpace = $.CGImageGetColorSpace(snapshot);
    var outputSpace = Number($.CGColorSpaceGetModel(sourceSpace)) === Number($.kCGColorSpaceModelRGB)
        ? sourceSpace : $.CGColorSpaceCreateWithName($.kCGColorSpaceSRGB);
    var cg = context.createCGImageFromRectFormatColorSpaceDeferred(output, rect(0,0,pw,ph), $.kCIFormatRGBA8, outputSpace, false);
    var result = $.NSImage.alloc.initWithCGImageSize(cg, $.NSMakeSize(tw,th));
    var rep = $.NSBitmapImageRep.alloc.initWithCGImage(cg);
    var error = 0;
    [0.25,0.75].forEach(function(fy) { [0.25,0.75].forEach(function(fx) {
        var a = rgba(sourceRep, Number($.CGImageGetWidth(snapshot))*fx, Number($.CGImageGetHeight(snapshot))*fy);
        var b = rgba(rep, x+cw*fx, y+ch*fy);
        for (var i=0; i<4; i++) error = Math.max(error, Math.abs(a[i]-b[i]));
    }); });
    return {name:name, pixels:[Number($.CGImageGetWidth(cg)),Number($.CGImageGetHeight(cg))],
            expectedPixels:[pw,ph], logical:[result.size.width,result.size.height], target:[tw,th],
            maxColorError:error, paddingAlpha:rgba(rep,0,0)[3], hasPadding:x>0 || y>0};
}
JSON.stringify(ObjC.unwrap(context.description) ? {cases:[
    ["identity",80,40,80,40,80,40,false,false],
    ["downscale",128,64,128,64,32,16,false,false],
    ["upscale",32,16,32,16,128,64,false,false],
    ["letterbox",80,40,80,40,64,64,false,false],
    ["pillarbox-alpha",40,80,40,80,64,64,true,false],
    ["retina",160,80,80,40,80,40,false,false],
    ["logical-aspect",80,40,80,80,48,48,false,false],
    ["fractional-grayscale",80,40,80,40,31.2,31.2,false,true]
].map(check)} : {unavailable:true});
'''


if __name__ == "__main__":
    unittest.main()
