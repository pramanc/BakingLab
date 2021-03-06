//=================================================================================================
//
//  Baking Lab
//  by MJP and David Neubelt
//  http://mynameismjp.wordpress.com/
//
//  All code licensed under the MIT license
//
//=================================================================================================

//=================================================================================================
// Includes
//=================================================================================================
#include <Constants.hlsl>
#include "EVSM.hlsl"
#include <SH.hlsl>
#include "AppSettings.hlsl"
#include "SG.hlsl"

//=================================================================================================
// Constants
//=================================================================================================
static const uint NumCascades = 4;

//=================================================================================================
// Constant buffers
//=================================================================================================
cbuffer VSConstants : register(b0)
{
    float4x4 World;
	float4x4 View;
    float4x4 WorldViewProjection;
    float4x4 PrevWorldViewProjection;
}

cbuffer PSConstants : register(b0)
{
    float3 SunDirectionWS;
    float CosSunAngularRadius;
    float3 SunIlluminance;
    float SinSunAngularRadius;
    float3 CameraPosWS;
	float4x4 ShadowMatrix;
	float4 CascadeSplits;
    float4 CascadeOffsets[NumCascades];
    float4 CascadeScales[NumCascades];
    float OffsetScale;
    float PositiveExponent;
    float NegativeExponent;
    float LightBleedingReduction;
    float2 RTSize;
    float2 JitterOffset;
    float4 SGDirections[MaxSGCount];
    float SGSharpness;
}

//=================================================================================================
// Resources
//=================================================================================================
Texture2D<float4> AlbedoMap : register(t0);
Texture2D<float2> NormalMap : register(t1);
Texture2D<float> RoughnessMap : register(t2);
Texture2D<float> MetallicMap : register(t3);
Texture2DArray SunShadowMap : register(t4);
Texture2DArray<float4> BakedLightingMap : register(t5);
TextureCube<float> AreaLightShadowMap : register(t6);
Texture3D<float4> SHSpecularLookupA : register(t7);
Texture3D<float2> SHSpecularLookupB : register(t8);

SamplerState AnisoSampler : register(s0);
SamplerState EVSMSampler : register(s1);
SamplerState LinearSampler : register(s2);
SamplerComparisonState PCFSampler : register(s3);

//=================================================================================================
// Input/Output structs
//=================================================================================================
struct VSInput
{
    float3 PositionOS 		    : POSITION;
    float3 NormalOS 		    : NORMAL;
    float2 TexCoord 		    : TEXCOORD0;
    float2 LightMapUV           : TEXCOORD1;
	float3 TangentOS 		    : TANGENT;
	float3 BitangentOS		    : BITANGENT;
};

struct VSOutput
{
    float4 PositionCS 		    : SV_Position;

    float3 NormalWS 		    : NORMALWS;
    float3 PositionWS           : POSITIONWS;
    float DepthVS               : DEPTHVS;
	float3 TangentWS 		    : TANGENTWS;
	float3 BitangentWS 		    : BITANGENTWS;
	float2 TexCoord 		    : TEXCOORD;
    float2 LightMapUV           : LIGHTMAPUV;
    float3 PrevPosition         : PREVPOSITION;
};

struct PSInput
{
    float4 PositionSS 		    : SV_Position;

    float3 NormalWS 		    : NORMALWS;
    float3 PositionWS           : POSITIONWS;
    float DepthVS               : DEPTHVS;
    float3 TangentWS 		    : TANGENTWS;
	float3 BitangentWS 		    : BITANGENTWS;
    float2 TexCoord 		    : TEXCOORD;
    float2 LightMapUV           : LIGHTMAPUV;
    float3 PrevPosition         : PREVPOSITION;
};

struct PSOutput
{
    float4 Lighting             : SV_Target0;
    float2 Velocity             : SV_Target1;
};

