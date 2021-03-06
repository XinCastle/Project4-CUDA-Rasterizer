/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <iostream>
#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>


#define BLINN 1
#define LAMBERT 0
#define PERSPECTIVE 1
#define BILINEAR 1
#define POINTSHADING 0
#define LINESHADING 0
#define SOLID 1


namespace {

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		 glm::vec3 col;
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int texWidth, texHeight;
		// ...
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
		TextureData* tex = NULL;
		int diffuseTexWidth;
		int diffuseTexHeight;
	};

	struct Fragment {
		glm::vec3 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;
		 VertexAttributeTexcoord texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int diffuseTexWidth;
		 int diffuseTexHeight;
		// ...
	};

	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
	};

}

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;

static int * dev_depth = NULL;	// you might need this buffer when doing depth test

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}


#define COL(C) (C / 255.0)
#define MIN(X, Y) (((X) < (Y)) ? (X) : (Y))
#define MAX(X, Y) (((X) > (Y)) ? (X) : (Y))




__device__
glm::vec3 bilinearInterpolation(float a, float b, glm::vec3 txy, glm::vec3 txplus1, glm::vec3 typuls1, glm::vec3 txyplus1) 
{
	glm::vec3 temp = (1.f - a) * txy + a * txplus1;
	glm::vec3 temp1 = (1.f - a) * typuls1 + a * txyplus1;
	return temp * (1.f - b) + temp1 * b;
}



__host__ __device__
glm::vec3 getTexColor(TextureData* tex, int stride, int u, int v)
{
	int idx = (u + v * stride) * 3;
	return glm::vec3(COL(tex[idx + 0]),
		COL(tex[idx + 1]),
		COL(tex[idx + 2]));
}


__host__ __device__
int clamp(int v, int a, int b)
{
	return MIN(MAX(a, v), b);
}



template<class T>
__host__ __device__
T lerp(float v, T a, T b)
{
	return a * (1.0f - v) + v * b;
}




/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        framebuffer[index] = fragmentBuffer[index].color;

		// TODO: add your fragment shader code here
		Fragment &tmpfrag = fragmentBuffer[index];
		glm::vec3 tmpcol = tmpfrag.color;
		glm::vec3 result(0.f, 0.f, 0.f);
		glm::vec3 tmppos = tmpfrag.eyePos;
		glm::vec3 tmpnor = tmpfrag.eyeNor;


		glm::vec3 lightpos(60.f, 60.f, 60.f);
		glm::vec3 lightdir = glm::normalize((lightpos - tmppos));
		glm::vec3 specColor(0.f, 0.f, 0.f);
		float ambient = 0.1;
		float shininess = 32.0f;
		float lambertian = glm::max(glm::dot(lightdir, tmpnor), 0.0f);
		float specular = 0.0f;
#if BLINN
		glm::vec3 viewDir = glm::normalize(-tmppos);
		glm::vec3 halfDir = normalize(lightdir + viewDir);
		float specAngle = glm::max(glm::dot(halfDir, tmpnor), 0.0f);
		specular = glm::pow(specAngle, shininess);
		result = lambertian * tmpcol + ambient * glm::vec3(.9f, .9f, .9f) + specular * glm::vec3(1.f, 1.f, 1.f);
#elif LAMBERT
		resullt = lambertian * tmpcol + ambient * glm::vec3(.9f, .9f, .9f);
#endif
		//framebuffer[index] = result;


		float texwidth = fragmentBuffer[index].diffuseTexWidth;
		float texheight = fragmentBuffer[index].diffuseTexHeight; 

		//Here, the TextureData* is char, which is 8 bit (2 to the power of 8) representing 0-255 color number.
		//in this char, every 3 chars are used to express a single fragment's RGB values.
		//therefore, when calculating uvindex, we need to multiply 3.
		//moreover, when calculating the color value, we need to divide 255 to get its color value.
		TextureData* tmptex = fragmentBuffer[index].dev_diffuseTex;
		float ufloat = fragmentBuffer[index].texcoord0.x * texwidth;
		float vfloat = fragmentBuffer[index].texcoord0.y * texheight;
		//int u = fragmentBuffer[index].texcoord0.x * texwidth;
		//int v = fragmentBuffer[index].texcoord0.y * texheight;
		int u = clamp((int)ufloat, 0, texwidth - 1);
		int v = clamp((int)vfloat, 0, texheight - 1);


