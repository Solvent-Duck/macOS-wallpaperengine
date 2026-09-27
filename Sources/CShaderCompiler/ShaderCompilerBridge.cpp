#include "ShaderCompilerBridge.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "SPIRV/GlslangToSpv.h"
#include "glslang/Include/ResourceLimits.h"
#include "glslang/Public/ShaderLang.h"
#include "nlohmann/json.hpp"
#include "spirv_msl.hpp"

namespace {
using JSON = nlohmann::json;

struct VertexAttribute {
    std::string name;
    uint32_t location;
    uint32_t vecSize;
    uint32_t bufferIndex;
};

struct MSLOutput {
    std::string vertexMSL;
    std::string fragmentMSL;
    std::map<std::string, uint32_t> vertexUniformSlots;
    std::map<std::string, uint32_t> fragmentUniformSlots;
    std::map<std::string, uint32_t> fragmentTextureSlots;
    std::map<std::string, uint32_t> fragmentSamplerSlots;
    std::vector<VertexAttribute> vertexAttributes;
};

constexpr uint32_t kMetalBufferSlotCount = 31;

TBuiltInResource BuiltInResource = { .maxLights = 32,
                                     .maxClipPlanes = 6,
                                     .maxTextureUnits = 32,
                                     .maxTextureCoords = 32,
                                     .maxVertexAttribs = 64,
                                     .maxVertexUniformComponents = 4096,
                                     .maxVaryingFloats = 64,
                                     .maxVertexTextureImageUnits = 32,
                                     .maxCombinedTextureImageUnits = 80,
                                     .maxTextureImageUnits = 32,
                                     .maxFragmentUniformComponents = 4096,
                                     .maxDrawBuffers = 32,
                                     .maxVertexUniformVectors = 128,
                                     .maxVaryingVectors = 8,
                                     .maxFragmentUniformVectors = 16,
                                     .maxVertexOutputVectors = 16,
                                     .maxFragmentInputVectors = 15,
                                     .minProgramTexelOffset = -8,
                                     .maxProgramTexelOffset = 7,
                                     .maxClipDistances = 8,
                                     .maxComputeWorkGroupCountX = 65535,
                                     .maxComputeWorkGroupCountY = 65535,
                                     .maxComputeWorkGroupCountZ = 65535,
                                     .maxComputeWorkGroupSizeX = 1024,
                                     .maxComputeWorkGroupSizeY = 1024,
                                     .maxComputeWorkGroupSizeZ = 64,
                                     .maxComputeUniformComponents = 1024,
                                     .maxComputeTextureImageUnits = 16,
                                     .maxComputeImageUniforms = 8,
                                     .maxComputeAtomicCounters = 8,
                                     .maxComputeAtomicCounterBuffers = 1,
                                     .maxVaryingComponents = 60,
                                     .maxVertexOutputComponents = 64,
                                     .maxGeometryInputComponents = 64,
                                     .maxGeometryOutputComponents = 128,
                                     .maxFragmentInputComponents = 128,
                                     .maxImageUnits = 8,
                                     .maxCombinedImageUnitsAndFragmentOutputs = 8,
                                     .maxCombinedShaderOutputResources = 8,
                                     .maxImageSamples = 0,
                                     .maxVertexImageUniforms = 0,
                                     .maxTessControlImageUniforms = 0,
                                     .maxTessEvaluationImageUniforms = 0,
                                     .maxGeometryImageUniforms = 0,
                                     .maxFragmentImageUniforms = 8,
                                     .maxCombinedImageUniforms = 8,
                                     .maxGeometryTextureImageUnits = 16,
                                     .maxGeometryOutputVertices = 256,
                                     .maxGeometryTotalOutputComponents = 1024,
                                     .maxGeometryUniformComponents = 1024,
                                     .maxGeometryVaryingComponents = 64,
                                     .maxTessControlInputComponents = 128,
                                     .maxTessControlOutputComponents = 128,
                                     .maxTessControlTextureImageUnits = 16,
                                     .maxTessControlUniformComponents = 1024,
                                     .maxTessControlTotalOutputComponents = 4096,
                                     .maxTessEvaluationInputComponents = 128,
                                     .maxTessEvaluationOutputComponents = 128,
                                     .maxTessEvaluationTextureImageUnits = 16,
                                     .maxTessEvaluationUniformComponents = 1024,
                                     .maxTessPatchComponents = 120,
                                     .maxPatchVertices = 32,
                                     .maxTessGenLevel = 64,
                                     .maxViewports = 16,
                                     .maxVertexAtomicCounters = 0,
                                     .maxTessControlAtomicCounters = 0,
                                     .maxTessEvaluationAtomicCounters = 0,
                                     .maxGeometryAtomicCounters = 0,
                                     .maxFragmentAtomicCounters = 8,
                                     .maxCombinedAtomicCounters = 8,
                                     .maxAtomicCounterBindings = 1,
                                     .maxVertexAtomicCounterBuffers = 0,
                                     .maxTessControlAtomicCounterBuffers = 0,
                                     .maxTessEvaluationAtomicCounterBuffers = 0,
                                     .maxGeometryAtomicCounterBuffers = 0,
                                     .maxFragmentAtomicCounterBuffers = 1,
                                     .maxCombinedAtomicCounterBuffers = 1,
                                     .maxAtomicCounterBufferSize = 16384,
                                     .maxTransformFeedbackBuffers = 4,
                                     .maxTransformFeedbackInterleavedComponents = 64,
                                     .maxCullDistances = 8,
                                     .maxCombinedClipAndCullDistances = 8,
                                     .maxSamples = 4,
                                     .maxMeshOutputVerticesNV = 256,
                                     .maxMeshOutputPrimitivesNV = 512,
                                     .maxMeshWorkGroupSizeX_NV = 32,
                                     .maxMeshWorkGroupSizeY_NV = 1,
                                     .maxMeshWorkGroupSizeZ_NV = 1,
                                     .maxTaskWorkGroupSizeX_NV = 32,
                                     .maxTaskWorkGroupSizeY_NV = 1,
                                     .maxTaskWorkGroupSizeZ_NV = 1,
                                     .maxMeshViewCountNV = 4,
                                     .limits = {
                                         .nonInductiveForLoops = true,
                                         .whileLoops = true,
                                         .doWhileLoops = true,
                                         .generalUniformIndexing = true,
                                         .generalAttributeMatrixVectorIndexing = true,
                                         .generalVaryingIndexing = true,
                                         .generalSamplerIndexing = true,
                                         .generalVariableIndexing = true,
                                         .generalConstantMatrixVectorIndexing = true,
                                     } };

bool g_glslangInitialized = false;

void ensureGlslangProcess () {
    if (!g_glslangInitialized) {
        glslang::InitializeProcess ();
        g_glslangInitialized = true;
    }
}

void parseMSLSignatureSlots (
    const std::string& msl,
    std::map<std::string, uint32_t>& bufferSlots,
    std::map<std::string, uint32_t>& textureSlots,
    std::map<std::string, uint32_t>& samplerSlots
) {
    const size_t funcPos = msl.find ("main0(");
    if (funcPos == std::string::npos) {
        return;
    }

    const size_t lineEnd = msl.find ('\n', funcPos);
    const std::string signature
        = msl.substr (funcPos, lineEnd == std::string::npos ? std::string::npos : lineEnd - funcPos);

    auto extract = [&] (const std::string& tag, std::map<std::string, uint32_t>& output) {
        const std::string marker = "[[" + tag + "(";
        size_t position = 0;

        while ((position = signature.find (marker, position)) != std::string::npos) {
            const size_t numberEnd = signature.find (")]", position + marker.size ());
            if (numberEnd == std::string::npos) {
                break;
            }

            const uint32_t slot = static_cast<uint32_t> (
                std::stoul (signature.substr (position + marker.size (), numberEnd - position - marker.size ())));

            size_t nameEnd = position;
            while (nameEnd > 0 && (signature[nameEnd - 1] == ' ' || signature[nameEnd - 1] == '\t')) {
                --nameEnd;
            }

            size_t nameStart = nameEnd;
            while (nameStart > 0
                   && (std::isalnum (static_cast<unsigned char> (signature[nameStart - 1]))
                       || signature[nameStart - 1] == '_')) {
                --nameStart;
            }

            const std::string name = signature.substr (nameStart, nameEnd - nameStart);
            if (!name.empty () && name != "in" && name != "out" && name != "patchIn") {
                output[name] = slot;
            }

            position = numberEnd + 2;
        }
    };

    extract ("buffer", bufferSlots);
    extract ("texture", textureSlots);
    extract ("sampler", samplerSlots);
}

void rewritePromotedUniformAddressSpace (
    std::string& msl,
    const std::map<std::string, uint32_t>& uniformSlots
) {
    for (const auto& [uniformName, slot] : uniformSlots) {
        (void) slot;
        const std::string needle = "& " + uniformName;
        const std::string threadConst = "thread const ";
        const size_t threadConstLength = threadConst.size ();
        size_t position = 0;

        while ((position = msl.find (needle, position)) != std::string::npos) {
            size_t lineStart = msl.rfind ('\n', position);
            lineStart = (lineStart == std::string::npos) ? 0 : lineStart + 1;
            size_t threadConstPosition = msl.rfind (threadConst, position - 1);

            if (threadConstPosition != std::string::npos && threadConstPosition >= lineStart) {
                msl.replace (threadConstPosition, threadConstLength, "constant ");
                position = threadConstPosition + std::strlen ("constant ") + needle.size ();
            } else {
                position += needle.size ();
            }
        }
    }
}

void compactBufferSlots (
    std::string& msl,
    std::map<std::string, uint32_t>& bufferSlots,
    uint32_t maxSlotExclusive
) {
    if (bufferSlots.empty ()) {
        return;
    }
    if (bufferSlots.size () > maxSlotExclusive) {
        throw std::runtime_error ("Shader uniforms exceed available Metal buffer slots");
    }

    std::vector<std::pair<std::string, uint32_t>> ordered (bufferSlots.begin (), bufferSlots.end ());
    std::sort (
        ordered.begin (),
        ordered.end (),
        [] (const auto& lhs, const auto& rhs) {
            if (lhs.second != rhs.second) {
                return lhs.second < rhs.second;
            }
            return lhs.first < rhs.first;
        });

    uint32_t nextSlot = 0;
    for (const auto& [name, oldSlot] : ordered) {
        const std::string oldAttribute = name + " [[buffer(" + std::to_string (oldSlot) + ")]]";
        const std::string newAttribute = name + " [[buffer(" + std::to_string (nextSlot) + ")]]";

        size_t position = 0;
        while ((position = msl.find (oldAttribute, position)) != std::string::npos) {
            msl.replace (position, oldAttribute.size (), newAttribute);
            position += newAttribute.size ();
        }

        bufferSlots[name] = nextSlot++;
    }
}

std::string compileStageToMSLJSON (const std::string& vertex, const std::string& fragment) {
    ensureGlslangProcess ();

    glslang::TShader vertexShader (EShLangVertex);
    const char* vertexSource = vertex.c_str ();
    vertexShader.setStrings (&vertexSource, 1);
    vertexShader.setEntryPoint ("main");
    vertexShader.setEnvInput (glslang::EShSourceGlsl, EShLangVertex, glslang::EShClientOpenGL, 330);
    vertexShader.setEnvClient (glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
    vertexShader.setEnvTarget (glslang::EShTargetSpv, glslang::EShTargetSpv_1_5);
    vertexShader.setAutoMapLocations (true);
    vertexShader.setAutoMapBindings (true);

    if (!vertexShader.parse (&BuiltInResource, 100, false, EShMsgDefault)) {
        return JSON {
            { "ok", false },
            { "error", std::string ("MSL vertex unit parsing failed: ") + vertexShader.getInfoLog () },
        }.dump ();
    }

    glslang::TShader fragmentShader (EShLangFragment);
    const char* fragmentSource = fragment.c_str ();
    fragmentShader.setStrings (&fragmentSource, 1);
    fragmentShader.setEntryPoint ("main");
    fragmentShader.setEnvInput (glslang::EShSourceGlsl, EShLangFragment, glslang::EShClientOpenGL, 330);
    fragmentShader.setEnvClient (glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
    fragmentShader.setEnvTarget (glslang::EShTargetSpv, glslang::EShTargetSpv_1_5);
    fragmentShader.setAutoMapLocations (true);
    fragmentShader.setAutoMapBindings (true);

    if (!fragmentShader.parse (&BuiltInResource, 100, false, EShMsgDefault)) {
        return JSON {
            { "ok", false },
            { "error", std::string ("MSL fragment unit parsing failed: ") + fragmentShader.getInfoLog () },
        }.dump ();
    }

    glslang::TProgram program;
    program.addShader (&vertexShader);
    program.addShader (&fragmentShader);

    if (!program.link (EShMsgDefault)) {
        return JSON {
            { "ok", false },
            { "error", std::string ("MSL program linking failed: ") + program.getInfoLog () },
        }.dump ();
    }

    spirv_cross::CompilerMSL::Options mslOptions;
    mslOptions.platform = spirv_cross::CompilerMSL::Options::macOS;
    mslOptions.msl_version = spirv_cross::CompilerMSL::Options::make_msl_version (2, 0);

    MSLOutput output;

    std::vector<uint32_t> spirv;
    glslang::GlslangToSpv (*program.getIntermediate (EShLangVertex), spirv);

    spirv_cross::CompilerMSL vertexCompiler (spirv);
    vertexCompiler.set_msl_options (mslOptions);

    {
        const auto activeVariables = vertexCompiler.get_active_interface_variables ();
        auto stageInputs = vertexCompiler.get_shader_resources ().stage_inputs;
        stageInputs.erase (
            std::remove_if (
                stageInputs.begin (),
                stageInputs.end (),
                [&] (const spirv_cross::Resource& resource) {
                    return activeVariables.find (resource.id) == activeVariables.end ();
                }),
            stageInputs.end ());

        std::sort (
            stageInputs.begin (),
            stageInputs.end (),
            [] (const spirv_cross::Resource& lhs, const spirv_cross::Resource& rhs) {
                return lhs.name < rhs.name;
            });

        if (stageInputs.size () > kMetalBufferSlotCount) {
            throw std::runtime_error ("Shader attributes exceed available Metal buffer slots");
        }
        const auto dataBaseSlot = kMetalBufferSlotCount - static_cast<uint32_t> (stageInputs.size ());
        uint32_t nextLocation = 0;
        for (const auto& input : stageInputs) {
            vertexCompiler.set_decoration (input.id, spv::DecorationLocation, nextLocation);
            const auto& type = vertexCompiler.get_type (input.type_id);
            output.vertexAttributes.push_back (
                { input.name, nextLocation, type.vecsize, dataBaseSlot + nextLocation });
            ++nextLocation;
        }
    }

    output.vertexMSL = vertexCompiler.compile ();

    for (const auto& attribute : output.vertexAttributes) {
        if (output.vertexMSL.find (attribute.name + " [[attribute(") != std::string::npos) {
            continue;
        }

        const std::string from = attribute.name + ";";
        const std::string to = attribute.name + " [[attribute(" + std::to_string (attribute.location) + ")]];";
        const size_t position = output.vertexMSL.find (from);
        if (position != std::string::npos) {
            output.vertexMSL.replace (position, from.size (), to);
        }
    }

    {
        std::map<std::string, uint32_t> unused;
        parseMSLSignatureSlots (output.vertexMSL, output.vertexUniformSlots, unused, unused);
    }
    const auto uniformSlotLimit = output.vertexAttributes.empty ()
        ? kMetalBufferSlotCount : output.vertexAttributes.front ().bufferIndex;
    compactBufferSlots (output.vertexMSL, output.vertexUniformSlots, uniformSlotLimit);
    rewritePromotedUniformAddressSpace (output.vertexMSL, output.vertexUniformSlots);

    spirv.clear ();
    glslang::GlslangToSpv (*program.getIntermediate (EShLangFragment), spirv);

    spirv_cross::CompilerMSL fragmentCompiler (spirv);
    fragmentCompiler.set_msl_options (mslOptions);
    output.fragmentMSL = fragmentCompiler.compile ();
    parseMSLSignatureSlots (
        output.fragmentMSL,
        output.fragmentUniformSlots,
        output.fragmentTextureSlots,
        output.fragmentSamplerSlots);
    compactBufferSlots (output.fragmentMSL, output.fragmentUniformSlots, kMetalBufferSlotCount);
    rewritePromotedUniformAddressSpace (output.fragmentMSL, output.fragmentUniformSlots);

    JSON encoded {
        { "ok", true },
        { "vertexMSL", output.vertexMSL },
        { "fragmentMSL", output.fragmentMSL },
        { "vertexUniformSlots", output.vertexUniformSlots },
        { "fragmentUniformSlots", output.fragmentUniformSlots },
        { "fragmentTextureSlots", output.fragmentTextureSlots },
        { "fragmentSamplerSlots", output.fragmentSamplerSlots },
        { "vertexAttributes", JSON::array () },
    };

    for (const auto& attribute : output.vertexAttributes) {
        encoded["vertexAttributes"].push_back (
            {
                { "name", attribute.name },
                { "location", attribute.location },
                { "vecSize", attribute.vecSize },
                { "bufferIndex", attribute.bufferIndex },
            });
    }

    return encoded.dump ();
}
} // namespace

char* nsc_compile_shader_pair_to_msl_json (const char* vertex_source, const char* fragment_source) {
    if (vertex_source == nullptr || fragment_source == nullptr) {
        return nullptr;
    }

    try {
        const std::string encoded = compileStageToMSLJSON (vertex_source, fragment_source);
        auto* result = static_cast<char*> (std::malloc (encoded.size () + 1));
        if (result == nullptr) {
            return nullptr;
        }

        std::memcpy (result, encoded.c_str (), encoded.size () + 1);
        return result;
    } catch (const std::exception& error) {
        const std::string encoded = JSON {
            { "ok", false },
            { "error", std::string ("MSL compilation wrapper failed: ") + error.what () },
        }.dump ();
        auto* result = static_cast<char*> (std::malloc (encoded.size () + 1));
        if (result == nullptr) {
            return nullptr;
        }

        std::memcpy (result, encoded.c_str (), encoded.size () + 1);
        return result;
    } catch (...) {
        const std::string encoded = JSON {
            { "ok", false },
            { "error", "MSL compilation wrapper failed: unknown exception" },
        }.dump ();
        auto* result = static_cast<char*> (std::malloc (encoded.size () + 1));
        if (result == nullptr) {
            return nullptr;
        }

        std::memcpy (result, encoded.c_str (), encoded.size () + 1);
        return result;
    }
}

char* nsc_preprocess_shader_source (const char* source, int is_fragment) {
    if (source == nullptr) {
        return nullptr;
    }
    try {
        ensureGlslangProcess ();
        const EShLanguage stage = is_fragment ? EShLangFragment : EShLangVertex;
        glslang::TShader shader (stage);
        shader.setStrings (&source, 1);
        shader.setEnvInput (glslang::EShSourceGlsl, stage, glslang::EShClientOpenGL, 330);
        shader.setEnvClient (glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
        shader.setEnvTarget (glslang::EShTargetSpv, glslang::EShTargetSpv_1_5);
        glslang::TShader::ForbidIncluder includer;
        std::string expanded;
        if (!shader.preprocess (&BuiltInResource, 100, ENoProfile, false, false,
                                EShMsgDefault, &expanded, includer)) {
            return nullptr;
        }
        auto* result = static_cast<char*> (std::malloc (expanded.size () + 1));
        if (result != nullptr) {
            std::memcpy (result, expanded.c_str (), expanded.size () + 1);
        }
        return result;
    } catch (...) {
        return nullptr;
    }
}

void nsc_free_compiler_string (char* value) {
    if (value != nullptr) {
        std::free (value);
    }
}

void nsc_finalize_glslang () {
    if (g_glslangInitialized) {
        glslang::FinalizeProcess ();
        g_glslangInitialized = false;
    }
}