//=================================================================================================
// Vertex Shader
//=================================================================================================
VSOutput VS(in VSInput input, in uint VertexID : SV_VertexID)
{
    VSOutput output;

    float3 positionOS = input.PositionOS;

    // Calc the world-space position
    output.PositionWS = mul(float4(positionOS, 1.0f), World).xyz;

    // Calc the clip-space position
    output.PositionCS = mul(float4(positionOS, 1.0f), WorldViewProjection);
    output.DepthVS = output.PositionCS.w;


	// Rotate the normal into world space
    output.NormalWS = normalize(mul(input.NormalOS, (float3x3)World));

	// Rotate the rest of the tangent frame into world space
	output.TangentWS = normalize(mul(input.TangentOS, (float3x3)World));
	output.BitangentWS = normalize(mul(input.BitangentOS, (float3x3)World));

    // Pass along the texture coordinates
    output.TexCoord = input.TexCoord;
    output.LightMapUV = input.LightMapUV;

    output.PrevPosition = mul(float4(input.PositionOS, 1.0f), PrevWorldViewProjection).xyw;

    return output;
}

//-------------------------------------------------------------------------------------------------
// Samples the EVSM shadow map
//-------------------------------------------------------------------------------------------------
float SampleShadowMapEVSM(in float3 shadowPos, in float3 shadowPosDX,
                          in float3 shadowPosDY, uint cascadeIdx)
{
    float2 exponents = GetEVSMExponents(PositiveExponent, NegativeExponent,
                                        CascadeScales[cascadeIdx].xyz);
    float2 warpedDepth = WarpDepth(shadowPos.z, exponents);

    float4 occluder = SunShadowMap.SampleGrad(EVSMSampler, float3(shadowPos.xy, cascadeIdx),
                                            shadowPosDX.xy, shadowPosDY.xy);

    // Derivative of warping at depth
    float2 depthScale = 0.0001f * exponents * warpedDepth;
    float2 minVariance = depthScale * depthScale;

    float posContrib = ChebyshevUpperBound(occluder.xz, warpedDepth.x, minVariance.x, LightBleedingReduction);
    float negContrib = ChebyshevUpperBound(occluder.yw, warpedDepth.y, minVariance.y, LightBleedingReduction);
    float shadowContrib = posContrib;
    shadowContrib = min(shadowContrib, negContrib);

    return shadowContrib;
}

//-------------------------------------------------------------------------------------------------
// Samples the appropriate shadow map cascade
//-------------------------------------------------------------------------------------------------
float3 SampleShadowCascade(in float3 shadowPosition, in float3 shadowPosDX,
                           in float3 shadowPosDY, in uint cascadeIdx)
{
    shadowPosition += CascadeOffsets[cascadeIdx].xyz;
    shadowPosition *= CascadeScales[cascadeIdx].xyz;

    shadowPosDX *= CascadeScales[cascadeIdx].xyz;
    shadowPosDY *= CascadeScales[cascadeIdx].xyz;

    float3 cascadeColor = 1.0f;

    float shadow = SampleShadowMapEVSM(shadowPosition, shadowPosDX, shadowPosDY, cascadeIdx);

    return shadow * cascadeColor;
}

//--------------------------------------------------------------------------------------
// Computes the sun visibility term by performing the shadow test
//--------------------------------------------------------------------------------------
float3 SunShadowVisibility(in float3 positionWS, in float depthVS)
{
	float3 shadowVisibility = 1.0f;
	uint cascadeIdx = 0;

    // Project into shadow space
    float3 samplePos = positionWS;
	float3 shadowPosition = mul(float4(samplePos, 1.0f), ShadowMatrix).xyz;
    float3 shadowPosDX = ddx(shadowPosition);
    float3 shadowPosDY = ddy(shadowPosition);

	// Figure out which cascade to sample from
	[unroll]
	for(uint i = 0; i < NumCascades - 1; ++i)
	{
		[flatten]
		if(depthVS > CascadeSplits[i])
			cascadeIdx = i + 1;
	}

	shadowVisibility = SampleShadowCascade(shadowPosition, shadowPosDX, shadowPosDY,
                                           cascadeIdx);

	return shadowVisibility;
}