#if BILINEAR
		//if (tmptex != NULL)
		//{
			//int pxy = 3 * (u + v * texwidth);
			//int pxplus1 = 3 * (u + 1 + v * texwidth);
			//int pyplus1 = 3 * (u + (v + 1) * texwidth);
			//int pxyplus1 = 3 * (u + 1 + (v + 1) * texwidth);

			//glm::vec3 texturexy(tmptex[pxy] / 255.f, tmptex[pxy + 1] / 255.f, tmptex[pxy + 2] / 255.f);
			//glm::vec3 texturexplus1(tmptex[pxplus1] / 255.f, tmptex[pxplus1 + 1] / 255.f, tmptex[pxplus1 + 2] / 255.f);
			//glm::vec3 textureyplus1(tmptex[pyplus1] / 255.f, tmptex[pyplus1 + 1] / 255.f, tmptex[pyplus1 + 2] / 255.f);
			//glm::vec3 texturexyplus1(tmptex[pxyplus1] / 255.f, tmptex[pxyplus1 + 1] / 255.f, tmptex[pxyplus1 + 2] / 255.f);

			//result = bilinearInterpolation((float)(ufloat - u), (float)(vfloat - v), texturexy, texturexplus1, textureyplus1, texturexyplus1);
		//}
		//else 
		//{
		//	printf("DAMN\n");
		//	result = tmpfrag.color;
		//}
		if (tmptex != NULL)
		{
			float du = ufloat - u;
			float dv = vfloat - v;
			auto x0y0 = getTexColor(tmptex, texwidth, u + 0, v + 0);
			auto x1y0 = getTexColor(tmptex, texwidth, u + 1, v + 0);
			auto x0y1 = getTexColor(tmptex, texwidth, u + 0, v + 1);
			auto x1y1 = getTexColor(tmptex, texwidth, u + 1, v + 1);
			result = lerp<glm::vec3>(dv, lerp<glm::vec3>(du, x0y0, x1y0), lerp<glm::vec3>(du, x0y1, x1y1));
		}
		else
		{
			result = tmpfrag.color;
		}
#else
		//printf("%i %i\n", u, v);
		int uvindex = 3 * (u + v * texwidth);
		//result = glm::vec3(tmptex[uvindex+0] / 255.f, tmptex[uvindex+1] / 255.f, tmptex[uvindex + 2] / 255.f);
		if (tmptex != NULL)
		{
			result = glm::vec3(tmptex[uvindex] / 255.f, tmptex[uvindex + 1] / 255.f, tmptex[uvindex + 2] / 255.f);
		}
		else
		{
			result = tmpfrag.color;
		}
#endif
		framebuffer[index] = result;
    }
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;
	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
    
	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(int));

	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						//printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {

							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);

									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;
									//printf("%i\n", diffuseTexWidth);
									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();

					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,

						dev_vertexOut	//VertexOut
					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}


	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
	}


	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());

		//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}



__global__ 
void _vertexTransformAndAssembly(
	int numVertices, 
	PrimitiveDevBufPointers primitive, 
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
	int width, int height) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space
		
		//first get the position of the vertex
		glm::vec4 vp = glm::vec4(primitive.dev_position[vid],1.0f);
		//then multiply mvp matrix
		glm::vec4 vpedit = MVP * vp;
		//divide w
		vpedit = vpedit / vpedit.w;
		//viewport
		vpedit.x = 0.5f * (float)width * (1.0f - vpedit.x);
		vpedit.y = 0.5f * (float)height * (1.0f - vpedit.y);

		// TODO: Apply vertex assembly here
		// Assemble all attribute arraies into the primitive array
		primitive.dev_verticesOut[vid].pos = vpedit;
		primitive.dev_verticesOut[vid].eyePos = multiplyMV(MV,vp);
		primitive.dev_verticesOut[vid].eyeNor = glm::normalize(MV_normal * primitive.dev_normal[vid]);
		primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
		primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
		primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
		if (primitive.dev_texcoord0 != NULL)
		{
			primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
		}

		primitive.dev_verticesOut[vid].col = glm::vec3(0.8, 0.8, 0.8);
	}
}



static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) {

		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles

		int pid;	// id for cur primitives vector
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES)
		{
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
			dev_primitives[pid + curPrimitiveBeginId].tex = primitive.dev_diffuseTex;
			dev_primitives[pid + curPrimitiveBeginId].diffuseTexWidth = primitive.diffuseTexWidth;
			dev_primitives[pid + curPrimitiveBeginId].diffuseTexHeight = primitive.diffuseTexHeight;
		}


		// TODO: other primitive types (point, line)
	}
	
}



