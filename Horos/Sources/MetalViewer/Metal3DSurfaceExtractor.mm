#import "Metal3DSurfaceExtractor.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include <vtkCleanPolyData.h>
#include <vtkCellArray.h>
#include <vtkDataArray.h>
#include <vtkFlyingEdges3D.h>
#include <vtkImageData.h>
#include <vtkPointData.h>
#include <vtkPolyData.h>
#include <vtkPolyDataConnectivityFilter.h>
#include <vtkPolyDataNormals.h>
#include <vtkTriangleFilter.h>

@interface Metal3DSurfaceExtractionResult ()

@property (nonatomic, readwrite) NSData *surfaceVoxelMask;
@property (nonatomic, readwrite) NSData *vertexFloatData;
@property (nonatomic, readwrite) NSInteger triangleVertexCount;
@property (nonatomic, readwrite) NSInteger surfaceVoxelCount;
@property (nonatomic, readwrite) NSInteger pointCount;
@property (nonatomic, readwrite) NSInteger triangleCount;

- (instancetype)initWithSurfaceVoxelMask:(NSData *)surfaceVoxelMask
                         vertexFloatData:(NSData *)vertexFloatData
                     triangleVertexCount:(NSInteger)triangleVertexCount
                        surfaceVoxelCount:(NSInteger)surfaceVoxelCount
                               pointCount:(NSInteger)pointCount
                            triangleCount:(NSInteger)triangleCount;

@end

@implementation Metal3DSurfaceExtractionResult

- (instancetype)initWithSurfaceVoxelMask:(NSData *)surfaceVoxelMask
                         vertexFloatData:(NSData *)vertexFloatData
                     triangleVertexCount:(NSInteger)triangleVertexCount
                        surfaceVoxelCount:(NSInteger)surfaceVoxelCount
                               pointCount:(NSInteger)pointCount
                            triangleCount:(NSInteger)triangleCount
{
    self = [super init];
    if (self) {
        _surfaceVoxelMask = surfaceVoxelMask;
        _vertexFloatData = vertexFloatData;
        _triangleVertexCount = triangleVertexCount;
        _surfaceVoxelCount = surfaceVoxelCount;
        _pointCount = pointCount;
        _triangleCount = triangleCount;
    }
    return self;
}

@end