//-------------------------------------------------------------------------------------------------
// Computes the area light shadow visibility term
//-------------------------------------------------------------------------------------------------
float AreaLightShadowVisibility(in float3 positionWS)
{
    float3 shadowPos = positionWS - float3(AreaLightX, AreaLightY, AreaLightZ);
    float3 shadowDistance = length(shadowPos);
    float3 shadowDir = normalize(shadowPos);

    // Doing the max of the components tells us 2 things: which cubemap face we're going to use,
    // and also what the projected distance is onto the major axis for that face.
    float projectedDistance = max(max(abs(shadowPos.x), abs(shadowPos.y)), abs(shadowPos.z));

    // Compute the project depth value that matches what would be stored in the depth buffer
    // for the current cube map face. Note that we use a reversed infinite projection.
    float nearClip = AreaLightSize;
    float a = 0.0f;
    float b = nearClip;
    float z = projectedDistance * a + b;
    float dbDistance = z / projectedDistance;

    return AreaLightShadowMap.SampleCmpLevelZero(PCFSampler, shadowDir, dbDistance + AreaLightShadowBias);
}

//-------------------------------------------------------------------------------------------------
// Calculates the lighting result for an analytical light source
//-------------------------------------------------------------------------------------------------
float3 CalcLighting(in float3 normal, in float3 lightDir, in float3 lightColor,
					in float3 diffuseAlbedo, in float3 specularAlbedo, in float roughness,
					in float3 positionWS, inout float3 irradiance)
{
    float3 lighting = diffuseAlbedo * (1.0f / 3.14159f);

    float3 view = normalize(CameraPosWS - positionWS);
    const float nDotL = saturate(dot(normal, lightDir));
    if(nDotL > 0.0f)
    {
        const float nDotV = saturate(dot(normal, view));
        float3 h = normalize(view + lightDir);

        float3 fresnel = Fresnel(specularAlbedo, h, lightDir);

        float specular = GGX_Specular(roughness, normal, h, view, lightDir);
        lighting += specular * fresnel;
    }

    irradiance += nDotL * lightColor;
    return lighting * nDotL * lightColor;
}

// ------------------------------------------------------------------------------------------------
// Computes the irradiance for an SG light source using the selected approximation
// ------------------------------------------------------------------------------------------------
float3 SGIrradiance(in SG lightingLobe, in float3 normal, in int diffuseMode)
{
    if(diffuseMode == SGDiffuseModes_Punctual)
        return SGIrradiancePunctual(lightingLobe, normal);
    else if(diffuseMode == SGDiffuseModes_Fitted)
        return SGIrradianceFitted(lightingLobe, normal);
    else
        return SGIrradianceInnerProduct(lightingLobe, normal);
}

// ------------------------------------------------------------------------------------------------
// Computes the specular contribution from an SG light source
// ------------------------------------------------------------------------------------------------
float3 SpecularTermSG(in SG light, in float3 normal, in float roughness,
                          in float3 view, in float3 specAlbedo)
{
    if(UseASGWarp)
        return SpecularTermASGWarp(light, normal, roughness, view, specAlbedo);
    else
        return SpecularTermSGWarp(light, normal, roughness, view, specAlbedo);
}