__global__ void _rasterization(int totalNumPrimitives, Primitive *dev_primitives, Fragment *dev_fragmentBuffer, int *dev_depth, int width, int height)
{
	int pid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (pid < totalNumPrimitives)
	{
		//get AABB. to use getAABBfortriangle we need to know glm::vec3 tri[3], so get it from dev_primitives
		glm::vec3 tri[3] = {glm::vec3(dev_primitives[pid].v[0].pos), glm::vec3(dev_primitives[pid].v[1].pos), glm::vec3(dev_primitives[pid].v[2].pos) };
		//as well as all the other attributes in primitives: eyepos,eyenor,texcoord,color
		glm::vec3 triEyePos[3] = { dev_primitives[pid].v[0].eyePos, dev_primitives[pid].v[1].eyePos, dev_primitives[pid].v[2].eyePos };
		glm::vec3 triEyeNor[3] = { dev_primitives[pid].v[0].eyeNor, dev_primitives[pid].v[1].eyeNor, dev_primitives[pid].v[2].eyeNor };
		glm::vec2 triTexcoord0[3] = { dev_primitives[pid].v[0].texcoord0, dev_primitives[pid].v[1].texcoord0, dev_primitives[pid].v[2].texcoord0 };
		glm::vec3 color(0.8f, 0.8f, 0.8f);

		//after getting all the attributes, declare the AABB
		//here since every primitive has a tri, so here every primitive has an aabb
		AABB aabb = getAABBForTriangle(tri);
		//find the bounding box value
		//same as above, every primitive has its own xmin,xmax,ymin and ymax
		int xmin = glm::max((int)aabb.min.x, 0);
		int xmax = glm::min((int)aabb.max.x, width - 1);
		int ymin = glm::max((int)aabb.min.y, 0);
		int ymax = glm::min((int)aabb.max.y, height - 1);

		int depth;
		//declare a vec3 for calling calculateBarycentricCoordinate function
		glm::vec3 barycoord;
		int pixelid;
		
#if SOLID
		//loop every fragment in the bounding box
		for (int x = xmin; x <= xmax; x++)
		{
			for (int y = ymin; y <= ymax; y++)
			{
				glm::vec2 tmpfrag(x, y);
				//calculate the barycentriccoordinate of x,y
				barycoord = calculateBarycentricCoordinate(tri, tmpfrag);
				//if it's inside the triangle
				if (isBarycentricCoordInBounds(barycoord)==true)
				{
					//first get its pixel id to call atomicMin
					pixelid = x + y*width;

					//get z coordinate by calling getZAtCoordinate function. Times INT_MIN to convert it into
					//integer for using atomicMin in the following.
					depth = getZAtCoordinate(barycoord, tri) * INT_MIN;
					//call atomicMin. If there is only one fragment on this pixel, nothing happens, the depth
					//calculated will substitute the old value saved in dev_depth. If there are several fragments
					//on this same pixel, the characteristic of atomicMin will work. Every time there will only
					//be one thread get into this comparison and pass its value to dev_depth. Then another one gets in
					atomicMin(&dev_depth[pixelid], depth);
					int fragid = pixelid;

					if (dev_depth[pixelid] == depth)
					{
						//pass the value calculated using barycentric method to fragmentbuffer.
						glm::vec3 eyeposB = barycoord.x * triEyePos[0] + barycoord.y * triEyePos[1] + barycoord.z * triEyePos[2];
						dev_fragmentBuffer[pixelid].eyePos = eyeposB;
						glm::vec3 eyenorB = glm::normalize(barycoord.x * triEyeNor[0] + barycoord.y * triEyeNor[1] + barycoord.z * triEyeNor[2]);
						dev_fragmentBuffer[pixelid].eyeNor = eyenorB;
						glm::vec2 texB = barycoord.x * triTexcoord0[0] + barycoord.y * triTexcoord0[1] + barycoord.z * triTexcoord0[2];
						dev_fragmentBuffer[pixelid].dev_diffuseTex = dev_primitives[pid].tex;
						dev_fragmentBuffer[pixelid].texcoord0 = texB;
						dev_fragmentBuffer[pixelid].diffuseTexHeight = dev_primitives[pid].diffuseTexHeight;
						dev_fragmentBuffer[pixelid].diffuseTexWidth = dev_primitives[pid].diffuseTexWidth;

						dev_fragmentBuffer[pixelid].color = barycoord.x * dev_primitives[pid].v[0].col + barycoord.y * dev_primitives[pid].v[1].col + barycoord.z * dev_primitives[pid].v[2].col;

#if PERSPECTIVE
						glm::vec3 zbuffer(1.f / triEyePos[0].z, 1.f / triEyePos[1].z, 1.f / triEyePos[2].z);
						glm::vec3 bottom(barycoord.x * zbuffer[0], barycoord.y * zbuffer[1], barycoord.z * zbuffer[2]);
						float sumbot = bottom.x + bottom.y + bottom.z;
						float denominator_inv = 1.f / sumbot;
						glm::vec2 numerator = bottom.x * triTexcoord0[0] + bottom.y * triTexcoord0[1] + bottom.z * triTexcoord0[2];
						dev_fragmentBuffer[pixelid].texcoord0 = numerator * denominator_inv;
#else
						dev_fragmentBuffer[pixelid].texcoord0 = texB;
#endif
					}
				}
			}
		}
#elif POINTSHADING
		for (int x = xmin; x <= xmax; x++)
		{
			for (int y = ymin; y < ymax; y++)
			{
				glm::vec2 tmpfrag(x, y);
				//calculate the barycentriccoordinate of x,y
				barycoord = calculateBarycentricCoordinate(tri, tmpfrag);
				if (isBarycentricCoordOnCorner(barycoord))
				{
					//first get its pixel id to call atomicMin
					pixelid = x + y*width;

					//get z coordinate by calling getZAtCoordinate function. Times INT_MIN to convert it into
					//integer for using atomicMin in the following.
					depth = getZAtCoordinate(barycoord, tri) * INT_MIN;
					//call atomicMin. If there is only one fragment on this pixel, nothing happens, the depth
					//calculated will substitute the old value saved in dev_depth. If there are several fragments
					//on this same pixel, the characteristic of atomicMin will work. Every time there will only
					//be one thread get into this comparison and pass its value to dev_depth. Then another one gets in
					atomicMin(&dev_depth[pixelid], depth);
					int fragid = pixelid;

					if (dev_depth[pixelid] == depth)
					{
						dev_fragmentBuffer[pixelid].color = glm::vec3(0.1, 1, 1);
						//pass the value calculated using barycentric method to fragmentbuffer.
						glm::vec3 eyeposB = barycoord.x * triEyePos[0] + barycoord.y * triEyePos[1] + barycoord.z * triEyePos[2];
						dev_fragmentBuffer[pixelid].eyePos = eyeposB;
						glm::vec3 eyenorB = glm::normalize(barycoord.x * triEyeNor[0] + barycoord.y * triEyeNor[1] + barycoord.z * triEyeNor[2]);
						dev_fragmentBuffer[pixelid].eyeNor = eyenorB;
						dev_fragmentBuffer[pixelid].dev_diffuseTex = NULL;
					}
				}
			}
		}
#elif LINESHADING
		for (int x = xmin; x <= xmax; x++)
		{
			for (int y = ymin; y < ymax; y++)
			{
				glm::vec2 tmpfrag(x, y);
				//calculate the barycentriccoordinate of x,y
				barycoord = calculateBarycentricCoordinate(tri, tmpfrag);
				if (isBarycentricCoordOnBounds(barycoord))
				{
					//first get its pixel id to call atomicMin
					pixelid = x + y*width;

					//get z coordinate by calling getZAtCoordinate function. Times INT_MIN to convert it into
					//integer for using atomicMin in the following.
					depth = getZAtCoordinate(barycoord, tri) * INT_MIN;
					//call atomicMin. If there is only one fragment on this pixel, nothing happens, the depth
					//calculated will substitute the old value saved in dev_depth. If there are several fragments
					//on this same pixel, the characteristic of atomicMin will work. Every time there will only
					//be one thread get into this comparison and pass its value to dev_depth. Then another one gets in
					atomicMin(&dev_depth[pixelid], depth);
					int fragid = pixelid;

					if (dev_depth[pixelid] == depth)
					{
						dev_fragmentBuffer[pixelid].color = glm::vec3(0.1, 1, 1);
						//pass the value calculated using barycentric method to fragmentbuffer.
						glm::vec3 eyeposB = barycoord.x * triEyePos[0] + barycoord.y * triEyePos[1] + barycoord.z * triEyePos[2];
						dev_fragmentBuffer[pixelid].eyePos = eyeposB;
						glm::vec3 eyenorB = glm::normalize(barycoord.x * triEyeNor[0] + barycoord.y * triEyeNor[1] + barycoord.z * triEyeNor[2]);
						dev_fragmentBuffer[pixelid].eyeNor = eyenorB;
						dev_fragmentBuffer[pixelid].dev_diffuseTex = NULL;
					}
				}
			}
		}
#endif

	}
}








/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices,
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	initDepth << <blockCount2d, blockSize2d >> >(width, height, dev_depth);
	
	// TODO: rasterize
	dim3 numThreadsPerBlock(128);
	dim3 numBlocksForPrimitives((totalNumPrimitives + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
	_rasterization <<<numBlocksForPrimitives, numThreadsPerBlock>>>(totalNumPrimitives, dev_primitives, dev_fragmentBuffer, dev_depth, width, height);
	checkCUDAError("_rasterization");

    // Copy depthbuffer colors into framebuffer
	render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer);
	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

    checkCUDAError("rasterize Free");
}