@implementation Metal3DSurfaceExtractor

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceFromVolume:(NSData *)volumeData
                                                                    width:(NSInteger)width
                                                                   height:(NSInteger)height
                                                                    depth:(NSInteger)depth
                                                                 spacingX:(float)spacingX
                                                                 spacingY:(float)spacingY
                                                                 spacingZ:(float)spacingZ
                                                                threshold:(float)threshold
{
    if (width <= 1 || height <= 1 || depth <= 1) {
        return nil;
    }

    const NSInteger voxelCount = width * height * depth;
    if ((NSInteger)volumeData.length < voxelCount * (NSInteger)sizeof(float)) {
        return nil;
    }

    const NSInteger paddedWidth = width + 2;
    const NSInteger paddedHeight = height + 2;
    const NSInteger paddedDepth = depth + 2;
    const NSInteger paddedSliceCount = paddedWidth * paddedHeight;
    const NSInteger paddedVoxelCount = paddedSliceCount * paddedDepth;

    vtkImageData *image = vtkImageData::New();
    image->SetDimensions((int)paddedWidth, (int)paddedHeight, (int)paddedDepth);
    image->SetSpacing((double)spacingX, (double)spacingY, (double)spacingZ);
    image->SetOrigin((double)-spacingX, (double)-spacingY, (double)-spacingZ);
    image->AllocateScalars(VTK_FLOAT, 1);

    void *destination = image->GetScalarPointer();
    if (destination == nullptr) {
        image->Delete();
        return nil;
    }
    std::memset(destination, 0, paddedVoxelCount * sizeof(float));

    const float *sourceVoxels = (const float *)volumeData.bytes;
    float *paddedVoxels = (float *)destination;
    const NSInteger sourceSliceCount = width * height;
    for (NSInteger z = 0; z < depth; z++) {
        const NSInteger sourceSliceOffset = z * sourceSliceCount;
        const NSInteger paddedSliceOffset = (z + 1) * paddedSliceCount;
        for (NSInteger y = 0; y < height; y++) {
            const float *sourceRow = sourceVoxels + sourceSliceOffset + y * width;
            float *paddedRow = paddedVoxels + paddedSliceOffset + (y + 1) * paddedWidth + 1;
            std::memcpy(paddedRow, sourceRow, width * sizeof(float));
        }
    }

    vtkFlyingEdges3D *flyingEdges = vtkFlyingEdges3D::New();
    flyingEdges->SetInputData(image);
    flyingEdges->SetValue(0, (double)threshold);
    flyingEdges->ComputeNormalsOn();
    flyingEdges->ComputeScalarsOff();

    vtkPolyDataConnectivityFilter *connectivity = vtkPolyDataConnectivityFilter::New();
    connectivity->SetInputConnection(flyingEdges->GetOutputPort());
    connectivity->SetExtractionModeToLargestRegion();

    vtkCleanPolyData *clean = vtkCleanPolyData::New();
    clean->SetInputConnection(connectivity->GetOutputPort());

    vtkTriangleFilter *triangulate = vtkTriangleFilter::New();
    triangulate->SetInputConnection(clean->GetOutputPort());

    vtkPolyDataNormals *normals = vtkPolyDataNormals::New();
    normals->SetInputConnection(triangulate->GetOutputPort());
    normals->ConsistencyOn();
    normals->AutoOrientNormalsOn();
    normals->SplittingOff();
    normals->ComputePointNormalsOn();
    normals->ComputeCellNormalsOff();
    normals->Update();

    vtkPolyData *surface = normals->GetOutput();
    if (surface == nullptr || surface->GetNumberOfPoints() == 0 || surface->GetNumberOfCells() == 0) {
        normals->Delete();
        triangulate->Delete();
        clean->Delete();
        connectivity->Delete();
        flyingEdges->Delete();
        image->Delete();
        return nil;
    }

    NSMutableData *surfaceVoxelMask = [NSMutableData dataWithLength:(NSUInteger)voxelCount];
    unsigned char *surfaceMaskBytes = (unsigned char *)surfaceVoxelMask.mutableBytes;
    NSInteger surfaceVoxelCount = 0;

    auto markSurfaceIndex = [&](const NSInteger x, const NSInteger y, const NSInteger z) {
        if (x < 0 || x >= width || y < 0 || y >= height || z < 0 || z >= depth) {
            return;
        }
        const NSInteger index = z * width * height + y * width + x;
        if (index >= 0 && index < voxelCount && surfaceMaskBytes[index] == 0) {
            surfaceMaskBytes[index] = 255;
            surfaceVoxelCount++;
        }
    };

    auto markSurfaceVoxel = [&](const double point[3]) {
        const double voxelX = point[0] / std::max(spacingX, 0.0001f);
        const double voxelY = point[1] / std::max(spacingY, 0.0001f);
        const double voxelZ = point[2] / std::max(spacingZ, 0.0001f);
        const NSInteger x0 = (NSInteger)std::floor(voxelX);
        const NSInteger x1 = (NSInteger)std::ceil(voxelX);
        const NSInteger y0 = (NSInteger)std::floor(voxelY);
        const NSInteger y1 = (NSInteger)std::ceil(voxelY);
        const NSInteger z0 = (NSInteger)std::floor(voxelZ);
        const NSInteger z1 = (NSInteger)std::ceil(voxelZ);

        for (NSInteger z = z0; z <= z1; z++) {
            for (NSInteger y = y0; y <= y1; y++) {
                for (NSInteger x = x0; x <= x1; x++) {
                    markSurfaceIndex(x, y, z);
                }
            }
        }
    };

    vtkDataArray *pointNormals = surface->GetPointData() ? surface->GetPointData()->GetNormals() : nullptr;
    NSMutableData *vertexFloatData = [NSMutableData data];
    vtkCellArray *polys = surface->GetPolys();
    vtkIdType pointCount = 0;
    const vtkIdType *pointIds = nullptr;
    NSInteger triangleCount = 0;
    NSInteger triangleVertexCount = 0;

    polys->InitTraversal();
    while (polys->GetNextCell(pointCount, pointIds)) {
        if (pointCount < 3) {
            continue;
        }

        for (vtkIdType localTriangle = 1; localTriangle + 1 < pointCount; localTriangle++) {
            const vtkIdType triangleIds[3] = { pointIds[0], pointIds[localTriangle], pointIds[localTriangle + 1] };
            for (int vertexIndex = 0; vertexIndex < 3; vertexIndex++) {
                double point[3] = { 0, 0, 0 };
                double normal[3] = { 0, 0, 1 };
                surface->GetPoint(triangleIds[vertexIndex], point);
                if (pointNormals != nullptr) {
                    pointNormals->GetTuple(triangleIds[vertexIndex], normal);
                }
                markSurfaceVoxel(point);

                float packed[6] = {
                    (float)point[0],
                    (float)point[1],
                    (float)point[2],
                    (float)normal[0],
                    (float)normal[1],
                    (float)normal[2]
                };
                [vertexFloatData appendBytes:packed length:sizeof(packed)];
                triangleVertexCount++;
            }
            triangleCount++;
        }
    }

    Metal3DSurfaceExtractionResult *result = [[Metal3DSurfaceExtractionResult alloc]
        initWithSurfaceVoxelMask:surfaceVoxelMask
                 vertexFloatData:vertexFloatData
             triangleVertexCount:triangleVertexCount
                surfaceVoxelCount:surfaceVoxelCount
                       pointCount:(NSInteger)surface->GetNumberOfPoints()
                    triangleCount:triangleCount];

    normals->Delete();
    triangulate->Delete();
    clean->Delete();
    connectivity->Delete();
    flyingEdges->Delete();
    image->Delete();

    return result;
}

@end