// ------------------------------------------------------------------------------------------------
// Determine the exit radiance towards the eye from the SG's stored in the lightmap
// ------------------------------------------------------------------------------------------------
void ComputeSGContribution(in Texture2DArray<float4> bakedLightingMap, in float2 lightMapUV, in float3 normalTS,
                          in float3 specularAlbedo, in float roughness, in float3 viewTS, in uint numSGs,
                          out float3 irradiance, out float3 specular)
{
    irradiance = 0.0f;
    specular = 0.0f;

    for(uint i = 0; i < numSGs; ++i)
    {
        SG sg;
        sg.Amplitude = bakedLightingMap.SampleLevel(LinearSampler, float3(lightMapUV, i), 0.0f).xyz;
        sg.Axis = SGDirections[i].xyz;
        sg.Sharpness = SGSharpness;

        irradiance += SGIrradiance(sg, normalTS, SGDiffuseMode);
        specular += SpecularTermSG(sg, normalTS, roughness, viewTS, specularAlbedo);
    }
}

SH9Color GetSHSpecularBRDF(in float3 viewTS, in float3x3 tangentToWorld, in float3 normalTS,
                           in float3 specularAlbedo, in float sqrtRoughness)
{
    // Make a local coordinate frame in tangent space, with the x-axis
    // aligned with the view direction and the z-axis aligned with the normal
    float3 zBasis = normalTS;
    float3 yBasis = normalize(cross(zBasis, viewTS));
    float3 xBasis = normalize(cross(yBasis, zBasis));
    float3x3 localFrame = float3x3(xBasis, yBasis, zBasis);
    float viewAngle = saturate(dot(normalTS, viewTS));

    // Look up coefficients from the SH lookup texture to make the SH BRDF
    SH9Color shBrdf = (SH9Color)0.0f;

    [unroll]
    for(uint i = 0; i < 3; ++i)
    {
        float4 t0 = SHSpecularLookupA.SampleLevel(LinearSampler, float3(viewAngle, sqrtRoughness, specularAlbedo[i]), 0.0f);
        float2 t1 = SHSpecularLookupB.SampleLevel(LinearSampler, float3(viewAngle, sqrtRoughness, specularAlbedo[i]), 0.0f);
        shBrdf.c[0][i] = t0.x;
        shBrdf.c[2][i] = t0.y;
        shBrdf.c[3][i] = t0.z;
        shBrdf.c[6][i] = t0.w;
        shBrdf.c[7][i] = t1.x;
        shBrdf.c[8][i] = t1.y;
    }

    // Transform the SH BRDF to tangent space
    return RotateSH9(shBrdf, localFrame);
}

//=================================================================================================
// Pixel Shader
//=================================================================================================
PSOutput PS(in PSInput input)
{
	float3 vtxNormal = normalize(input.NormalWS);
    float3 positionWS = input.PositionWS;

    float3 viewWS = normalize(CameraPosWS - positionWS);

    float3 normalWS = vtxNormal;

    float2 uv = input.TexCoord;

	float3 normalTS = float3(0, 0, 1);
	float3 tangentWS = normalize(input.TangentWS);
	float3 bitangentWS = normalize(input.BitangentWS);
	float3x3 tangentToWorld = float3x3(tangentWS, bitangentWS, normalWS);

    if(EnableNormalMaps)
    {
        // Sample the normal map, and convert the normal to world space
        normalTS.xy = NormalMap.Sample(AnisoSampler, uv).xy * 2.0f - 1.0f;
        normalTS.z = sqrt(1.0f - saturate(normalTS.x * normalTS.x + normalTS.y * normalTS.y));
        normalTS = lerp(float3(0, 0, 1), normalTS, NormalMapIntensity);
        normalWS = normalize(mul(normalTS, tangentToWorld));
    }

    float3 viewTS = mul(viewWS, transpose(tangentToWorld));

    // Gather material parameters
    float3 albedoMap = 1.0f;

    if(EnableAlbedoMaps)
        albedoMap = AlbedoMap.Sample(AnisoSampler, uv).xyz;

    float metallic = saturate(MetallicMap.Sample(AnisoSampler, uv));
    float3 diffuseAlbedo = lerp(albedoMap.xyz, 0.0f, metallic) * DiffuseAlbedoScale * EnableDiffuse;
    float3 specularAlbedo = lerp(0.03f, albedoMap.xyz, metallic) * EnableSpecular;

    float sqrtRoughness = RoughnessMap.Sample(AnisoSampler, uv);
    sqrtRoughness *= RoughnessScale;
    float roughness = sqrtRoughness * sqrtRoughness;

    float depthVS = input.DepthVS;

    // Add in the primary directional light
    float3 lighting = 0.0f;
    float3 irradiance = 0.0f;

    if(EnableDirectLighting && EnableSun)
    {
        float3 sunIrradiance = 0.0f;
        float3 sunShadowVisibility = SunShadowVisibility(positionWS, depthVS);
        float3 sunDirection = SunDirectionWS;
        if(SunAreaLightApproximation)
        {
            float3 D = SunDirectionWS;
            float3 R = reflect(-viewWS, normalWS);
            float r = SinSunAngularRadius;
            float d = CosSunAngularRadius;
            float3 DDotR = dot(D, R);
            float3 S = R - DDotR * D;
            sunDirection = DDotR < d ? normalize(d * D + normalize(S) * r) : R;
        }
        lighting += CalcLighting(normalWS, sunDirection, SunIlluminance, diffuseAlbedo, specularAlbedo,
                                 roughness, positionWS, sunIrradiance) * sunShadowVisibility;
        irradiance += sunIrradiance * sunShadowVisibility;
    }

    if(EnableDirectLighting && EnableAreaLight && BakeDirectAreaLight == false)
    {
        float3 areaLightPos = float3(AreaLightX, AreaLightY, AreaLightZ);
        float3 areaLightDir = normalize(areaLightPos - positionWS);
        float areaLightDist = length(areaLightPos - positionWS);
        SG lightLobe = MakeSphereSG(areaLightDir, AreaLightSize, AreaLightColor * FP16Scale, areaLightDist);
        float3 sgIrradiance = SGIrradiance(lightLobe, normalWS, SGDiffuseMode);

        float areaLightVisibility = 1.0f;
        if(EnableAreaLightShadows)
            areaLightVisibility = AreaLightShadowVisibility(positionWS);

        lighting += sgIrradiance * (diffuseAlbedo / Pi) * areaLightVisibility;
        lighting += SpecularTermSG(lightLobe, normalWS, roughness, viewWS, specularAlbedo) * areaLightVisibility;
        irradiance += sgIrradiance * areaLightVisibility;
    }

	// Add in the indirect
    if(EnableIndirectLighting || ViewIndirectSpecular)
    {
        float3 indirectIrradiance = 0.0f;
        float3 indirectSpecular = 0.0f;

        if(BakeMode == BakeModes_Diffuse)
        {
            indirectIrradiance = BakedLightingMap.SampleLevel(LinearSampler, float3(input.LightMapUV, 0.0f), 0.0f).xyz * Pi;
        }
        else if(BakeMode == BakeModes_HL2)
        {
            const float3 BasisDirs[3] =
            {
                float3(-1.0f / sqrt(6.0f), -1.0f / sqrt(2.0f), 1.0f / sqrt(3.0f)),
                float3(-1.0f / sqrt(6.0f), 1.0f / sqrt(2.0f), 1.0f / sqrt(3.0f)),
                float3(sqrt(2.0f / 3.0f), 0.0f, 1.0f / sqrt(3.0f)),
            };

            float weightSum = 0.0f;

            [unroll]
            for(uint i = 0; i < 3; ++i)
            {
                float3 lightMap = BakedLightingMap.SampleLevel(LinearSampler, float3(input.LightMapUV, i), 0.0f).xyz;
                indirectIrradiance += saturate(dot(normalTS, BasisDirs[i])) * lightMap;
            }
        }
        else if(BakeMode == BakeModes_SH4)
        {
            SH4Color shRadiance;

            [unroll]
            for(uint i = 0; i < 4; ++i)
                shRadiance.c[i] = BakedLightingMap.SampleLevel(LinearSampler, float3(input.LightMapUV, i), 0.0f).xyz;

            indirectIrradiance = EvalSH4Irradiance(normalTS, shRadiance);

            SH4Color shSpecularBRDF = ConvertToSH4(GetSHSpecularBRDF(viewTS, tangentToWorld, normalTS, specularAlbedo, sqrtRoughness));
            indirectSpecular = SHDotProduct(shSpecularBRDF, shRadiance);
        }
        else if(BakeMode == BakeModes_SH9)
        {
            SH9Color shRadiance;

            [unroll]
            for(uint i = 0; i < 9; ++i)
                shRadiance.c[i] = BakedLightingMap.SampleLevel(LinearSampler, float3(input.LightMapUV, i), 0.0f).xyz;

            indirectIrradiance = EvalSH9Irradiance(normalTS, shRadiance);

            SH9Color shSpecularBRDF = GetSHSpecularBRDF(viewTS, tangentToWorld, normalTS, specularAlbedo, sqrtRoughness);
            indirectSpecular = SHDotProduct(shSpecularBRDF, shRadiance);
        }
        else if(BakeMode == BakeModes_H4)
        {
            H4Color hbIrradiance;

            [unroll]
            for(uint i = 0; i < 4; ++i)
                hbIrradiance.c[i] = BakedLightingMap.SampleLevel(LinearSampler, float3(input.LightMapUV, i), 0.0f).xyz;

            indirectIrradiance = EvalH4(normalTS, hbIrradiance);
        }
        else if(BakeMode == BakeModes_H6)
        {
            H6Color hbIrradiance;

            [unroll]
            for(uint i = 0; i < 6; ++i)
                hbIrradiance.c[i] = BakedLightingMap.SampleLevel(LinearSampler, float3(input.LightMapUV, i), 0.0f).xyz;

            indirectIrradiance = EvalH6(normalTS, hbIrradiance);
        }
        else if(BakeMode == BakeModes_SG5)
        {
            ComputeSGContribution(BakedLightingMap, input.LightMapUV, normalTS, specularAlbedo, roughness,
                                  viewTS, 5, indirectIrradiance, indirectSpecular);
        }
        else if(BakeMode == BakeModes_SG6)
        {
            ComputeSGContribution(BakedLightingMap, input.LightMapUV, normalTS, specularAlbedo, roughness,
                                  viewTS, 6, indirectIrradiance, indirectSpecular);
        }
        else if(BakeMode == BakeModes_SG9)
        {
            ComputeSGContribution(BakedLightingMap, input.LightMapUV, normalTS, specularAlbedo, roughness,
                                  viewTS, 9, indirectIrradiance, indirectSpecular);
        }
        else if(BakeMode == BakeModes_SG12)
        {
            ComputeSGContribution(BakedLightingMap, input.LightMapUV, normalTS, specularAlbedo, roughness,
                                  viewTS, 12, indirectIrradiance, indirectSpecular);
        }

        if(EnableIndirectDiffuse)
        {
            irradiance += indirectIrradiance;
            lighting += indirectIrradiance * (diffuseAlbedo / Pi);
        }

        if(EnableIndirectSpecular)
            lighting += indirectSpecular;

        if(ViewIndirectSpecular)
            lighting = indirectSpecular;
    }

    float illuminance = dot(irradiance, float3(0.2126f, 0.7152f, 0.0722f));

    PSOutput output;
    output.Lighting =  clamp(float4(lighting, illuminance), 0.0f, FP16Max);

    float2 prevPositionSS = (input.PrevPosition.xy / input.PrevPosition.z) * float2(0.5f, -0.5f) + 0.5f;
    prevPositionSS *= RTSize;
    output.Velocity = input.PositionSS.xy - prevPositionSS;
    output.Velocity -= JitterOffset;
    output.Velocity /= RTSize;

    return output;
}
